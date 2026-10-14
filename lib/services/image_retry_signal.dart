import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:rxdart/rxdart.dart';

import 'network_service.dart';

/// When images that failed to load should try again.
///
/// Image loaders give up on a failure: without this, a logo that failed
/// while offline stayed a placeholder after the internet came back.
abstract final class ImageRetrySignal {
  static final StreamController<void> _resumed =
      StreamController<void>.broadcast();
  static AppLifecycleListener? _lifecycle;

  /// Fires when the internet comes back, and when the app returns to the
  /// foreground while online: a load can also fail on a weak signal
  /// without the app ever counting as offline.
  static Stream<void> get stream {
    _lifecycle ??= AppLifecycleListener(onResume: () => _resumed.add(null));
    final network = NetworkService.instance;
    return Rx.merge<void>([
      // Skips the value the subject replays on listen: only a change
      // means the internet came back.
      network.isOffline.stream.skip(1).where((offline) => !offline),
      _resumed.stream.where((_) => !network.isOffline.value),
    ]);
  }
}
