import 'package:audio_service/audio_service.dart';
import 'package:fast_cached_network_image/fast_cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/utils.dart';
import 'dart:developer' as developer;

enum PlayerState { started, stopped, playing, buffering, error }

Future<AppAudioHandler> initAudioService({required audioPlayer, required graphqlClient}) async {
  return await AudioService.init(
    builder: () => AppAudioHandler(audioPlayer: audioPlayer, graphqlClient: graphqlClient),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.radiocrestin.radiocrestin.channel.audio',
      androidNotificationChannelName: 'Radio Crestin',
      androidNotificationOngoing: true,
    ),
  );
}

// https://github.com/ryanheise/audio_service/blob/master/audio_service/example/lib/main.dart
class AppAudioHandler extends BaseAudioHandler with ChangeNotifier { // mix in default seek callback implementations
  
  final AudioPlayer audioPlayer;
  final GraphQLClient graphqlClient;

  List<Query$GetStations$stations> stations = List<Query$GetStations$stations>.empty(growable: true);
  List<Query$GetStations$station_groups> stationGroups = List<Query$GetStations$station_groups>.empty(growable: true);

  int? stationIdx;
  bool started = false;
  PlaybackState? appPlaybackState;
  Object? error;

  /// Initialise our audio handler.
  AppAudioHandler({required this.audioPlayer, required this.graphqlClient}) {
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

  // In this simple example, we handle only 4 actions: play, pause, seek and
  // stop. Any button press from the Flutter UI, notification, lock screen or
  // headset will be routed through to these 4 methods so that you can handle
  // your audio playback logic in one place.


  @override
  Future<void> play() async {
    final station = getStation();
    if(station == null) {
      throw Exception("No station selected");
    }
    // This will recreate the player
    setStationIdx(stationIdx);
    developer.log("Playing station $station ${station.stream_url}");
    mediaItem.add(metadata);
    try {
      await audioPlayer.setAudioSource(AudioSource.uri(Uri.parse(metadata.id)));
    } catch (e) {
      setError(e);
    }
    started = true;
    await audioPlayer.play();
    refreshStationMetadata();
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    await audioPlayer.pause();
    started = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) => audioPlayer.seek(position);

  @override
  Future<void> stop() async {
    await audioPlayer.positionStream.drain();
    await audioPlayer.stop();
    started = false;
    stationIdx = null;
    notifyListeners();
  }
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
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
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
        pollInterval: const Duration(seconds: 60),
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
      stationGroups = parsedData.station_groups;
      stationIdx ??= 0;
      loadThumbnailsInCache();
      refreshStationMetadata();
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
    final station = getStation();
    if(station == null){
      return;
    }

    await updateMediaItem(metadata);
    developer.log("refreshStationMetadata done: ${metadata}");
  }

  Query$GetStations$stations? getStation() {
    if(stationIdx != null) {
      return stations[stationIdx!];
    }
    return null;
  }

  void setStationIdx(int? stationIdx) {
    if(this.stationIdx != null) {
      stop();
    }
    this.stationIdx = stationIdx;
    notifyListeners();
  }

  void setError(Object error) {
    developer.log("Error: $error");
    this.error = error;
    notifyListeners();
  }

  MediaItem get metadata {
    return Utils.getStationMetadata(getStation());
  }
}