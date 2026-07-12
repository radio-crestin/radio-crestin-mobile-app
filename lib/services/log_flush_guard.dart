import 'dart:async';
import 'dart:developer' as developer;

import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network_service.dart';

/// Guarantees captured exceptions reach PostHog even across offline periods
/// and crashes.
///
/// `Posthog().flush()` drains events, replay, and log queues together, and
/// the SDK persists those queues to disk across restarts. So the guarantee
/// reduces to: flush as soon as an exception is captured, and if the device
/// is offline remember (`pending_log_flush` in [SharedPreferences]) to flush
/// when connectivity returns — including on the next launch after a crash.
///
/// Log/event uploads are tiny, so unlike session replay they are NOT gated
/// on WiFi — any connectivity is enough.
class LogFlushGuard {
  static final LogFlushGuard _instance = LogFlushGuard();

  /// The app-wide singleton, flushing through the PostHog SDK.
  static LogFlushGuard get instance => _instance;

  /// Creates a guard. [flush] overrides the upload call (used by tests).
  LogFlushGuard({Future<void> Function()? flush})
      : _flush = flush ?? _posthogFlush;

  static Future<void> _posthogFlush() => Posthog().flush();

  /// SharedPreferences key marking a flush owed from a previous offline
  /// exception (or a crash before the flush completed).
  static const pendingFlushKey = 'pending_log_flush';

  final Future<void> Function() _flush;
  SharedPreferences? _prefs;
  StreamSubscription<bool>? _subscription;
  bool _started = false;

  /// Whether a flush is owed from an earlier offline exception.
  bool get isPending => _prefs?.getBool(pendingFlushKey) ?? false;

  /// Subscribes to connectivity and settles any pending flush. Call once
  /// after `Posthog().setup(...)`. The seeded [NetworkService.isOffline]
  /// stream replays the current value on listen, so this also performs the
  /// startup check that covers the crash-then-restart case (the SDK's own
  /// queues survive restarts on disk). Idempotent.
  void start(SharedPreferences prefs) {
    if (_started) return;
    _started = true;
    _prefs = prefs;
    // Events are delivered on a microtask, so an event can be stale by the
    // time it arrives (e.g. the replayed seed after connectivity already
    // changed) — always consult the live value instead of the event.
    _subscription = NetworkService.instance.isOffline.stream.listen((_) {
      final offline = NetworkService.instance.isOffline.value;
      if (!offline && isPending) _flushNow();
    });
  }

  /// Uploads queued data now, or marks a pending flush when offline.
  /// Fire-and-forget; never throws into the caller.
  void requestFlush() {
    if (NetworkService.instance.isOffline.value) {
      unawaited(_prefs?.setBool(pendingFlushKey, true));
      return;
    }
    _flushNow();
  }

  void _flushNow() {
    unawaited(_flush().then((_) async {
      await _prefs?.setBool(pendingFlushKey, false);
    }).catchError((Object e) {
      // Upload failed (e.g. network dropped mid-flight) — owe a flush so the
      // connectivity listener or next launch retries.
      developer.log('LogFlushGuard: flush failed, deferring: $e');
      unawaited(_prefs?.setBool(pendingFlushKey, true));
    }));
  }

  /// Cancels the connectivity subscription. Provided for tests; the guard
  /// lives for the app's lifetime in production.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _started = false;
  }
}
