import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:fast_cached_network_image/fast_cached_network_image.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/tracking.dart';
import 'package:radio_crestin/utils.dart';
import 'dart:developer' as developer;

enum PlayerState { started, stopped, playing, buffering, error }

Future<AppAudioHandler> initAudioService({required graphqlClient}) async {
  return await AudioService.init(
    builder: () => AppAudioHandler(graphqlClient: graphqlClient),
    config: const AudioServiceConfig(
      // androidNotificationChannelId: 'com.radiocrestin.radiocrestin.channel.audio',
      androidNotificationChannelName: 'Radio Crestin',
      androidNotificationIcon: "drawable/ic_launcher_foreground",
      // androidNotificationOngoing: true,
      notificationColor: Color(0xffe91e63),
      preloadArtwork: true,
      androidShowNotificationBadge: true,
      androidStopForegroundOnPause: false,
    ),
  );
}

// https://github.com/ryanheise/audio_service/blob/master/audio_service/example/lib/main.dart
class AppAudioHandler extends BaseAudioHandler with ChangeNotifier { // mix in default seek callback implementations
  
  final AudioPlayer audioPlayer = AudioPlayer(
    // TODO: enable userAgent to identify users
    // Currently it's disabled because it creates an insecure proxy on localhost to add this header
    // and it's needs more configuration
   // userAgent: 'radiocrestinapp/1.0 (Linux;Android 11) https://www.radio-crestin.com',
  );
  final GraphQLClient graphqlClient;

  List<Query$GetStations$stations> stations = List<Query$GetStations$stations>.empty(growable: true);

  //TODO: it's not recommended to use station index because the stations list might be updated
  int? stationIdx;
  bool started = false;
  PlaybackState? appPlaybackState;
  Object? error;
  int errorRetryCount = 0;
  final int maxErrorRetryCount = 10;
  int stationStreamSourceIdx = 0;

  /// Initialise our audio handler.
  AppAudioHandler({required this.graphqlClient}) {
    // So that our clients (the Flutter UI and the system notification) know
    // what state to display, here we set up our audio handler to broadcast all
    // playback state changes as they happen via playbackState...
    audioPlayer.playbackEventStream.map(_transformEvent).pipe(playbackState);

    playbackState.stream.listen((event) {
      appPlaybackState = event;
    }, onError: (Object e, StackTrace st) {
      setError(e);
    });
    subscribeRefreshStations();
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    super.onTaskRemoved();
  }

  @override
  Future<void> play() async {
    developer.log("play");
    stationStreamSourceIdx = 0;
    errorRetryCount = 0;
    final station = currentStation;
    if(station == null) {
      throw Exception("No station selected");
    }
    // This will recreate the player
    setStationIdx(stationIdx);
    mediaItem.add(metadata);
    await setCurrentStationStreamAsDataSource();
    await audioPlayer.play();
    started = true;
    refreshStationMetadata();
    notifyListeners();
    AppTracking.trackPlayStation(station);
    AppTracking.trackListenStation(currentStation!, currentStreamUrl);
    super.play();
  }

  @override
  Future<void> pause() async {
    developer.log("pause");

    final station = currentStation;
    // await audioPlayer.positionStream.drain();
    await audioPlayer.stop();

    started = false;
    notifyListeners();
    if(station != null) {
      AppTracking.trackStopStation(station);
    }
    super.pause();
  }

  @override
  Future<void> seek(Duration position) => audioPlayer.seek(position);

  @override
  Future<void> stop() async {
    developer.log("stop");
    final station = currentStation;
    await audioPlayer.positionStream.drain();
    await audioPlayer.stop();
    started = false;
    stationIdx = null;
    notifyListeners();
    if(station != null) {
      AppTracking.trackStopStation(station);
    }
    super.stop();
  }

  @override
  Future<void> skipToQueueItem(int i) async {
    developer.log("skipToQueueItem");
  }

  @override
  Future<void> skipToNext() async {
    developer.log("skipToNext");
    var newStationIdx = 0;
    if(stationIdx == null) {
      newStationIdx = 0;
    } else {
      newStationIdx = (stationIdx! + 1) % stations.length;
    }
    setStationIdx(newStationIdx);
    play();
    notifyListeners();
  }

  @override
  Future<void> skipToPrevious() async {
    developer.log("skipToPrevious");
    var newStationIdx = 0;
    if(stationIdx == null) {
      newStationIdx = 0;
    } else {
      newStationIdx = (stationIdx! - 1) % stations.length;
    }
    setStationIdx(newStationIdx);
    play();
    notifyListeners();
  }

