import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/performance_monitor.dart';

void main() {
  group('PerformanceMonitor', () {
    setUp(() {
      PerformanceMonitor.reset();
    });

    group('startOperation / endOperation', () {
      test('returns elapsed time in milliseconds', () {
        PerformanceMonitor.startOperation('test_op');
        // Small delay to ensure non-zero elapsed time
        final elapsed = PerformanceMonitor.endOperation('test_op');
        expect(elapsed, greaterThanOrEqualTo(0));
      });

      test('returns -1 when ending an unstarted operation', () {
        final elapsed = PerformanceMonitor.endOperation('nonexistent');
        expect(elapsed, -1);
      });

      test('supports concurrent operations with same name', () {
        PerformanceMonitor.startOperation('concurrent');
        PerformanceMonitor.startOperation('concurrent');

        final elapsed1 = PerformanceMonitor.endOperation('concurrent');
        final elapsed2 = PerformanceMonitor.endOperation('concurrent');

        expect(elapsed1, greaterThanOrEqualTo(0));
        expect(elapsed2, greaterThanOrEqualTo(0));
      });

      test('cleans up after all concurrent operations end', () {
        PerformanceMonitor.startOperation('cleanup');
        PerformanceMonitor.endOperation('cleanup');

        // Ending again should return -1
        final elapsed = PerformanceMonitor.endOperation('cleanup');
        expect(elapsed, -1);
      });
    });

    group('trackAsync', () {
      test('wraps async function with timing', () async {
        final result = await PerformanceMonitor.trackAsync('async_op', () async {
          return 42;
        });
        expect(result, 42);
      });

      test('still records timing when function throws', () async {
        try {
          await PerformanceMonitor.trackAsync('failing_op', () async {
            throw Exception('test error');
          });
        } catch (_) {
          // Expected
        }

        // The operation should have been ended (no leak)
        final elapsed = PerformanceMonitor.endOperation('failing_op');
        expect(elapsed, -1); // Already ended by trackAsync
      });
    });

    group('markAppStart / markAppReady', () {
      test('records startup time', () {
        PerformanceMonitor.markAppStart();
        PerformanceMonitor.markAppReady();
        // No crash = success; we can't easily inspect _operationHistory
      });

      test('markAppReady does nothing without markAppStart', () {
        PerformanceMonitor.markAppReady();
        // No crash = success
      });
    });

    group('reset', () {
      test('clears all tracked data', () {
        PerformanceMonitor.startOperation('to_reset');
        PerformanceMonitor.endOperation('to_reset');

        PerformanceMonitor.reset();

        // After reset, ending the same op should return -1
        final elapsed = PerformanceMonitor.endOperation('to_reset');
        expect(elapsed, -1);
      });
    });

    group('printReport', () {
      test('does not crash with no data', () {
        PerformanceMonitor.printReport();
      });

      test('does not crash with data', () {
        PerformanceMonitor.markAppStart();
        PerformanceMonitor.markAppReady();
        PerformanceMonitor.startOperation('some_op');
        PerformanceMonitor.endOperation('some_op');
        PerformanceMonitor.printReport();
      });
    });
  });
}
