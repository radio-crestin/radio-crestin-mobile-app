import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:flutter_airplay/flutter_airplay.dart' as flutter_airplay;
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/services/car_play_service.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/cast_service.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart' show CastMediaPlayerState;
import 'package:radio_crestin/tv/tv_platform.dart';
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

/// Snapshot of the currently loaded stream. Drives the diagnostic UI in
/// Settings and is included in PostHog `listening_*` heartbeats so sessions
/// can be correlated with stream switches.
class StreamInfo {
  final String url;
  final String? type;        // 'HLS', 'proxied_stream', etc. — from station_streams.type
  final int attemptIndex;    // 0-based index into the station's stream list
  final int totalStreams;
  final String stationSlug;
  final String stationTitle;
  final DateTime loadedAt;

  const StreamInfo({
    required this.url,
    required this.type,
    required this.attemptIndex,
    required this.totalStreams,
    required this.stationSlug,
    required this.stationTitle,
    required this.loadedAt,
  });

  String get host {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}

enum StreamEventKind {
  attempt,            // play() trying to load a stream
  loaded,             // setAudioSource succeeded
  failed,             // setAudioSource raised
  switched,           // loaded URL differs from previous loaded URL
  hlsCompleted,       // HLS reported processingState == completed
  nonHlsCompleted,    // direct MP3 completed (treated as error)
  lostIdle,           // processingState == idle while playing
  bufferingStall,     // buffering exceeded long-stall threshold (15s)
  bufferingDrop,      // brief rebuffer (>=100ms): the audible-glitch case
  playerError,        // playbackEventStream raised (error not tied to load attempt)
  audioInterruption,  // AVAudioSession interruption begin/end (route change, call, lock)
  lifecycle,          // app lifecycle transitions (resumed/inactive/paused/hidden)
  microStall,         // position didn't advance while playing (sub-buffering glitch)
}

/// Lightweight event record kept in a capped ring buffer for the in-app
/// diagnostic view.
class StreamEvent {
  final DateTime timestamp;
  final StreamEventKind kind;
  final String message;

