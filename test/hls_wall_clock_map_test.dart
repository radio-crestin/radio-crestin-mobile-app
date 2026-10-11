import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/hls_timeline.dart';

import 'helpers/hls_fixtures.dart';

/// [HlsWallClockMap]: σ = min(Last-Modified − live edge) + 0.5 over the
/// last 4 polls, per skew epoch.
void main() {
  // rve-suceava: PDT 40 s ahead of the wall clock (true σ = -40).
  const trueSigma = -40.0;
  const firstEdge = 1791720000.0;

  /// The n-th poll: the edge grew by one 6 s segment per poll, and the
  /// playlist was modified [lag] seconds after that segment closed.
  HlsPlaylistSnapshot poll(int n, double lag, {bool withHeader = true}) {
    final edge = firstEdge + 6.0 * n;
    final wall = edge + trueSigma + lag;
    return windowSnapshot(
      seq: 1000 + n,
      w0: edge - 660,
      windowSeconds: 660,
      fetchedAt: wall + 1.5,
      // HTTP dates truncate to whole seconds.
      lastModified: withHeader ? wall.floorToDouble() : null,
    );
  }

  test(
      'skew = min(LM − edge) + 0.5 over the last 4 samples (late '
      'metadata-only rewrites ignored)', () {
    final map = HlsWallClockMap();
    // Measured Last-Modified lags behind the newest segment: +0/+1/+2/+4/+6.
    final lags = [0.0, 4.0, 1.0, 6.0, 2.0];
    for (var i = 0; i < lags.length; i++) {
      map.add(poll(i, lags[i]));
    }
    // The window holds lags {4, 1, 6, 2}: the minimum is the +1 rewrite.
    expect(map.skewSeconds, closeTo(trueSigma + 1 + 0.5, 1.0));
    expect(map.epoch, 0);
  });

  test('fallback to fetchedAt without Last-Modified (no +0.5)', () {
    final map = HlsWallClockMap()..add(poll(0, 0, withHeader: false));
    expect(map.skewSeconds, closeTo(trueSigma + 1.5, 1e-6));
  });

  test('window slides: a 5th sample evicts the oldest', () {
    final map = HlsWallClockMap();
    map.add(poll(0, 0)); // the minimum
    for (var i = 1; i <= 3; i++) {
      map.add(poll(i, 1.0));
    }
    final withMinimum = map.skewSeconds!;
    map.add(poll(4, 1.0));
    expect(map.skewSeconds!, greaterThan(withMinimum + 0.5));
  });

  test(
      'warm-up: samples +4/+2/+1 s above the truth (a_jump) give a '
      'monotonically falling estimate; a 4-sample window over the '
      '{+1,+4,+2} cycle never rises again', () {
    final map = HlsWallClockMap();
    final estimates = <double>[];
    final lags = [4.0, 2.0, 1.0, 4.0, 2.0, 1.0, 4.0, 2.0, 1.0, 4.0];
    for (var i = 0; i < lags.length; i++) {
      map.add(poll(i, lags[i]));
      estimates.add(map.skewSeconds!);
    }
    for (var i = 1; i < estimates.length; i++) {
      expect(estimates[i], lessThanOrEqualTo(estimates[i - 1]));
    }
    expect(estimates.skip(2).toSet(), hasLength(1));
    expect(map.epoch, 0, reason: 'rewrite jitter is not a skew step');
  });

  test('a repeated edge is not a sample (origin stall rewrites)', () {
    final map = HlsWallClockMap()..add(poll(0, 0));
    final first = map.skewSeconds;
    // Same newest segment, re-published later by metadata-only rewrites.
    for (var k = 1; k <= 5; k++) {
      final again = poll(0, 10.0 * k);
      map.add(again);
    }
    expect(map.skewSeconds, first);
    expect(map.latestSample, 0);
  });

  test(
      'step: two samples > 2 s above the minimum start a new epoch; the '
      'old epoch keeps its σ', () {
    final map = HlsWallClockMap();
    for (var i = 0; i < 3; i++) {
      expect(map.add(poll(i, 0)), isNull);
    }
    final before = map.skewSeconds!;
    // An upstream stall: segments published from now on carry +30 s.
    expect(map.add(poll(3, 30)), isNull);
    final rebaseFrom = map.add(poll(4, 30));
    expect(rebaseFrom, 3, reason: 'both stepped samples move');
    expect(map.epoch, 1);
    expect(map.sigmaFor(0), before);
    expect(map.skewSeconds, closeTo(before + 30, 1.0));
  });

  test('reset clears samples', () {
    final map = HlsWallClockMap()..add(poll(0, 0));
    map.reset();
    expect(map.skewSeconds, isNull);
    expect(map.epoch, 0);
    expect(map.latestSample, -1);
  });
}
