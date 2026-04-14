import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/services/car_play_service.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/review_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/utils.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'globals.dart' as globals;

enum PlayerState { started, stopped, playing, buffering, error }

/// Describes why a station connection failed.
enum ConnectionErrorReason {
  timeout,    // Stream didn't load within the allowed time
  network,    // No internet or DNS failure (SocketException)
  httpError,  // Server returned an error (404, 403, 500, etc.)
  unknown,    // Other / unclassifiable error
}

class ConnectionError {
  final String stationName;
  final ConnectionErrorReason reason;
  final String? details; // e.g. "404" or the raw error message

  const ConnectionError({
    required this.stationName,
    required this.reason,
    this.details,
  });
}

Future<AppAudioHandler> initAudioService({required graphqlClient}) async {
  final AudioPlayer player = AudioPlayer(
    // TODO: enable userAgent to identify users
    // Currently it's disabled because it creates an insecure proxy on localhost to add this header
    // and it's needs more configuration
    // userAgent: 'radiocrestinapp/1.0 (Linux;Android 11) https://www.radio-crestin.com',
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 50),
        maxBufferDuration: Duration(minutes: 10),
        bufferForPlaybackDuration: Duration(seconds: 3),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
      ),
      androidLivePlaybackSpeedControl: AndroidLivePlaybackSpeedControl(
        fallbackMinPlaybackSpeed: 1.0,
        fallbackMaxPlaybackSpeed: 1.0,
      ),
      darwinLoadControl: DarwinLoadControl(
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        automaticallyWaitsToMinimizeStalling: true,
        preferredForwardBufferDuration: Duration(seconds: 60),
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
        'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 1, // list
        'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
        'android.media.browse.SEARCH_SUPPORTED': true,
      },
    ),
  );
}

// https://github.com/ryanheise/audio_service/blob/master/audio_service/example/lib/main.dart
// https://github.com/ryanheise/audio_service/blob/81bb480ac2aeaec08cd61c62765529613db60837/audio_service/example/lib/example_playlist.dart
class AppAudioHandler extends BaseAudioHandler {
  final GraphQLClient graphqlClient;
  final StationDataService stationDataService = GetIt.instance<StationDataService>();

  Object? error;
  int errorRetryCount = 0;
  final int maxErrorRetryCount = 10;
  bool started = false;
  int? playerIndex;

  // Track loaded stream to avoid unnecessary reconnection on pause/resume
  String? _loadedStreamUrl;
  String? _loadedStreamType;
  String? get loadedStreamType => _loadedStreamType;
  // True while play() is loading a new source — keeps broadcast in loading state
  // to prevent spinner flash between setAudioSource() and player.play().
  bool _isConnecting = false;
  bool get isPlayingOrConnecting => player.playing || _isConnecting;
  bool get isCarConnected => GetIt.instance.isRegistered<CarPlayService>() &&
      GetIt.instance<CarPlayService>().isConnected;
  bool _hasBeenPlayed = false;
  Timer? _disconnectTimer;
  Timer? _bufferingStallTimer;
  static const _bufferingStallTimeout = Duration(seconds: 15);
  // Monotonically increasing ID to cancel stale play() operations.
  // Each playStation() increments this; play() checks it after every await
  // to bail out if a newer operation has superseded it.
  int _playOperationId = 0;
  // Completer used to immediately break out of a stale setAudioSource() await
  // instead of waiting for the full 3-10s timeout to expire.
  Completer<void>? _sourceLoadCanceller;
  static const _disconnectDelay = Duration(seconds: 60);

  // Track last emitted mediaItem fields to avoid redundant Android notification updates
  int? _lastEmittedSongId;
  String? _lastEmittedArtUriString;

  final BehaviorSubject<Station?> currentStation = BehaviorSubject.seeded(null);

  /// Emits details when play() exhausts all retries and cannot connect.
  final PublishSubject<ConnectionError> connectionError = PublishSubject<ConnectionError>();
  final BehaviorSubject<List<MediaItem>> stationsMediaItems = BehaviorSubject.seeded(<MediaItem>[]);

  _log(String message) {
    developer.log("AppAudioHandler: $message");
  }

