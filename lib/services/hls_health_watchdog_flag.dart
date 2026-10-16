import 'dart:developer' as developer;

import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remote kill switch for the live-HLS liveness watchdog (PostHog flag
/// `hls_health_watchdog`, default on).
///
/// The watchdog reloads streams it judges silent; a bad rule in the field
/// would interrupt healthy listening, so it must be switchable without a
/// release. Mirrors the `RemoteDebugController` pattern: the last-seen
/// value is cached in [SharedPreferences] and applies from startup on the
/// next launch.
class HlsHealthWatchdogFlag {
  static final HlsHealthWatchdogFlag instance = HlsHealthWatchdogFlag._();

  HlsHealthWatchdogFlag._();

  /// PostHog feature flag key.
  static const flagKey = 'hls_health_watchdog';

  static const _kEnabledKey = 'hls_health_watchdog_enabled';

  SharedPreferences? _prefs;
  bool _enabled = true;

  /// Whether the watchdog may run. True until the flag says otherwise.
  bool get enabled => _enabled;

  /// Reads the cached value. Call before PostHog setup.
  Future<void> loadCache(SharedPreferences prefs) async {
    _prefs = prefs;
    _enabled = prefs.getBool(_kEnabledKey) ?? true;
  }

  /// Re-reads the flag once PostHog loaded flags, and caches it.
  Future<void> onFlagsLoaded() async {
    try {
      final result =
          await Posthog().getFeatureFlagResult(flagKey, sendEvent: false);
      _enabled = isEnabled(flagExists: result != null, flagOn: result?.enabled);
      await _prefs?.setBool(_kEnabledKey, _enabled);
    } catch (e) {
      developer.log('hls_health_watchdog flag read failed: $e');
    }
  }

  /// Pure: an undefined flag keeps the watchdog on; a defined one decides.
  static bool isEnabled({required bool flagExists, bool? flagOn}) =>
      !flagExists || (flagOn ?? true);
}
