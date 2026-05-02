import 'dart:developer' as developer;

import 'package:flutter/services.dart';

/// How the app process was started for the current cold launch.
enum LaunchSource {
  /// Launcher icon tap (Android) or any iOS cold launch. Default for unknown.
  launcher,

  /// Recents/task switcher tap on Android. iOS never reports this — the
  /// platform has no API to distinguish a fresh launch from the app
  /// switcher card vs. the home screen icon.
  recents,
}

/// Reads the native launch source flag exactly once per process and caches
/// it. The native layer captures the launch intent flags in
/// `MainActivity.onCreate` (Android) before any `setIntent()` from a later
/// `onNewIntent` can erase them, so the value is stable for the lifetime
/// of the Flutter engine.
class LaunchSourceService {
  static const _channel = MethodChannel('com.radiocrestin.app');

  static LaunchSource? _cached;

  /// Returns the cached source, fetching it from native on first call.
  /// Defaults to [LaunchSource.launcher] if the native side is missing
  /// (e.g. legacy build) or returns an unknown value.
  static Future<LaunchSource> get() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      final raw = await _channel.invokeMethod<String>('getLaunchSource');
      final source = raw == 'recents' ? LaunchSource.recents : LaunchSource.launcher;
      _cached = source;
      developer.log('LaunchSourceService: native reported "$raw" -> $source');
      return source;
    } catch (e) {
      developer.log('LaunchSourceService: error fetching launch source, defaulting to launcher: $e');
      _cached = LaunchSource.launcher;
      return LaunchSource.launcher;
    }
  }
}
