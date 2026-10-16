import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/retry_log_throttle.dart';

void main() {
  group('RetryLogThrottle.isDetailed', () {
    test('logs the first two passes attempt by attempt', () {
      final throttle = RetryLogThrottle();

      // Two streams: attempts 0-3 are the first two passes.
      for (var retry = 0; retry < 4; retry++) {
        expect(throttle.isDetailed(retry: retry, totalStreams: 2), isTrue,
            reason: 'attempt $retry');
      }
      expect(throttle.isDetailed(retry: 4, totalStreams: 2), isFalse);
      expect(throttle.isDetailed(retry: 400, totalStreams: 2), isFalse);
    });

    test('a station without streams counts one attempt per pass', () {
      final throttle = RetryLogThrottle();

      expect(throttle.isDetailed(retry: 1, totalStreams: 0), isTrue);
      expect(throttle.isDetailed(retry: 2, totalStreams: 0), isFalse);
    });
  });

  group('RetryLogThrottle.quietFailure', () {
    final start = DateTime.utc(2026, 10, 16, 12);

    test('sums up at the first quiet failure, then every 5 minutes', () {
      final throttle = RetryLogThrottle();

      expect(throttle.quietFailure(start), 1);
      // Every 10 s for just under 5 minutes: no summary.
      for (var s = 10; s < 300; s += 10) {
        expect(
            throttle.quietFailure(start.add(Duration(seconds: s))), isNull,
            reason: 'at ${s}s');
      }
      // The summary covers every failure since the last one.
      expect(throttle.quietFailure(start.add(const Duration(minutes: 5))), 30);
      expect(
          throttle.quietFailure(start.add(const Duration(minutes: 5, seconds: 10))),
          isNull);
    });
  });
}