  const StreamEvent({
    required this.timestamp,
    required this.kind,
    required this.message,
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
        // automaticallyWaitsToMinimizeStalling: tried false in c52d785 to
        // skip AVPlayer's pre-emptive pause; users reported playback
        // stopping permanently in background with no events fired (likely
        // AVPlayer entering a silent ready-state). Reverted to true. The
        // rebuffer-with-full-buffer hiccup needs a different approach.
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
  bool get isCasting => GetIt.instance.isRegistered<CastService>() &&
      GetIt.instance<CastService>().isCasting.value;
  bool _hasBeenPlayed = false;
  Timer? _disconnectTimer;

  // HLS EXT-X-PROGRAM-DATE-TIME tracking — used to compute the exact
  // Unix timestamp of the audio the user is hearing, for metadata sync.
  int? _hlsFirstSegmentEpoch;
  Timer? _hlsPlaylistRefreshTimer;
  // Most recent EXT-X-DATERANGE `ID` parsed from the active HLS playlist.
  // Compared (not counted) so the same group seen across consecutive
  // playlist windows does not retrigger a refresh.
  String? _lastSeenDateRangeId;
  Timer? _bufferingStallTimer;
  static const _bufferingStallTimeout = Duration(seconds: 15);

  // ── iOS background-suspension keep-alive ──────────────────────────
  // When the main player enters `buffering` and audio output stops, iOS
  // gives the app ~30–60s before suspending it (even with the `audio`
  // background mode). Suspension freezes the entire Dart isolate, so
  // every reconnect/retry path stops working — the user hears silence
  // until they bring the app back to the foreground. To prevent that,
  // we spin up a secondary player looping `assets/silence.m4a` whenever
  // the main player is buffering for more than _silenceKeepAliveDelay.
  // iOS sees continuous audio output and never suspends the engine, so
  // the recovery code (idle-while-playing, isOffline-restored, the
  // stall-timer reattempt) keeps running.
  AudioPlayer? _silenceKeeper;
  Timer? _silenceKeepAliveStartTimer;
  bool _silenceKeeperPlaying = false;
  static const _silenceKeepAliveDelay = Duration(seconds: 3);
  static const _silenceKeepAliveAsset = 'assets/silence.m4a';
  // Track every buffering enter/exit so short rebuffers (the audible-glitch
  // case) get logged. _bufferingStallTimer above is the long-stall escalation.
  // 250ms threshold: tried 100ms during the screen-lock investigation but
  // it surfaced sub-perceptual decoder reseeds the user wouldn't actually
  // hear, bloating the ring with noise that pushed real events out.
  static const _bufferingDropMinDuration = Duration(milliseconds: 250);
  DateTime? _bufferingStartedAt;
  Duration _bufferingStartPosition = Duration.zero;
  Duration _bufferingStartBuffered = Duration.zero;
  // Dedup playbackEventStream errors so a sticky error doesn't spam the log.
  int? _lastPlayerErrorCode;
  String? _lastPlayerErrorMessage;
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

  /// Currently loaded stream (null when stopped, paused-and-disconnected, or casting).
  final BehaviorSubject<StreamInfo?> currentStreamInfo = BehaviorSubject.seeded(null);

  /// Capped ring buffer of recent stream lifecycle events for in-app debugging.
  /// Most recent first; `_maxStreamEvents` keeps memory bounded.
  /// 60 entries: enough headroom to capture a full reload-loop investigation
  /// (every cycle is ~3 events: attempt + loaded + rebuffer, plus lifecycle
  /// + interruption noise) without truncating the trigger event.
  static const int _maxStreamEvents = 60;
  /// Suppresses spurious `completed` / `idle-while-playing` reloads that fire
  /// within this window of a successful load. AVPlayer occasionally
  /// mis-reports terminal state for live HLS during PDT-decoder confusion;
  /// without this debounce we re-issue play() every ~3s and create a reload
  /// loop visible to the user as repeated startup hiccups.
  static const _terminalStateReloadDebounce = Duration(seconds: 8);
  DateTime? _lastSuccessfulLoadAt;
  final BehaviorSubject<List<StreamEvent>> recentStreamEvents =
      BehaviorSubject.seeded(const <StreamEvent>[]);

  void _recordStreamEvent(StreamEventKind kind, String message) {
    final event = StreamEvent(
      timestamp: DateTime.now(),
      kind: kind,
      message: message,
    );
    final next = <StreamEvent>[event, ...recentStreamEvents.value];
    if (next.length > _maxStreamEvents) {
      next.removeRange(_maxStreamEvents, next.length);
    }
    recentStreamEvents.add(next);
  }

  /// Called when processingState transitions out of [ProcessingState.buffering].
  /// Records a `bufferingDrop` event when the rebuffer was perceptibly long
  /// (≥250ms) — below that threshold transitions are sub-perceptual decoder
  /// reseeding and would just add noise to the diagnostic log.
  void _recordBufferingExit(ProcessingState endState) {
    final startedAt = _bufferingStartedAt;
    if (startedAt == null) return;
    _bufferingStartedAt = null;
    final duration = DateTime.now().difference(startedAt);
    if (duration < _bufferingDropMinDuration) return;
    final positionEnd = player.position;
    final positionStart = _bufferingStartPosition;
    final bufferedAheadAtStart = _bufferingStartBuffered - positionStart;
    final lastInfo = currentStreamInfo.valueOrNull;
    _recordStreamEvent(
      StreamEventKind.bufferingDrop,
      'Rebuffer ${duration.inMilliseconds}ms — buf ${bufferedAheadAtStart.inMilliseconds}ms ahead at start, end=${endState.name}',
    );
    AnalyticsService.instance.capture('stream_buffering_drop', {
      'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
      'station_id': currentStation.valueOrNull?.id,
      'stream_url': lastInfo?.url,
      'stream_type': lastInfo?.type,
      'stream_index': lastInfo?.attemptIndex,
      'total_streams': lastInfo?.totalStreams,
      'duration_ms': duration.inMilliseconds,
      'position_start_ms': positionStart.inMilliseconds,
      'position_end_ms': positionEnd.inMilliseconds,
      'buffered_ahead_at_start_ms': bufferedAheadAtStart.inMilliseconds,
      'end_state': endState.name,
    });
  }

  /// Subscriber for `playbackEventStream.onError`. just_audio surfaces
  /// transient errors here without changing processingState (e.g. iOS HLS
  /// segment errors that the player recovers from). Dedup against the last
  /// emitted code/message so a sticky error doesn't spam the log.
  void _onPlayerStreamError(Object error, StackTrace stackTrace) {
    _log('playbackEventStream error: $error');
    int? code;
    String? msg;
    if (error is PlayerException) {
      code = error.code;
      msg = error.message;
    } else {
      msg = error.toString();
    }
    if (code == _lastPlayerErrorCode && msg == _lastPlayerErrorMessage) return;
    _lastPlayerErrorCode = code;
    _lastPlayerErrorMessage = msg;
    final lastInfo = currentStreamInfo.valueOrNull;
    final shortMsg = msg == null
        ? ''
        : (msg.length > 120 ? msg.substring(0, 120) : msg);
    _recordStreamEvent(
      StreamEventKind.playerError,
      'Player error${code != null ? ' code=$code' : ''}${shortMsg.isNotEmpty ? ': $shortMsg' : ''}',
    );
    AnalyticsService.instance.capture('stream_player_error', {
      'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
      'station_id': currentStation.valueOrNull?.id,
      'stream_url': lastInfo?.url,
      'stream_type': lastInfo?.type,
      'stream_index': lastInfo?.attemptIndex,
      'total_streams': lastInfo?.totalStreams,
      'error_code': code,
      'error_message': msg,
      'error_runtime_type': error.runtimeType.toString(),
    });
  }

  _log(String message) {
    developer.log("AppAudioHandler: $message");
  }

  /// Compact error description for logs/PostHog (avoids dumping multi-line stack traces).
  static String _shortErr(Object e) {
    if (e is TimeoutException) return 'TimeoutException';
    if (e is PlayerException) return 'PlayerException(${e.code}): ${e.message ?? ''}';
    if (e is SocketException) return 'SocketException: ${e.message}';
    final s = e.toString();
    return s.length > 200 ? s.substring(0, 200) : s;
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
    stationDataService.getActualPlaybackOffset = () {
      if (_loadedStreamType != 'HLS' || !player.playing) return null;
      final duration = player.duration;
      final position = player.position;
      if (duration == null || duration.inSeconds < 10) return null;
      final offset = duration - position;
      // Sanity check: offset should be positive and reasonable (< 10 minutes)
      if (offset.inSeconds <= 0 || offset.inMinutes > 10) return null;
      return offset;
    };
    stationDataService.getHlsPlaybackTimestamp = () {
      if (_loadedStreamType != 'HLS' || !player.playing) return null;
      if (_hlsFirstSegmentEpoch == null) return null;
      final positionSec = player.position.inSeconds;
      final epoch = _hlsFirstSegmentEpoch! + positionSec;
      // Align to 10s to match the API's timestamp granularity
      return (epoch ~/ 10) * 10;
    };
    stationDataService.isPlayingHls = () =>
        _loadedStreamType == 'HLS' && player.playing;
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
    // Errors raised on this stream (PlayerException etc.) are surfaced through
    // onError — these can fire without changing processingState (e.g., iOS
    // AVAudio session resets, transient HLS segment errors) and without them
    // a brief glitch leaves no trace in the diagnostic log.
    player.playbackEventStream.listen(
      _broadcastState,
      onError: _onPlayerStreamError,
    );

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
      // Record any buffering exit before per-state handling — captures every
      // brief rebuffer ≥250ms regardless of how the buffering ended.
      if (_bufferingStartedAt != null && state != ProcessingState.buffering) {
        _recordBufferingExit(state);
      }

      if (state == ProcessingState.completed) {
        _bufferingStallTimer?.cancel();
        if (_isConnecting) return;
        final isHls = _loadedStreamType == 'HLS';
        if (isHls) {
          // AVPlayer occasionally reports `completed` for live HLS streams
          // during PDT-decoder confusion in the first few seconds after
          // load. Without a debounce we re-issue play() and create a 3s
          // reload loop visible to the user as repeated startup hiccups
          // (5x "Attempt → Loaded → Rebuffer" within 10s, all with the
          // textbook 132009ms buf-ahead). Suppress reload if we just
          // loaded successfully.
          final lastLoad = _lastSuccessfulLoadAt;
          if (lastLoad != null &&
              DateTime.now().difference(lastLoad) < _terminalStateReloadDebounce) {
            _log("processingStateStream: HLS completed within debounce window — ignoring (likely PDT confusion, not real EOS)");
            _recordStreamEvent(
              StreamEventKind.hlsCompleted,
              'HLS completed (debounced — recently loaded)',
            );
            return;
          }
          _log("processingStateStream: HLS stream completed unexpectedly, reconnecting");
          final lastInfo = currentStreamInfo.valueOrNull;
          _recordStreamEvent(
            StreamEventKind.hlsCompleted,
            'HLS completed unexpectedly — reconnecting',
          );
          AnalyticsService.instance.capture('stream_unexpected_completion', {
            'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
            'station_id': currentStation.valueOrNull?.id,
            'stream_url': lastInfo?.url,
            'stream_type': lastInfo?.type ?? 'HLS',
            'stream_index': lastInfo?.attemptIndex,
            'total_streams': lastInfo?.totalStreams,
            'ms_since_loaded': lastInfo == null
                ? null
                : DateTime.now().difference(lastInfo.loadedAt).inMilliseconds,
          });
          _loadedStreamUrl = null;
          _loadedStreamType = null;
          play();
        } else {
          _log("processingStateStream: non-HLS stream completed unexpectedly");
          final lastInfo = currentStreamInfo.valueOrNull;
          _recordStreamEvent(
            StreamEventKind.nonHlsCompleted,
            'Non-HLS stream completed — stopping',
          );
          AnalyticsService.instance.capture('stream_unexpected_completion', {
            'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
            'station_id': currentStation.valueOrNull?.id,
            'stream_url': lastInfo?.url,
            'stream_type': lastInfo?.type,
            'stream_index': lastInfo?.attemptIndex,
            'total_streams': lastInfo?.totalStreams,
            'ms_since_loaded': lastInfo == null
                ? null
                : DateTime.now().difference(lastInfo.loadedAt).inMilliseconds,
          });
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
        // Same debounce as the `completed` branch — AVPlayer briefly
        // dipping into idle-while-playing within a few seconds of a
        // successful load is a PDT/decoder edge case, not a real
        // network drop. Don't re-issue play() while the source is
        // still considered healthy.
        final lastLoad = _lastSuccessfulLoadAt;
        if (lastLoad != null &&
            DateTime.now().difference(lastLoad) < _terminalStateReloadDebounce) {
          _log("processingStateStream: idle-while-playing within debounce window — ignoring");
          _recordStreamEvent(
            StreamEventKind.lostIdle,
            'Stream idle-while-playing (debounced — recently loaded)',
          );
          return;
        }
        _log("processingStateStream: stream lost (idle while playing), reconnecting");
        final lastInfo = currentStreamInfo.valueOrNull;
        _recordStreamEvent(
          StreamEventKind.lostIdle,
          'Stream lost (idle while playing) — reconnecting',
        );
        AnalyticsService.instance.capture('stream_lost_idle', {
          'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
          'station_id': currentStation.valueOrNull?.id,
          'stream_url': lastInfo?.url,
          'stream_type': lastInfo?.type,
          'stream_index': lastInfo?.attemptIndex,
          'total_streams': lastInfo?.totalStreams,
          'ms_since_loaded': lastInfo == null
              ? null
              : DateTime.now().difference(lastInfo.loadedAt).inMilliseconds,
        });
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        play();
      } else if (state == ProcessingState.buffering && player.playing && !_isConnecting) {
        // Capture the moment buffering started, with position + buffered
        // position. The gap (buffered - position) at start tells us whether
        // the network drained ahead of time (small gap = network slow) or
        // the decoder stalled on a buffered segment (large gap = server
        // segment problem). This is the highest-signal data for short
        // audible glitches.
        // Capture position/buffered only on first entry per buffering episode,
        // mirroring _bufferingStartedAt — otherwise a re-emission of the same
        // state would silently advance the snapshot while the timer keeps
        // counting from the original moment, skewing buf-ahead-at-start.
        if (_bufferingStartedAt == null) {
          _bufferingStartedAt = DateTime.now();
          _bufferingStartPosition = player.position;
          _bufferingStartBuffered = player.bufferedPosition;
          _scheduleSilenceKeepAlive();
        }
        // Stall timer: if buffering doesn't resolve within 15s, kick a
        // fresh play() instead of giving up. play() has its own retry
        // chain (maxRetries=4 across the station's stream URLs) and will
        // surface a connectionError only after all of those fail. Goal:
        // the stream auto-recovers without the user noticing — never
        // stop on a transient network blip.
        _bufferingStallTimer?.cancel();
        _bufferingStallTimer = Timer(_bufferingStallTimeout, () {
          if (player.processingState == ProcessingState.buffering && player.playing) {
            _log("processingStateStream: buffering stalled for ${_bufferingStallTimeout.inSeconds}s, reattempting play()");
            final lastInfo = currentStreamInfo.valueOrNull;
            _recordStreamEvent(
              StreamEventKind.bufferingStall,
              'Buffering stalled ${_bufferingStallTimeout.inSeconds}s — reattempting',
            );
            AnalyticsService.instance.capture('stream_buffering_stall', {
              'station_slug': lastInfo?.stationSlug ?? currentStation.valueOrNull?.slug ?? '',
              'station_id': currentStation.valueOrNull?.id,
              'stream_url': lastInfo?.url,
              'stream_type': lastInfo?.type,
              'stream_index': lastInfo?.attemptIndex,
              'total_streams': lastInfo?.totalStreams,
              'stall_seconds': _bufferingStallTimeout.inSeconds,
              'action': 'reattempt',
            });
            // Force play() to re-issue setAudioSource (rather than skip
            // because the URL is "already loaded").
            _loadedStreamUrl = null;
            _loadedStreamType = null;
            play();
          }
        });
      } else if (state == ProcessingState.ready) {
        _bufferingStallTimer?.cancel();
        _stopSilenceKeepAlive();
      } else {
        _stopSilenceKeepAlive();
      }
    });

    await player.setLoopMode(LoopMode.off);
    // Note: just_audio handles audio session interruptions automatically via
    // handleInterruptions: true (default). It pauses on interruption begin and
    // resumes on interruption end when shouldResume=true.
    //
    // We additionally subscribe to AudioSession events for diagnostic purposes:
    // when the user reports a "hiccup on screen lock", knowing whether iOS
    // emitted an interruption (and its type) tells us whether the stall was
    // a route change, a system interruption (call/timer/Siri), or neither.
    _attachAudioSessionDiagnostics();
  }

  /// Subscribe to AudioSession interruption + becomingNoisy events and write
  /// them to the diagnostic ring buffer. Cheap (event-driven, no polling)
  /// and gives us ground truth on what iOS is signalling during transitions.
  Future<void> _attachAudioSessionDiagnostics() async {
    try {
      final session = await AudioSession.instance;
      session.interruptionEventStream.listen((event) {
        final phase = event.begin ? 'begin' : 'end';
        final type = event.type.name;
        _recordStreamEvent(
          StreamEventKind.audioInterruption,
          'AudioSession interruption $phase ($type)',
        );
        AnalyticsService.instance.capture('audio_session_interruption', {
          'phase': phase,
          'type': type,
          'player_processing_state': player.processingState.name,
          'player_playing': player.playing,
          'position_ms': player.position.inMilliseconds,
          'buffered_ms': player.bufferedPosition.inMilliseconds,
        });
      });
      session.becomingNoisyEventStream.listen((_) {
        _recordStreamEvent(
          StreamEventKind.audioInterruption,
          'AudioSession becoming noisy (route disconnect)',
        );
        AnalyticsService.instance.capture('audio_session_becoming_noisy', const {});
      });
    } catch (e) {
      _log('audio session diagnostics setup failed: $e');
    }
  }

  /// Public hook called by HomePage's didChangeAppLifecycleState. Logs every
  /// transition to the ring buffer so a screen-lock-triggered hiccup is
  /// visually adjacent to the lifecycle change in the user's diagnostic copy.
  void recordLifecycleTransition(String state) {
    _recordStreamEvent(
      StreamEventKind.lifecycle,
      'App lifecycle: $state',
    );
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
    _stopHlsPlaylistRefresh();
    if (player.playing || player.processingState != ProcessingState.idle) {
      await player.stop();
    }
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    _bufferingStartedAt = null;
    _lastPlayerErrorCode = null;
    _lastPlayerErrorMessage = null;
    // Clear stream context so listening_started for the new station and the
    // Settings diagnostic don't carry the previous station's URL/type/index
    // until play() loads the new source.
    currentStreamInfo.add(null);
    AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);

    await selectStation(station);

    // When casting, send directly to Chromecast — don't start local audio.
    if (isCasting) {
      _log('playStation: casting active, sending to Cast');
      _isConnecting = false;
      // Cast immediately — don't wait for the reactive listener chain
      final castService = GetIt.instance<CastService>();
      castService.lastCastSlug = station.slug;
      castService.castStation(station);
      setCastPlaying(true);
      return;
    }

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

  /// Determines the playback source for stream tracking.
  ///
  /// Priority order (most specific wins):
  /// 1. CarPlay / Android Auto (car connection active)
  /// 2. AirPlay (iOS audio routed to AirPlay device)
  /// 3. Android TV (leanback hardware)
  /// 4. Phone/tablet (default mobile)
  String _getPlaybackSource() {
    if (isCarConnected) {
      return Platform.isIOS ? 'carplay' : 'android-auto';
    }
    if (Platform.isIOS && flutter_airplay.AirPlayRouteState.instance.isActive) {
      return 'airplay';
    }
    if (TvPlatform.isAndroidTV) {
      return 'android-tv';
    }
    return Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'unknown');
  }

