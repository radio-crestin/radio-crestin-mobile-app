import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show PathNotFoundException;

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

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
  Future<void> initialize() async {
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

    // Person profiles
    config.personProfiles = PostHogPersonProfiles.identifiedOnly;

    // Error tracking — catches FlutterError, PlatformDispatcher, and Isolate errors
    config.errorTrackingConfig.captureFlutterErrors = true;
    config.errorTrackingConfig.capturePlatformDispatcherErrors = true;
    config.errorTrackingConfig.captureIsolateErrors = true;
    config.errorTrackingConfig.captureSilentFlutterErrors = true;
    config.errorTrackingConfig.inAppIncludes.add('package:radio_crestin');

    await Posthog().setup(config);
    _initialized = true;
    _sessionId = await Posthog().getSessionId();
    developer.log('PostHog initialized, session: $_sessionId');
  }

  /// Manually capture an exception with context.
  /// Use for caught exceptions in try/catch blocks that shouldn't crash
  /// the app but should still be tracked.
  void captureException(Object error, StackTrace? stackTrace, {String? context}) {
    if (!_initialized) {
      developer.log('PostHog not initialized, buffering error: $error');
      return;
    }
    // Skip benign Hive compaction errors from concurrent Flutter engines
    if (error is PathNotFoundException &&
        stackTrace != null &&
        stackTrace.toString().contains('StorageBackendVm.compact')) {
      return;
    }
    capture('exception_caught', {
      'error_type': error.runtimeType.toString(),
      'error_message': error.toString(),
      if (stackTrace != null) 'stack_trace': stackTrace.toString().substring(0, (stackTrace.toString().length).clamp(0, 2000)),
      if (context != null) 'context': context,
    });
  }

  /// Identify user with persistent device ID.
  Future<void> identify({
    required String userId,
    String? appVersion,
    String? buildNumber,
    String? platform,
  }) async {
    _userId = userId;
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
    // Filter out null values and cast to Map<String, Object>
    final filtered = <String, Object>{};
    if (properties != null) {
      for (final entry in properties.entries) {
        if (entry.value != null) filtered[entry.key] = entry.value!;
      }
    }
    Posthog().capture(
      eventName: eventName,
      properties: filtered,
    );
  }

  /// Capture only in debug builds. For high-volume diagnostic events that
  /// would create noise in production analytics — error events should still
  /// use [capture]. The in-app event log (Settings → Diagnostic redare)
  /// always sees every event regardless of build mode.
  void captureDebug(String eventName, [Map<String, Object?>? properties]) {
    if (!kDebugMode) return;
    capture(eventName, properties);
  }

  /// Set a user property without re-identifying.
  void setUserProperty(String name, String value) {
    if (_userId == null) return;
    Posthog().identify(
      userId: _userId!,
      userProperties: {name: value},
    );
  }

  /// Log a message (replaces FirebaseCrashlytics.log).
  void log(String message) {
    capture('app_log', {'message': message});
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