  /// Classifies the last caught error into a [ConnectionError] with a reason.
  ConnectionError _classifyError(String stationName, Object? lastError) {
    ConnectionErrorReason reason;
    String? details;

    if (lastError is TimeoutException) {
      reason = ConnectionErrorReason.timeout;
    } else if (lastError is PlayerException) {
      final code = lastError.code;
      final msg = lastError.message ?? '';
      // iOS: -1009 = NSURLErrorNotConnectedToInternet (device truly offline)
      if (code == -1009) {
        reason = ConnectionErrorReason.network;
        details = msg;
      } else if (code == -1100 || (code >= 400 && code < 600)) {
        // -1100 = NSURLErrorFileDoesNotExist (HTTP 404 from server)
        // 4xx/5xx = HTTP server errors
        reason = ConnectionErrorReason.httpError;
        details = code == -1100 ? '404' : code.toString();
      } else {
        // -1004 = NSURLErrorCannotConnectToHost (server down, not user's internet)
        // ExoPlayer code 1 = TYPE_SOURCE (general source load failure)
        reason = ConnectionErrorReason.unknown;
        details = msg.isNotEmpty ? msg : null;
      }
    } else if (lastError is SocketException) {
      reason = ConnectionErrorReason.network;
      details = lastError.message;
    } else {
      reason = ConnectionErrorReason.unknown;
      details = lastError?.toString();
    }

    return ConnectionError(
      stationName: stationName,
      reason: reason,
      details: details,
    );
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

  // Android Auto media browsing support.
  // The system's built-in media browser calls this to build the browse tree.
  // No CarAppService needed — works like YouTube Music / Spotify.
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    _log("getChildren: $parentMediaId");
    switch (parentMediaId) {
      case AudioService.recentRootId:
        return []; // Disabled: queue button on Now Playing screen is sufficient
      case "favoriteStationsRootId":
        final favSlugs = stationDataService.favoriteStationSlugs.value;
        return stationsMediaItems.value
            .where((item) => favSlugs.contains(item.extras?["station_slug"]))
            .map((item) => item.copyWith(
              extras: {...?item.extras, 'fromFavorites': true},
            ))
            .toList();
      case "allStationsRootId":
        return stationsMediaItems.value
            .map((item) => item.copyWith(
              extras: {...?item.extras, 'fromFavorites': false},
            ))
            .toList();
      default:
        if (parentMediaId == AudioService.browsableRootId) {
          const pkg = 'com.radiocrestin.radio_crestin';
          return [
            MediaItem(
              id: "favoriteStationsRootId",
              title: _isRomanian ? "Stații Favorite" : "Favorite Stations",
              artUri: Uri.parse('android.resource://$pkg/drawable/ic_favorite'),
              playable: false,
              extras: const {
                'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
              },
            ),
            MediaItem(
              id: "allStationsRootId",
              title: _isRomanian ? "Toate Stațiile" : "All Stations",
              artUri: Uri.parse('android.resource://$pkg/drawable/ic_radio'),
              playable: false,
              extras: const {
                'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
              },
            ),
          ];
        }
        return [];
    }
  }

  static const _audioServiceChannel =
      MethodChannel('com.ryanheise.audio_service.client.methods');

  /// Fetches song history for the current station and sets it as the
  /// MediaSession queue. Android Auto shows this as a "Up next"-style
  /// page accessible from the queue button on the Now Playing screen.
  Future<void> _updateSongHistoryQueue() async {
    final station = currentStation.valueOrNull;
    if (station == null) {
      queue.add([]);
      return;
    }
    // Set localized queue title FIRST (cached in native queueTitleOverride,
    // then re-applied each time setQueue is called).
    final title = _isRomanian ? 'Redate recent' : 'Recently played';
    queueTitle.add(title);
    // Fire-and-forget: cache the title on the native side before queue is set
    _audioServiceChannel.invokeMethod('setQueueTitle', {'title': title}).catchError((e) {
      print('RC_DEBUG: setQueueTitle error: $e');
    });

    try {
      print('RC_DEBUG: fetching history for ${station.slug}');
      final history = await SongHistoryService.fetchHistory(station.slug);
      print('RC_DEBUG: history result: ${history?.history.length ?? "null"} items');
      if (history == null || history.history.isEmpty) {
        queue.add([]);
        return;
      }
      final stationThumbUrl = station.thumbnailUrl;
      final now = DateTime.now();
      final pastSongs = history.history
          .where((item) => item.hasSong && item.dateTime.isBefore(now))
          .toList()
        ..sort((a, b) => b.dateTime.compareTo(a.dateTime));
      final items = pastSongs
          .take(30)
          .map((item) {
            final time = item.dateTime.toLocal();
            final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
            final thumbUrl = item.songThumbnailUrl ?? stationThumbUrl;
            return MediaItem(
              id: 'history_${station.slug}_${item.timestamp}',
              title: item.songName ?? (_isRomanian ? 'Necunoscut' : 'Unknown'),
              artist: item.artistName != null
                  ? '$timeStr - ${item.artistName}'
                  : timeStr,
              artUri: thumbUrl != null ? Uri.parse(thumbUrl) : null,
            );
          })
          .toList();
      print('RC_DEBUG: setting queue with ${items.length} items');
      queue.add(items);
    } catch (e) {
      print('RC_DEBUG: _updateSongHistoryQueue error: $e');
    }
  }