  String addTrackingParametersToUrl(String url) {
    final source = _getPlaybackSource();
    final deviceId = globals.deviceId;

    final uri = Uri.parse(url);
    final queryParams = Map<String, String>.from(uri.queryParameters);

    queryParams['ref'] = 'radio-crestin-$source';
    queryParams['s'] = deviceId;

    return uri.replace(queryParameters: queryParams).toString();
  }

  @override
  Future<void> play() async {
    _log("play (isCasting=$isCasting)");
    if (isCasting) {
      // Resume playback on Cast — just send play(), don't reload media.
      // Optimistic UI via setCastPlaying so the notification icon flips
      // to pause immediately; the receiver's PLAYING MediaStatus will
      // re-confirm shortly via the main.dart state sync listener.
      GetIt.instance<CastService>().play();
      setCastPlaying(true);
      _disconnectTimer?.cancel();
      stationDataService.resumePolling();
      return;
    }
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
    final previousStreamInfo = currentStreamInfo.valueOrNull;

    while (item != null && myOpId == _playOperationId) {
      if (retry < maxRetries) {
        var streams = item.extras?["station_streams"] as List<dynamic>?;
        // Desktop (Linux/Windows) uses just_audio_media_kit (libmpv ~2023-09) which
        // has flaky support for HLS v9 with query params. Prefer direct streams there.
        if (streams != null && (Platform.isWindows || Platform.isLinux)) {
          final reordered = List<dynamic>.from(streams);
          reordered.sort((a, b) {
            final aHls = (a is Map && a["type"]?.toString() == 'HLS') ? 1 : 0;
            final bHls = (b is Map && b["type"]?.toString() == 'HLS') ? 1 : 0;
            return aHls - bHls;
          });
          streams = reordered;
        }
        final totalStreams = streams?.length ?? 0;
        final streamEntry = streams?[retry % (totalStreams == 0 ? 1 : totalStreams)];
        final streamUrl = (streamEntry is Map ? streamEntry["url"] : streamEntry)?.toString() ?? item.id;
        final streamType = streamEntry is Map ? streamEntry["type"]?.toString() : null;
        final attemptIndex = totalStreams == 0 ? 0 : retry % totalStreams;
        final isHls = streamType == 'HLS';
        _log("play: attempt $retry - $streamUrl (type: $streamType)");

        final stationSlug = item.extras?["station_slug"]?.toString() ?? '';
        final stationId = item.extras?["station_id"];
        final stationTitle = item.extras?["station_title"]?.toString() ?? '';

        _recordStreamEvent(
          StreamEventKind.attempt,
          'Attempt ${attemptIndex + 1}/$totalStreams ${streamType ?? '?'}',
        );
        // Debug-only: high volume on healthy connections. Errors and switches
        // still ship in production via capture() below.
        AnalyticsService.instance.captureDebug('stream_attempt', {
          'station_slug': stationSlug,
          if (stationId != null) 'station_id': stationId,
          'stream_url': streamUrl,
          'stream_type': streamType,
          'stream_index': attemptIndex,
          'total_streams': totalStreams,
          'retry': retry,
        });

        final attemptStart = DateTime.now();
        try {
          if (retry > 0) {
            await player.stop();
          }
          final trackedUrl = addTrackingParametersToUrl(streamUrl);
          final loadUrl = trackedUrl;
          final timeout = isHls ? const Duration(seconds: 3) : const Duration(seconds: 10);
          // Race setAudioSource against the canceller so playStation() can
          // break this await immediately instead of waiting for the timeout.
          final loadFuture = player.setAudioSource(
            AudioSource.uri(Uri.parse(loadUrl)),
            preload: true,
          );
          // Prevent unhandled error if abandoned by Future.any
          loadFuture.ignore();
          await Future.any([loadFuture, canceller.future]).timeout(timeout);
          _loadedStreamUrl = streamUrl;
          _loadedStreamType = streamType;
          _lastSuccessfulLoadAt = DateTime.now();
          final elapsedMs = DateTime.now().difference(attemptStart).inMilliseconds;
          _log("play: source loaded successfully ($trackedUrl)");

          final newInfo = StreamInfo(
            url: streamUrl,
            type: streamType,
            attemptIndex: attemptIndex,
            totalStreams: totalStreams,
            stationSlug: stationSlug,
            stationTitle: stationTitle,
            loadedAt: DateTime.now(),
          );
          currentStreamInfo.add(newInfo);
          AnalyticsService.instance.setCurrentStream(
            url: streamUrl,
            type: streamType,
            index: attemptIndex,
            total: totalStreams,
          );

          _recordStreamEvent(
            StreamEventKind.loaded,
            '${streamType ?? '?'} loaded in ${elapsedMs}ms',
          );
          // Debug-only: paired with stream_attempt; the listening_active
          // heartbeat already carries the loaded URL/type for production.
          AnalyticsService.instance.captureDebug('stream_loaded', {
            'station_slug': stationSlug,
            if (stationId != null) 'station_id': stationId,
            'stream_url': streamUrl,
            'stream_type': streamType,
            'stream_index': attemptIndex,
            'total_streams': totalStreams,
            'elapsed_ms': elapsedMs,
            'retry': retry,
          });

          // Fire stream_switched only when the loaded URL differs from the
          // previously-loaded URL — distinguishes a true fallback switch from
          // a same-stream reconnect.
          if (previousStreamInfo != null && previousStreamInfo.url != streamUrl) {
            final reason = previousStreamInfo.stationSlug != stationSlug
                ? 'station_change'
                : (retry > 0 ? 'load_failed_fallback' : 'reconnect_to_different');
            _recordStreamEvent(
              StreamEventKind.switched,
              'Switched to ${streamType ?? '?'} #${attemptIndex + 1} ($reason)',
            );
            AnalyticsService.instance.capture('stream_switched', {
              'station_slug': stationSlug,
              if (stationId != null) 'station_id': stationId,
              'reason': reason,
              'previous_url': previousStreamInfo.url,
              'new_url': streamUrl,
              'previous_type': previousStreamInfo.type,
              'new_type': streamType,
              'previous_index': previousStreamInfo.attemptIndex,
              'new_index': attemptIndex,
              'retry_count': retry,
              'ms_since_last_load':
                  DateTime.now().difference(previousStreamInfo.loadedAt).inMilliseconds,
            });
          }
          break;
        } catch (e) {
          lastError = e;
          final elapsedMs = DateTime.now().difference(attemptStart).inMilliseconds;
          _loadedStreamUrl = null;
          _loadedStreamType = null;
          // If superseded by a newer playStation(), exit immediately
          if (myOpId != _playOperationId) {
            _log("play: cancelled (op $myOpId < $_playOperationId)");
            break;
          }
          _log("play: attempt $retry failed - $e");
          _recordStreamEvent(
            StreamEventKind.failed,
            'Attempt ${attemptIndex + 1}/$totalStreams failed (${elapsedMs}ms): ${_shortErr(e)}',
          );
          AnalyticsService.instance.capture('stream_failed', {
            'station_slug': stationSlug,
            if (stationId != null) 'station_id': stationId,
            'stream_url': streamUrl,
            'stream_type': streamType,
            'stream_index': attemptIndex,
            'total_streams': totalStreams,
            'retry': retry,
            'elapsed_ms': elapsedMs,
            'error': _shortErr(e),
          });
          retry++;
        }
      } else {
        _log("play: max retries reached");
        _isConnecting = false;
        _loadedStreamUrl = null;
        _loadedStreamType = null;
        currentStreamInfo.add(null);
        AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);
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
      _startHlsPlaylistRefresh(); // parse EXT-X-PROGRAM-DATE-TIME for metadata sync
    } else {
      _stopHlsPlaylistRefresh();
    }

    return player.play();
  }

