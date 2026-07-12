import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network_service.dart';

/// Controls PostHog session replay via the `mobile-session-replay` feature
/// flag instead of a per-device backend decision.
///
/// The flag is multivariate:
///   * `always`   — record the whole session (10% rollout).
///   * `on-error` — record only after a real error is captured (90%).
///   * `disabled` — never record (per-user opt-out / flag off / null).
///
/// Each variant carries a JSON payload; `{"wifiOnly": true}` (the default)
/// restricts recording to WiFi/ethernet so replay never competes with audio
/// streaming for mobile-data bandwidth.
///
/// The flag value is only known *after* PostHog initializes, so the last-seen
/// variant + payload are cached in [SharedPreferences] and used to decide
/// [enableReplayAtSetup]. `config.sessionReplay` must be true at setup for the
/// native replay integration to be installed — a prerequisite for the runtime
/// [Posthog.startSessionRecording] / [Posthog.stopSessionRecording] calls this
/// controller makes. We therefore enable it at setup for every non-`disabled`
/// device (default on first launch) and immediately stop recording until the
/// flag-driven decision allows it. This keeps runtime start/stop reliable on
/// both platforms — including first-launch `always` users once flags load —
/// while still honoring a cached `disabled` opt-out (integration not installed,
/// nothing ever recorded).
class SessionReplayController {
  static final SessionReplayController _instance = SessionReplayController._();

  /// The app-wide singleton.
  static SessionReplayController get instance => _instance;

  SessionReplayController._();

  /// PostHog feature flag key controlling session replay.
  static const flagKey = 'mobile-session-replay';

  static const _kVariantKey = 'session_replay_variant';
  static const _kWifiOnlyKey = 'session_replay_wifi_only';

  SharedPreferences? _prefs;
  String? _variant;
  bool _wifiOnly = true;
  bool _errorOccurred = false;
  bool _started = false;

  /// Last native recording state we applied (null until the first decision).
  bool? _recording;

  final List<StreamSubscription<bool>> _subscriptions = [];

  /// Reads the cached variant + payload. Call before `Posthog().setup(...)`.
  Future<void> loadCache(SharedPreferences prefs) async {
    _prefs = prefs;
    _variant = prefs.getString(_kVariantKey);
    _wifiOnly = prefs.getBool(_kWifiOnlyKey) ?? true;
  }

  /// Whether `config.sessionReplay` should be true at setup.
  ///
  /// True for every device except a cached `disabled` opt-out, so the native
  /// replay integration is installed and runtime start/stop works.
  bool get enableReplayAtSetup => _variant != 'disabled';

  /// Subscribes to connectivity changes and applies the cached decision.
  ///
  /// Call right after `Posthog().setup(...)`. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    final network = NetworkService.instance;
    _subscriptions
        .add(network.isOnMobileData.stream.listen((_) => _apply()));
    _subscriptions.add(network.isOffline.stream.listen((_) => _apply()));
    _apply();
  }

  /// Re-reads the flag after PostHog loads it (the `onFeatureFlags` callback),
  /// updates the cache for next launch, and applies the decision at runtime.
  Future<void> onFlagsLoaded() async {
    try {
      final result = await Posthog().getFeatureFlagResult(flagKey);
      _variant = result?.variant;
      _wifiOnly = parseWifiOnly(result?.payload);
      // A null variant (flag off / not found) caches as `disabled` so the
      // native integration is skipped on the next launch.
      await _prefs?.setString(_kVariantKey, _variant ?? 'disabled');
      await _prefs?.setBool(_kWifiOnlyKey, _wifiOnly);
    } catch (e) {
      developer.log('Session replay flag read failed: $e');
    }
    _apply();
  }

  /// Records that a real (non-benign) error was captured, so `on-error`
  /// devices begin recording for the rest of the session (the WiFi gate still
  /// applies).
  void notifyErrorCaptured() {
    if (_errorOccurred) return;
    _errorOccurred = true;
    _apply();
  }

  /// Recomputes the decision and starts/stops native recording on change.
  void _apply() {
    if (!_started) return;
    final network = NetworkService.instance;
    final onWifi = !network.isOnMobileData.value && !network.isOffline.value;
    final record = shouldRecord(
      variant: _variant,
      wifiOnly: _wifiOnly,
      onWifi: onWifi,
      errorOccurred: _errorOccurred,
    );
    if (record == _recording) return;
    _recording = record;
    if (record) {
      unawaited(Posthog().startSessionRecording().catchError((_) {}));
    } else {
      unawaited(Posthog().stopSessionRecording().catchError((_) {}));
    }
  }

  /// Pure decision: whether replay should be recording right now.
  @visibleForTesting
  static bool shouldRecord({
    required String? variant,
    required bool wifiOnly,
    required bool onWifi,
    required bool errorOccurred,
  }) {
    final allowed = switch (variant) {
      'always' => true,
      'on-error' => errorOccurred,
      _ => false,
    };
    return allowed && (!wifiOnly || onWifi);
  }

  /// Extracts `wifiOnly` from a flag payload, defaulting to `true` when the
  /// payload is missing or malformed.
  @visibleForTesting
  static bool parseWifiOnly(Object? payload) {
    if (payload is Map) {
      final value = payload['wifiOnly'];
      if (value is bool) return value;
    }
    return true;
  }

  /// Cancels connectivity subscriptions. Provided for symmetry; the controller
  /// lives for the app's lifetime in production.
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _started = false;
  }
}