  static bool get _isRomanian {
    final locale = PlatformDispatcher.instance.locale;
    return locale.languageCode == 'ro';
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

  SharedPreferences get _prefs => GetIt.instance<SharedPreferences>();

  final int maxRetries = 4;

  AppAudioHandler({required this.graphqlClient, required this.player}) {
    stationDataService.getPlayingStreamType = (stationId) {
      if (currentStation.value?.id == stationId) return _loadedStreamType;
      return null;
    };
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

    // Ensure play/pause state changes are broadcast immediately.
    // playbackEventStream fires on position/buffer changes but may not fire
    // promptly on play()/pause() transitions. playingStream fires exactly
    // when the playing state flips, guaranteeing CarPlay/Android Auto sync.
    player.playingStream.listen((_) => _broadcastState(player.playbackEvent));

    // Handle stream lifecycle events:
    // - completed: HLS reconnect, MP3 stop
    // - idle while playing: stream dropped (e.g., network lost in background)
    // Guard: skip reconnection while loading a new source (_isConnecting),
    // as the idle/completed event is from the previous source being stopped.
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _bufferingStallTimer?.cancel();
        if (_isConnecting) return;
        final isHls = _loadedStreamType == 'HLS';
        if (isHls) {
          _log("processingStateStream: HLS stream completed unexpectedly, reconnecting");
          _loadedStreamUrl = null;
          _loadedStreamType = null;
          play();
        } else {
          _log("processingStateStream: non-HLS stream completed unexpectedly");
          final stationName = currentStation.valueOrNull?.title ?? '';
          connectionError.add(ConnectionError(
            stationName: stationName,
            reason: ConnectionErrorReason.unknown,
          ));
          _stopDueToError();
        }
      } else if (state == ProcessingState.idle && player.playing) {
        _bufferingStallTimer?.cancel();
        if (_isConnecting) return;
        _log("processingStateStream: stream lost (idle while playing), reconnecting");
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        play();
      } else if (state == ProcessingState.buffering && player.playing && !_isConnecting) {
        // Start a stall timer: if buffering doesn't resolve within 15s,
        // the connection is likely lost — stop and show error.
        _bufferingStallTimer?.cancel();
        _bufferingStallTimer = Timer(_bufferingStallTimeout, () {
          if (player.processingState == ProcessingState.buffering && player.playing) {
            _log("processingStateStream: buffering stalled for ${_bufferingStallTimeout.inSeconds}s, stopping");
            final stationName = currentStation.valueOrNull?.title ?? '';
            connectionError.add(ConnectionError(
              stationName: stationName,
              reason: ConnectionErrorReason.network,
            ));
            _stopDueToError();
          }
        });
      } else if (state == ProcessingState.ready) {
        _bufferingStallTimer?.cancel();
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

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    _log('customAction($name, $extras)');
    switch (name) {
      case 'toggleFavorite':
        final station = currentStation.value;
        if (station == null) return;
        final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
        await setStationIsFavorite(station, !isFav);
        // Re-broadcast so notification icon updates immediately
        _broadcastState(player.playbackEvent);
        break;
      case 'likeSong':
        final likeStation = currentStation.value;
        if (likeStation == null) return;
        final currentLike = _songLikeService.getLikeStatus(likeStation.songId);
        // Toggle: if already liked, reset to neutral; otherwise set to liked
        final newStatus = currentLike == 1 ? 0 : 1;
        await _songLikeService.setLikeStatus(
          stationId: likeStation.id,
          songId: likeStation.songId,
          likeStatus: newStatus,
          thumbnailUrl: likeStation.thumbnailUrl,
          songTitle: likeStation.songTitle,
          songArtist: likeStation.songArtist,
        );
        _broadcastState(player.playbackEvent);
        if (newStatus == 1) {
          final info = _buildSongInfo(likeStation);
          ReviewService.submitReview(
            stationId: likeStation.id,
            stars: 5,
            message: 'I like: $info',
            userIdentifier: globals.deviceId,
            songId: likeStation.songId,
          );
        } else {
          // Removing like — delete the review on the backend
          ReviewService.deleteReview(
            stationId: likeStation.id,
            songId: likeStation.songId,
          );
        }
        break;
      case 'dislikeSong':
        final dislikeStation = currentStation.value;
        if (dislikeStation == null) return;
        final currentDislike = _songLikeService.getLikeStatus(dislikeStation.songId);
        // Toggle: if already disliked, reset to neutral; otherwise set to disliked
        final newDislikeStatus = currentDislike == -1 ? 0 : -1;
        await _songLikeService.setLikeStatus(
          stationId: dislikeStation.id,
          songId: dislikeStation.songId,
          likeStatus: newDislikeStatus,
          thumbnailUrl: dislikeStation.thumbnailUrl,
          songTitle: dislikeStation.songTitle,
          songArtist: dislikeStation.songArtist,
        );
        _broadcastState(player.playbackEvent);
        if (newDislikeStatus == -1) {
          final info = _buildSongInfo(dislikeStation);
          ReviewService.submitReview(
            stationId: dislikeStation.id,
            stars: 1,
            message: "I don't like: $info",
            userIdentifier: globals.deviceId,
            songId: dislikeStation.songId,
          );
        } else {
          // Removing dislike — delete the review on the backend
          ReviewService.deleteReview(
            stationId: dislikeStation.id,
            songId: dislikeStation.songId,
          );
        }
        break;
      case 'showSongHistory':
        final station = currentStation.value;
        if (station == null) return;
        // Refresh the queue with latest song history
        await _updateSongHistoryQueue();
        // Store pending action so the app shows the modal when foregrounded
        _prefs.setString('pending_song_history', station.slug);
        // Bring the app to the foreground
        try {
          const channel = MethodChannel('com.radiocrestin.app');
          await channel.invokeMethod('bringToForeground');
        } catch (_) {
          // Ignore — app may already be in foreground or iOS doesn't need this
        }
        // Also notify the phone UI if already in foreground
        customEvent.add({
          'action': 'showSongHistory',
          'stationSlug': station.slug,
          'stationTitle': station.title,
          'stationThumbnailUrl': station.thumbnailUrl,
        });
        break;
    }
    return super.customAction(name, extras);
  }

  Future<void> selectStation(Station station) async {
    _log('selectStation($station)');
    print('RC_DEBUG: selectStation ${station.slug}');

    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);

    // Always use station thumbnail (cached) to save bandwidth.
    // Song metadata (title/artist) is still shown from the station data.
    final stationItem = _buildStationMediaItem(station);
    _lastEmittedSongId = station.songId;
    _lastEmittedArtUriString = stationItem.artUri?.toString();
    mediaItem.add(stationItem.copyWith(rating: Rating.newHeartRating(isFav)));
    _ensureStationArtCached(station);
    currentStation.add(station);

    // Fire-and-forget: don't block the tap path with disk I/O
    setLastPlayedStation(station);
    // Populate queue with song history for Android Auto queue page
    _updateSongHistoryQueue();
  }

