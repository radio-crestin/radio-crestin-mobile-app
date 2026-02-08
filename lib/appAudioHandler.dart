import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/tracking.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/utils.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'globals.dart' as globals;

enum PlayerState { started, stopped, playing, buffering, error }

Future<AppAudioHandler> initAudioService({required graphqlClient}) async {
  final AudioPlayer player = AudioPlayer(
    // TODO: enable userAgent to identify users
    // Currently it's disabled because it creates an insecure proxy on localhost to add this header
    // and it's needs more configuration
    // userAgent: 'radiocrestinapp/1.0 (Linux;Android 11) https://www.radio-crestin.com',
  );
  return await AudioService.init(
    builder: () {
      return AppAudioHandler(player: player, graphqlClient: graphqlClient);
    },
    config: const AudioServiceConfig(
      // androidNotificationChannelId: 'com.radiocrestin.radiocrestin.channel.audio',
      androidNotificationChannelName: 'Radio Crestin',
      androidNotificationIcon: "drawable/ic_launcher_foreground",
      androidNotificationOngoing: true,
      notificationColor: Color(0xffe91e63),
      preloadArtwork: true,
      // androidShowNotificationBadge: true,
      androidStopForegroundOnPause: true,
      androidBrowsableRootExtras: {
        'android.media.browse.CONTENT_STYLE_SUPPORTED': true,
        'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2, // grid
        'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 2, // grid
      },
    ),
  );
}

// https://github.com/ryanheise/audio_service/blob/master/audio_service/example/lib/main.dart
// https://github.com/ryanheise/audio_service/blob/81bb480ac2aeaec08cd61c62765529613db60837/audio_service/example/lib/example_playlist.dart
class AppAudioHandler extends BaseAudioHandler {
  final GraphQLClient graphqlClient;
  Timer? timer;
  late StreamSubscription<QueryResult<Query$GetStations>> watchStations;

  Object? error;
  int errorRetryCount = 0;
  final int maxErrorRetryCount = 10;
  int stationStreamSourceIdx = 0;
  bool started = false;
  int? playerIndex;

  // Track loaded stream to avoid unnecessary reconnection on pause/resume
  String? _loadedStreamUrl;
  Timer? _disconnectTimer;
  static const _disconnectDelay = Duration(seconds: 60);

  // Track last emitted mediaItem fields to avoid redundant Android notification updates
  int? _lastEmittedSongId;
  String? _lastEmittedArtUriString;

  final BehaviorSubject<List<Station>> stations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<Station>> filteredStations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> favoriteStationSlugs = BehaviorSubject.seeded([]);
  final BehaviorSubject<Station?> currentStation = BehaviorSubject.seeded(null);
  final BehaviorSubject<List<Query$GetStations$station_groups>> stationGroups =
      BehaviorSubject.seeded(<Query$GetStations$station_groups>[]);
  final BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup =
      BehaviorSubject.seeded(null);
  final BehaviorSubject<List<MediaItem>> stationsMediaItems = BehaviorSubject.seeded(<MediaItem>[]);

  // CarPlay: playlist to cycle through when using skip next/prev (set by CarPlayService)
  List<Station> carPlayPlaylist = [];

  _log(String message) {
    developer.log("AppAudioHandler: $message");
  }

