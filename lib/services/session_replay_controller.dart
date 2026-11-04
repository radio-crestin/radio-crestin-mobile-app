import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics_service.dart';
import 'network_service.dart';

/// When session replay records, as decided by one variant of the
/// `mobile-session-replay` flag.
enum ReplayMode {
  /// Replay is not installed.
  off,

  /// Records from the first real error to the end of the session.
  onError,

  /// Records the whole session.
  always,
}

/// The replay rules a device got from the `mobile-session-replay` flag.
///
/// The variant picks the [mode]; its payload may set `wifiOnly` (default
/// true) and `maxMinutes` (default 10, 0 for no limit).
@immutable
class ReplayPolicy {
  /// Replay off: not installed, nothing recorded.
  static const off = ReplayPolicy(mode: ReplayMode.off);

  /// The recording limit when the payload sets none.
  static const defaultMaxDuration = Duration(minutes: 10);

  /// When recording may run.
  final ReplayMode mode;

  /// Whether recording pauses off Wi-Fi, so it never takes mobile data
  /// from the audio stream.
  final bool wifiOnly;

  /// How long recording may run in a session, from when it first starts.
  /// Null means no limit.
  final Duration? maxDuration;

  const ReplayPolicy({
    required this.mode,
    this.wifiOnly = true,
    this.maxDuration = defaultMaxDuration,
  });

  /// Reads a flag [variant] and its [payload]. Anything unknown is [off].
  factory ReplayPolicy.fromFlag(String? variant, Object? payload) {
    final mode = switch (variant) {
      'on-error' => ReplayMode.onError,
      'always' => ReplayMode.always,
      _ => ReplayMode.off,
    };
    if (mode == ReplayMode.off) return off;
    final map = payload is Map ? payload : const {};
    final wifiOnly = map['wifiOnly'];
    final maxMinutes = map['maxMinutes'];
    return ReplayPolicy(
      mode: mode,
      wifiOnly: wifiOnly is bool ? wifiOnly : true,
      maxDuration: switch (maxMinutes) {
        int m when m <= 0 => null,
        int m => Duration(minutes: m),
        _ => defaultMaxDuration,
      },
    );
  }

  /// Whether this policy needs replay installed at PostHog setup.
  bool get installs => mode != ReplayMode.off;

  /// Whether recording should run right now.
  bool shouldRecord({
    required bool onWifi,
    required bool errorOccurred,
    required bool limitReached,
  }) {
    final modeAllows = switch (mode) {
      ReplayMode.off => false,
      ReplayMode.onError => errorOccurred,
      ReplayMode.always => true,
    };
    return modeAllows && !limitReached && (onWifi || !wifiOnly);
  }
}

/// Runs PostHog session replay as the `mobile-session-replay` flag says.
///
/// Replay is installed at PostHog setup only on phones the flag picked at
/// the previous launch, so every other phone never loads it: no native
/// recorder and no capture timer. A flag change therefore takes effect from
/// the next launch. A phone the live flag drops stops recording at once.
class SessionReplayController {
  /// PostHog feature flag key.
  static const flagKey = 'mobile-session-replay';

  static const _kVariantKey = 'session_replay_variant';
  static const _kPayloadKey = 'session_replay_payload';

  /// The app-wide instance.
  static final SessionReplayController instance = SessionReplayController();

  /// The parameters exist for tests: whether the platform supports replay,
  /// and the calls that read the flag and start, stop and arm the recording.
  SessionReplayController({
    bool? platformSupported,
    Future<PostHogFeatureFlagResult?> Function()? readFlag,
    Future<void> Function()? startRecording,
    Future<void> Function()? stopRecording,
    void Function(bool armed)? armCapture,
  })  : _platformSupported = platformSupported ?? _isPhonePlatform,
        _readFlag = readFlag ?? _readLiveFlag,
        _startRecording = startRecording ?? Posthog().startSessionRecording,
        _stopRecording = stopRecording ?? Posthog().stopSessionRecording,
        _armCapture =
            armCapture ?? AnalyticsService.instance.setReplayCaptureArmed;

  static Future<PostHogFeatureFlagResult?> _readLiveFlag() =>
      Posthog().getFeatureFlagResult(flagKey, sendEvent: false);

