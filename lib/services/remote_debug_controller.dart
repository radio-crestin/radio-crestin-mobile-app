import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics_service.dart';
import 'log_upload_service.dart';
import 'session_replay_controller.dart';

/// Parsed payload of the `mobile-remote-debug` boolean feature flag.
///
/// The flag sits at 0% rollout and is enabled per device by targeting the
/// person's `device_id`. Every payload key is optional and defaults to false
/// (including `wifiOnly` — unlike the replay flag — so remote debugging works
/// on mobile data).
@immutable
class RemoteDebugConfig {
  /// Whether the flag is enabled for this device.
  final bool enabled;

  /// Ship debug-level log records to PostHog (see
  /// [AnalyticsService.minShipLevel]).
  final bool verboseLogs;

  /// Force session replay on, regardless of the `mobile-session-replay`
  /// variant.
  final bool sessionReplay;

  /// Restrict the forced replay to WiFi/ethernet. Defaults false here.
  final bool wifiOnly;

  /// Automatically upload the local log files shortly after startup.
  final bool uploadLocalLogs;

  const RemoteDebugConfig({
    this.enabled = false,
    this.verboseLogs = false,
    this.sessionReplay = false,
    this.wifiOnly = false,
    this.uploadLocalLogs = false,
  });

  /// The everything-off default (flag off / first launch).
  static const disabled = RemoteDebugConfig();

  /// Parses a flag payload map. Missing or malformed keys default to false.
  /// Pure — unit tested directly.
  factory RemoteDebugConfig.parse({
    required bool enabled,
    Object? payload,
  }) {
    if (!enabled) return disabled;
    bool flag(String key) => payload is Map && payload[key] == true;
    return RemoteDebugConfig(
      enabled: true,
      verboseLogs: flag('verboseLogs'),
      sessionReplay: flag('sessionReplay'),
      wifiOnly: flag('wifiOnly'),
      uploadLocalLogs: flag('uploadLocalLogs'),
    );
  }
}

/// Consumes the `mobile-remote-debug` feature flag: verbose log shipping,
/// forced session replay, and automatic local-log upload for devices we are
/// actively debugging.
///
/// Mirrors the [SessionReplayController] pattern: the last-seen flag state is
/// cached in [SharedPreferences] so it applies from startup on the next
/// launch; when flags load, the live value updates the cache and re-applies.
/// When the flag turns off, everything reverts to normal behavior.
class RemoteDebugController {
  static final RemoteDebugController _instance = RemoteDebugController._();

  /// The app-wide singleton.
  static RemoteDebugController get instance => _instance;

  RemoteDebugController._();

  /// PostHog feature flag key for per-device remote debugging.
  static const flagKey = 'mobile-remote-debug';

  static const _kEnabledKey = 'remote_debug_enabled';
  static const _kVerboseKey = 'remote_debug_verbose_logs';
  static const _kReplayKey = 'remote_debug_session_replay';
  static const _kWifiOnlyKey = 'remote_debug_wifi_only';
  static const _kUploadKey = 'remote_debug_upload_logs';

  SharedPreferences? _prefs;
  RemoteDebugConfig _config = RemoteDebugConfig.disabled;
  bool _autoUploadScheduled = false;

  /// The active (cached or live) configuration.
  RemoteDebugConfig get config => _config;

  /// Whether the cached config forces session replay — feeds
  /// `config.sessionReplay` at PostHog setup so the native replay integration
  /// installs even for devices whose replay variant is `disabled`.
  bool get forceSessionReplay => _config.enabled && _config.sessionReplay;

  /// Reads the cached flag state. Call before `Posthog().setup(...)`.
  Future<void> loadCache(SharedPreferences prefs) async {
    _prefs = prefs;
    _config = (prefs.getBool(_kEnabledKey) ?? false)
        ? RemoteDebugConfig(
            enabled: true,
            verboseLogs: prefs.getBool(_kVerboseKey) ?? false,
            sessionReplay: prefs.getBool(_kReplayKey) ?? false,
            wifiOnly: prefs.getBool(_kWifiOnlyKey) ?? false,
            uploadLocalLogs: prefs.getBool(_kUploadKey) ?? false,
          )
        : RemoteDebugConfig.disabled;
  }

  /// Applies the cached configuration. Call right after
  /// `Posthog().setup(...)` (and after `SessionReplayController.start()`).
  void start() => _apply();

  /// Re-reads the flag after PostHog loads it, updates the cache for next
  /// launch, and re-applies.
  Future<void> onFlagsLoaded() async {
    try {
      final result = await Posthog().getFeatureFlagResult(flagKey);
      _config = RemoteDebugConfig.parse(
        enabled: result?.enabled ?? false,
        payload: result?.payload,
      );
      final prefs = _prefs;
      if (prefs != null) {
        await prefs.setBool(_kEnabledKey, _config.enabled);
        await prefs.setBool(_kVerboseKey, _config.verboseLogs);
        await prefs.setBool(_kReplayKey, _config.sessionReplay);
        await prefs.setBool(_kWifiOnlyKey, _config.wifiOnly);
        await prefs.setBool(_kUploadKey, _config.uploadLocalLogs);
      }
    } catch (e) {
      developer.log('Remote debug flag read failed: $e');
    }
    _apply();
  }

  void _apply() {
    AnalyticsService.instance
        .setRemoteVerbose(_config.enabled && _config.verboseLogs);
    SessionReplayController.instance.setRemoteOverride(
      force: _config.enabled && _config.sessionReplay,
      wifiOnly: _config.wifiOnly,
    );
    if (_config.enabled && _config.uploadLocalLogs) _scheduleAutoUpload();
  }

  /// Uploads local logs shortly after startup — post-frame so it never
  /// competes with first paint, debounced to once per 6h inside
  /// [LogUploadService.maybeAutoUpload]. At most once per app session.
  void _scheduleAutoUpload() {
    if (_autoUploadScheduled) return;
    _autoUploadScheduled = true;
    final prefs = _prefs;
    if (prefs == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      unawaited(LogUploadService.instance.maybeAutoUpload(prefs));
    });
  }
}
