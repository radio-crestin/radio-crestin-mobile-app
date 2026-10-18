import 'dart:developer' as developer;

import 'package:flutter/services.dart';

/// Holds iOS background time: `UIApplication.beginBackgroundTask`, which
/// keeps the app running a while (about 30 s, as iOS decides) after it
/// would otherwise be suspended in the background, without playing
/// anything (see `BackgroundTaskHandler.swift`).
///
/// One task at a time: [begin] replaces the last one. iOS ends it once the
/// time runs out, and the app is suspended as usual.
class IosBackgroundTask {
  IosBackgroundTask({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.radiocrestin.background_task';

  final MethodChannel _channel;
  bool _held = false;

  /// Asks for background time; returns whether iOS granted it.
  Future<bool> begin() async {
    // Set before the call, so that an end() racing it still goes out:
    // the channel delivers both in order.
    _held = true;
    try {
      return await _channel.invokeMethod<bool>('begin') ?? false;
    } catch (e) {
      developer.log('IosBackgroundTask: begin failed: $e');
      return false;
    }
  }

  /// Gives the time back, when one was asked for.
  Future<void> end() async {
    if (!_held) return;
    _held = false;
    try {
      await _channel.invokeMethod<void>('end');
    } catch (e) {
      developer.log('IosBackgroundTask: end failed: $e');
    }
  }
}