  @override
  Future<void> pause() async {
    _log("pause (isCasting=$isCasting)");
    if (isCasting) {
      GetIt.instance<CastService>().pause();
      setCastPlaying(false);
      return;
    }
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
      currentStreamInfo.add(null);
      AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);
      player.setAudioSource(
        AudioSource.uri(Uri.parse(CONSTANTS.STATIC_MP3_URL)),
        preload: false,
      );
      // Keep polling if car or cast is connected — user sees metadata on screen
      final carConnected = GetIt.instance.isRegistered<CarPlayService>() &&
          GetIt.instance<CarPlayService>().isConnected;
      if (!carConnected && !isCasting) {
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

  /// Fetch the HLS playlist and extract the first EXT-X-PROGRAM-DATE-TIME epoch
  /// plus the latest EXT-X-DATERANGE entry. The PROGRAM-DATE-TIME is the
  /// authoritative timestamp for the first segment — combined with
  /// `player.position` it gives the exact epoch of the audio being played,
  /// used for metadata sync. The DATERANGE block carries the song-change
  /// signal: when the `ID` flips relative to the last fetch, fire an
  /// out-of-cycle metadata poll. This is **additive** over the 10s
  /// `/stations-metadata` REST poll — at 30s cadence it adds at most ~3
  /// extra lightweight HTTP fetches per minute and only triggers
  /// `refreshMetadataNow` when the song actually changes.
  Future<void> _refreshHlsPlaylistTimestamp() async {
    final url = _loadedStreamUrl;
    if (url == null || _loadedStreamType != 'HLS') return;
    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;
      bool epochResolved = false;
      String? latestDateRangeId;
      DateTime? latestDateRangeStart;
      for (final line in response.body.split('\n')) {
        if (!epochResolved && line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
          final dateStr = line.substring('#EXT-X-PROGRAM-DATE-TIME:'.length).trim();
          final dt = DateTime.tryParse(dateStr);
          if (dt != null) {
            _hlsFirstSegmentEpoch = dt.millisecondsSinceEpoch ~/ 1000;
            _log('_refreshHlsPlaylistTimestamp: first segment epoch=$_hlsFirstSegmentEpoch');
            epochResolved = true;
          }
        } else if (line.startsWith('#EXT-X-DATERANGE:')) {
          // Server emits multiple DATERANGE entries (window covers ~5 min of
          // segments) — pick the most recent by START-DATE so we react to the
          // currently announced song, not a stale one from the playlist tail.
          final match = RegExp(
            r'ID="([^"]+)".*?START-DATE="([^"]+)"',
          ).firstMatch(line);
          if (match != null) {
            final id = match.group(1)!;
            final start = DateTime.tryParse(match.group(2)!);
            if (start != null &&
                (latestDateRangeStart == null ||
                    start.isAfter(latestDateRangeStart))) {
              latestDateRangeId = id;
              latestDateRangeStart = start;
            }
          }
        }
      }
      if (latestDateRangeId != null && latestDateRangeId != _lastSeenDateRangeId) {
        _lastSeenDateRangeId = latestDateRangeId;
        _log('_refreshHlsPlaylistTimestamp: new DATERANGE id=$latestDateRangeId, refreshing metadata');
        // _pollMetadata() has its own _isPollInFlight guard, so a duplicate
        // trigger from a near-simultaneous REST tick is a safe no-op.
        unawaited(stationDataService.refreshMetadataNow());
      }
    } catch (e) {
      _log('_refreshHlsPlaylistTimestamp: $e');
    }
  }

