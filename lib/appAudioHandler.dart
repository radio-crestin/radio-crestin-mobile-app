import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/tracking.dart';
import 'package:radio_crestin/utils.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';

enum PlayerState { started, stopped, playing, buffering, error }

Future<AppAudioHandler> initAudioService({required graphqlClient}) async {
  return await AudioService.init(
    builder: () {
      final AudioPlayer player = AudioPlayer(
          // TODO: enable userAgent to identify users
          // Currently it's disabled because it creates an insecure proxy on localhost to add this header
          // and it's needs more configuration
          // userAgent: 'radiocrestinapp/1.0 (Linux;Android 11) https://www.radio-crestin.com',
          );
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
      // androidStopForegroundOnPause: true,
    ),
  );
}

// https://github.com/ryanheise/audio_service/blob/master/audio_service/example/lib/main.dart
// https://github.com/ryanheise/audio_service/blob/81bb480ac2aeaec08cd61c62765529613db60837/audio_service/example/lib/example_playlist.dart
class AppAudioHandler extends BaseAudioHandler {
  final GraphQLClient graphqlClient;
  List<Query$GetStations$stations> stations =
      List<Query$GetStations$stations>.empty(growable: true);
  var _timer;

  Object? error;
  int errorRetryCount = 0;
  final int maxErrorRetryCount = 10;
  int stationStreamSourceIdx = 0;
  bool started = false;
  int? playerIndex;
  bool onOpenEventTriggered = false;

  var _watchStations;

  final BehaviorSubject<List<MediaItem>> stationsMediaItems = BehaviorSubject.seeded(<MediaItem>[]);

  _log(String message) {
    developer.log("AppAudioHandler: $message");
  }

  final AudioPlayer player;

  // ignore: close_sinks
  final BehaviorSubject<List<MediaItem>> _recentSubject = BehaviorSubject.seeded(<MediaItem>[]);
  final LAST_PLAYED_MEDIA_ITEM = "last_played_media_item";

  final int maxRetries = 5;

  AppAudioHandler({required this.graphqlClient, required AudioPlayer this.player}) {
    _init();
    _setupRefreshStations();
  }

  Future<void> _init() async {
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

  @override
  Future<void> skipToNext() {
    _log('skipToNext()');
    if (mediaItem.value != null) {
      final currentMediaItemIndex = stationsMediaItems.value.indexOf(mediaItem.value!);
      if (currentMediaItemIndex < stationsMediaItems.value.length - 1) {
        return playMediaItem(stationsMediaItems.value[currentMediaItemIndex + 1]);
      } else {
        return playMediaItem(stationsMediaItems.value[0]);
      }
    }
    return super.skipToNext();
  }

  @override
  Future<void> skipToPrevious() {
    _log('skipToPrevious()');
    if (mediaItem.value != null) {
      var currentMediaItemIndex = stationsMediaItems.value.indexOf(mediaItem.value!);
      if (currentMediaItemIndex > 0) {
        return playMediaItem(stationsMediaItems.value[currentMediaItemIndex - 1]);
      } else {
        return playMediaItem(stationsMediaItems.value[stationsMediaItems.value.length - 1]);
      }
    }
    return super.skipToPrevious();
  }

  @override
  Future<void> skipToQueueItem(int index) {
    _log("skipToQueueItem: $index");
    playMediaItem(stationsMediaItems.value[index]);
    return super.skipToQueueItem(index);
  }

  @override
  Future<void> play() {
    _log("play");
    if (currentStation != null) {
      AppTracking.trackPlayStation(currentStation!);
      AppTracking.trackListenStation(currentStation!, currentStreamUrl);
    }
    startListeningTracker();

    // Switch the audio source back to the HLS stream when playing
    player.setAudioSource(AudioSource.uri(Uri.parse(currentStreamUrl)), preload: true);

    return player.play();
  }

  @override
  Future<void> pause() async {
    _log("pause");
    if (currentStation != null) {
      AppTracking.trackStopStation(currentStation!);
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
    return pause();
  }

  /// Broadcasts the current state to all clients.
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

  void _setupRefreshStations() async {
    _log("Starting to fetch stations");
    stations = (await graphqlClient.query(Options$Query$GetStations())).parsedData?.stations ?? [];
    updateStationsMediaItems(stations);

    _watchStations = graphqlClient
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
      stations = parsedData.stations;
      await updateStationsMediaItems(stations);
      if (!onOpenEventTriggered) {
        // mediaItem.add(await getLastPlayedMediaItem());
        playMediaItem(await getLastPlayedMediaItem());
        onOpenEventTriggered = true;
      }
      loadThumbnailsInCache();
    });
  }