  /// Builds a MediaItem with the station thumbnail URL and song metadata.
  /// Always uses HTTPS URLs for artUri (not file:// cached paths) because
  /// Android Auto's system player runs in a separate process and can't
  /// access our app's internal storage.
  MediaItem _buildStationMediaItem(Station station) {
    final thumbnailUrl = station.rawStationData.thumbnail_url;
    final Uri stationArtUri = (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
        ? Uri.parse(thumbnailUrl)
        : Uri.parse(CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL);
    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
    return MediaItem(
      id: Utils.getStationStreamUrls(station.rawStationData).firstOrNull ?? "",
      title: station.rawStationData.title,
      album: station.rawStationData.title,
      displayTitle: station.displayTitle,
      displaySubtitle: station.displaySubtitle,
      artist: station.artist,
      duration: null,
      artUri: stationArtUri,
      isLive: true,
      rating: Rating.newHeartRating(isFav),
      extras: {
        "station_id": station.rawStationData.id,
        "station_slug": station.rawStationData.slug,
        "station_title": station.rawStationData.title,
        "song_id": station.songId,
        "song_title": station.songTitle,
        "song_artist": station.artist,
        "total_listeners": station.rawStationData.total_listeners,
        "station_is_up": station.isUp,
        "station_thumbnail_url": station.rawStationData.thumbnail_url,
        "station_streams": Utils.getStationStreamObjects(station.rawStationData),
      },
    );
  }

  /// Pre-caches the station thumbnail to disk for the in-app UI.
  /// Does NOT re-emit mediaItem with file:// URIs — the MediaSession
  /// artUri stays as HTTPS so Android Auto's system player (which runs
  /// in a separate process) can download it directly.
  void _ensureStationArtCached(Station station) {
    final stationThumbnailUrl = station.rawStationData.thumbnail_url;
    if (stationThumbnailUrl == null || stationThumbnailUrl.isEmpty) return;
    // Just trigger the download for in-app disk cache — don't replace artUri
    ImageCacheService.instance.getOrDownload(stationThumbnailUrl);
  }

  /// In unstable connection mode, cache song thumbnails permanently to disk.
  /// This ensures thumbnails are available even on poor connections.
  void _ensureSongThumbnailCachedPermanently(Station station) {
    final songThumbnailUrl = station.rawStationData.now_playing?.song?.thumbnail_url;
    if (songThumbnailUrl == null || songThumbnailUrl.isEmpty) return;
    // Just trigger download — ImageCacheService stores on disk permanently
    ImageCacheService.instance.getOrDownload(songThumbnailUrl);
  }

  Future<void> playStation(Station station, {bool? fromFavorites}) async {
    _log('playStation(${station.slug}, fromFavorites=$fromFavorites)');
    _hasBeenPlayed = true;

    // Track navigation context for next/previous behavior
    if (fromFavorites != null) {
      stationDataService.startedFromFavorites = fromFavorites;
    }

    // Track play count for recommendation algorithm
    GetIt.instance<PlayCountService>().incrementPlayCount(station.slug);

    // Avoid stop-restart if already playing/loading this exact station
    if (currentStation.valueOrNull?.id == station.id && isPlayingOrConnecting) {
      _log('playStation: already playing/loading station ${station.slug}, skipping');
      return;
    }

    // Cancel any in-flight play() from a previous playStation() call
    _cancelInFlightPlay();

    // Enter "connecting" state BEFORE stopping the player so that
    // _broadcastState emits processingState=loading (not ready).
    // Without this, player.stop() → idle → mapped to ready → AnimatedPlayButton
    // treats it as settled state and clears the optimistic play intent,
    // causing the pause button to stop working during the transition.
    _isConnecting = true;
    _broadcastState(player.playbackEvent);

    // Stop and clean up the previous station before starting the new one
    _disconnectTimer?.cancel();
    if (player.playing || player.processingState != ProcessingState.idle) {
      await player.stop();
    }
    _loadedStreamUrl = null;
    _loadedStreamType = null;

    await selectStation(station);

    // Track listening session in PostHog
    AnalyticsService.instance.startListening(station.slug, station.title, stationId: station.id);

    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    return play();
  }

  /// Returns stations sorted by the user's saved sort preference.
  /// Delegates to StationDataService (the single source of truth).
  List<Station> getSortedStations() {
    return stationDataService.getSortedStations();
  }

  @override
  Future<void> skipToNext() {
    _log('skipToNext() startedFromFavorites=${stationDataService.startedFromFavorites}');
    if (currentStation.value == null) return super.skipToNext();
    final next = stationDataService.getNextStation(currentStation.value!.slug);
    _log('skipToNext: current=${currentStation.value!.slug}, next=${next?.slug}');
    if (next == null) return super.skipToNext();
    AnalyticsService.instance.trackStationSkip(currentStation.value!.slug, next.slug, 'next');
    return playStation(next);
  }

  @override
  Future<void> skipToPrevious() {
    _log('skipToPrevious() startedFromFavorites=${stationDataService.startedFromFavorites}');
    if (currentStation.value == null) return super.skipToPrevious();
    final prev = stationDataService.getPreviousStation(currentStation.value!.slug);
    _log('skipToPrevious: current=${currentStation.value!.slug}, prev=${prev?.slug}');
    if (prev == null) return super.skipToPrevious();
    AnalyticsService.instance.trackStationSkip(currentStation.value!.slug, prev.slug, 'previous');
    return playStation(prev);
  }

  @override
  Future<void> skipToQueueItem(int index) {
    _log("skipToQueueItem: $index");
    final stations = stationDataService.stations.value;
    if (index >= 0 && index < stations.length) {
      playStation(stations[index]);
    }
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
    final myOpId = _playOperationId;
    _disconnectTimer?.cancel();
    stationDataService.resumePolling();


    var item = mediaItem.valueOrNull;

    // Fast resume: if a stream is already loaded for this station, just resume playback.
    // _loadedStreamUrl is nulled on station change, pause-disconnect, and stop,
    // so non-null means the current station's stream is still loaded.
    if (_loadedStreamUrl != null &&
        player.processingState != ProcessingState.idle) {
      _log("play: fast resume (stream already loaded)");
      AnalyticsService.instance.resumeListening();
      return player.play();
    }

    // Need to load a new stream source
    PerformanceMonitor.startOperation('audio_play');
    _isConnecting = true;
    _broadcastState(player.playbackEvent);
    var retry = 0;
    Object? lastError;
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
          final trackedUrl = addTrackingParametersToUrl(streamUrl);
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
          _log("play: source loaded successfully ($trackedUrl)");
          break;
        } catch (e) {
          lastError = e;
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
        final stationName = currentStation.valueOrNull?.title ?? '';
        final classifiedError = _classifyError(stationName, lastError);
        connectionError.add(classifiedError);
        AnalyticsService.instance.endListening(reason: 'error');
        AnalyticsService.instance.captureException(
          lastError ?? Exception('Max retries reached'),
          null,
          context: 'play_station_failed:${classifiedError.reason.name}',
        );
        _stopDueToError();
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
      _seekBehindLiveEdge(); // non-blocking: seek starts, play() follows immediately
    }

    return player.play();
  }

