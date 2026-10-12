import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

/// An armed sleep timer: the duration the listener picked and when it fires.
@immutable
class SleepTimerState {
  /// The duration the listener picked (15 min, 1 h, ...).
  final Duration duration;

  /// Wall-clock moment when playback stops.
  final DateTime endsAt;

  const SleepTimerState({required this.duration, required this.endsAt});

  /// Time left until [endsAt] at [now], never negative.
  Duration remainingAt(DateTime now) {
    final left = endsAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Share of [duration] still left at [now], from 1.0 down to 0.0.
  double fractionLeftAt(DateTime now) {
    if (duration <= Duration.zero) return 0.0;
    final fraction = remainingAt(now).inMilliseconds / duration.inMilliseconds;
    return fraction.clamp(0.0, 1.0).toDouble();
  }
}

/// Formats a sleep-timer countdown as `m:ss`, or `h:mm:ss` past an hour.
///
/// Rounds up, so the last second still reads `0:01` instead of `0:00`.
String formatSleepCountdown(Duration remaining) {
  final seconds = (remaining.inMilliseconds / 1000).ceil();
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final secs = twoDigits(seconds % 60);
  return hours > 0 ? '$hours:${twoDigits(minutes)}:$secs' : '$minutes:$secs';
}

/// Calls `onTick` whenever the whole-second countdown of a timer changes.
///
/// Each tick is scheduled for the next second boundary of the remaining time
/// instead of on a free-running one-second period, so a countdown neither
/// skips nor lingers on a second and does no work in between.
class SleepCountdownTicker {
  SleepCountdownTicker({
    required DateTime Function() now,
    required VoidCallback onTick,
  })  : _now = now,
        _onTick = onTick;

  final DateTime Function() _now;
  final VoidCallback _onTick;
  Timer? _timer;

  /// Ticks for [armed], or stops ticking when it is null.
  void follow(SleepTimerState? armed) {
    _timer?.cancel();
    _timer = null;
    if (armed != null) _scheduleNext(armed);
  }

  /// Stops ticking.
  void stop() => follow(null);

  void _scheduleNext(SleepTimerState armed) {
    final left = armed.remainingAt(_now()).inMilliseconds;
    if (left <= 0) return;
    final untilChange = left % 1000 == 0 ? 1000 : left % 1000;
    // A few milliseconds late, so the new second already shows when it fires.
    _timer = Timer(Duration(milliseconds: untilChange + 5), () {
      _onTick();
      _scheduleNext(armed);
    });
  }
}

/// Stops playback after a listener-chosen delay.
///
/// The volume fades out over the last [fadeDuration] so the radio never cuts
/// off abruptly while someone is falling asleep, and it is restored once
/// playback has stopped (or the timer is cancelled) so the next play is not
/// silent. Owned by `AppAudioHandler`, so the timer survives the full player
/// being collapsed or rebuilt; the UI only reads [state] and calls [start] /
/// [cancel].
class SleepTimerService {
  SleepTimerService({
    required Future<void> Function() stopPlayback,
    required Future<void> Function(double volume) setVolume,
    DateTime Function()? now,
  })  : _stopPlayback = stopPlayback,
        _setVolume = setVolume,
        _now = now ?? DateTime.now;

  /// How long before the end the volume starts to drop.
  static const Duration fadeDuration = Duration(minutes: 1);

  /// How often the volume is lowered during the fade.
  static const Duration _fadeStep = Duration(milliseconds: 500);

  final Future<void> Function() _stopPlayback;
  final Future<void> Function(double volume) _setVolume;
  final DateTime Function() _now;

  /// The armed timer, or null when none is running.
  final BehaviorSubject<SleepTimerState?> state =
      BehaviorSubject<SleepTimerState?>.seeded(null);

  Timer? _fadeStartTimer;
  Timer? _fadeTicker;
  Timer? _endTimer;
  bool _volumeLowered = false;

  /// The current wall-clock time, from the injected clock.
  DateTime get now => _now();

  /// Arms the timer for [duration], replacing any timer already running.
  void start(Duration duration) {
    _cancelTimers();
    _restoreVolume();
    state
        .add(SleepTimerState(duration: duration, endsAt: _now().add(duration)));

    final untilFade = duration - fadeDuration;
    if (untilFade <= Duration.zero) {
      _startFade();
    } else {
      _fadeStartTimer = Timer(untilFade, _startFade);
    }
    _endTimer = Timer(duration, _complete);
  }

  /// Disarms the timer; playback continues at full volume.
  void cancel() {
    if (state.value == null) return;
    _cancelTimers();
    _restoreVolume();
    state.add(null);
  }

  /// Cancels the pending timers and closes [state].
  Future<void> dispose() async {
    _cancelTimers();
    await state.close();
  }

  void _startFade() {
    _fadeTicker?.cancel();
    _applyFade();
    _fadeTicker = Timer.periodic(_fadeStep, (_) => _applyFade());
  }

  void _applyFade() {
    final armed = state.value;
    if (armed == null) return;
    final left = armed.remainingAt(_now());
    final volume = (left.inMilliseconds / fadeDuration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
    // Still at full volume (the fade's first instant): nothing to send.
    if (volume >= 1.0 && !_volumeLowered) return;
    _volumeLowered = true;
    _setVolumeSafely(volume);
  }

  Future<void> _complete() async {
    _cancelTimers();
    state.add(null);
    try {
      await _stopPlayback();
    } catch (e) {
      debugPrint('SleepTimerService: stopping playback failed: $e');
    }
    // Restored only after the stop so the jump back to full volume is never
    // audible.
    _restoreVolume();
  }

  void _restoreVolume() {
    if (!_volumeLowered) return;
    _volumeLowered = false;
    _setVolumeSafely(1.0);
  }

  void _setVolumeSafely(double volume) {
    unawaited(_setVolume(volume).catchError((Object e) {
      debugPrint('SleepTimerService: setVolume($volume) failed: $e');
    }));
  }

  void _cancelTimers() {
    _fadeStartTimer?.cancel();
    _fadeTicker?.cancel();
    _endTimer?.cancel();
    _fadeStartTimer = null;
    _fadeTicker = null;
    _endTimer = null;
  }
}
