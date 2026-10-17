import 'dart:io';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../seek_mode_manager.dart';
import '../tv/tv_platform.dart';
import 'analytics_service.dart';
import 'hls_health_watchdog_flag.dart';
import 'hls_hold_proxy_flag.dart';
import 'remote_debug_controller.dart';

/// Marks each launch in the log with an `app started` record, written
/// within the launch's first second.
///
/// It names the build and the phone, the locale and the time zone (the log's
/// timestamps are UTC), the settings that shape playback and the flags in
/// force, so a log file a listener sends says what wrote it. The device id
/// stays out: device ids never go into the logs.
abstract final class AppStartLog {
  /// Collects the details and writes the record. Never throws: when the
  /// device details can't be read, the record goes out without them.
  static Future<void> write({
    required SharedPreferences prefs,
    required String appVersion,
    required String buildNumber,
  }) async {
    var device = const <String, Object>{};
    try {
      device = await _deviceDetails();
    } catch (_) {
      // The rest of the record still says what wrote the log.
    }
    AnalyticsService.instance.log(
      'app started',
      attributes(
        prefs: prefs,
        appVersion: appVersion,
        buildNumber: buildNumber,
        device: device,
        locale: ui.PlatformDispatcher.instance.locale.toString(),
        now: DateTime.now(),
      ),
    );
  }

  /// The record's attributes: the arguments, plus the settings and flags
  /// as they stand. Unit tested directly.
  @visibleForTesting
  static Map<String, Object> attributes({
    required SharedPreferences prefs,
    required String appVersion,
    required String buildNumber,
    required Map<String, Object> device,
    required String locale,
    required DateTime now,
  }) {
    final remoteDebug = RemoteDebugController.instance.config;
    return {
      'app_version': appVersion,
      'build_number': buildNumber,
      'build_mode': AnalyticsService.buildMode,
      'platform': Platform.operatingSystem,
      ...device,
      'tv': TvPlatform.isTV,
      'locale': locale,
      'timezone': now.timeZoneName,
      'timezone_offset_minutes': now.timeZoneOffset.inMinutes,
      'seek_mode': SeekModeManager.seekMode.value.name,
      'unstable_connection': SeekModeManager.isUnstableConnection,
      'auto_start': prefs.getBool('_autoStartStation') ?? true,
      'notifications': prefs.getBool('_notificationsEnabled') ?? true,
      'developer_mode': prefs.getBool('developer_mode_enabled') ?? false,
      'hls_watchdog': HlsHealthWatchdogFlag.instance.enabled,
      // Only where the proxy runs (see AppAudioHandler.holdProxyPlatform).
      if (Platform.isIOS) 'hls_hold_proxy': HlsHoldProxyFlag.instance.enabled,
      'remote_debug': remoteDebug.enabled,
      if (remoteDebug.enabled) ...{
        'remote_verbose_logs': remoteDebug.verboseLogs,
        'remote_upload_logs': remoteDebug.uploadLocalLogs,
      },
    };
  }

  static Future<Map<String, Object>> _deviceDetails() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      return {
        'os_version': android.version.release,
        'sdk_int': android.version.sdkInt,
        'manufacturer': android.manufacturer,
        'device_model': android.model,
        'is_physical_device': android.isPhysicalDevice,
      };
    }
    if (Platform.isIOS) {
      final ios = await info.iosInfo;
      return {
        'os_version': ios.systemVersion,
        // e.g. "iPhone14,5"; `model` is only "iPhone".
        'device_model': ios.utsname.machine,
        'is_physical_device': ios.isPhysicalDevice,
      };
    }
    return {'os_version': Platform.operatingSystemVersion};
  }
}