  @override
  Future<void> pause() async {
    _log("pause");
    _cancelInFlightPlay();
    _hasBeenPlayed = false;
    AnalyticsService.instance.endListening(reason: 'pause');
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
      // Keep polling if car is connected — user sees metadata on car screen
      final carConnected = GetIt.instance.isRegistered<CarPlayService>() &&
          GetIt.instance<CarPlayService>().isConnected;
      if (!carConnected) {
        stationDataService.pausePolling();
      }
    });

    return super.pause();
  }

  /// Applies a new seek offset: refreshes station metadata (so now_playing
  /// matches the new offset) and restarts the HLS stream if currently playing.
  Future<void> reapplySeekOffset() async {
    // Immediately re-fetch stations with the new timestamp offset
    stationDataService.refreshStations();

    if (_loadedStreamType != 'HLS' || !player.playing) return;
    _log('reapplySeekOffset: restarting HLS stream with new offset');
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await play();
  }

  /// Re-emits the current media item so that thumbnail and metadata reflect
  /// the latest data-saving settings (unstable connection, mobile data, etc.).
  void refreshCurrentMetadata() {
    final station = currentStation.valueOrNull;
    if (station == null || mediaItem.valueOrNull == null) return;
    final item = _buildStationMediaItem(station);
    _lastEmittedSongId = -1; // force re-evaluation on next poll
    _lastEmittedArtUriString = item.artUri?.toString();
    final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
    mediaItem.add(item.copyWith(rating: Rating.newHeartRating(isFav)));
  }

  /// For HLS streams with retained segments, seeks behind the live edge
  /// so the buffer fills instantly at network speed. The offset is controlled
  /// by SeekModeManager (Instant / 2 min / 4 min). Applied on both WiFi
  /// and mobile data for resilience during network transitions (e.g. leaving
  /// WiFi range when connecting to CarPlay).
  ///
  /// Non-blocking: fires the seek without awaiting so player.play() can
  /// start immediately. Both AVFoundation and ExoPlayer correctly play
  /// from the seek target when play() overlaps an in-progress seek.
  void _seekBehindLiveEdge() {
    final offset = SeekModeManager.currentOffset;
    if (offset == Duration.zero) {
      _log('_seekBehindLiveEdge: instant mode, skipping');
      return;
    }
    final duration = player.duration;
    if (duration == null || duration.inSeconds < 10) {
      _log('_seekBehindLiveEdge: no duration or too short ($duration), skipping');
      return;
    }
    // Clamp: if offset exceeds the window, seek to the beginning instead of skipping
    final effectiveOffset = offset > duration - const Duration(seconds: 5)
        ? duration - const Duration(seconds: 5)
        : offset;
    final seekTarget = duration - effectiveOffset;
    _log('_seekBehindLiveEdge: duration=$duration, offset=$offset, effectiveOffset=$effectiveOffset, seeking to $seekTarget');
    player.seek(seekTarget).catchError((e) {
      _log('_seekBehindLiveEdge: seek failed ($e), continuing from live edge');
    });
  }

  /// Stops playback after an error WITHOUT calling super.stop().
  /// This keeps MPRemoteCommandCenter alive so CarPlay/lock-screen
  /// next/prev/play buttons still work and the user can recover.
  Future<void> _stopDueToError() async {
    _log("_stopDueToError (keeping command center alive)");
    _cancelInFlightPlay();
    _hasBeenPlayed = false;
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await player.stop();
    // Broadcast stopped state with controls still available (no super.stop())
    _broadcastState(player.playbackEvent);
  }

  @override
  Future<void> stop() async {
    _log("stop");
    _cancelInFlightPlay();
    _hasBeenPlayed = false;
    AnalyticsService.instance.endListening();
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await player.stop();
    return super.stop();
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) {
    _log('playFromSearch($query, $extras)');

    final stations = stationDataService.stations.value;
    if (stations.isEmpty) return super.playFromSearch(query, extras);

    var maxR = 0;
    late Station selectedStation;
    for (var v in stations) {
      var r = partialRatio(v.title, query);
      if (r > maxR) {
        maxR = r;
        selectedStation = v;
      }
    }
    if (maxR > 0) {
      return playStation(selectedStation);
    } else {
      return playStation(stations[0]);
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
    // History items: tapping keeps the current station playing
    if (mediaItem.id.startsWith('history_')) return;
    final stationId = mediaItem.extras?["station_id"];
    var station = stationDataService.stations.value.cast<Station?>()
        .firstWhere((element) => element!.id == stationId, orElse: () => null);

    // In release mode, Android Auto can call playMediaItem before stations
    // have loaded from the API. Wait for the first non-empty emission.
    if (station == null && stationDataService.stations.value.isEmpty) {
      _log('playMediaItem: stations not loaded yet, waiting...');
      try {
        await stationDataService.stations.stream
            .firstWhere((stations) => stations.isNotEmpty)
            .timeout(const Duration(seconds: 10));
        station = stationDataService.stations.value.cast<Station?>()
            .firstWhere((element) => element!.id == stationId, orElse: () => null);
      } catch (e) {
        _log('playMediaItem: timeout waiting for stations: $e');
      }
    }

    if (station != null) {
      final fromFavorites = mediaItem.extras?['fromFavorites'] as bool?;
      playStation(station, fromFavorites: fromFavorites);
    } else {
      _log('playMediaItem: station not found for $stationId');
    }
  }

  // Metadata refresh
  SongLikeService get _songLikeService => GetIt.instance<SongLikeService>();

  String _buildSongInfo(Station station) {
    final title = station.songTitle;
    final artist = station.songArtist;
    if (artist.isNotEmpty) return '$title - $artist';
    if (title.isNotEmpty) return title;
    return station.title;
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    final station = currentStation.valueOrNull;
    final isFav = station != null &&
        stationDataService.favoriteStationSlugs.value.contains(station.slug);
    final songId = station?.songId ?? -1;
    final likeStatus = _songLikeService.getLikeStatus(songId);
    final isLiked = likeStatus == 1;
    final isDisliked = likeStatus == -1;

    playbackState.add(playbackState.value.copyWith(
      controls: [
        // [0] Favorite toggle
        MediaControl.custom(
          androidIcon: isFav ? 'drawable/ic_favorite' : 'drawable/ic_favorite_border',
          label: isFav
              ? (_isRomanian ? 'Elimină din favorite' : 'Remove from favorites')
              : (_isRomanian ? 'Adaugă la favorite' : 'Add to favorites'),
          name: 'toggleFavorite',
        ),
        // [1] Recent songs
        MediaControl.custom(
          androidIcon: 'drawable/ic_history',
          label: _isRomanian ? 'Melodii recente' : 'Recent songs',
          name: 'showSongHistory',
        ),
        // [2] Like song (outline when not liked, filled when liked)
        MediaControl.custom(
          androidIcon: isLiked ? 'drawable/ic_thumb_up' : 'drawable/ic_thumb_up_outline',
          label: isLiked
              ? (_isRomanian ? 'Retrage like' : 'Remove like')
              : (_isRomanian ? 'Îmi place' : 'Like'),
          name: 'likeSong',
        ),
        // [3] Previous
        MediaControl.skipToPrevious,
        // [4] Play/Pause
        if (playing) MediaControl.pause else MediaControl.play,
        // [5] Next
        MediaControl.skipToNext,
        // [6] Dislike song (outline when not disliked, filled when disliked)
        MediaControl.custom(
          androidIcon: isDisliked ? 'drawable/ic_thumb_down' : 'drawable/ic_thumb_down_outline',
          label: isDisliked
              ? (_isRomanian ? 'Retrage dislike' : 'Remove dislike')
              : (_isRomanian ? 'Nu îmi place' : 'Dislike'),
          name: 'dislikeSong',
        ),
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setRating,
        MediaAction.skipToQueueItem,
      },
      androidCompactActionIndices: const [3, 4, 5],
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
    if (query.isEmpty) return stationsMediaItems.value;
    final lowerQuery = query.toLowerCase();
    final results = stationsMediaItems.value.where((item) {
      final title = (item.title ?? '').toLowerCase();
      final artist = (item.artist ?? '').toLowerCase();
      final displayTitle = (item.displayTitle ?? '').toLowerCase();
      final displaySubtitle = (item.displaySubtitle ?? '').toLowerCase();
      return title.contains(lowerQuery) ||
          artist.contains(lowerQuery) ||
          displayTitle.contains(lowerQuery) ||
          displaySubtitle.contains(lowerQuery);
    }).toList();
    _log('search -> ${results.length} results');
    return results;
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
    AnalyticsService.instance.endListening(reason: 'app_killed');
    AnalyticsService.instance.flush();
    player.stop();
    stationDataService.dispose();
    return super.onTaskRemoved();
  }

  // Method to completely stop and cleanup the audio service
  Future<void> dispose() async {
    _log('dispose()');
    _cancelInFlightPlay();
    _disconnectTimer?.cancel();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await player.stop();
    await player.dispose();
    stationDataService.dispose();
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
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    _log('playFromMediaId($mediaId, $extras)');
    // History items: tapping keeps the current station playing
    if (mediaId.startsWith('history_')) return;
    var selectedMediaItem = stationsMediaItems.value.cast<MediaItem?>()
        .firstWhere((item) => item!.id == mediaId, orElse: () => null);

    // Wait for stations to load if not yet available (release mode race condition)
    if (selectedMediaItem == null && stationsMediaItems.value.isEmpty) {
      _log('playFromMediaId: waiting for stations to load...');
      try {
        await stationsMediaItems.stream
            .firstWhere((items) => items.isNotEmpty)
            .timeout(const Duration(seconds: 10));
        selectedMediaItem = stationsMediaItems.value.cast<MediaItem?>()
            .firstWhere((item) => item!.id == mediaId, orElse: () => null);
      } catch (e) {
        _log('playFromMediaId: timeout waiting for stations: $e');
      }
    }

    if (selectedMediaItem != null) {
      // The system passes extras from getChildren (includes fromFavorites).
      // Merge them into the media item so playMediaItem can read the flag.
      if (extras != null && extras.containsKey('fromFavorites')) {
        selectedMediaItem = selectedMediaItem.copyWith(
          extras: {...?selectedMediaItem.extras, 'fromFavorites': extras['fromFavorites']},
        );
      }
      return playMediaItem(selectedMediaItem);
    }
  }


  String get currentStreamUrl {
    return mediaItem.value?.id ?? "-";
  }

  /// Called on foreground resume or connectivity restore. Reconnects if the
  /// stream was silently lost (idle) or stalled waiting for data (buffering).
  void reconnectIfNeeded() {
    if (currentStation.valueOrNull == null) return;
    if (_isConnecting) return;
    if (!_hasBeenPlayed) return;
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
    await _prefs.setString(LAST_PLAYED_MEDIA_ITEM, station.slug);
  }

  Future<Station?> getLastPlayedStation() async {
    final stations = stationDataService.stations.value;
    if (stations.isEmpty) return null;
    var stationSlug = _prefs.getString(LAST_PLAYED_MEDIA_ITEM);
    return stations.firstWhere(
      (station) => station.slug == stationSlug,
      orElse: () => stations.first,
    );
  }

  Future<void> setStationIsFavorite(Station station, bool isFavorite) async {
    await stationDataService.setStationIsFavorite(station, isFavorite);
    // Update MediaItem rating so MediaSession reflects the new favorite state
    final currentItem = mediaItem.valueOrNull;
    if (currentItem != null && currentStation.value?.slug == station.slug) {
      mediaItem.add(currentItem.copyWith(rating: Rating.newHeartRating(isFavorite)));
      // Update notification/Android Auto favorite icon
      _broadcastState(player.playbackEvent);
    }
    Utils.incrementActionsMade(
      graphQLClient: graphqlClient,
      currentStationName: currentStation.valueOrNull?.title,
    );
  }

  void _initUpdateCurrentStationMetadata() {
    // When mobile data toggles: re-emit metadata with station thumbnail.
    // Metadata text (song name/artist) is always shown since differential
    // fetching is lightweight. Only difference: skip song thumbnail download.
    NetworkService.instance.isOnMobileData.stream.listen((onMobile) {
      _log("isOnMobileData changed: $onMobile");
      final station = currentStation.valueOrNull;
      if (station == null || mediaItem.valueOrNull == null) return;

      // Re-emit with station thumbnail (cached on disk, no download needed)
      final item = _buildStationMediaItem(station);
      _lastEmittedSongId = onMobile ? -1 : station.songId;
      _lastEmittedArtUriString = item.artUri?.toString();
      final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
      mediaItem.add(item.copyWith(rating: Rating.newHeartRating(isFav)));
      if (!onMobile) {
        _ensureStationArtCached(station);
      }
    });

    // When car connects/disconnects: re-emit metadata with station thumbnail.
    // Metadata text is always shown (differential fetching is lightweight).
    // Car mode only skips song thumbnail downloads — uses cached station thumbnails.
    if (GetIt.instance.isRegistered<CarPlayService>()) {
      GetIt.instance<CarPlayService>().isCarConnected.stream.listen((connected) {
        _log("Car connection changed: $connected");
        final station = currentStation.valueOrNull;
        if (station == null || mediaItem.valueOrNull == null) return;

        // Re-emit with station thumbnail and full metadata text
        final item = _buildStationMediaItem(station);
        _lastEmittedSongId = connected ? -1 : station.songId;
        _lastEmittedArtUriString = item.artUri?.toString();
        final isFav = stationDataService.favoriteStationSlugs.value.contains(station.slug);
        mediaItem.add(item.copyWith(rating: Rating.newHeartRating(isFav)));
      });
    }

    // When connectivity is restored: reconnect stalled audio if the app is in
    // foreground OR CarPlay/Android Auto is connected (user may be driving with
    // the phone screen off). Delay 2s so the network is actually usable.
    NetworkService.instance.isOffline.stream.listen((offline) {
      if (offline) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final carPlayConnected = GetIt.instance.isRegistered<CarPlayService>() && GetIt.instance<CarPlayService>().isConnected;
      if (lifecycle != AppLifecycleState.resumed && !carPlayConnected) {
        _log("isOffline -> false: app not in foreground ($lifecycle) and CarPlay not connected, skipping reconnect");
        return;
      }
      _log("isOffline -> false: will reconnect in 2s (foreground=${lifecycle == AppLifecycleState.resumed}, carPlay=$carPlayConnected)");
      Future.delayed(const Duration(seconds: 2), () {
        _log("isOffline -> false: checking if player needs reconnect");
        reconnectIfNeeded();
      });
    });

    // Station data poll: update metadata when stations change.
    stationDataService.stations.stream.listen((stations) {
      _log("updateCurrentStationMetadata");

      Station? updatedCurrentStation;
      if(currentStation.valueOrNull != null) {
        updatedCurrentStation = stations.cast<Station?>().firstWhere((element) => element!.id == currentStation.value!.id, orElse: () => null);
        if (updatedCurrentStation != null) currentStation.add(updatedCurrentStation);
      }

      // Use the app's sort preference for the media browse tree so Android
      // Auto's built-in media browser matches the custom UI order.
      // Always use HTTPS artUri (not file:// cached paths) because Android
      // Auto's system player runs in a separate process.
      final sortedStations = stationDataService.getSortedStations();
      final newStationsMediaItems = sortedStations.map((station) {
        final thumbnailUrl = station.rawStationData.thumbnail_url;
        final artUri = (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
            ? Uri.parse(thumbnailUrl)
            : Uri.parse(CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL);
        final item = station.mediaItem;
        // Strip "Radio " prefix for the A-Z alphabet index so letters
        // distribute evenly instead of clustering under "R".
        final title = station.rawStationData.title;
        final sortKey = title.startsWith('Radio ')
            ? title.substring(6)
            : title;
        final extras = Map<String, dynamic>.from(item.extras ?? {});
        extras['android.media.extra.SORT_KEY'] = sortKey;
        return item.copyWith(artUri: artUri, extras: extras);
      }).toList();

      stationsMediaItems.add(newStationsMediaItems);

      if (mediaItem.value != null && updatedCurrentStation != null) {
        final newSongId = updatedCurrentStation.songId;
        final songChanged = newSongId != _lastEmittedSongId;

        if (songChanged) {
          final isFav = stationDataService.favoriteStationSlugs.value.contains(updatedCurrentStation.slug);

          // Always show metadata text (song name/artist) — differential fetching is lightweight.
          // Data saving modes (mobile data, car, unstable) only differ in thumbnail handling:
          // they use the station thumbnail (cached on disk) instead of downloading song thumbnails.
          final newItem = _buildStationMediaItem(updatedCurrentStation);
          _lastEmittedSongId = newSongId;
          _lastEmittedArtUriString = newItem.artUri?.toString();
          mediaItem.add(newItem.copyWith(rating: Rating.newHeartRating(isFav)));

          // In unstable mode, additionally pre-cache song thumbnails to disk
          if (SeekModeManager.isUnstableConnection) {
            _ensureSongThumbnailCachedPermanently(updatedCurrentStation);
          }

          // Refresh queue with latest song history when song changes
          _updateSongHistoryQueue();
        }
      }
    });
  }
}
