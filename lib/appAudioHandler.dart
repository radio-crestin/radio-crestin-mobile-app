import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:fast_cached_network_image/fast_cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/tracking.dart';
import 'package:radio_crestin/utils.dart';
import 'dart:developer' as developer;

import 'package:rxdart/rxdart.dart';
import 'package:flutter/material.dart';

enum PlayerState { started, stopped, playing, buffering, error }

Future<AppAudioHandler> initAudioService({required graphqlClient}) async {
  return await AudioService.init(
    builder: () => AppAudioHandler(graphqlClient: graphqlClient),
    config: const AudioServiceConfig(
      // androidNotificationChannelId: 'com.radiocrestin.radiocrestin.channel.audio',
      androidNotificationChannelName: 'Radio Crestin',
      androidNotificationIcon: "drawable/ic_launcher_foreground",
      androidNotificationOngoing: true,
      notificationColor: Color(0xffe91e63),
      preloadArtwork: true,
      androidShowNotificationBadge: true,
      androidStopForegroundOnPause: true,
    ),
  );
}

class QueueState {
  final List<MediaItem> queue;
  final MediaItem? mediaItem;

  const QueueState(this.queue, this.mediaItem);
}

// https://github.com/ryanheise/audio_service/blob/master/audio_service/example/lib/main.dart
// https://github.com/ryanheise/audio_service/blob/81bb480ac2aeaec08cd61c62765529613db60837/audio_service/example/lib/example_playlist.dart
class AppAudioHandler extends BaseAudioHandler with QueueHandler {
  final GraphQLClient graphqlClient;
  List<Query$GetStations$stations> stations =
      List<Query$GetStations$stations>.empty(growable: true);
  List<MediaItem> stationsMediaItems = List<MediaItem>.empty(growable: true);
  var _timer;

  Object? error;
  int errorRetryCount = 0;
  final int maxErrorRetryCount = 10;
  int stationStreamSourceIdx = 0;
  bool started = false;
  int? _playerIndex = null;

  final AudioPlayer _player = AudioPlayer(
      // TODO: enable userAgent to identify users
      // Currently it's disabled because it creates an insecure proxy on localhost to add this header
      // and it's needs more configuration
      // userAgent: 'radiocrestinapp/1.0 (Linux;Android 11) https://www.radio-crestin.com',
      );

  // ignore: close_sinks
  final BehaviorSubject<List<MediaItem>> _recentSubject =
      BehaviorSubject.seeded(<MediaItem>[]);

  final int maxRetries = 5;

  AppAudioHandler({required this.graphqlClient}) {
    _init();
    _setupRefreshStations();
  }

  Future<void> _init() async {
    // For Android 11, record the most recent item so it can be resumed.
    mediaItem
        .whereType<MediaItem>()
        .listen((item) => _recentSubject.add([item]));

    // Propagate all events from the audio player to AudioService clients.
    _player.playbackEventStream.listen(_broadcastState);

    // In this example, the service stops when reaching the end.
    _player.processingStateStream.listen((state) {
      developer.log("processingStateStream: $state");
      if (state == ProcessingState.completed) stop();
    });

    await _player.setLoopMode(LoopMode.off);
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    developer.log("getChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        // When the user resumes a media session, tell the system what the most
        // recently played item was.
        return _recentSubject.value;
      default:
        return stationsMediaItems;
    }
  }

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    developer.log("subscribeToChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        final stream = _recentSubject.map((_) => <String, dynamic>{});
        return _recentSubject.hasValue
            ? stream.shareValueSeeded(<String, dynamic>{})
            : stream.shareValue();
      default:
        return Stream.value(stationsMediaItems)
            .map((_) => <String, dynamic>{})
            .shareValue();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    developer.log('starting to skip to $index');
    // Then default implementations of skipToNext and skipToPrevious provided by
    // the [QueueHandler] mixin will delegate to this method.
    if (index < 0 || index >= queue.value.length) return;

    _playerIndex = index;
    mediaItem.add(queue.value[index]);
    await seek(Duration.zero, index: index);
  }

