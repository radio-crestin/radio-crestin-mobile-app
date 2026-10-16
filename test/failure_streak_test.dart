import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/failure_streak.dart';

void main() {
  group('FailureStreak', () {
    final start = DateTime.utc(2026, 10, 16, 12);

    test('only the first failure of a streak is worth logging', () {
      final streak = FailureStreak();

      expect(streak.fail(start), isTrue);
      expect(streak.fail(start.add(const Duration(minutes: 1))), isFalse);
      expect(streak.fail(start.add(const Duration(minutes: 2))), isFalse);
    });

    test('a success ends the streak with its count and length', () {
      final streak = FailureStreak()
        ..fail(start)
        ..fail(start.add(const Duration(minutes: 1)))
        ..fail(start.add(const Duration(minutes: 2)));

      final ended = streak.succeed(start.add(const Duration(minutes: 3)));

      expect(ended?.failures, 3);
      expect(ended?.duration, const Duration(minutes: 3));
    });

    test('a success with nothing failing ends nothing', () {
      expect(FailureStreak().succeed(start), isNull);
    });

    test('a failure after a recovery starts a new streak', () {
      final streak = FailureStreak()..fail(start);
      streak.succeed(start.add(const Duration(minutes: 1)));

      expect(streak.fail(start.add(const Duration(minutes: 2))), isTrue);
      expect(streak.succeed(start.add(const Duration(minutes: 4)))?.failures, 1);
    });
  });
}
