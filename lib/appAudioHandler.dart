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
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/tracking.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extended_image/extended_image.dart';

import 'components/NotificationBanner.dart';
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

  final BehaviorSubject<List<Station>> stations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<Station>> filteredStations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> favoriteStationSlugs = BehaviorSubject.seeded([]);
  final BehaviorSubject<Station?> currentStation = BehaviorSubject.seeded(null);
  final BehaviorSubject<List<Query$GetStations$station_groups>> stationGroups =
      BehaviorSubject.seeded(<Query$GetStations$station_groups>[]);
  final BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup =
      BehaviorSubject.seeded(null);
  final BehaviorSubject<List<MediaItem>> stationsMediaItems = BehaviorSubject.seeded(<MediaItem>[]);

  _log(String message) {
    developer.log("AppAudioHandler: $message");
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
    _initFavoriteStationSlugs();
    _setupRefreshStations();
  }

  // Android Auto
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    _log("getChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        // When the user resumes a media session, tell the system what the most
        // recently played item was.
        return _recentSubject.value;
      default:
        return {
          AudioService.browsableRootId: const [
            MediaItem(
              id: "radioStationsRootId",
              title: "Statii Radio",
              playable: false,
            ),
          ],
          "radioStationsRootId": stationsMediaItems.value,
        }[parentMediaId]!;
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
      default:
        return Stream.value({
          AudioService.browsableRootId: const [
            MediaItem(
              id: "radioStationsRootId",
              title: "Radiouri Crestine",
              playable: false,
            ),
          ],
          "radioStationsRootId": stationsMediaItems.value,
        }[parentMediaId]!)
            .map((_) => <String, dynamic>{})
            .shareValue();
    }
  }

  // Audio Player
  Future<void> _initPlayer() async {
    _log("initPlayer");

    // For Android 11, record the most recent item so it can be resumed.
    mediaItem.whereType<MediaItem>().listen((item) {
      _recentSubject.add([item]);
    });

    // Propagate all events from the audio player to AudioService clients.
    player.playbackEventStream.listen(_broadcastState, onError: (error) {
      _log("Player stream error: $error");
      globals.appStore?.handleError(error);
      stop();
    });

    // In this example, the service stops when reaching the end.
    player.processingStateStream.listen((state) {
      _log("processingStateStream: $state");
      if (state == ProcessingState.completed) stop();
    });

    await player.setLoopMode(LoopMode.off);
  }

  Future<void> selectStation(Station station) async {
    _log('playStation($station)');
    final item = await station.mediaItem;

    mediaItem.add(item);
    currentStation.add(station);

    await setLastPlayedStation(station);
  }

  Future<void> playStation(Station station) async {
    _log('playStation($station)');
    await selectStation(station);
    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return play();
  }

  @override
  Future<void> skipToNext() {
    _log('skipToNext()');
    if (currentStation.value != null) {
      final currentStationIndex = filteredStations.value.indexWhere((s) {
        return s.rawStationData.id == currentStation.value!.id;
      });
      if (currentStationIndex < filteredStations.value.length - 1) {
        return playStation(filteredStations.value[currentStationIndex + 1]);
      } else {
        return playStation(filteredStations.value[0]);
      }
    }
    return super.skipToNext();
  }

  @override
  Future<void> skipToPrevious() {
    _log('skipToPrevious()');
    if (mediaItem.value != null) {
      final currentStationIndex = filteredStations.value.indexWhere((s) {
        return s.rawStationData.id == currentStation.value!.id;
      });
      if (currentStationIndex > 0) {
        return playStation(filteredStations.value[currentStationIndex - 1]);
      } else {
        return playStation(filteredStations.value[filteredStations.value.length - 1]);
      }
    }
    return super.skipToPrevious();
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
    if (currentStation.value != null) {
      AppTracking.trackPlayStation(currentStation.value!, graphQLClient: graphqlClient);
      AppTracking.trackListenStation(currentStation.value!, currentStreamUrl);
    }
    startListeningTracker();

    var retry = 0;
    var item = mediaItem.valueOrNull;
    var initialStation = currentStation.valueOrNull;
    while (item != null && initialStation == currentStation.valueOrNull) {
      if (retry < maxRetries) {
        final streamUrl = item.extras?["station_streams"]
        [retry % item.extras?["station_streams"].length] ??
            item.id;
        _log("playMediaItem: $streamUrl");
        try {
          final trackedUrl = addTrackingParametersToUrl(streamUrl);
          await player.setAudioSource(
            AudioSource.uri(Uri.parse(trackedUrl)),
            preload: true,
          );
          break;
        } catch (e) {
          _log("playMediaItem: Player Error: $e");
          retry++;
          if (retry >= maxRetries) {
            _log("playMediaItem: max retries reached");
            globals.appStore?.handleError(e);
            stop();
            return;
          }
        }
      }
    }

    return player.play();
  }

  @override
  Future<void> pause() async {
    _log("pause");
    if (currentStation.value != null) {
      AppTracking.trackStopStation(currentStation.value!);
    }

    /**
     * We switch the audio source to a static mp3 file to stop downloading the HLS stream while is on pause.
     * This is to save bandwidth and battery.
     *
     * And we switch back to HLS when pressing play.
     */

    await player.pause();
    await player.setAudioSource(AudioSource.uri(Uri.parse(CONSTANTS.STATIC_MP3_URL)),
        preload: false);
    return super.pause();
  }

  @override
  Future<void> stop() async {
    _log("stop");
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
    _log("_broadcastState: $event, player.processingState: ${player.processingState}");
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
            .map((rawStationData) => Station(
                rawStationData: rawStationData,
                isFavorite: favoriteStationSlugs.value.contains(rawStationData.slug)))
            .toList());
        stationGroups.add(parsedData.station_groups);
        loadThumbnailsInCache();
      }
    } catch (e) {
      _log("Error refreshing stations: $e");
    }
  }

  void _setupRefreshStations() async {
    _log("Starting to fetch stations");
    final parsedData = (await graphqlClient.query(Options$Query$GetStations())).parsedData;
    stations.add((parsedData?.stations ?? [])
        .map((rawStationData) => Station(
            rawStationData: rawStationData,
            isFavorite: favoriteStationSlugs.value.contains(rawStationData.slug)))
        .toList());
    stationGroups.add(parsedData?.station_groups ?? []);

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
      stations.add((parsedData.stations)
          .map((rawStationData) => Station(
              rawStationData: rawStationData,
              isFavorite: favoriteStationSlugs.value.contains(rawStationData.slug)))
          .toList());
      stationGroups.add(parsedData.station_groups);

      loadThumbnailsInCache();
    });
  }

  void loadThumbnailsInCache() {
    _log("Loading thumbnails in cache");
    for (var station in stations.value) {
      // Preload and cache the station thumbnail URL (used as fallback)
      if (station.thumbnailUrl != null && station.thumbnailUrl!.isNotEmpty) {
        // Force the image to load and cache by using ExtendedNetworkImageProvider
        final provider = ExtendedNetworkImageProvider(station.thumbnailUrl!, cache: true);
        provider.resolve(const ImageConfiguration())
          .addListener(ImageStreamListener(
            (_, __) {}, 
            onError: (error, _) => _log("Failed to cache thumbnail: ${station.thumbnailUrl}")
          ));
      }
    }
    _log("Done loading thumbnails in cache");
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
    stopListeningTracker();
    player.stop();
    // player.dispose();
    watchStations.cancel();
    return super.onTaskRemoved();
  }

  // Method to completely stop and cleanup the audio service
  Future<void> dispose() async {
    _log('dispose()');
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
  _initFavoriteStationSlugs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? favoriteJson = prefs.getString(_favoriteStationsKey);
    List<String> newFavoriteStationSlugs = [];
    if (favoriteJson != null) {
      newFavoriteStationSlugs = List<String>.from(json.decode(favoriteJson));
    }
    favoriteStationSlugs.add(newFavoriteStationSlugs);
    updateStationsFavoriteStatus();
  }

  Future<void> setStationIsFavorite(Station station, bool isFavorite) async {
    developer.log("setStationIsFavorite: ${station.slug} $isFavorite");
    if (isFavorite) {
      favoriteStationSlugs.add([...favoriteStationSlugs.value, station.slug]);
    } else {
      favoriteStationSlugs
          .add(favoriteStationSlugs.value.where((slug) => slug != station.slug).toList());
    }
    updateStationsFavoriteStatus();

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_favoriteStationsKey, json.encode(favoriteStationSlugs.value));
    Utils.incrementActionsMade(
      graphQLClient: graphqlClient,
      currentStationName: currentStation.valueOrNull?.title,
    );
  }

  updateStationsFavoriteStatus() {
    stations.add(stations.value.map((station) {
      station.isFavorite = favoriteStationSlugs.value.contains(station.slug);
      return station;
    }).toList());

    if (currentStation.value != null) {
      currentStation
          .add(stations.value.firstWhere((station) => station.slug == currentStation.value!.slug));
    }
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
    stations.stream.listen((stations) async {
      _log("updateCurrentStationMetadata");
      final sortedStations = stations..sort((a, b) => a.order.compareTo(b.order));

      if(currentStation.valueOrNull != null) {
        currentStation.add(stations.firstWhere((element) => element.id == currentStation.value!.id));
      }

      final newStationsMediaItems =
          (await Future.wait(sortedStations.map((station) => station.mediaItem)));

      stationsMediaItems.add(newStationsMediaItems);

      // Update current metadata of played media item
      if (mediaItem.value != null) {
        var newMediaItems = stationsMediaItems.value;
        var newMediaItem =
            newMediaItems.where((item) => item.id == mediaItem.value?.id).firstOrNull;
        if (newMediaItem != null) {
          mediaItem.add(newMediaItem);
        }
      }
    });
  }
}