  @override
  Future<void> play() {
    developer.log("play: ${_player.currentIndex}");
    if (_player.currentIndex != null) {
      AppTracking.trackPlayStation(currentStation!);
      AppTracking.trackListenStation(currentStation!, currentStreamUrl);
    }
    startListeningTracker();
    return _player.play();
  }

  @override
  Future<void> pause() {
    developer.log("pause");
    return stop();
  }

  @override
  Future<void> seek(final Duration? position, {int? index}) {
    developer.log("seek: $position $index");
    _playerIndex = index ?? 0;
    stopListeningTracker();
    return setAudioSource(index ?? 0);
  }

  @override
  Future<void> stop() async {
    AppTracking.trackStopStation(currentStation!);
    await _player.pause();
    await _player.stop();
    await playbackState.firstWhere((state) => state.processingState == AudioProcessingState.idle);
  }

  /// Broadcasts the current state to all clients.
  void _broadcastState(PlaybackEvent event) {
    developer.log("_broadcastState: $event");
    final playing = _player.playing;
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
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _playerIndex,
    ));
  }

  void _setupRefreshStations() async {
    developer.log("Starting to fetch stations");
    stations = (await graphqlClient.query(Options$Query$GetStations()))
            .parsedData
            ?.stations ??
        [];
    updateStationsMediaItems(stations, true);

    graphqlClient
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
        .listen((event) {
      developer.log("Done fetching stations");
      final parsedData = event.parsedData;
      if (parsedData == null) {
        developer.log("No data");
        return;
      }
      stations = parsedData.stations;
      updateStationsMediaItems(stations, false);
      loadThumbnailsInCache();
    });
  }

  void loadThumbnailsInCache() {
    developer.log("Loading thumbnails in cache");
    for (var station in stations) {
      if (station.thumbnail_url != null) {
        FastCachedImage(
          url: station.thumbnail_url!,
        );
      }
    }
    developer.log("Done loading thumbnails in cache");
  }

  void updateStationsMediaItems(
      List<Query$GetStations$stations> stations, bool updateAudioSource) {
    developer.log("updatePlaylistWithStationsData");
    // iterate stations and extract metadata
    final mediaItemQueue = <MediaItem>[];
    for (var station in stations) {
      mediaItemQueue.add(Utils.getStationMetadata(station));
    }
    stationsMediaItems = mediaItemQueue;
    queue.add(stationsMediaItems);

    // Update current played media item
    if (_playerIndex != null) {
      mediaItem.add(stationsMediaItems[_playerIndex!]);
    }

    if (updateAudioSource) {
      setAudioSource(_playerIndex ?? 0);
    }
  }

  Future<void> setAudioSource(int index) async {
    developer.log("setAudioSource: $index");
    final station = stations[index];
    var retry = 0;
    while(true) {
      if(retry < maxRetries) {
        final streams = Utils.getStationStreamUrls(station);
        final streamUrl = streams[retry % streams.length];
        developer.log("setAudioSource: Trying stream: $streamUrl");
        try {
          await _player.setAudioSource(
            AudioSource.uri(Uri.parse(streamUrl)),
          );
          break;
        } catch (e) {
          developer.log("setAudioSource: Player Error: $e");
          if(e is PlayerException) {
            if(e.message == "Source error") {
              retry++;
            } else {
              rethrow;
            }
          } else {
            rethrow;
          }
        }
      } else {
        developer.log("setAudioSource: max retries reached");
        stop();
        break;
      }
    }
  }

  Query$GetStations$stations? get currentStation {
    if (_playerIndex != null) {
      return stations[_playerIndex!];
    }
    return null;
  }

  void startListeningTracker() {
    _timer = Timer.periodic(
        const Duration(seconds: 5),
        (Timer t) => {
              if (currentStation != null && _player.playing)
                {
                  AppTracking.trackListenStation(
                      currentStation!, currentStreamUrl)
                }
            });
  }

  void stopListeningTracker() {
    _timer?.cancel();
  }

  String get currentStreamUrl {
    return mediaItem.value?.id ?? "-";
  }
}
