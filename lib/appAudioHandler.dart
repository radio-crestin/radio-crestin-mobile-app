import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/tracking.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/services/car_play_service.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
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
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 30),
        maxBufferDuration: Duration(minutes: 2),
        bufferForPlaybackDuration: Duration(milliseconds: 2500),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
      ),
      androidLivePlaybackSpeedControl: AndroidLivePlaybackSpeedControl(
        fallbackMinPlaybackSpeed: 1.0,
        fallbackMaxPlaybackSpeed: 1.0,
      ),
      darwinLoadControl: DarwinLoadControl(
        preferredForwardBufferDuration: Duration(minutes: 2),
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
      ),
    ),
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
  final StationDataService stationDataService = GetIt.instance<StationDataService>();
  Timer? timer;

  Object? error;
  int errorRetryCount = 0;
  final int maxErrorRetryCount = 10;
  bool started = false;
  int? playerIndex;

  // Track loaded stream to avoid unnecessary reconnection on pause/resume
  String? _loadedStreamUrl;
  String? _loadedStreamType;
  // True while play() is loading a new source — keeps broadcast in loading state
  // to prevent spinner flash between setAudioSource() and player.play().
  bool _isConnecting = false;
  bool get isPlayingOrConnecting => player.playing || _isConnecting;
  Timer? _disconnectTimer;
  // Monotonically increasing ID to cancel stale play() operations.
  // Each playStation() increments this; play() checks it after every await
  // to bail out if a newer operation has superseded it.
  int _playOperationId = 0;
  // Completer used to immediately break out of a stale setAudioSource() await
  // instead of waiting for the full 3-10s timeout to expire.
  Completer<void>? _sourceLoadCanceller;
  static const _disconnectDelay = Duration(seconds: 60);
  static const _liveEdgeOffset = Duration(minutes: 2);

  // Track last emitted mediaItem fields to avoid redundant Android notification updates
  int? _lastEmittedSongId;
  String? _lastEmittedArtUriString;

  final BehaviorSubject<Station?> currentStation = BehaviorSubject.seeded(null);
  final BehaviorSubject<List<MediaItem>> stationsMediaItems = BehaviorSubject.seeded(<MediaItem>[]);

  // Active playlist for skip next/prev - set by whoever selects a station (app UI, CarPlay, Android Auto)
  List<Station> activePlaylist = [];
  // When true, _getActivePlaylist() filters activePlaylist to only current favorites
  bool _activePlaylistIsFavorites = false;

  _log(String message) {
    developer.log("AppAudioHandler: $message");
  }

  /// Cancels any in-flight play() operation by bumping the operation ID
  /// and completing the source load canceller.
  void _cancelInFlightPlay() {
    ++_playOperationId;
    _isConnecting = false;
    if (_sourceLoadCanceller != null && !_sourceLoadCanceller!.isCompleted) {
      _sourceLoadCanceller!.completeError('cancelled');
    }
  }

  // Android Auto media browsing support
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    _log("getChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        return _recentSubject.value;
      case "favoriteStationsRootId":
        final favSlugs = stationDataService.favoriteStationSlugs.value;
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
        final stream = stationDataService.favoriteStationSlugs.map((_) => <String, dynamic>{});
        return stationDataService.favoriteStationSlugs.hasValue
            ? stream.shareValueSeeded(<String, dynamic>{})
            : stream.shareValue();
      default:
        final stream = stationsMediaItems.map((_) => <String, dynamic>{});
        return stationsMediaItems.hasValue
            ? stream.shareValueSeeded(<String, dynamic>{})
            : stream.shareValue();
    }
  }

  final AudioPlayer player;

  // ignore: close_sinks
  final BehaviorSubject<List<MediaItem>> _recentSubject = BehaviorSubject.seeded(<MediaItem>[]);
  static const LAST_PLAYED_MEDIA_ITEM = "last_played_media_item";

  final int maxRetries = 5;

  AppAudioHandler({required this.graphqlClient, required this.player}) {
    _initPlayer();
    _initUpdateCurrentStationMetadata();
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

    // Handle stream lifecycle events:
    // - completed: HLS reconnect, MP3 stop
    // - idle while playing: stream dropped (e.g., network lost in background)
    // Guard: skip reconnection while loading a new source (_isConnecting),
    // as the idle/completed event is from the previous source being stopped.
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (_isConnecting) return;
        final isHls = _loadedStreamType == 'HLS';
        if (isHls) {
          _log("processingStateStream: HLS stream completed unexpectedly, reconnecting");
          _loadedStreamUrl = null;
          _loadedStreamType = null;
          play();
        } else {
          stop();
        }
      } else if (state == ProcessingState.idle && player.playing) {
        if (_isConnecting) return;
        _log("processingStateStream: stream lost (idle while playing), reconnecting");
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        play();
      }
    });

    await player.setLoopMode(LoopMode.off);
    // Note: just_audio handles audio session interruptions automatically via
    // handleInterruptions: true (default). It pauses on interruption begin and
    // resumes on interruption end when shouldResume=true.
  }

  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {
    _log('setRating($rating)');
    final station = currentStation.value;
    if (station == null) return;
    await setStationIsFavorite(station, rating.hasHeart());
  }

  Future<void> selectStation(Station station, {List<Station>? playlist, bool isFavoritesPlaylist = false}) async {
    _log('selectStation($station)');
    if (playlist != null) {
      activePlaylist = List.from(playlist);
      _activePlaylistIsFavorites = isFavoritesPlaylist;
    }

    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);

    if (NetworkService.instance.isOnMobileData.value) {
      final stripped = _buildStationOnlyMediaItem(station);
      _lastEmittedSongId = -1;
      _lastEmittedArtUriString = stripped.artUri?.toString();
      mediaItem.add(stripped.copyWith(rating: Rating.newHeartRating(isFav)));
    } else {
      final item = station.mediaItem;
      _lastEmittedSongId = station.songId;
      _lastEmittedArtUriString = item.artUri?.toString();
      mediaItem.add(item.copyWith(rating: Rating.newHeartRating(isFav)));
      _cacheSongThumbnail(station);
    }
    currentStation.add(station);

    await setLastPlayedStation(station);
  }

  /// Builds a MediaItem with only station info (no song metadata/thumbnail).
  /// Used in data-saving mode (mobile data + background).
  MediaItem _buildStationOnlyMediaItem(Station station) {
    final Uri stationArtUri;
    final cachedPath = station.cachedThumbnailPath;
    if (cachedPath != null) {
      stationArtUri = Uri.file(cachedPath);
    } else {
      final thumbnailUrl = station.rawStationData.thumbnail_url;
      stationArtUri = (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
          ? Uri.parse(thumbnailUrl)
          : Uri.parse(CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL);
    }
    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
    return MediaItem(
      id: Utils.getStationStreamUrls(station.rawStationData).firstOrNull ?? "",
      title: station.rawStationData.title,
      displayTitle: station.rawStationData.title,
      displaySubtitle: "",
      artist: "",
      duration: null,
      artUri: stationArtUri,
      isLive: true,
      rating: Rating.newHeartRating(isFav),
      extras: {
        "station_id": station.rawStationData.id,
        "station_slug": station.rawStationData.slug,
        "station_title": station.rawStationData.title,
        "song_id": -1,
        "song_title": "",
        "song_artist": "",
        "total_listeners": station.rawStationData.total_listeners,
        "station_is_up": station.isUp,
        "station_thumbnail_url": station.rawStationData.thumbnail_url,
        "station_streams": Utils.getStationStreamObjects(station.rawStationData),
      },
    );
  }

  void _cacheSongThumbnail(Station station) {
    if (NetworkService.instance.isOnMobileData.value) return;
    final songThumbnailUrl = station.rawStationData.now_playing?.song?.thumbnail_url;
    if (songThumbnailUrl != null && songThumbnailUrl.isNotEmpty) {
      ImageCacheService.instance.getOrDownload(songThumbnailUrl).then((file) {
        if (NetworkService.instance.isOnMobileData.value) return;
        if (file != null && currentStation.valueOrNull?.id == station.id) {
          // Update mediaItem with local file URI so notification uses cached image
          final currentItem = mediaItem.valueOrNull;
          if (currentItem != null) {
            final localUri = Uri.file(file.path);
            _lastEmittedArtUriString = localUri.toString();
            final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
            mediaItem.add(currentItem.copyWith(
              artUri: localUri,
              rating: Rating.newHeartRating(isFav),
            ));
          }
        }
      });
    }
  }

  Future<void> playStation(Station station, {List<Station>? playlist, bool isFavoritesPlaylist = false}) async {
    _log('playStation($station)');

    // Avoid stop-restart if already playing/loading this exact station
    if (currentStation.valueOrNull?.id == station.id && isPlayingOrConnecting) {
      _log('playStation: already playing/loading station ${station.slug}, skipping');
      if (playlist != null) {
        activePlaylist = List.from(playlist);
        _activePlaylistIsFavorites = isFavoritesPlaylist;
      }
      return;
    }

    // Cancel any in-flight play() from a previous playStation() call
    _cancelInFlightPlay();

    // Stop and clean up the previous station before starting the new one
    _disconnectTimer?.cancel();
    if (player.playing || player.processingState != ProcessingState.idle) {
      stopListeningTracker();
      await player.stop();
    }
    _loadedStreamUrl = null;
    _loadedStreamType = null;

    await selectStation(station, playlist: playlist, isFavoritesPlaylist: isFavoritesPlaylist);
    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return play();
  }

  List<Station> _getActivePlaylist() {
    if (_activePlaylistIsFavorites) {
      final favSlugs = stationDataService.favoriteStationSlugs.value;
      final currentFavorites = stationDataService.filteredStations.value
          .where((s) => favSlugs.contains(s.slug))
          .toList();
      if (currentFavorites.isNotEmpty) return currentFavorites;
    }
    if (activePlaylist.isNotEmpty) return activePlaylist;
    return stationDataService.filteredStations.value;
  }

  @override
  Future<void> skipToNext() {
    _log('skipToNext()');
    if (currentStation.value == null) return super.skipToNext();

    final playlist = _getActivePlaylist();
    if (playlist.isEmpty) return super.skipToNext();

    final currentIndex = playlist.indexWhere((s) => s.slug == currentStation.value!.slug);
    final nextIndex = (currentIndex + 1) % playlist.length;
    return playStation(playlist[nextIndex < 0 ? 0 : nextIndex]);
  }

  @override
  Future<void> skipToPrevious() {
    _log('skipToPrevious()');
    if (currentStation.value == null) return super.skipToPrevious();

    final playlist = _getActivePlaylist();
    if (playlist.isEmpty) return super.skipToPrevious();

    final currentIndex = playlist.indexWhere((s) => s.slug == currentStation.value!.slug);
    final prevIndex = currentIndex <= 0 ? playlist.length - 1 : currentIndex - 1;
    return playStation(playlist[prevIndex]);
  }

  @override
  Future<void> skipToQueueItem(int index) {
    _log("skipToQueueItem: $index");
    playStation(stationDataService.stations.value[index]);
    return super.skipToQueueItem(index);
  }

  String addTrackingParametersToUrl(String url, {bool isHls = false}) {
    // HLS servers reject unknown query parameters with redirect loops.
    // iOS AVFoundation hard-limits redirects to 16, causing -1007 errors.
    if (isHls) return url;

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
    final myOpId = _playOperationId;
    _disconnectTimer?.cancel();
    stationDataService.resumePolling();

    if (currentStation.value != null) {
      AppTracking.trackPlayStation(currentStation.value!, graphQLClient: graphqlClient);
      AppTracking.trackListenStation(currentStation.value!, currentStreamUrl);
    }
    startListeningTracker();

    var item = mediaItem.valueOrNull;

    // Fast resume: if a stream is already loaded for this station, just resume playback.
    // _loadedStreamUrl is nulled on station change, pause-disconnect, and stop,
    // so non-null means the current station's stream is still loaded.
    if (_loadedStreamUrl != null &&
        player.processingState != ProcessingState.idle) {
      _log("play: fast resume (stream already loaded)");
      return player.play();
    }

    // Need to load a new stream source
    PerformanceMonitor.startOperation('audio_play');
    _isConnecting = true;
    _broadcastState(player.playbackEvent);
    var retry = 0;
    final canceller = Completer<void>();
    _sourceLoadCanceller = canceller;

    while (item != null && myOpId == _playOperationId) {
      if (retry < maxRetries) {
        final streams = item.extras?["station_streams"] as List<dynamic>?;
        final streamEntry = streams?[retry % (streams?.length ?? 1)];
        final streamUrl = (streamEntry is Map ? streamEntry["url"] : streamEntry)?.toString() ?? item.id;
        final streamType = streamEntry is Map ? streamEntry["type"]?.toString() : null;
        final isHls = streamType == 'HLS';
        _log("play: attempt $retry - $streamUrl (type: $streamType)");
        try {
          if (retry > 0) {
            await player.stop();
          }
          final trackedUrl = addTrackingParametersToUrl(streamUrl, isHls: isHls);
          final timeout = isHls ? const Duration(seconds: 3) : const Duration(seconds: 10);
          // Race setAudioSource against the canceller so playStation() can
          // break this await immediately instead of waiting for the timeout.
          final loadFuture = player.setAudioSource(
            AudioSource.uri(Uri.parse(trackedUrl)),
            preload: true,
          );
          // Prevent unhandled error if abandoned by Future.any
          loadFuture.ignore();
          await Future.any([loadFuture, canceller.future]).timeout(timeout);
          _loadedStreamUrl = streamUrl;
          _loadedStreamType = streamType;
          _log("play: source loaded successfully ($streamUrl)");
          break;
        } catch (e) {
          _loadedStreamUrl = null;
          _loadedStreamType = null;
          // If superseded by a newer playStation(), exit immediately
          if (myOpId != _playOperationId) {
            _log("play: cancelled (op $myOpId < $_playOperationId)");
            break;
          }
          _log("play: attempt $retry failed - $e");
          retry++;
        }
      } else {
        _log("play: max retries reached");
        _isConnecting = false;
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        PerformanceMonitor.endOperation('audio_play');
        stop();
        return;
      }
    }

    _sourceLoadCanceller = null;
    PerformanceMonitor.endOperation('audio_play');
    _isConnecting = false;

    // Bail out if a newer playStation() call has superseded this one
    if (myOpId != _playOperationId) {
      _log("play: superseded (op $myOpId < $_playOperationId), aborting");
      return;
    }

    if (_loadedStreamType == 'HLS') {
      await _seekBehindLiveEdge();
    }

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
      _loadedStreamType = null;
      player.setAudioSource(
        AudioSource.uri(Uri.parse(CONSTANTS.STATIC_MP3_URL)),
        preload: false,
      );
      stationDataService.pausePolling();
    });

    return super.pause();
  }

  /// For HLS streams with retained segments on mobile data, seeks 2 minutes
  /// behind the live edge so the buffer fills instantly at network speed.
  /// On WiFi this is unnecessary — WiFi is stable enough for live edge playback.
  Future<void> _seekBehindLiveEdge() async {
    if (!NetworkService.instance.isOnMobileData.value) {
      _log('_seekBehindLiveEdge: on WiFi, skipping');
      return;
    }
    final duration = player.duration;
    if (duration == null || duration < _liveEdgeOffset + const Duration(seconds: 10)) {
      _log('_seekBehindLiveEdge: window $duration too short, skipping');
      return;
    }
    final seekTarget = duration - _liveEdgeOffset;
    _log('_seekBehindLiveEdge: duration=$duration, seeking to $seekTarget');
    try {
      await player.seek(seekTarget);
    } catch (e) {
      _log('_seekBehindLiveEdge: seek failed ($e), continuing from live edge');
    }
  }

  @override
  Future<void> stop() async {
    _log("stop");
    _cancelInFlightPlay();
    _disconnectTimer?.cancel();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
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
    for (var v in stationDataService.stations.value) {
      var r = partialRatio(v.title, query);
      if (r > maxR) {
        maxR = r;
        selectedStation = v;
      }
    }
    if (maxR > 0) {
      return playStation(selectedStation);
    } else {
      return playStation(stationDataService.stations.value[0]);
    }
  }

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) {
    for (var v in stationDataService.stations.value) {
      if (v.stationStreams.toString().contains(uri.toString())) {
        return playStation(v);
      }
    }
    return super.playFromUri(uri);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    _log('playMediaItem($mediaItem)');
    final station = stationDataService.stations.value.cast<Station?>().firstWhere((element) => element!.id == mediaItem.extras?["station_id"], orElse: () => null);
    if (station != null) playStation(station);
  }

  // Metadata refresh
  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setRating,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _isConnecting
        ? AudioProcessingState.loading
        : const {
            // We're using ready here to not interupt Android Auto playback when going to next/previous station
            ProcessingState.idle: AudioProcessingState.ready,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[player.processingState] ?? AudioProcessingState.idle,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: playerIndex,
    ));
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
    // Don't stop audio if CarPlay/Android Auto is connected — user may still be listening
    try {
      final carPlayService = GetIt.instance<CarPlayService>();
      if (carPlayService.isConnected) {
        _log('onTaskRemoved: CarPlay/Android Auto connected, keeping audio alive');
        return super.onTaskRemoved();
      }
    } catch (_) {}
    _cancelInFlightPlay();
    _disconnectTimer?.cancel();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    stopListeningTracker();
    player.stop();
    stationDataService.cancelWatchStations();
    return super.onTaskRemoved();
  }

  // Method to completely stop and cleanup the audio service
  Future<void> dispose() async {
    _log('dispose()');
    _cancelInFlightPlay();
    _disconnectTimer?.cancel();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    stopListeningTracker();
    await player.stop();
    await player.dispose();
    stationDataService.cancelWatchStations();
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
    final selectedMediaItem = stationsMediaItems.value.cast<MediaItem?>().firstWhere((item) => item!.id == mediaId, orElse: () => null);
    if (selectedMediaItem != null) return playMediaItem(selectedMediaItem);
    return Future.value();
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

  /// Called on foreground resume or connectivity restore. Reconnects if the
  /// stream was silently lost (idle) or stalled waiting for data (buffering).
  void reconnectIfNeeded() {
    if (currentStation.valueOrNull == null) return;
    if (_isConnecting) return;
    final state = player.processingState;
    if (state == ProcessingState.idle ||
        (state == ProcessingState.buffering && player.playing)) {
      _log("reconnectIfNeeded: player stalled (state=$state), reconnecting");
      _loadedStreamUrl = null;
      _loadedStreamType = null;
      play();
    }
  }

  // Last played station
  setLastPlayedStation(Station station) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(LAST_PLAYED_MEDIA_ITEM, station.slug);
  }

  Future<Station> getLastPlayedStation() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    var stationSlug = prefs.getString(LAST_PLAYED_MEDIA_ITEM);
    return stationDataService.stations.value.firstWhere(
      (station) => station.slug == stationSlug,
      orElse: () => stationDataService.stations.value.first,
    );
  }

  Future<void> setStationIsFavorite(Station station, bool isFavorite) async {
    await stationDataService.setStationIsFavorite(station, isFavorite);
    // Update MediaItem rating so MediaSession reflects the new favorite state
    final currentItem = mediaItem.valueOrNull;
    if (currentItem != null && currentStation.value?.slug == station.slug) {
      mediaItem.add(currentItem.copyWith(rating: Rating.newHeartRating(isFavorite)));
    }
    Utils.incrementActionsMade(
      graphQLClient: graphqlClient,
      currentStationName: currentStation.valueOrNull?.title,
    );
  }

  void _initUpdateCurrentStationMetadata() {
    // When mobile data toggles: immediately strip or restore notification metadata.
    NetworkService.instance.isOnMobileData.stream.listen((onMobile) {
      _log("isOnMobileData changed: $onMobile");
      final station = currentStation.valueOrNull;
      if (station == null || mediaItem.valueOrNull == null) return;

      if (onMobile) {
        final stripped = _buildStationOnlyMediaItem(station);
        _lastEmittedSongId = -1;
        _lastEmittedArtUriString = stripped.artUri?.toString();
        mediaItem.add(stripped);
      } else {
        final fullItem = station.mediaItem;
        final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
        _lastEmittedSongId = station.songId;
        _lastEmittedArtUriString = fullItem.artUri.toString();
        mediaItem.add(fullItem.copyWith(rating: Rating.newHeartRating(isFav)));
        _cacheSongThumbnail(station);
      }
    });

    // When connectivity is restored while app is in foreground: reconnect stalled audio.
    // If app is backgrounded, reconnection happens via didChangeAppLifecycleState.resumed.
    // Delay 2s so the network is actually usable and any in-progress play() retries finish.
    NetworkService.instance.isOffline.stream.listen((offline) {
      if (offline) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != AppLifecycleState.resumed) {
        _log("isOffline -> false: app not in foreground ($lifecycle), skipping reconnect");
        return;
      }
      _log("isOffline -> false: will reconnect in 2s");
      Future.delayed(const Duration(seconds: 2), () {
        _log("isOffline -> false: checking if player needs reconnect");
        reconnectIfNeeded();
      });
    });

    // Station data poll: update metadata when stations change.
    stationDataService.stations.stream.listen((stations) {
      _log("updateCurrentStationMetadata");
      final sortedStations = stations..sort((a, b) => a.order.compareTo(b.order));

      Station? updatedCurrentStation;
      if(currentStation.valueOrNull != null) {
        updatedCurrentStation = stations.cast<Station?>().firstWhere((element) => element!.id == currentStation.value!.id, orElse: () => null);
        if (updatedCurrentStation != null) currentStation.add(updatedCurrentStation);
      }

      final newStationsMediaItems =
          sortedStations.map((station) => station.mediaItem).toList();

      stationsMediaItems.add(newStationsMediaItems);

      if (mediaItem.value != null && updatedCurrentStation != null) {
        if (NetworkService.instance.isOnMobileData.value) {
          _log("updateCurrentStationMetadata: on mobile data, skipping song update");
        } else {
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
              final isFav = stationDataService.favoriteStationSlugs.value.contains(updatedCurrentStation.slug);
              mediaItem.add(newMediaItem.copyWith(rating: Rating.newHeartRating(isFav)));
            }

            if (songChanged) {
              _cacheSongThumbnail(updatedCurrentStation);
            }
          }
        }
      }
    });
  }
}
