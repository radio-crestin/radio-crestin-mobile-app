import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether iOS lets the app reach devices on the local network.
enum LocalNetworkAccess { granted, denied }

/// Reports the iOS Local Network permission that Chromecast discovery needs.
///
/// iOS has no API to read this permission, and without it the Cast SDK just
/// finds no devices. While [watch] is listened to, the native side runs its
/// own Bonjour browse for Cast devices and reports whether iOS blocks it.
/// Android has no such permission, so the stream stays empty there.
abstract final class LocalNetworkAccessMonitor {
  static const _channel = EventChannel('com.radiocrestin.local_network');

  /// Emits the current access once known, then each change.
  static Stream<LocalNetworkAccess> watch() {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const Stream.empty();
    }
    return _channel
        .receiveBroadcastStream()
        .map((event) => LocalNetworkAccess.values.byName(event as String))
        .distinct();
  }
}