  /// Start periodic refresh of HLS playlist timestamps.
  void _startHlsPlaylistRefresh() {
    _hlsPlaylistRefreshTimer?.cancel();
    // Initial fetch, then refresh every 30s as the playlist window slides
    _refreshHlsPlaylistTimestamp();
    _hlsPlaylistRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshHlsPlaylistTimestamp();
    });
  }

  /// Stop periodic refresh and clear HLS playlist state.
  void _stopHlsPlaylistRefresh() {
    _hlsPlaylistRefreshTimer?.cancel();
    _hlsPlaylistRefreshTimer = null;
    _hlsFirstSegmentEpoch = null;
    // Reset so the first DATERANGE seen on the next stream registers as a
    // change rather than colliding with the previous stream's last ID.
    _lastSeenDateRangeId = null;
  }

  // ── Silence keep-alive (iOS-only background-suspension prevention) ──

  /// Schedule the silence keeper to start playing after
  /// [_silenceKeepAliveDelay] of continuous buffering. No-op on Android
  /// where audio_service runs as a foreground service and the engine is
  /// not suspended on stall.
  void _scheduleSilenceKeepAlive() {
    if (!Platform.isIOS) return;
    _silenceKeepAliveStartTimer?.cancel();
    _silenceKeepAliveStartTimer = Timer(_silenceKeepAliveDelay, () async {
      // Re-check the state — buffering may have ended during the delay.
      if (player.processingState != ProcessingState.buffering) return;
      if (!player.playing) return;
      await _startSilenceKeepAlive();
    });
  }

  Future<void> _startSilenceKeepAlive() async {
    if (_silenceKeeperPlaying) return;
    try {
      _silenceKeeper ??= AudioPlayer(handleInterruptions: false);
      // Lazily load the asset on first use. setAsset() is idempotent if the
      // source is already loaded, but cheaper to skip on subsequent calls.
      if (_silenceKeeper!.audioSource == null) {
        await _silenceKeeper!.setAsset(_silenceKeepAliveAsset);
        await _silenceKeeper!.setLoopMode(LoopMode.all);
        // Volume just above zero so AVPlayer continues pushing samples to
        // AVAudioSession (zero-amplitude or muted may be optimized out and
        // defeat the purpose). 0.001 is below audible threshold.
        await _silenceKeeper!.setVolume(0.001);
      }
      await _silenceKeeper!.play();
      _silenceKeeperPlaying = true;
      _log('silence keeper started — preventing iOS background suspension');
    } catch (e) {
      _log('silence keeper start failed: $e');
    }
  }

  void _stopSilenceKeepAlive() {
    _silenceKeepAliveStartTimer?.cancel();
    _silenceKeepAliveStartTimer = null;
    if (!_silenceKeeperPlaying) return;
    _silenceKeeperPlaying = false;
    final keeper = _silenceKeeper;
    if (keeper == null) return;
    keeper.stop().catchError((e) {
      _log('silence keeper stop failed: $e');
    });
    _log('silence keeper stopped');
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
    _bufferingStartedAt = null;
    _stopSilenceKeepAlive();
    _lastPlayerErrorCode = null;
    _lastPlayerErrorMessage = null;
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    currentStreamInfo.add(null);
    AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);
    await player.stop();
    // Broadcast stopped state with controls still available (no super.stop())
    _broadcastState(player.playbackEvent);
  }

  @override
  Future<void> stop() async {
    _log("stop (isCasting=$isCasting)");
    if (isCasting) {
      GetIt.instance<CastService>().stop();
      setCastPlaying(false);
      return;
    }
    _cancelInFlightPlay();
    _hasBeenPlayed = false;
    AnalyticsService.instance.endListening();
    _disconnectTimer?.cancel();
    _bufferingStallTimer?.cancel();
    _bufferingStartedAt = null;
    _stopSilenceKeepAlive();
    _lastPlayerErrorCode = null;
    _lastPlayerErrorMessage = null;
    _stopHlsPlaylistRefresh();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    currentStreamInfo.add(null);
    AnalyticsService.instance.setCurrentStream(url: null, type: null, index: null, total: null);
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

  /// Maps the Cast receiver's player state to AudioProcessingState.
  AudioProcessingState _castProcessingState() {
    if (!GetIt.instance.isRegistered<CastService>()) {
      return AudioProcessingState.ready;
    }
    switch (GetIt.instance<CastService>().castPlayerState.value) {
      case CastMediaPlayerState.buffering:
      case CastMediaPlayerState.loading:
        return AudioProcessingState.buffering;
      case CastMediaPlayerState.idle:
      case CastMediaPlayerState.playing:
      case CastMediaPlayerState.paused:
      case CastMediaPlayerState.unknown:
        return AudioProcessingState.ready;
    }
  }

  /// Re-emits `playbackState` with current controls, processing state, and
  /// the latest known `playing` flag. Callers use this after synthesizing
  /// state changes outside the normal `player.playbackEventStream` path
  /// (e.g., adopting an in-progress Cast session).
  void broadcastCurrentState() {
    _broadcastState(player.playbackEvent);
  }

  /// Single source of truth for "playing" while casting.
  ///
  /// Flipping `playbackState.playing` with `copyWith` alone leaves the
  /// `controls` list stale — the Play/Pause icon is rebuilt inside
  /// `_broadcastState` from the current `playing` value. This helper
  /// does both atomically and is the only sanctioned way to mutate
  /// the Cast-side playing flag.
  ///
  /// Call this from:
  ///   - `play()` / `pause()` / `stop()` Cast branches (optimistic)
  ///   - the main.dart cast-state sync listener (reactive, from receiver)
  ///   - `playStation()` Cast branch (new station loaded)
  ///   - Cast session adoption in main.dart
  void setCastPlaying(bool playing) {
    playbackState.add(playbackState.value.copyWith(playing: playing));
    _broadcastState(player.playbackEvent);
  }

  void _broadcastState(PlaybackEvent event) {
    // When casting, use the last-known playback state (not the local player)
    final playing = isCasting ? (playbackState.value.playing) : player.playing;
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
        : isCasting
          ? _castProcessingState()
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
    // Stop Cast playback explicitly — the native stopCastingOnAppTerminated
    // flag handles this too, but an explicit stop is more reliable when the
    // OS kills the process abruptly.
    try {
      if (isCasting) {
        _log('onTaskRemoved: stopping Cast playback');
        GetIt.instance<CastService>().disconnect();
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
    _bufferingStallTimer?.cancel();
    _stopSilenceKeepAlive();
    _loadedStreamUrl = null;
    _loadedStreamType = null;
    await player.stop();
    await player.dispose();
    final keeper = _silenceKeeper;
    _silenceKeeper = null;
    if (keeper != null) {
      await keeper.dispose().catchError((e) => _log('silence keeper dispose failed: $e'));
    }
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
  /// stream was silently lost (idle) or stalled waiting for data (buffering)
  /// — and importantly, when the user wants playback (`_hasBeenPlayed`) but
  /// the player isn't actually playing for any reason. The last condition
  /// covers airplane-mode → recovery: after maxRetries fail in play(), the
  /// player can sit in `ready` with a stale source and `playing == false`
  /// indefinitely; without forcing a reload here, the user-perceived
  /// behaviour is "audio never came back".
  void reconnectIfNeeded() {
    if (currentStation.valueOrNull == null) return;
    if (_isConnecting) return;
    if (!_hasBeenPlayed) return;
    // While casting, the local player is intentionally idle — Cast owns
    // playback. Don't treat its idle state as a "stall" and trigger a
    // reconnect, which would cascade into play() and ultimately a Cast
    // LOAD we didn't ask for.
    if (isCasting) return;
    // Apply the same 8s debounce as the listener's terminal-state branches:
    // a lifecycle.resumed firing within seconds of a successful load (e.g.
    // a brief ⌥-tab away and back) shouldn't kick a fresh play() while
    // AVPlayer is still settling. Without this, the "shouldBePlayingButIsnt"
    // predicate below would re-issue play() during the 200–800ms PDT
    // decoder-confusion window where player.playing transiently flips
    // false, looping us right back into "Attempt → Loaded → Rebuffer".
    final lastLoad = _lastSuccessfulLoadAt;
    if (lastLoad != null &&
        DateTime.now().difference(lastLoad) < _terminalStateReloadDebounce) {
      _log("reconnectIfNeeded: within debounce window of last load — skipping");
      return;
    }
    final state = player.processingState;
    final stalled = state == ProcessingState.idle ||
        (state == ProcessingState.buffering && player.playing);
    // User-wants-play-but-isn't-playing: covers the post-airplane-mode case
    // where AVPlayer is `ready` with stale source / `completed` from a
    // failed reload chain / paused due to a transient interruption that
    // wasn't auto-resumed.
    final shouldBePlayingButIsnt = !player.playing;
    if (stalled || shouldBePlayingButIsnt) {
      _log("reconnectIfNeeded: reconnecting (state=$state, playing=${player.playing}, stalled=$stalled)");
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

    // When connectivity is restored: always attempt reconnect. The earlier
    // foreground-only gate prevented background recovery — but
    // reconnectIfNeeded() already no-ops when there's no station, while
    // connecting, casting, or not stalled, so the gate was redundant and
    // actively harmful for the "audio that never stops" goal. Delay 2s so
    // the network is actually usable.
    NetworkService.instance.isOffline.stream.listen((offline) {
      if (offline) return;
      _log("isOffline -> false: will reconnect in 2s");
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

          // Push updated metadata to Cast device in real-time
          if (isCasting) {
            try {
              GetIt.instance<CastService>().updateCastMetadata(updatedCurrentStation);
            } catch (e) {
              _log('Cast metadata update failed: $e');
            }
          }

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