  // PostHog's Flutter replay runs on Android and iOS only.
  static bool get _isPhonePlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  final bool _platformSupported;
  final Future<PostHogFeatureFlagResult?> Function() _readFlag;
  final Future<void> Function() _startRecording;
  final Future<void> Function() _stopRecording;
  final void Function(bool armed) _armCapture;

  SharedPreferences? _prefs;
  ReplayPolicy _policy = ReplayPolicy.off;
  bool _installed = false;
  bool _onWifi = false;
  bool _errorOccurred = false;
  bool _limitReached = false;
  bool? _recording;
  Timer? _limitTimer;
  final List<StreamSubscription<bool>> _subscriptions = [];

  /// Reads the policy cached by the previous launch. Call before PostHog
  /// setup.
  void loadCache(SharedPreferences prefs) {
    _prefs = prefs;
    final payload = prefs.getString(_kPayloadKey);
    _policy = ReplayPolicy.fromFlag(
      prefs.getString(_kVariantKey),
      payload == null ? null : _decode(payload),
    );
  }

  /// Whether PostHog setup should install replay (`config.sessionReplay`).
  bool get installAtSetup => _platformSupported && _policy.installs;

  /// Whether replay was installed at this launch's setup.
  bool get installed => _installed;

  /// Starts following the network and applies the cached policy. Call
  /// right after PostHog setup, with the [installAtSetup] it used.
  void start({required bool installed, NetworkService? network}) {
    _installed = installed;
    if (!installed) return;
    final net = network ?? NetworkService.instance;
    void onNetwork(_) {
      _onWifi = !net.isOnMobileData.value && !net.isOffline.value;
      _apply();
    }

    _subscriptions
      ..add(net.isOnMobileData.listen(onNetwork))
      ..add(net.isOffline.listen(onNetwork));
    // Setup starts recording right away; stop it until the policy allows.
    onNetwork(null);
  }

  /// Reads the live flag once PostHog loaded flags, caches it for the next
  /// launch, and applies it now if replay is installed.
  Future<void> onFlagsLoaded() async {
    try {
      final result = await _readFlag();
      await _cache(result?.variant, result?.payload);
      _policy = ReplayPolicy.fromFlag(result?.variant, result?.payload);
    } catch (e) {
      developer.log('$flagKey flag read failed: $e');
    }
    _apply();
  }

  /// Marks that a real (non-benign) error happened, which starts recording
  /// on `on-error` phones.
  void notifyErrorCaptured() {
    if (_errorOccurred) return;
    _errorOccurred = true;
    _apply();
  }

  Future<void> _cache(String? variant, Object? payload) async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (variant == null) {
      await prefs.remove(_kVariantKey);
    } else {
      await prefs.setString(_kVariantKey, variant);
    }
    await prefs.setString(_kPayloadKey, jsonEncode(payload));
  }

  void _apply() {
    if (!_installed) return;
    final record = _policy.shouldRecord(
      onWifi: _onWifi,
      errorOccurred: _errorOccurred,
      limitReached: _limitReached,
    );
    if (record == _recording) return;
    _recording = record;
    // Keeps a PostHogWidget that has not mounted yet from starting its
    // capture timer while nothing records.
    _armCapture(record);
    if (record) _startLimitTimer();
    AnalyticsService.instance.logDebug('session replay', {
      'mode': _policy.mode.name,
      'on_wifi': _onWifi,
      'error_occurred': _errorOccurred,
      'limit_reached': _limitReached,
      'recording': record,
    });
    final call = record ? _startRecording : _stopRecording;
    unawaited(call().catchError((Object e) {
      developer.log('session replay ${record ? 'start' : 'stop'} failed: $e');
    }));
  }

  // Counted from when recording first starts, Wi-Fi pauses included.
  void _startLimitTimer() {
    final limit = _policy.maxDuration;
    if (limit == null || _limitTimer != null) return;
    _limitTimer = Timer(limit, () {
      _limitReached = true;
      _apply();
    });
  }

  static Object? _decode(String json) {
    try {
      return jsonDecode(json);
    } on FormatException {
      return null;
    }
  }

  /// Stops following the network. The app's instance lives as long as the
  /// app; this is for tests.
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _limitTimer?.cancel();
    _limitTimer = null;
  }
}