  void loadThumbnailsInCache() {
    _log("Loading thumbnails in cache");
    for (var station in stations) {
      if (station.thumbnail_url != null) {
        Utils.displayImage(station.thumbnail_url!, cache: true);
      }
    }
    _log("Done loading thumbnails in cache");
  }

  Future<void> updateStationsMediaItems(List<Query$GetStations$stations> stations) async {
    _log("updatePlaylistWithStationsData");

    // iterate stations and extract metadata
    final newStationsMediaItems = <MediaItem>[];
    for (var station in stations) {
      newStationsMediaItems.add(await Utils.getStationMetadata(station));
    }
    newStationsMediaItems.sort((a, b) {
      return a.title.compareTo(b.title);
    });

    stationsMediaItems.add(newStationsMediaItems);
    // queue.add(stationsMediaItems);

    // Update current played media item
    if (mediaItem.value != null) {
      var newMediaItems = stationsMediaItems.value;
      var newMediaItem = newMediaItems.where((item) => item.id == mediaItem.value?.id).firstOrNull;
      if (newMediaItem != null) {
        mediaItem.add(newMediaItem);
      }
    }
  }

  Query$GetStations$stations? get currentStation {
    if (mediaItem.value != null) {
      return stations.firstWhere((element) => element.id == mediaItem.value!.extras?["station_id"]);
    } else {
      // Handle the case when either 'stations' or 'mediaItem.value' is null
      return null; // Or provide a default value or error handling as needed
    }
  }

  void startListeningTracker() {
    _timer?.cancel();
    _timer = Timer.periodic(
        const Duration(seconds: 5),
        (Timer t) => {
              if (currentStation != null && player.playing)
                {AppTracking.trackListenStation(currentStation!, currentStreamUrl)}
            });
  }

  void stopListeningTracker() {
    _timer?.cancel();
  }

  String get currentStreamUrl {
    return mediaItem.value?.id ?? "-";
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) {
    _log('playFromSearch($query, $extras)');

    var maxR = 0;
    var selectedStationMediaItem;
    for (var v in stationsMediaItems.value) {
      var r = partialRatio(v.title, query);
      if (r > maxR) {
        maxR = r;
        selectedStationMediaItem = v;
      }
    }
    if (maxR > 0) {
      return playMediaItem(selectedStationMediaItem);
    } else {
      return playMediaItem(stationsMediaItems.value[0]);
    }
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) {
    for (var v in stationsMediaItems.value) {
      if (v.id.toString() == uri.toString()) {
        return playMediaItem(v);
      }
    }
    return super.playFromUri(uri);
  }

  @override
  Future<void> playMediaItem(MediaItem item) async {
    _log('playMediaItem($item)');
    var retry = 0;

    mediaItem.add(item);
    await setLastPlayedMediaItem(item);

    while (true) {
      if (retry < maxRetries) {
        final streamUrl = item.extras?["station_streams"]
                [retry % item.extras?["station_streams"].length] ??
            item.id;
        _log("playMediaItem: $streamUrl");
        try {
          await player.setAudioSource(
            AudioSource.uri(Uri.parse(streamUrl)),
            preload: true,
          );
          break;
        } catch (e) {
          _log("playMediaItem: Player Error: $e");
          retry++;
        }
      } else {
        _log("playMediaItem: max retries reached");
        stop();
        break;
      }
    }
    return play();
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
    stop();
    // player.dispose();
    _watchStations?.cancel();
    return super.onTaskRemoved();
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

  setLastPlayedMediaItem(MediaItem mediaItem) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(LAST_PLAYED_MEDIA_ITEM, mediaItem.extras?['station_slug']);
  }

  Future<MediaItem> getLastPlayedMediaItem() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    var mediaItemSlug = prefs.getString(LAST_PLAYED_MEDIA_ITEM);
    return stationsMediaItems.value.firstWhere(
      (item) => item.extras?['station_slug'] == mediaItemSlug,
      orElse: () => stationsMediaItems.value.first,
    );
  }

  Future<void> setMediaItemIsFavorite(MediaItem item, bool isFavorite) async {
    Query$GetStations$stations station =
        stations.firstWhere((s) => s.slug == item.extras?['station_slug']);

    developer.log("setMediaItemIsFavorite: ${station.slug} $isFavorite");
    Utils.setStationIsFavorite(station, isFavorite);
    Utils.incrementActionsMade();
    await updateStationsMediaItems(stations);
  }
}