  /// Transform a just_audio event into an audio_service state.
  ///
  /// This method is used from the constructor. Every event received from the
  /// just_audio audioPlayer will be transformed into an audio_service state so that
  /// it can be broadcast to audio_service clients.
  PlaybackState _transformEvent(PlaybackEvent event) {
    developer.log("_transformEvent: $event ${audioPlayer.processingState} ${audioPlayer.playerState} ${audioPlayer.playing}");
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        // MediaControl.stop,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.ready,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        // ProcessingState.idle: AudioProcessingState.ready,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[audioPlayer.processingState]!,
      playing: audioPlayer.playing,
      updatePosition: audioPlayer.position,
      bufferedPosition: audioPlayer.bufferedPosition,
      speed: audioPlayer.speed,
      queueIndex: event.currentIndex,
    );
  }


  void subscribeRefreshStations() async {
    developer.log("Starting to fetch stations");
    graphqlClient.watchQuery$GetStations(
      WatchOptions$Query$GetStations(
        fetchPolicy: FetchPolicy.cacheAndNetwork,
        errorPolicy: ErrorPolicy.all,
        cacheRereadPolicy: CacheRereadPolicy.ignoreAll,
        pollInterval: const Duration(seconds: 5),
        fetchResults: true,
      ),
    ).stream.listen((event) {
      developer.log("Done fetching stations");
      final parsedData = event.parsedData;
      if(parsedData == null) {
        developer.log("No data");
        return;
      }
      stations = parsedData.stations;
      stationIdx ??= 0;
      loadThumbnailsInCache();
      refreshStationMetadata();
      notifyListeners();
    });
  }

  void loadThumbnailsInCache() {
    developer.log("Loading thumbnails in cache");
    stations.forEach((station) {
      if(station.thumbnail_url != null) {
        FastCachedImage(
          url: station.thumbnail_url!,
        );
      }
    });
    developer.log("Done loading thumbnails in cache");
  }

  onPlayButtonPressed() {
    developer.log("onPlayButtonPressed");
    play();
  }

  onPauseButtonPressed() {
    developer.log("onPauseButtonPressed");
    pause();
  }

  onNextStationButtonPressed() {
    developer.log("onNextStationButtonPressed");
    skipToNext();

  }

  onPreviousStationButtonPressed() {
    developer.log("onPreviousStationButtonPressed");
    skipToPrevious();

  }

  void refreshStationMetadata() async {
    developer.log("refreshStationMetadata");
    final station = currentStation;
    if(station == null){
      return;
    }

    await updateMediaItem(metadata);
    developer.log("refreshStationMetadata done: $metadata");
  }

  void setStationIdx(int? stationIdx) {
    if(this.stationIdx != null) {
      stop();
    }
    this.stationIdx = stationIdx;
    notifyListeners();
  }

  Future<void> setError(Object error) async {
    developer.log("Error: $error");
    FirebaseCrashlytics.instance.recordError(error, null, fatal: false);
    this.error = error;

    if(currentStation != null) {
      AppTracking.trackStopStation(currentStation!);

      if(errorRetryCount < maxErrorRetryCount) {
        developer.log("Retrying with new STREAM_URL");
        errorRetryCount += 1;
        stationStreamSourceIdx = (stationStreamSourceIdx + 1)  % stationStreams.length;
        await setCurrentStationStreamAsDataSource();
        await audioPlayer.play();
        AppTracking.trackPlayStation(currentStation!);
        AppTracking.trackListenStation(currentStation!, currentStreamUrl);
        return;
      } else {
        developer.log("Stopped streaming because of too many errors");
        started = false;
        pause();
      }
    }
    notifyListeners();
  }

  setCurrentStationStreamAsDataSource() async {
    developer.log("STREAM_URL: $currentStreamUrl (errorRetryCount: $errorRetryCount)");

    try {
      await audioPlayer.setAudioSource(AudioSource.uri(Uri.parse(currentStreamUrl)));
    } catch (e) {
      setError(e);
    }
  }

  String get currentStreamUrl {
    return stationStreams[stationStreamSourceIdx] ?? "";
  }
  MediaItem get metadata {
    return Utils.getStationMetadata(currentStation);
  }
  Query$GetStations$stations? get currentStation {
    if(stationIdx != null) {
      return stations[stationIdx!];
    }
    return null;
  }

  List<String> get stationStreams {
    return Utils.getStationStreamUrls(currentStation);
  }

  void startListeningTracker() {
    Timer.periodic(const Duration(seconds: 5), (Timer t) => {
      if (currentStation != null && audioPlayer.playing) {
        AppTracking.trackListenStation(currentStation!, currentStreamUrl)
      }
    });
  }
}