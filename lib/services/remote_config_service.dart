import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Backend-controlled runtime configuration via Firebase Remote Config.
///
/// Values live in the Firebase console, so they can be changed without
/// shipping a new app release. Reads apply the last cached values instantly
/// (no network wait at startup); a fresh fetch runs in the background so the
/// next launch picks up the latest values.
///
/// Only call [initialize] on platforms where Firebase is supported.
class RemoteConfigService {
  static final RemoteConfigService _instance = RemoteConfigService._();
  static RemoteConfigService get instance => _instance;

  RemoteConfigService._();

  // Remote Config keys — create these in the Firebase console.
  static const _kSessionReplayEnabled = 'session_replay_enabled';
  static const _kSessionReplaySampleRatePct = 'session_replay_sample_rate_pct';

  // In-code fallbacks used until the console values are fetched (and on the
  // very first launch / when offline).
  static const _defaultSessionReplayEnabled = true;
  static const _defaultSessionReplaySampleRatePct = 100.0;

  bool _initialized = false;

  /// Apply cached config and trigger a non-blocking refresh for next launch.
  ///
  /// All operations here are local (no network), so awaiting this does not
  /// delay startup — the actual fetch is fire-and-forget.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 8),
        // How stale a cached value may be before a fetch hits the network.
        // Instant in debug so config changes are easy to test.
        minimumFetchInterval:
            kDebugMode ? Duration.zero : const Duration(hours: 1),
      ));
      await rc.setDefaults(<String, dynamic>{
        _kSessionReplayEnabled: _defaultSessionReplayEnabled,
        _kSessionReplaySampleRatePct: _defaultSessionReplaySampleRatePct,
      });
      // Activate values fetched on a previous launch — local, no network.
      await rc.activate();
      // Refresh in the background so the next launch sees the latest values.
      unawaited(rc.fetchAndActivate());
      _initialized = true;
    } catch (e) {
      // Offline or unsupported — callers fall back to the defaults below.
      _initialized = false;
    }
  }

  /// Resolved session replay settings.
  ///
  /// [sampleRate] is a 0.0–1.0 fraction derived from the percentage key;
  /// PostHog rolls against it once per session to decide whether to record.
  ({bool enabled, double sampleRate}) get sessionReplay {
    if (!_initialized) {
      return (
        enabled: _defaultSessionReplayEnabled,
        sampleRate: _defaultSessionReplaySampleRatePct / 100.0,
      );
    }
    final rc = FirebaseRemoteConfig.instance;
    return (
      enabled: rc.getBool(_kSessionReplayEnabled),
      sampleRate: (rc.getDouble(_kSessionReplaySampleRatePct) / 100.0)
          .clamp(0.0, 1.0),
    );
  }
}
