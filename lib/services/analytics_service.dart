import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show PathNotFoundException;

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_log_store.dart';
import 'log_flush_guard.dart';
import 'session_replay_controller.dart';

/// Centralized analytics service wrapping PostHog.
/// Handles user identification, event tracking, error tracking,
/// and listening duration measurement.
class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._();
  static AnalyticsService get instance => _instance;

  AnalyticsService._();

  static const _projectApiKey =
      'phc_nYXw3QDHsrAMhEGXnvLcMDgyTG3rgKtEK2HaxV97csvy';

  /// The `build_mode` super property on every event: `debug`, `profile` or
  /// `release`.
  static const buildMode = kReleaseMode
      ? 'release'
      : kProfileMode
          ? 'profile'
          : 'debug';

  bool _initialized = false;
  String? _sessionId;
  String? _userId;

  // The config handed to setup, kept only when it installed the native
  // replay integration. The SDK stores this same object, and
  // `PostHogWidget` reads its `sessionReplay` when it mounts.
  PostHogConfig? _replayConfig;

  // Identity context, attached to every structured log record so a log line in
  // PostHog Logs can be pinned to an app version / platform without a join.
  String? _appVersion;
  String? _platform;

  // Verbose logging tiers. LocalLogStore always receives everything; PostHog
  // receives info+ by default and debug+ while either verbose source is on
  // (the `mobile-remote-debug` flag payload, or on-device developer mode).
  bool _verboseRemote = false;
  bool _verboseDeveloper = false;

  /// Minimum severity shipped to PostHog (the local store gets everything).
  PostHogLogSeverity get minShipLevel => (_verboseRemote || _verboseDeveloper)
      ? PostHogLogSeverity.debug
      : PostHogLogSeverity.info;

  /// Set by the `mobile-remote-debug` flag payload (`verboseLogs`).
  void setRemoteVerbose(bool enabled) => _verboseRemote = enabled;

  /// Set while the hidden developer mode (Settings) is enabled.
  void setDeveloperVerbose(bool enabled) => _verboseDeveloper = enabled;

  /// Whether a record at [level] ships to PostHog given [minLevel].
  /// Pure — unit tested directly.
  @visibleForTesting
  static bool shouldShip(
    PostHogLogSeverity level,
    PostHogLogSeverity minLevel,
  ) =>
      level.index >= minLevel.index;

  // Listening duration tracking
  String? _currentStationSlug;
  String? _currentStationName;
  int? _currentStationId;
  DateTime? _listeningStartTime;
  bool _isListening = false;

  // The open session is mirrored to disk every minute — a local write, no
  // event — so a session the OS kills mid-listen (no `listening_stopped`) is
  // still reported with its real duration on the next launch. This replaces
  // a per-minute `listening_active` event that was ~65% of all event volume.
  SharedPreferences? _prefs;
  Timer? _sessionSaveTimer;
  static const _sessionSaveInterval = Duration(seconds: 60);

  /// SharedPreferences key holding the saved open session.
  @visibleForTesting
  static const openSessionKey = 'analytics_open_listening_session';

  /// A saved session refreshed more recently than this may still be live in
  /// another engine (Android Auto runs `main()` in a second, headless
  /// engine), so it is not reported as interrupted.
  static const interruptedSessionMinAge = Duration(minutes: 3);

  // Person properties last sent to this project, so a launch only sends a
  // `$set` when one changed (the SDK dedupes in memory only).
  static const _kSentPersonPropertiesKey = 'analytics_sent_person_properties';

  // Stream-level context, included on listening_started / listening_resumed
  // so sessions can be filtered by stream switches without joining tables.
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
  /// replay decision can first be read. [appVersion] becomes the OTLP
  /// `service.version` on every log record. [prefs] persists the open
  /// listening session and the person properties already sent; without it
  /// neither survives a restart.
  Future<void> initialize({
    bool sessionReplayAtSetup = false,
    VoidCallback? onFeatureFlagsLoaded,
    String? appVersion,
    SharedPreferences? prefs,
  }) async {
    _appVersion = appVersion ?? _appVersion;
    final config = PostHogConfig(_projectApiKey);
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

    // PostHog Logs (OTLP) resource attributes. Buffering, disk persistence
    // across restarts, and auto-flush (30s / flushAt / on backgrounding) are
    // SDK defaults and left untouched; the 500-per-10s rate cap is far above
    // our volume (no per-second logs, heartbeats are events-only).
    config.logsConfig.serviceName = 'radio-crestin-mobile';
    if (appVersion != null) config.logsConfig.serviceVersion = appVersion;
    config.logsConfig.environment =
        kReleaseMode ? 'production' : 'development';

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
    // Only our code counts as in-app, so an issue points at our frame rather
    // than a plugin's or the Flutter engine's. Dart frames match the bare
    // package name (not `package:radio_crestin`); native frames match the
    // iOS module or Android class-name prefix.
    config.errorTrackingConfig.inAppByDefault = false;
    config.errorTrackingConfig.inAppIncludes.addAll(const [
      'radio_crestin',
      'flutter_carplay',
      'Runner',
      'com.radiocrestin',
    ]);

    await Posthog().setup(config);
    // Lets dashboards and the test-account filter drop debug runs.
    await Posthog().register('build_mode', buildMode);
    // Only after setup, which has already sent the flag to native.
    _replayConfig = sessionReplayAtSetup ? config : null;
    _initialized = true;
    if (prefs != null) _attachStorage(prefs);
    _sessionId = await Posthog().getSessionId();
    developer.log('PostHog initialized, session: $_sessionId');
  }

  void _attachStorage(SharedPreferences prefs) {
    _prefs = prefs;
    // Before anything is saved: the slot still holds the previous run's
    // session, if that run never closed it.
    _reportInterruptedSession();
    // A session that started before storage was attached is saved now.
    if (_isListening) _saveOpenSession();
  }

  /// Arms or idles `PostHogWidget`'s snapshot loop before it mounts.
  ///
  /// The widget reads `config.sessionReplay` only in `initState`, and the
  /// SDK leaves it true even after `stopSessionRecording`, so a device that
  /// is not recording would otherwise walk the whole widget tree every
  /// 1.5 s for the entire session. Once mounted, the widget follows
  /// start/stop on its own. Safe after setup: the config was already sent
  /// to native and nothing else reads the flag.
  void setReplayCaptureArmed(bool armed) {
    // Null without the native integration, where recording can never
    // start: never arm.
    _replayConfig?.sessionReplay = armed;
  }

  /// Manually capture an exception with context.
  ///
  /// Routes through the PostHog SDK's exception capture so the error lands in
  /// Error Tracking as a proper `$exception` issue with a fully parsed,
  /// symbolicated stack trace — the same rich, unminified view as auto-captured
  /// Flutter errors — instead of a truncated string on a custom event. Use for
  /// caught exceptions in try/catch blocks that shouldn't crash the app but
  /// should still be tracked. [properties] ride on the exception event and
  /// its log record (e.g. which station failed).
  void captureException(
    Object error,
    StackTrace? stackTrace, {
    String? context,
    Map<String, Object?>? properties,
  }) {
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
    final extra = _filterNulls(properties);
    // Fire-and-forget: the native capture is async but callers don't await.
    // The full stack trace is sent untruncated so PostHog can resolve every
    // frame to source.
    unawaited(Posthog().captureException(
      error: error,
      stackTrace: stackTrace,
      properties: {
        ...extra,
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
        ...extra,
      },
    );

    // Real error → start replay for `on-error` devices (WiFi gate still applies).
    SessionReplayController.instance.notifyErrorCaptured();

    // Guarantee upload: flush now, or owe a flush until connectivity returns
    // (LogFlushGuard persists the debt across restarts, and the SDK's queues
    // survive on disk). Not WiFi-gated — log/event uploads are tiny.
    LogFlushGuard.instance.requestFlush();
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
    final properties = <String, Object>{
      if (appVersion != null) 'app_version': appVersion,
      if (buildNumber != null) 'build_number': buildNumber,
      if (platform != null) 'platform': platform,
    };
    // Reset first to clear any stale anonymous/misidentified distinct_id
    // from previous sessions. This generates a fresh anonymous ID which
    // identify() then links to the real userId.
    final currentId = await Posthog().getDistinctId();
    if (currentId != userId) {
      await Posthog().reset();
      await Posthog().identify(userId: userId, userProperties: properties);
      _rememberSentPersonProperties(properties, replace: true);
    } else {
      // Identified on an earlier launch. Identifying again would send a
      // `$set` on every launch, so only changed properties go out.
      await _setPersonProperties(properties);
    }
    // Register device ID as a super property so it's on every event. The
    // reset above clears super properties, so `build_mode` goes again too.
    await Posthog().register('device_id', userId);
    await Posthog().register('build_mode', buildMode);
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
    // The debug log record always flows through the choke point (local store
    // in every build; ships to PostHog only in verbose mode) — only the
    // analytics *event* stays debug-build-only.
    _emitLog(PostHogLogSeverity.debug, eventName, _filterNulls(properties));
    if (!kDebugMode) return;
    capture(eventName, properties);
  }

  /// Set a user property without re-identifying. No-op when unchanged.
  void setUserProperty(String name, String value) {
    if (_userId == null) return;
    unawaited(_setPersonProperties({name: value}));
  }

  // ── Person properties ──

  /// Sends the [properties] that differ from those last sent to this
  /// project, as one `$set`.
  Future<void> _setPersonProperties(Map<String, Object> properties) async {
    final changed =
        changedPersonProperties(_loadSentPersonProperties(), properties);
    if (changed.isEmpty) return;
    await Posthog().setPersonProperties(userPropertiesToSet: changed);
    _rememberSentPersonProperties(changed);
  }

  /// The entries of [next] whose value differs from [sent]. Pure — unit
  /// tested directly.
  @visibleForTesting
  static Map<String, Object> changedPersonProperties(
    Map<String, Object> sent,
    Map<String, Object> next,
  ) =>
      {
        for (final entry in next.entries)
          if (sent[entry.key] != entry.value) entry.key: entry.value,
      };

  Map<String, Object> _loadSentPersonProperties() {
    final raw = _prefs?.getString(_kSentPersonPropertiesKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      // Sent to another project (an earlier API key): resend everything.
      if (decoded is! Map || decoded['project'] != _projectApiKey) {
        return const {};
      }
      return Map<String, Object>.from(decoded['properties'] as Map);
    } catch (_) {
      return const {};
    }
  }

  void _rememberSentPersonProperties(
    Map<String, Object> properties, {
    bool replace = false,
  }) {
    final prefs = _prefs;
    if (prefs == null) return;
    final sent = {
      if (!replace) ..._loadSentPersonProperties(),
      ...properties,
    };
    unawaited(prefs.setString(
      _kSentPersonPropertiesKey,
      jsonEncode({'project': _projectApiKey, 'properties': sent}),
    ));
  }

  /// Emit an info-level structured log record to PostHog Logs.
  void log(String message, [Map<String, Object?>? attributes]) {
    _emitLog(PostHogLogSeverity.info, message, _filterNulls(attributes));
  }

  /// Emit a debug-level structured log record. Always lands in the local log
  /// file; ships to PostHog only while verbose mode is on. Use for detailed
  /// playback diagnostics (attempts, switches, stalls, decisions).
  void logDebug(String message, [Map<String, Object?>? attributes]) {
    _emitLog(PostHogLogSeverity.debug, message, _filterNulls(attributes));
  }

  /// Emit a warning-level structured log record (e.g. a recoverable stream
  /// failure worth debugging in PostHog Logs).
  void logWarning(String message, [Map<String, Object?>? attributes]) {
    _emitLog(PostHogLogSeverity.warn, message, _filterNulls(attributes));
  }

  // ── Structured logging (PostHog Logs) ──

  /// Forwards a record to PostHog Logs and mirrors it to [LocalLogStore] —
  /// the single choke point for every log record the app emits. Fire-and-
  /// forget and never throws into the caller — a failed log must not disturb
  /// playback.
  void _emitLog(
    PostHogLogSeverity level,
    String body, [
    Map<String, Object>? attributes,
  ]) {
    if (body.trim().isEmpty) return;
    // Local copy first: it also captures records emitted before PostHog is up
    // and always receives every severity, including debug.
    LocalLogStore.instance.append(level.name, body, attributes);
    if (!_initialized || !shouldShip(level, minShipLevel)) return;
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

  void _startSessionSaving() {
    _saveOpenSession();
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer =
        Timer.periodic(_sessionSaveInterval, (_) => _saveOpenSession());
  }

  void _stopSessionSaving() {
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer = null;
    unawaited(_prefs?.remove(openSessionKey));
  }

  void _saveOpenSession() {
    final prefs = _prefs;
    final start = _listeningStartTime;
    final slug = _currentStationSlug;
    if (prefs == null || !_isListening || start == null || slug == null) {
      return;
    }
    unawaited(prefs.setString(
      openSessionKey,
      jsonEncode({
        'station_slug': slug,
        'station_name': _currentStationName ?? '',
        if (_currentStationId != null) 'station_id': _currentStationId,
        'started_at_ms': start.millisecondsSinceEpoch,
        'saved_at_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    ));
  }

  /// Reports the session a previous run left open (the OS killed the app
  /// mid-listen) as `listening_stopped`, timed up to its last save.
  ///
  /// A session saved within [interruptedSessionMinAge] is left alone: it may
  /// belong to a live engine. Relaunching that soon after a kill loses the
  /// killed session once a new one overwrites the slot.
  void _reportInterruptedSession() {
    final raw = _prefs?.getString(openSessionKey);
    if (raw == null) return;
    final properties = interruptedSessionProperties(raw, DateTime.now());
    if (properties == null) return;
    unawaited(_prefs?.remove(openSessionKey));
    capture('listening_stopped', properties);
    _emitLog(PostHogLogSeverity.info, 'listening stopped', properties);
  }

  /// The `listening_stopped` properties for a saved open session [raw], or
  /// null when it is malformed or saved less than [interruptedSessionMinAge]
  /// before [now]. Pure — unit tested directly.
  @visibleForTesting
  static Map<String, Object>? interruptedSessionProperties(
    String raw,
    DateTime now,
  ) {
    try {
      final session = jsonDecode(raw) as Map<String, dynamic>;
      final slug = session['station_slug'] as String;
      final startedAt = session['started_at_ms'] as int;
      final savedAt = session['saved_at_ms'] as int;
      final age = now.millisecondsSinceEpoch - savedAt;
      if (age < interruptedSessionMinAge.inMilliseconds) return null;
      final stationId = session['station_id'] as int?;
      final seconds = (savedAt - startedAt) ~/ 1000;
      return {
        'station_slug': slug,
        'station_name': session['station_name'] as String? ?? '',
        if (stationId != null) 'station_id': stationId,
        'duration_seconds': seconds < 0 ? 0 : seconds,
        'reason': 'app_killed',
        'recovered': true,
      };
    } catch (_) {
      return null;
    }
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

    _startSessionSaving();
  }

  /// Starts or resumes tracking for [slug] unless it is already tracked.
  ///
  /// Idempotent, so every play path can call it: resumes the paused session
  /// of the same station, or starts a new one (ending another station's).
  void ensureListening(String slug, String name, {int? stationId}) {
    if (_currentStationSlug == slug) {
      if (!_isListening) resumeListening();
      return;
    }
    startListening(slug, name, stationId: stationId);
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

    _startSessionSaving();
  }

  /// Call when the user pauses/stops or the app is killed.
  /// [reason]: 'pause', 'stop', 'station_switch', 'app_killed', 'error'
  void endListening({String reason = 'stop'}) {
    if (!_isListening || _listeningStartTime == null) return;

    _stopSessionSaving();

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
