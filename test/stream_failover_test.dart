import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/stream_failover.dart';

/// Regression suite for the "stuck on dead HLS" report: when HLS died
/// mid-playback every reconnect restarted the retry cycle at index 0 (the
/// same dead HLS), and after maxRetries=4 the player gave up entirely.
/// [StreamFailover] replaces both behaviors: failure memory picks the cycle
/// start, cycles never give up, and backoff only kicks in after a full
/// failed pass over all streams.
void main() {
  const hls = 'https://cdn.example.com/station/index.m3u8';
  const direct = 'https://stream.example.com/station.mp3';
  const backup = 'https://backup.example.com/station.aac';

  group('StreamFailover.loadTimeout', () {
    test('HLS keeps the fast 3s cap (no fast-start regression)', () {
      expect(StreamFailover.loadTimeout(isHls: true),
          const Duration(seconds: 3));
    });

    test('direct streams are capped at 5s (was 10s — read as "stuck")', () {
      expect(StreamFailover.loadTimeout(isHls: false),
          const Duration(seconds: 5));
    });

    test('every load is bounded by at most 5s', () {
      expect(StreamFailover.hlsLoadTimeout,
          lessThanOrEqualTo(const Duration(seconds: 5)));
      expect(StreamFailover.directLoadTimeout,
          lessThanOrEqualTo(const Duration(seconds: 5)));
    });
  });

  group('StreamFailover.retryDelay', () {
    test('first full cycle over multiple streams is instant', () {
      for (var retry = 0; retry < 3; retry++) {
        expect(
          StreamFailover.retryDelay(retry: retry, totalStreams: 3),
          Duration.zero,
          reason: 'attempt $retry is within cycle 0',
        );
      }
    });

    test('advancing between streams mid-cycle is always instant', () {
      // Cycle 2 of a 3-stream station: only the boundary attempt delays.
      expect(StreamFailover.retryDelay(retry: 7, totalStreams: 3),
          Duration.zero);
      expect(StreamFailover.retryDelay(retry: 8, totalStreams: 3),
          Duration.zero);
    });

    test('backoff grows per full failed cycle: 1s, 2s, 5s, then 10s cap', () {
      expect(StreamFailover.retryDelay(retry: 3, totalStreams: 3),
          const Duration(seconds: 1));
      expect(StreamFailover.retryDelay(retry: 6, totalStreams: 3),
          const Duration(seconds: 2));
      expect(StreamFailover.retryDelay(retry: 9, totalStreams: 3),
          const Duration(seconds: 5));
      expect(StreamFailover.retryDelay(retry: 12, totalStreams: 3),
          const Duration(seconds: 10));
      expect(StreamFailover.retryDelay(retry: 30, totalStreams: 3),
          const Duration(seconds: 10));
    });

    test('single-stream station: every retry is a cycle boundary', () {
      expect(StreamFailover.retryDelay(retry: 0, totalStreams: 1),
          Duration.zero);
      expect(StreamFailover.retryDelay(retry: 1, totalStreams: 1),
          const Duration(seconds: 1));
      expect(StreamFailover.retryDelay(retry: 2, totalStreams: 1),
          const Duration(seconds: 2));
      expect(StreamFailover.retryDelay(retry: 3, totalStreams: 1),
          const Duration(seconds: 5));
      expect(StreamFailover.retryDelay(retry: 4, totalStreams: 1),
          const Duration(seconds: 10));
    });

    test('zero streams (item.id fallback) behaves like a single stream', () {
      expect(StreamFailover.retryDelay(retry: 0, totalStreams: 0),
          Duration.zero);
      expect(StreamFailover.retryDelay(retry: 1, totalStreams: 0),
          const Duration(seconds: 1));
    });
  });

  group('StreamFailover failure memory', () {
    late StreamFailover failover;
    final t0 = DateTime(2026, 7, 12, 12, 0, 0);

    setUp(() => failover = StreamFailover());

    test('no failures → cycle starts at the preferred stream (index 0)', () {
      expect(failover.startIndex([hls, direct], t0), 0);
    });

    test('recent HLS failure → cycle starts at the next stream', () {
      // Scenario (c): HLS died mid-playback, the watchdog/stall recorded it;
      // the reconnect must go straight to the direct stream instead of
      // re-looping on the dead HLS.
      failover.recordFailure(hls, t0);
      expect(failover.startIndex([hls, direct], t0), 1);
    });

    test('first two failed → starts at the third', () {
      failover.recordFailure(hls, t0);
      failover.recordFailure(direct, t0);
      expect(failover.startIndex([hls, direct, backup], t0), 2);
    });

    test('all streams failed → starts at 0 (preferred order, never stuck)',
        () {
      failover.recordFailure(hls, t0);
      failover.recordFailure(direct, t0);
      expect(failover.startIndex([hls, direct], t0), 0);
    });

    test('single-stream station keeps retrying its only URL', () {
      failover.recordFailure(hls, t0);
      expect(failover.startIndex([hls], t0), 0);
    });

    test('memory expires after the window → HLS regains preference', () {
      failover.recordFailure(hls, t0);
      final later = t0.add(
          StreamFailover.failureMemoryWindow + const Duration(seconds: 1));
      expect(failover.isRecentlyFailed(hls, later), isFalse);
      expect(failover.startIndex([hls, direct], later), 0);
    });

    test('memory persists within the window', () {
      failover.recordFailure(hls, t0);
      final justBefore = t0.add(
          StreamFailover.failureMemoryWindow - const Duration(seconds: 1));
      expect(failover.isRecentlyFailed(hls, justBefore), isTrue);
      expect(failover.startIndex([hls, direct], justBefore), 1);
    });

    test('successful load clears the memory (recovery back to HLS)', () {
      failover.recordFailure(hls, t0);
      failover.recordSuccess(hls);
      expect(failover.isRecentlyFailed(hls, t0), isFalse);
      expect(failover.startIndex([hls, direct], t0), 0);
    });

    test('memory window outlives one watchdog detection cycle', () {
      // Worst-case silent-stall detection: frozen-grace (12s) + frozen
      // timeout (10s) + one watchdog poll (5s) ≈ 27s. The memory must
      // outlive it or a repeatedly-freezing HLS would be re-picked between
      // two consecutive watchdog recoveries.
      expect(StreamFailover.failureMemoryWindow,
          greaterThan(const Duration(seconds: 30)));
    });

    test('repeated freeze scenario: HLS stays skipped across reconnects', () {
      // t0: watchdog records the frozen HLS; reconnect starts at direct.
      failover.recordFailure(hls, t0);
      expect(failover.startIndex([hls, direct], t0), 1);
      // 30s later the direct stream blips and a stall reconnect fires —
      // HLS is still remembered, so we stay on direct instead of walking
      // back into the dead HLS.
      final t1 = t0.add(const Duration(seconds: 30));
      expect(failover.startIndex([hls, direct], t1), 1);
    });
  });
}
