import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Detects whether the app is running on a TV form factor.
class TvPlatform {
  static bool _isTV = false;

  /// Whether the current device is a TV (Android TV or Apple TV).
  static bool get isTV => _isTV;

  /// Initialize TV detection. Must be called before runApp.
  static Future<void> initialize() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // Android TV devices report 'television' in systemFeatures
        // or have 'android.software.leanback' feature.
        _isTV = androidInfo.systemFeatures.contains('android.software.leanback') ||
            androidInfo.systemFeatures.contains('android.hardware.type.television');
      }
      // Note: Apple TV (tvOS) would be detected by Platform.isIOS + device model,
      // but requires custom Flutter engine. Listed for future compatibility.
    } catch (e) {
      debugPrint('TV platform detection failed: $e');
      _isTV = false;
    }
  }
}
