import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Detects whether the app is running on a TV or desktop form factor.
/// Desktop platforms (macOS, Linux, Windows) reuse the TV layout since
/// both are large-screen, landscape-oriented surfaces.
class TvPlatform {
  static bool _isTV = false;
  static bool _isDesktop = false;

  /// Whether the current device is a TV (Android TV) or desktop (macOS/Linux/Windows).
  /// Both use the TV/large-screen layout.
  static bool get isTV => _isTV || _isDesktop;

  /// True only for actual Android TV hardware.
  static bool get isAndroidTV => _isTV;

  /// True for macOS, Linux, or Windows desktop.
  static bool get isDesktop => _isDesktop;

  /// Initialize platform detection. Must be called before runApp.
  static Future<void> initialize() async {
    // Desktop detection — no async needed
    _isDesktop = Platform.isMacOS || Platform.isLinux || Platform.isWindows;

    // Android TV detection
    try {
      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        _isTV = androidInfo.systemFeatures.contains('android.software.leanback') ||
            androidInfo.systemFeatures.contains('android.hardware.type.television');
      }
    } catch (e) {
      debugPrint('TV platform detection failed: $e');
      _isTV = false;
    }
  }
}