  // Android Auto media browsing support
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    _log("getChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        return _recentSubject.value;
      case "favoriteStationsRootId":
        final favSlugs = favoriteStationSlugs.value;
        return stationsMediaItems.value
            .where((item) => favSlugs.contains(item.extras?["station_slug"]))
            .toList();
      case "allStationsRootId":
        return stationsMediaItems.value;
      default:
        return {
          AudioService.browsableRootId: const [
            MediaItem(
              id: "favoriteStationsRootId",
              title: "Statii Favorite",
              playable: false,
            ),
            MediaItem(
              id: "allStationsRootId",
              title: "Toate Statiile",
              playable: false,
            ),
          ],
        }[parentMediaId] ?? [];
    }
  }

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    _log("subscribeToChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        final stream = _recentSubject.map((_) => <String, dynamic>{});
        return _recentSubject.hasValue
            ? stream.shareValueSeeded(<String, dynamic>{})
            : stream.shareValue();
      case "favoriteStationsRootId":
        final stream = favoriteStationSlugs.map((_) => <String, dynamic>{});
        return favoriteStationSlugs.hasValue
            ? stream.shareValueSeeded(<String, dynamic>{})
            : stream.shareValue();
      default:
        final stream = stationsMediaItems.map((_) => <String, dynamic>{});
        return stationsMediaItems.hasValue
            ? stream.shareValueSeeded(<String, dynamic>{})
            : stream.shareValue();
    }
  }

  bool _hasStationsChanged(List<Station> oldStations, List<Station> newStations) {
    if (oldStations.length != newStations.length) return true;
    for (int i = 0; i < oldStations.length; i++) {
      final o = oldStations[i];
      final n = newStations[i];
      if (o.id != n.id ||
          o.title != n.title ||
          o.songId != n.songId ||
          o.songTitle != n.songTitle ||
          o.totalListeners != n.totalListeners ||
          o.isUp != n.isUp) {
        return true;
      }
    }
    return false;
  }

  final AudioPlayer player;

  // ignore: close_sinks
  final BehaviorSubject<List<MediaItem>> _recentSubject = BehaviorSubject.seeded(<MediaItem>[]);
  static const LAST_PLAYED_MEDIA_ITEM = "last_played_media_item";

  final int maxRetries = 5;
  static const _favoriteStationsKey = 'favoriteStationSlugs';

  AppAudioHandler({required this.graphqlClient, required this.player}) {
    _initPlayer();
    _initFilteredStationsStream();
    _initUpdateCurrentStationMetadata();
    _initFavoriteStationSlugsThenStations();
  }

  Future<void> _initFavoriteStationSlugsThenStations() async {
    await _initFavoriteStationSlugs();
    _setupRefreshStations();
  }

  // Audio Player
  Future<void> _initPlayer() async {
    _log("initPlayer");

    // For Android 11, record the most recent item so it can be resumed.
    mediaItem.whereType<MediaItem>().listen((item) {
      _recentSubject.add([item]);
    });

    // Propagate all events from the audio player to AudioService clients.
    player.playbackEventStream.listen(_broadcastState);

    // In this example, the service stops when reaching the end.
    player.processingStateStream.listen((state) {
      _log("processingStateStream: $state");
      if (state == ProcessingState.completed) stop();
    });

    await player.setLoopMode(LoopMode.off);
  }

  Future<void> selectStation(Station station) async {
    _log('playStation($station)');
    final item = station.mediaItem;

    _lastEmittedSongId = station.songId;
    _lastEmittedArtUriString = item.artUri?.toString();
    mediaItem.add(item);
    currentStation.add(station);

    await setLastPlayedStation(station);

    // Cache the song thumbnail on-demand so notification/lock screen gets a local file
    _cacheSongThumbnail(station);
  }

  void _cacheSongThumbnail(Station station) {
    final songThumbnailUrl = station.rawStationData.now_playing?.song?.thumbnail_url;
    if (songThumbnailUrl != null && songThumbnailUrl.isNotEmpty) {
      ImageCacheService.instance.getOrDownload(songThumbnailUrl).then((file) {
        if (file != null && currentStation.valueOrNull?.id == station.id) {
          // Update mediaItem with local file URI so notification uses cached image
          final currentItem = mediaItem.valueOrNull;
          if (currentItem != null) {
            final localUri = Uri.file(file.path);
            _lastEmittedArtUriString = localUri.toString();
            mediaItem.add(currentItem.copyWith(artUri: localUri));
          }
        }
      });
    }
  }

  Future<void> playStation(Station station) async {
    _log('playStation($station)');

    // Stop and clean up the previous station before starting the new one
    _disconnectTimer?.cancel();
    if (player.playing || player.processingState != ProcessingState.idle) {
      stopListeningTracker();
      await player.stop();
    }
    _loadedStreamUrl = null;

    await selectStation(station);
    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return play();
  }

  List<Station> _getCarPlayPlaylist() {
    if (carPlayPlaylist.isNotEmpty) return carPlayPlaylist;
    return filteredStations.value;
  }

  @override
  Future<void> skipToNext() {
    _log('skipToNext()');
    if (currentStation.value == null) return super.skipToNext();

    final playlist = _getCarPlayPlaylist();
    if (playlist.isEmpty) return super.skipToNext();

    final currentIndex = playlist.indexWhere((s) => s.slug == currentStation.value!.slug);
    final nextIndex = (currentIndex + 1) % playlist.length;
    return playStation(playlist[nextIndex < 0 ? 0 : nextIndex]);
  }

  @override
  Future<void> skipToPrevious() {
    _log('skipToPrevious()');
    if (currentStation.value == null) return super.skipToPrevious();

    final playlist = _getCarPlayPlaylist();
    if (playlist.isEmpty) return super.skipToPrevious();

    final currentIndex = playlist.indexWhere((s) => s.slug == currentStation.value!.slug);
    final prevIndex = currentIndex <= 0 ? playlist.length - 1 : currentIndex - 1;
    return playStation(playlist[prevIndex]);
  }

  @override
  Future<void> skipToQueueItem(int index) {
    _log("skipToQueueItem: $index");
    playStation(stations.value[index]);
    return super.skipToQueueItem(index);
  }

  String addTrackingParametersToUrl(String url) {
    final platform = Platform.isIOS ? "ios" : (Platform.isAndroid ? "android" : "unknown");
    final deviceId = globals.deviceId;
    
    final uri = Uri.parse(url);
    final queryParams = Map<String, String>.from(uri.queryParameters);
    
    queryParams['ref'] = 'radio-crestin-mobile-app-$platform';
    queryParams['s'] = deviceId;
    
    return uri.replace(queryParameters: queryParams).toString();
  }

  @override
  Future<void> play() async {
    _log("play");
    _disconnectTimer?.cancel();

    if (currentStation.value != null) {
      AppTracking.trackPlayStation(currentStation.value!, graphQLClient: graphqlClient);
      AppTracking.trackListenStation(currentStation.value!, currentStreamUrl);
    }
    startListeningTracker();

    var item = mediaItem.valueOrNull;
    final desiredStreamUrl = (item?.extras?["station_streams"] as List<dynamic>?)?.firstOrNull?.toString() ?? item?.id;

    // Fast resume: if the same stream is already loaded, just resume playback
    if (desiredStreamUrl != null &&
        _loadedStreamUrl == desiredStreamUrl &&
        player.processingState != ProcessingState.idle) {
      _log("play: fast resume (stream already loaded)");
      return player.play();
    }

    // Need to load a new stream source
    PerformanceMonitor.startOperation('audio_play');
    var retry = 0;
    var initialStation = currentStation.valueOrNull;

    while (item != null && initialStation == currentStation.valueOrNull) {
      if (retry < maxRetries) {
        final streams = item.extras?["station_streams"] as List<dynamic>?;
        final streamUrl = streams?[retry % (streams?.length ?? 1)]?.toString() ?? item.id;
        _log("play: attempt $retry - $streamUrl");
        try {
          final trackedUrl = addTrackingParametersToUrl(streamUrl);
          await player.setAudioSource(
            AudioSource.uri(Uri.parse(trackedUrl)),
            preload: true,
          ).timeout(const Duration(seconds: 10));
          _loadedStreamUrl = desiredStreamUrl;
          _log("play: source loaded successfully");
          break;
        } catch (e) {
          _log("play: attempt $retry failed - $e");
          _loadedStreamUrl = null;
          retry++;
        }
      } else {
        _log("play: max retries reached");
        _loadedStreamUrl = null;
        PerformanceMonitor.endOperation('audio_play');
        stop();
        return;
      }
    }

    PerformanceMonitor.endOperation('audio_play');
    return player.play();
  }

  @override
  Future<void> pause() async {
    _log("pause");
    if (currentStation.value != null) {
      AppTracking.trackStopStation(currentStation.value!);
    }

    await player.pause();

    // Disconnect after 60s of being paused to save bandwidth.
    // If the user resumes within 60s, play() will fast-resume without reconnecting.
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(_disconnectDelay, () {
      _log("pause: disconnecting idle stream after ${_disconnectDelay.inSeconds}s");
      _loadedStreamUrl = null;
      player.setAudioSource(
        AudioSource.uri(Uri.parse(CONSTANTS.STATIC_MP3_URL)),
        preload: false,
      );
    });

    return super.pause();
  }

  @override
  Future<void> stop() async {
    _log("stop");
    _disconnectTimer?.cancel();
    _loadedStreamUrl = null;
    if (currentStation.value != null) {
      AppTracking.trackStopStation(currentStation.value!);
    }
    stopListeningTracker();
    await player.stop();
    return super.stop();
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) {
    _log('playFromSearch($query, $extras)');

    var maxR = 0;
    late Station selectedStation;
    for (var v in stations.value) {
      var r = partialRatio(v.title, query);
      if (r > maxR) {
        maxR = r;
        selectedStation = v;
      }
    }
    if (maxR > 0) {
      return playStation(selectedStation);
    } else {
      return playStation(stations.value[0]);
    }
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) {
    for (var v in stations.value) {
      if (v.stationStreams.toString().contains(uri.toString())) {
        return playStation(v);
      }
    }
    return super.playFromUri(uri);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    _log('playMediaItem($mediaItem)');
    playStation(
        stations.value.firstWhere((element) => element.id == mediaItem.extras?["station_id"]));
  }

  // Metadata refresh
  void _broadcastState(PlaybackEvent event) {
    // Avoid logging on every playback event for performance
    final playing = player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        // MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        // We're using ready here to not interupt Android Auto playback when going to next/previous station
        ProcessingState.idle: AudioProcessingState.ready,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: playerIndex,
    ));
  }

  Future<void> refreshStations() async {
    _log("Manually refreshing stations");
    try {
      final result = await graphqlClient.query(
        Options$Query$GetStations(
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );
      final parsedData = result.parsedData;
      if (parsedData != null) {
        stations.add((parsedData.stations)
            .map((rawStationData) => Station(rawStationData: rawStationData))
            .toList());
        stationGroups.add(parsedData.station_groups);
        _preCacheStationThumbnails();
      }
    } catch (e) {
      _log("Error refreshing stations: $e");
    }
  }

  void _setupRefreshStations() async {
    _log("Starting to fetch stations");
    PerformanceMonitor.startOperation('initial_stations_fetch');
    final parsedData = (await graphqlClient.query(Options$Query$GetStations())).parsedData;
    stations.add((parsedData?.stations ?? [])
        .map((rawStationData) => Station(
            rawStationData: rawStationData))
        .toList());
    stationGroups.add(parsedData?.station_groups ?? []);
    PerformanceMonitor.endOperation('initial_stations_fetch');

    // Pre-cache station thumbnails (stable URLs, ~50-150 stations)
    _preCacheStationThumbnails();

    watchStations = graphqlClient
        .watchQuery$GetStations(
          WatchOptions$Query$GetStations(
            fetchPolicy: FetchPolicy.cacheAndNetwork,
            errorPolicy: ErrorPolicy.all,
            cacheRereadPolicy: CacheRereadPolicy.ignoreAll,
            pollInterval: const Duration(seconds: 5),
            fetchResults: true,
          ),
        )
        .stream
        .listen((event) async {
      _log("Done fetching stations");
      final parsedData = event.parsedData;
      if (parsedData == null) {
        _log("No data");
        return;
      }
      final newStations = (parsedData.stations)
          .map((rawStationData) => Station(rawStationData: rawStationData))
          .toList();

      // Only emit if station data actually changed (avoid redundant rebuilds)
      if (_hasStationsChanged(stations.value, newStations)) {
        stations.add(newStations);
        stationGroups.add(parsedData.station_groups);
        _preCacheStationThumbnails();
      } else {
        _log("Stations unchanged, skipping update");
      }
    });
  }

  void _preCacheStationThumbnails() {
    final urls = stations.value
        .where((s) => s.thumbnailUrl != null && s.thumbnailUrl!.isNotEmpty)
        .map((s) => s.thumbnailUrl!)
        .toList();
    if (urls.isEmpty) return;
    // Fire-and-forget: pre-cache in background
    ImageCacheService.instance.preCacheUrls(urls);
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    _log('getMediaItem($mediaId)');
    final result = await super.getMediaItem(mediaId);
    _log('getMediaItem -> $result');
    return result;
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    _log('search($query, $extras)');
    final result = await super.search(query, extras);
    _log('search -> $result');
    return result;
  }

  @override
  Future<void> onTaskRemoved() {
    _log('onTaskRemoved()');
    _disconnectTimer?.cancel();
    _loadedStreamUrl = null;
    stopListeningTracker();
    player.stop();
    // player.dispose();
    watchStations.cancel();
    return super.onTaskRemoved();
  }

  // Method to completely stop and cleanup the audio service
  Future<void> dispose() async {
    _log('dispose()');
    _disconnectTimer?.cancel();
    _loadedStreamUrl = null;
    stopListeningTracker();
    await player.stop();
    await player.dispose();
    watchStations.cancel();
    await super.stop();
  }

  @override
  Future<void> prepareFromSearch(String query, [Map<String, dynamic>? extras]) {
    _log('prepareFromSearch($query, $extras)');
    return super.prepareFromSearch(query, extras);
  }

  @override
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]) {
    _log('prepareFromSearch($uri, $extras)');
    return super.prepareFromUri(uri, extras);
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) {
    _log('click($button)');
    return super.click(button);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) {
    _log('playFromMediaId($mediaId, $extras)');
    final selectedMediaItem = stationsMediaItems.value.firstWhere((item) => item.id == mediaId);
    return playMediaItem(selectedMediaItem);
  }

  // Events Tracking
  void startListeningTracker() {
    timer?.cancel();
    timer = Timer.periodic(
        const Duration(seconds: 5),
        (Timer t) => {
              if (currentStation.value != null && player.playing)
                {AppTracking.trackListenStation(currentStation.value!, currentStreamUrl)}
            });
  }

  void stopListeningTracker() {
    timer?.cancel();
  }

  String get currentStreamUrl {
    return mediaItem.value?.id ?? "-";
  }

  // Last played station
  setLastPlayedStation(Station station) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(LAST_PLAYED_MEDIA_ITEM, station.slug);
  }

  Future<Station> getLastPlayedStation() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    var stationSlug = prefs.getString(LAST_PLAYED_MEDIA_ITEM);
    return stations.value.firstWhere(
      (station) => station.slug == stationSlug,
      orElse: () => stations.value.first,
    );
  }

  // Favorite Stations
  Future<void> _initFavoriteStationSlugs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? favoriteJson = prefs.getString(_favoriteStationsKey);
    List<String> newFavoriteStationSlugs = [];
    if (favoriteJson != null) {
      newFavoriteStationSlugs = List<String>.from(json.decode(favoriteJson));
    }
    favoriteStationSlugs.add(newFavoriteStationSlugs);

  }

  Future<void> setStationIsFavorite(Station station, bool isFavorite) async {
    developer.log("setStationIsFavorite: ${station.slug} $isFavorite");
    if (isFavorite) {
      favoriteStationSlugs.add([...favoriteStationSlugs.value, station.slug]);
    } else {
      favoriteStationSlugs
          .add(favoriteStationSlugs.value.where((slug) => slug != station.slug).toList());
    }


    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_favoriteStationsKey, json.encode(favoriteStationSlugs.value));
    Utils.incrementActionsMade(
      graphQLClient: graphqlClient,
      currentStationName: currentStation.valueOrNull?.title,
    );
  }


  void _initFilteredStationsStream() {
    final combinedStream =
        Rx.combineLatest2<Query$GetStations$station_groups?, List<Station>, List<Station>>(
      selectedStationGroup.stream, // Use the stream property
      stations.stream, // Use the stream property
      (selectedGroup, allStations) {
        allStations.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        if (selectedGroup == null) {
          return allStations;
        }
        selectedGroup.station_to_station_groups.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        final selectedStationsIds =
            selectedGroup.station_to_station_groups.map((e) => e.station_id);
        return allStations.where((station) {
          return selectedStationsIds.contains(station.id);
        }).toList();
      },
    );
    // Subscribe to the combined stream and update the filteredStationsSubject BehaviorSubject.
    combinedStream.listen((filteredStationsList) {
      filteredStations.add(filteredStationsList);
    });
  }

  void _initUpdateCurrentStationMetadata() {
    stations.stream.listen((stations) {
      _log("updateCurrentStationMetadata");
      final sortedStations = stations..sort((a, b) => a.order.compareTo(b.order));

      Station? updatedCurrentStation;
      if(currentStation.valueOrNull != null) {
        updatedCurrentStation = stations.firstWhere((element) => element.id == currentStation.value!.id);
        currentStation.add(updatedCurrentStation);
      }

      final newStationsMediaItems =
          sortedStations.map((station) => station.mediaItem).toList();

      stationsMediaItems.add(newStationsMediaItems);

      // Update current metadata only if it actually changed
      if (mediaItem.value != null && updatedCurrentStation != null) {
        final newSongId = updatedCurrentStation.songId;
        final newArtUri = updatedCurrentStation.artUri.toString();

        final songChanged = newSongId != _lastEmittedSongId;
        final artChanged = newArtUri != _lastEmittedArtUriString;

        if (songChanged || artChanged) {
          final newMediaItem =
              newStationsMediaItems.where((item) => item.id == mediaItem.value?.id).firstOrNull;
          if (newMediaItem != null) {
            _lastEmittedSongId = newSongId;
            _lastEmittedArtUriString = newMediaItem.artUri?.toString();
            mediaItem.add(newMediaItem);
          }

          // Cache the new song thumbnail so Android notification gets a local file
          if (songChanged) {
            _cacheSongThumbnail(updatedCurrentStation);
          }
        }
      }
    });
  }
}
