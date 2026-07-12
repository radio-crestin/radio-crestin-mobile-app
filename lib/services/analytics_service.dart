import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show PathNotFoundException;

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'session_replay_controller.dart';

/// Centralized analytics service wrapping PostHog.
/// Handles user identification, event tracking, error tracking,
/// and listening duration measurement.
class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._();
  static AnalyticsService get instance => _instance;

  AnalyticsService._();

  bool _initialized = false;
  String? _sessionId;
  String? _userId;

  // Identity context, attached to every structured log record so a log line in
  // PostHog Logs can be pinned to an app version / platform without a join.
  String? _appVersion;
  String? _platform;

  // Listening duration tracking
  String? _currentStationSlug;
  String? _currentStationName;
  int? _currentStationId;
  DateTime? _listeningStartTime;
  bool _isListening = false;
  Timer? _heartbeatTimer;
  static const _heartbeatInterval = Duration(seconds: 60);

  // Stream-level context, included on listening_started / listening_active so
  // sessions can be filtered by stream switches without joining tables.
  String? _currentStreamUrl;
  String? _currentStreamType;
  int? _currentStreamIndex;
  int? _currentStreamTotal;

  String? get sessionId => _sessionId;
  bool get isListening => _isListening;

  /// Set or clear the current stream context. Pass `url: null` to clear.
  void setCurrentStream({
    required String? url,
    required String? type,
    required int? index,
    required int? total,
  }) {
    _currentStreamUrl = url;
    _currentStreamType = type;
    _currentStreamIndex = index;
    _currentStreamTotal = total;
  }

  Map<String, Object> get _streamContext => {
        if (_currentStreamUrl != null) 'stream_url': _currentStreamUrl!,
        if (_currentStreamType != null) 'stream_type': _currentStreamType!,
        if (_currentStreamIndex != null) 'stream_index': _currentStreamIndex!,
        if (_currentStreamTotal != null) 'total_streams': _currentStreamTotal!,
      };

  /// Initialize PostHog with manual setup for error tracking support.
  ///
  /// [sessionReplayAtSetup] decides `config.sessionReplay`. It must be true for
  /// the native replay integration to install so that runtime start/stop works
  /// (see [SessionReplayController]); the controller then stops recording until
  /// the `mobile-session-replay` feature flag allows it. [onFeatureFlagsLoaded]
  /// is invoked once PostHog has loaded feature flags, which is when the
  /// replay decision can first be read.
  Future<void> initialize({
    bool sessionReplayAtSetup = false,
    VoidCallback? onFeatureFlagsLoaded,
  }) async {
    final config = PostHogConfig('phc_9lTquHDSyoFxkYq4VPd8cFiQ21VZd627Lv8jSV8S7Fi');
    config.host = 'https://k.radiocrestin.ro';
    config.debug = kDebugMode;

    // Event batching
    config.flushAt = 20;
    config.maxQueueSize = 1000;
    config.maxBatchSize = 50;
    config.flushInterval = const Duration(seconds: 30);

    // Lifecycle events
    config.captureApplicationLifecycleEvents = true;

    // Session replay (screen recording) — Android & iOS.
    // Requires "Record user sessions" enabled in PostHog Project Settings.
    // Whether recording actually runs is decided at runtime by the
    // `mobile-session-replay` feature flag (see SessionReplayController); this
    // only installs the native integration so runtime start/stop can work.
    config.sessionReplay = sessionReplayAtSetup;
    // No sensitive data is shown (station names, song titles, artwork), so we
    // leave text and images unmasked to keep recordings useful. Wrap any
    // sensitive widget with PostHogMaskWidget to mask it individually.
    config.sessionReplayConfig.maskAllTexts = false;
    config.sessionReplayConfig.maskAllImages = false;
    // Snapshot throttle — higher = fewer captures, so audio streaming keeps the
    // bandwidth/CPU. Smooth playback is the priority, so we throttle to 1.5s.
    config.sessionReplayConfig.throttleDelay =
        const Duration(milliseconds: 1500);
    // Always full-rate: sampling is done by the flag's 10% variant rollout, not
    // the SDK.
    config.sessionReplayConfig.sampleRate = 1.0;

    // Feature flags gate session replay; fire the caller's callback once loaded.
    config.onFeatureFlags = onFeatureFlagsLoaded;

    // PostHog Logs (OTLP) resource attributes.
    config.logsConfig.serviceName = 'radio-crestin-mobile';
    config.logsConfig.environment = kDebugMode ? 'development' : 'production';

    // Person profiles
    config.personProfiles = PostHogPersonProfiles.identifiedOnly;

    // Error tracking — catches FlutterError, PlatformDispatcher, Isolate, and
    // native (iOS/Android) crashes. Native capture replaces Firebase
    // Crashlytics: Apple Mach exceptions / POSIX signals / NSExceptions and
    // Android Java/Kotlin exceptions are persisted and sent as a fatal
    // `$exception` on the next launch.
    config.errorTrackingConfig.captureFlutterErrors = true;
    config.errorTrackingConfig.capturePlatformDispatcherErrors = true;
    config.errorTrackingConfig.captureIsolateErrors = true;
    config.errorTrackingConfig.captureSilentFlutterErrors = true;
    config.errorTrackingConfig.captureNativeExceptions = true;
    config.errorTrackingConfig.inAppIncludes.add('package:radio_crestin');

    await Posthog().setup(config);
    _initialized = true;
    _sessionId = await Posthog().getSessionId();
    developer.log('PostHog initialized, session: $_sessionId');
  }

  /// Manually capture an exception with context.
  ///
  /// Routes through the PostHog SDK's exception capture so the error lands in
  /// Error Tracking as a proper `$exception` issue with a fully parsed,
  /// symbolicated stack trace — the same rich, unminified view as auto-captured
  /// Flutter errors — instead of a truncated string on a custom event. Use for
  /// caught exceptions in try/catch blocks that shouldn't crash the app but
  /// should still be tracked.
  void captureException(Object error, StackTrace? stackTrace, {String? context}) {
    if (!_initialized) {
      developer.log('PostHog not initialized, dropping error: $error');
      return;
    }
    // Skip benign Hive compaction errors from concurrent Flutter engines.
    if (error is PathNotFoundException &&
        stackTrace != null &&
        stackTrace.toString().contains('StorageBackendVm.compact')) {
      return;
    }
    // Fire-and-forget: the native capture is async but callers don't await.
    // The full stack trace is sent untruncated so PostHog can resolve every
    // frame to source.
    unawaited(Posthog().captureException(
      error: error,
      stackTrace: stackTrace,
      properties: {
        if (context != null) 'context': context,
      },
    ));

    // Mirror to PostHog Logs with full detail (message, stack, station/stream
    // context, app version, platform) so playback issues are debuggable there.
    _emitLog(
      PostHogLogSeverity.error,
      context == null ? error.toString() : '$context: $error',
      {
        'error_type': error.runtimeType.toString(),
        if (context != null) 'context': context,
        if (stackTrace != null) 'stack_trace': stackTrace.toString(),
        ..._logContext(),
      },
    );

    // Real error → start replay for `on-error` devices (WiFi gate still applies).
    SessionReplayController.instance.notifyErrorCaptured();
  }

  /// Identify user with persistent device ID.
  Future<void> identify({
    required String userId,
    String? appVersion,
    String? buildNumber,
    String? platform,
  }) async {
    _userId = userId;
    _appVersion = appVersion ?? _appVersion;
    _platform = platform ?? _platform;
    // Reset first to clear any stale anonymous/misidentified distinct_id
    // from previous sessions. This generates a fresh anonymous ID which
    // identify() then links to the real userId.
    final currentId = await Posthog().getDistinctId();
    if (currentId != userId) {
      await Posthog().reset();
    }
    await Posthog().identify(
      userId: userId,
      userProperties: {
        if (appVersion != null) 'app_version': appVersion,
        if (buildNumber != null) 'build_number': buildNumber,
        if (platform != null) 'platform': platform,
      },
    );
    // Register device ID as a super property so it's on every event
    await Posthog().register('device_id', userId);
  }

  /// Capture a custom event.
  void capture(String eventName, [Map<String, Object?>? properties]) {
    Posthog().capture(
      eventName: eventName,
      properties: _filterNulls(properties),
    );
  }

  /// Capture only in debug builds. For high-volume diagnostic events that
  /// would create noise in production analytics — error events should still
  /// use [capture]. The in-app event log (Settings → Diagnostic redare)
  /// always sees every event regardless of build mode.
  void captureDebug(String eventName, [Map<String, Object?>? properties]) {
    if (!kDebugMode) return;
    capture(eventName, properties);
    _emitLog(PostHogLogSeverity.debug, eventName, _filterNulls(properties));
  }

  /// Set a user property without re-identifying.
  void setUserProperty(String name, String value) {
    if (_userId == null) return;
    Posthog().identify(
      userId: _userId!,
      userProperties: {name: value},
    );
  }

  /// Emit an info-level structured log record to PostHog Logs.
  void log(String message, [Map<String, Object?>? attributes]) {
    _emitLog(PostHogLogSeverity.info, message, _filterNulls(attributes));
  }

  /// Emit a warning-level structured log record (e.g. a recoverable stream
  /// failure worth debugging in PostHog Logs).
  void logWarning(String message, [Map<String, Object?>? attributes]) {
    _emitLog(PostHogLogSeverity.warn, message, _filterNulls(attributes));
  }

  // ── Structured logging (PostHog Logs) ──

  /// Forwards a record to PostHog Logs. Fire-and-forget and never throws into
  /// the caller — a failed log must not disturb playback.
  void _emitLog(
    PostHogLogSeverity level,
    String body, [
    Map<String, Object>? attributes,
  ]) {
    if (!_initialized || body.trim().isEmpty) return;
    unawaited(
      Posthog()
          .captureLog(body: body, level: level, attributes: attributes)
          .catchError((Object _) {}),
    );
  }

  /// Identity + station/stream context shared by every rich log record.
  Map<String, Object> _logContext() => {
        if (_currentStationSlug != null) 'station_slug': _currentStationSlug!,
        if (_currentStationName != null) 'station_name': _currentStationName!,
        if (_currentStationId != null) 'station_id': _currentStationId!,
        ..._streamContext,
        if (_appVersion != null) 'app_version': _appVersion!,
        if (_platform != null) 'platform': _platform!,
      };

  /// Drops null-valued entries and narrows to `Map<String, Object>`.
  Map<String, Object> _filterNulls(Map<String, Object?>? properties) {
    final filtered = <String, Object>{};
    if (properties != null) {
      for (final entry in properties.entries) {
        final value = entry.value;
        if (value != null) filtered[entry.key] = value;
      }
    }
    return filtered;
  }

  // ── Listening session tracking ──

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (!_isListening) return;
      final durationSeconds = _listeningStartTime != null
          ? DateTime.now().difference(_listeningStartTime!).inSeconds
          : 0;
      capture('listening_active', {
        'station_slug': _currentStationSlug ?? '',
        'station_name': _currentStationName ?? '',
        if (_currentStationId != null) 'station_id': _currentStationId!,
        'session_duration_seconds': durationSeconds,
        ..._streamContext,
      });
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Call when the user starts playing a station.
  void startListening(String stationSlug, String stationName, {int? stationId}) {
    // End any previous session first
    if (_isListening) {
      endListening(reason: 'station_switch');
    }
    _currentStationSlug = stationSlug;
    _currentStationName = stationName;
    _currentStationId = stationId;
    _listeningStartTime = DateTime.now();
    _isListening = true;

    capture('listening_started', {
      'station_slug': stationSlug,
      'station_name': stationName,
      if (stationId != null) 'station_id': stationId,
      ..._streamContext,
    });
    _emitLog(PostHogLogSeverity.info, 'listening started', {
      'station_slug': stationSlug,
      'station_name': stationName,
      if (stationId != null) 'station_id': stationId,
      ..._streamContext,
    });

    _startHeartbeat();
  }

  /// Call when playback resumes from pause (same station, continues session).
  void resumeListening() {
    if (_currentStationSlug == null) return;
    if (_isListening) return; // already tracking
    _listeningStartTime = DateTime.now();
    _isListening = true;

    capture('listening_resumed', {
      'station_slug': _currentStationSlug!,
      'station_name': _currentStationName ?? '',
      if (_currentStationId != null) 'station_id': _currentStationId!,
      ..._streamContext,
    });
    _emitLog(PostHogLogSeverity.info, 'listening resumed', {
      'station_slug': _currentStationSlug!,
      if (_currentStationId != null) 'station_id': _currentStationId!,
      ..._streamContext,
    });

    _startHeartbeat();
  }

  /// Call when the user pauses/stops or the app is killed.
  /// [reason]: 'pause', 'stop', 'station_switch', 'app_killed', 'error'
  void endListening({String reason = 'stop'}) {
    if (!_isListening || _listeningStartTime == null) return;

    _stopHeartbeat();

    final duration = DateTime.now().difference(_listeningStartTime!);
    final durationSeconds = duration.inSeconds;

    capture('listening_stopped', {
      'station_slug': _currentStationSlug ?? '',
      'station_name': _currentStationName ?? '',
      if (_currentStationId != null) 'station_id': _currentStationId!,
      'duration_seconds': durationSeconds,
      'reason': reason,
    });
    _emitLog(PostHogLogSeverity.info, 'listening stopped', {
      'station_slug': _currentStationSlug ?? '',
      if (_currentStationId != null) 'station_id': _currentStationId!,
      'duration_seconds': durationSeconds,
      'reason': reason,
    });

    _isListening = false;
    _listeningStartTime = null;
    // Keep station info so resumeListening() can reuse it
    if (reason == 'stop' || reason == 'app_killed' || reason == 'error') {
      _currentStationSlug = null;
      _currentStationName = null;
      _currentStationId = null;
    }
  }

  /// Call when the user skips to next/previous station.
  void trackStationSkip(String fromSlug, String toSlug, String direction) {
    capture('station_skip', {
      'from_station_slug': fromSlug,
      'to_station_slug': toSlug,
      'direction': direction,
    });
  }

  /// Call when the user favorites/unfavorites a station.
  /// Uses same event name as web: 'favorite_toggled'
  void trackFavorite(String stationSlug, bool isFavorite, {int? stationId}) {
    capture('favorite_toggled', {
      'station_slug': stationSlug,
      'is_favorite': isFavorite,
      if (stationId != null) 'station_id': stationId,
    });
  }

  /// Call when user submits a review.
  /// Uses same event name as web: 'review_submitted'
  void trackReviewSubmitted({
    required int stationId,
    required String stationName,
    required int stars,
    int? songId,
    bool hasMessage = false,
  }) {
    capture('review_submitted', {
      'station_id': stationId,
      'station_name': stationName,
      'stars': stars,
      if (songId != null) 'song_id': songId,
      'has_message': hasMessage,
    });
  }

  /// Flush pending events (e.g. before app goes to background).
  Future<void> flush() async {
    await Posthog().flush();
  }
}
