import 'dart:developer' as developer;

import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remote kill switch for the local hold proxy live HLS loads go through on
/// iOS (PostHog flag `hls_hold_proxy`, default on). See `HlsHoldProxy`.
///
/// Every live HLS load of the origin goes through the proxy, so a fault in
/// it would cost every iPhone its streams: it must be switchable without a
/// release. Turned off, loads go straight to the origin again, from the
/// next one on. Mirrors `HlsHealthWatchdogFlag`: the last-seen value is
/// cached in [SharedPreferences] and applies from startup on the next
/// launch.
class HlsHoldProxyFlag {
  static final HlsHoldProxyFlag instance = HlsHoldProxyFlag._();

  HlsHoldProxyFlag._();

  /// PostHog feature flag key.
  static const flagKey = 'hls_hold_proxy';

  static const _kEnabledKey = 'hls_hold_proxy_enabled';

  SharedPreferences? _prefs;
  bool _enabled = true;

  /// Whether live HLS loads may go through the proxy. True until the flag
  /// says otherwise.
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
      developer.log('hls_hold_proxy flag read failed: $e');
    }
  }

  /// Pure: an undefined flag keeps the proxy on; a defined one decides.
  static bool isEnabled({required bool flagExists, bool? flagOn}) =>
      !flagExists || (flagOn ?? true);
}
