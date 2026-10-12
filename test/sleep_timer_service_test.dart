import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/sleep_timer_service.dart';

/// Manually advanced wall clock, kept in step with the fake timers that
/// `testWidgets` drives through `tester.pump`.
class _FakeClock {
  DateTime now = DateTime(2026, 10, 12, 23, 0);
}

/// Records what the service asks the audio layer to do, in order.
class _FakeAudio {
  final List<String> events = [];
  final List<double> volumes = [];

  Future<void> stop() async => events.add('stop');

  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    events.add('volume');
  }

  int get stopCount => events.where((e) => e == 'stop').length;
}

void main() {
  late _FakeClock clock;
  late _FakeAudio audio;
  late SleepTimerService service;

  void createService() {
    clock = _FakeClock();
    audio = _FakeAudio();
    service = SleepTimerService(
      stopPlayback: audio.stop,
      setVolume: audio.setVolume,
      now: () => clock.now,
    );
  }

  /// Moves time forward in one go (safe while no periodic timer runs).
  Future<void> jump(WidgetTester tester, Duration by) async {
    clock.now = clock.now.add(by);
    await tester.pump(by);
  }

  /// Moves time forward in small steps so fade ticks see matching clocks.
  Future<void> advance(WidgetTester tester, Duration by) async {
    const step = Duration(milliseconds: 250);
    var left = by;
    while (left > Duration.zero) {
      final next = left < step ? left : step;
      clock.now = clock.now.add(next);
      await tester.pump(next);
      left -= next;
    }
  }

  testWidgets('arms a timer with its duration and end time', (tester) async {
    createService();

    service.start(const Duration(minutes: 30));

    final armed = service.state.value!;
    expect(armed.duration, const Duration(minutes: 30));
    expect(armed.endsAt, clock.now.add(const Duration(minutes: 30)));
    expect(armed.fractionLeftAt(clock.now), 1.0);

    service.cancel();
  });

  testWidgets('fades out over the last minute, stops, then restores volume',
      (tester) async {
    createService();
    service.start(const Duration(minutes: 15));

    await jump(tester, const Duration(minutes: 13));
    expect(audio.events, isEmpty, reason: 'no fade before the last minute');

    await jump(tester, const Duration(minutes: 1));
    await advance(tester, const Duration(seconds: 30));
    expect(audio.volumes.last, closeTo(0.5, 0.02));
    expect(audio.stopCount, 0);

    await advance(tester, const Duration(seconds: 30));
    expect(audio.stopCount, 1);
    expect(service.state.value, isNull);
    expect(audio.volumes.last, 1.0);
    expect(
      audio.events.lastIndexOf('stop'),
      lessThan(audio.events.lastIndexOf('volume')),
      reason: 'volume is restored only after playback stopped',
    );
  });

  testWidgets('cancelling during the fade restores volume and never stops',
      (tester) async {
    createService();
    service.start(const Duration(minutes: 15));

    await jump(tester, const Duration(minutes: 14));
    await advance(tester, const Duration(seconds: 20));
    expect(audio.volumes.last, lessThan(1.0));

    service.cancel();
    expect(service.state.value, isNull);
    expect(audio.volumes.last, 1.0);

    await jump(tester, const Duration(minutes: 5));
    expect(audio.stopCount, 0);
  });

  testWidgets('choosing again replaces the running timer', (tester) async {
    createService();
    service.start(const Duration(minutes: 15));
    await jump(tester, const Duration(minutes: 10));

    service.start(const Duration(minutes: 30));
    await jump(tester, const Duration(minutes: 28));
    expect(audio.stopCount, 0, reason: 'the first timer was replaced');

    await advance(tester, const Duration(minutes: 2));
    expect(audio.stopCount, 1);
  });

  testWidgets('cancelling with no timer armed does nothing', (tester) async {
    createService();

    service.cancel();

    expect(service.state.value, isNull);
    expect(audio.events, isEmpty);
  });

  group('SleepCountdownTicker', () {
    late int ticks;
    late SleepCountdownTicker ticker;

    setUp(() {
      clock = _FakeClock();
      ticks = 0;
      ticker =
          SleepCountdownTicker(now: () => clock.now, onTick: () => ticks++);
    });

    SleepTimerState armedFor(Duration left) => SleepTimerState(
          duration: left,
          endsAt: clock.now.add(left),
        );

    testWidgets('ticks right after each whole second, not in between',
        (tester) async {
      // Opened 400 ms into a second: the first change is 400 ms away.
      ticker.follow(armedFor(const Duration(minutes: 30, milliseconds: 400)));

      await jump(tester, const Duration(milliseconds: 404));
      expect(ticks, 0);
      await jump(tester, const Duration(milliseconds: 1));
      expect(ticks, 1);

      await jump(tester, const Duration(milliseconds: 999));
      expect(ticks, 1, reason: 'one tick per second, no extra work between');
      await jump(tester, const Duration(milliseconds: 1));
      expect(ticks, 2);

      ticker.stop();
    });

    testWidgets('stops on its own when the countdown reaches zero',
        (tester) async {
      ticker.follow(armedFor(const Duration(seconds: 2)));

      await jump(tester, const Duration(milliseconds: 1005));
      await jump(tester, const Duration(milliseconds: 1000));
      expect(ticks, 2);

      await jump(tester, const Duration(minutes: 5));
      expect(ticks, 2);
    });

    testWidgets('does nothing after stop or with no timer', (tester) async {
      ticker.follow(armedFor(const Duration(minutes: 30)));
      ticker.stop();
      ticker.follow(null);

      await jump(tester, const Duration(minutes: 5));
      expect(ticks, 0);
    });
  });

  group('SleepTimerState', () {
    final endsAt = DateTime(2026, 10, 12, 23, 30);
    final state = SleepTimerState(
      duration: const Duration(minutes: 30),
      endsAt: endsAt,
    );

    test('reports the time and share left', () {
      final now = endsAt.subtract(const Duration(minutes: 15));
      expect(state.remainingAt(now), const Duration(minutes: 15));
      expect(state.fractionLeftAt(now), 0.5);
    });

    test('never goes below zero after the end', () {
      final now = endsAt.add(const Duration(minutes: 1));
      expect(state.remainingAt(now), Duration.zero);
      expect(state.fractionLeftAt(now), 0.0);
    });
  });

  group('formatSleepCountdown', () {
    test('formats minutes and seconds', () {
      expect(
        formatSleepCountdown(const Duration(minutes: 28, seconds: 41)),
        '28:41',
      );
    });

    test('rounds up so the last second does not read 0:00', () {
      expect(formatSleepCountdown(const Duration(milliseconds: 300)), '0:01');
    });

    test('adds hours past sixty minutes', () {
      expect(
        formatSleepCountdown(const Duration(hours: 1, minutes: 5, seconds: 9)),
        '1:05:09',
      );
    });
  });
}
