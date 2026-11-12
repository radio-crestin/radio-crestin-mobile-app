import 'dart:async';

/// Measures how long the app's UI isolate goes without a turn of its event
/// loop: the time a tap waits before the app can take it.
///
/// On Android the UI isolate runs on the main thread (Flutter 3.29+), so a
/// stall of 5 s while the listener presses a key is an ANR ("Input
/// dispatching timed out").
class UiStallMeter {
  UiStallMeter.start() {
    _last = _clock.elapsed;
    _timer = Timer.periodic(_interval, (_) => _onTick());
  }

  static const _interval = Duration(milliseconds: 16);

  final _clock = Stopwatch()..start();
  late Duration _last;
  late final Timer _timer;

  /// The longest wait so far, beyond the timer's own interval.
  Duration longest = Duration.zero;

  void _onTick() {
    final now = _clock.elapsed;
    final stall = now - _last - _interval;
    if (stall > longest) longest = stall;
    _last = now;
  }

  void stop() => _timer.cancel();
}
