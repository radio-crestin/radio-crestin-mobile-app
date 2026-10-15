import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/hls_timeline.dart';

import 'helpers/hls_fixtures.dart';

/// [HlsTimeline]: audible clock, origin progress and liveness inputs,
/// driven like `AppAudioHandler` drives it.
void main() {
  group('audible instant (C3: per-station PDT skew)', () {
    test(
        'audibleInstant = playhead + skew: constant latency over 330 s with '
        'skew +4531 s (biblia, 300 s offset)', () {
      final o = _Origin(sigma: 4531);
      final p = _Player(o, latency: 318)..start(o.t0);
      final latencies = <double>[];
      for (var t = o.t0 + 2; t < o.t0 + 330; t += 1) {
        p.pollEvery10s(t);
        p.timeline.tick(at(t));
        latencies.add(t - secondsOf(p.timeline.audibleInstant(at(t))!));
      }
      for (final l in latencies) {
        expect(l, closeTo(318, 1.0));
      }
    });

    test('skew −126 s (PDT ahead) and +337 s give the same latency', () {
      double latencyFor(double sigma) {
        final o = _Origin(sigma: sigma);
        final p = _Player(o, latency: 138)..start(o.t0);
        for (var t = o.t0 + 2; t < o.t0 + 60; t += 1) {
          p.pollEvery10s(t);
          p.timeline.tick(at(t));
        }
        final now = o.t0 + 60;
        return now - secondsOf(p.timeline.audibleInstant(at(now))!);
      }

      expect(latencyFor(-126), closeTo(latencyFor(337), 0.01));
      expect(latencyFor(-126), closeTo(138, 1.0));
    });

    test('frozen while paused or buffering', () {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 138)..start(o.t0);
      p.timeline.tick(at(o.t0 + 2));
      final atPause = p.timeline.audibleInstant(at(o.t0 + 20));
      p.event(o.t0 + 20, playing: false);
      expect(p.timeline.audibleInstant(at(o.t0 + 50)), atPause);
      p.event(o.t0 + 50, playing: true);
      expect(
          secondsOf(p.timeline.audibleInstant(at(o.t0 + 60))!) -
              secondsOf(atPause!),
          closeTo(10, 1e-3));
    });

    test(
        'a re-dated segment is read with its new PDT; the audible instant '
        'does not move (backend PDT re-anchor)', () {
      final o = _Origin(sigma: 300);
      final p = _Player(o, latency: 138)..start(o.t0);
      for (var t = o.t0 + 1; t <= o.t0 + 40; t += 1) {
        p.pollEvery10s(t);
        p.timeline.tick(at(t));
      }
      final pdtBefore = p.timeline.playheadPdt(at(o.t0 + 41))!;
      final audibleBefore = p.timeline.audibleInstant(at(o.t0 + 41))!;
      // B1 deploy: published segments re-dated onto the wall clock
      // (PDT + 300 s); the samples of the new domain show σ ≈ 0.
      final redated = _Origin(sigma: 300, pdtShift: 300);
      for (var t = o.t0 + 41; t <= o.t0 + 100; t += 1) {
        if ((t - o.t0) % 10 == 1) {
          p.timeline.onSnapshot(redated.snapshot(t), at(t));
        }
        p.timeline.tick(at(t));
        final elapsed = t - (o.t0 + 41);
        expect(p.timeline.playheadPdt(at(t)),
            closeTo(pdtBefore + 300 + elapsed, 1e-6));
        expect(secondsOf(p.timeline.audibleInstant(at(t))!),
            closeTo(secondsOf(audibleBefore) + elapsed, 1e-3));
      }
    });
  });

  group('anchoring', () {
    test(
        'tick anchors 1 s after advancing starts with no further event '
        '(ExoPlayer: native 647.986 arrives 0.1 s after ready, then nothing)',
        () {
      final o = _Origin(sigma: 0);
      final t = HlsTimeline();
      t.onSnapshot(o.snapshot(o.t0), at(o.t0));
      t.onPlayerEvent(
          playing: true,
          ready: true,
          updatePosition: Duration.zero,
          updateTime: at(o.t0),
          bufferedPosition: Duration.zero,
          now: at(o.t0));
      t.onPlayerEvent(
          playing: true,
          ready: true,
          updatePosition: const Duration(milliseconds: 647986),
          updateTime: at(o.t0 + 0.1),
          bufferedPosition: const Duration(seconds: 660),
          now: at(o.t0 + 0.1));
      expect(t.takeJustAnchored(), isFalse);
      t.tick(at(o.t0 + 1.1));
      expect(t.takeJustAnchored(), isTrue);
      expect(t.takeJustAnchored(), isFalse, reason: 'edge-triggered');
      expect(t.anchorQuality, HlsAnchorQuality.exact);
    });

    test(
        'first poll fails, the second arrives 10 s later, no further native '
        'events: projected anchor, audible instant within 12 s (R3)', () {
      final o = _Origin(sigma: -40);
      final t = HlsTimeline();
      final start = o.t0;
      t.onPollFailed(at(start));
      t.onPlayerEvent(
          playing: true,
          ready: true,
          updatePosition: const Duration(seconds: 540),
          updateTime: at(start + 0.1),
          bufferedPosition: const Duration(seconds: 600),
          now: at(start + 0.1));
      expect(t.needsAnchorSnapshot(at(start + 1)), isTrue);
      t.tick(at(start + 1.1));
      expect(t.isAnchored, isFalse);
      t.onSnapshot(o.snapshot(start + 10), at(start + 10));
      t.tick(at(start + 10.2));
      expect(t.audibleInstant(at(start + 10.2)), isNotNull);
      expect(t.anchorQuality, HlsAnchorQuality.projected);
      expect(t.needsAnchorSnapshot(at(start + 10.2)), isFalse,
          reason: 'a later fetch cannot match the old report');
    });

    test('a playlist without PDT is an approximate anchor', () {
      final t = HlsTimeline()..onPlaylistWithoutPdt(at(1000));
      expect(t.takeJustAnchored(), isTrue);
      expect(t.lacksProgramDateTime, isTrue);
      expect(t.anchorQuality, HlsAnchorQuality.approximate);
      expect(t.audibleInstant(at(1001)), isNull,
          reason: 'the owner approximates now - (offset + hold-back)');
      expect(
          HlsTimeline.approximateLatency(const Duration(minutes: 2),
              darwin: true, startVariant: false),
          const Duration(seconds: 138));
    });

    test(
        'a start variant is estimated at its offset plus one segment behind '
        'live, with no hold-back on any platform', () {
      // index-2m.m3u8 carries EXT-X-START:TIME-OFFSET=-120 in place of
      // index.m3u8's -18, counted from the end of the newest segment.
      for (final darwin in [true, false]) {
        expect(
            HlsTimeline.approximateLatency(const Duration(minutes: 2),
                darwin: darwin, startVariant: true),
            const Duration(seconds: 126));
        expect(
            HlsTimeline.approximateLatency(const Duration(minutes: 5),
                darwin: darwin, startVariant: true),
            const Duration(seconds: 306));
      }
      expect(
          HlsTimeline.approximateLatency(const Duration(minutes: 2),
              darwin: false, startVariant: false),
          const Duration(minutes: 2));
    });
  });

  group('origin progress', () {
    test(
        'originAdvancedAt follows the live edge, not MEDIA-SEQUENCE '
        '(restarted playlist grows with constant sequence)', () {
      final t = HlsTimeline();
      HlsPlaylistSnapshot restarted(int segments, double fetched) =>
          windowSnapshot(
              seq: 7000,
              w0: 1000,
              windowSeconds: 6.0 * segments,
              fetchedAt: fetched,
              uriPrefix: 'restart');
      t.onSnapshot(restarted(1, 100), at(100));
      t.onSnapshot(restarted(3, 110), at(110));
      expect(t.healthSample(at(111)).originAdvancedAt, at(110));
      t.onSnapshot(restarted(3, 120), at(120));
      expect(t.healthSample(at(121)).originAdvancedAt, at(110));
    });

    test('poll failure keeps the clock, does not advance or age the origin',
        () {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 138)..start(o.t0);
      p.timeline.tick(at(o.t0 + 2));
      final advancedAt = p.timeline.healthSample(at(o.t0 + 2)).originAdvancedAt;
      final pdt = p.timeline.playheadPdt(at(o.t0 + 12))!;
      p.timeline.onPollFailed(at(o.t0 + 10));
      p.timeline.onPollFailed(at(o.t0 + 20));
      final s = p.timeline.healthSample(at(o.t0 + 21));
      expect(s.originAdvancedAt, advancedAt);
      expect(s.originStaleFor, isNull, reason: 'failed polls prove nothing');
      expect(s.originUnreachableFor, isNotNull);
      expect(p.timeline.playheadPdt(at(o.t0 + 12)), closeTo(pdt, 1e-6));
    });

    test(
        'staleness needs two successful polls with an unchanged edge '
        'spanning 3 target durations', () {
      final o = _Origin(sigma: 0);
      final t = HlsTimeline();
      final frozen = o.snapshot(o.t0);
      t.onSnapshot(frozen, at(o.t0));
      t.onSnapshot(frozen, at(o.t0 + 10));
      expect(t.healthSample(at(o.t0 + 11)).originStaleFor, isNull);
      t.onSnapshot(frozen, at(o.t0 + 20));
      expect(t.healthSample(at(o.t0 + 21)).originStaleFor,
          const Duration(seconds: 20));
    });

    test('bufferedChangedAt updates only on change', () {
      final t = HlsTimeline();
      void buffered(double when, int seconds) => t.onPlayerEvent(
          playing: true,
          ready: true,
          updatePosition: Duration.zero,
          updateTime: at(when),
          bufferedPosition: Duration(seconds: seconds),
          now: at(when));
      buffered(10, 60);
      buffered(15, 60);
      expect(t.healthSample(at(16)).bufferedChangedAt, at(10));
      buffered(20, 66);
      expect(t.healthSample(at(21)).bufferedChangedAt, at(20));
    });

    test('a sequence restart below the recorded media flags a window reset',
        () {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 138)..start(o.t0);
      p.timeline.tick(at(o.t0 + 2));
      expect(p.timeline.healthSample(at(o.t0 + 3)).windowReset, isFalse);
      final restarted = windowSnapshot(
          seq: 3,
          w0: 5000,
          windowSeconds: 30,
          fetchedAt: o.t0 + 10,
          uriPrefix: 'boot2');
      p.timeline.onSnapshot(restarted, at(o.t0 + 10));
      final s = p.timeline.healthSample(at(o.t0 + 11));
      expect(s.windowReset, isTrue);
      expect(p.timeline.playheadPdt(at(o.t0 + 11)), isNotNull,
          reason: 'the anchored media is still measured');
    });
  });

  group('liveness inputs (reviewer R1)', () {
    LiveHlsStall rule(_Player p, double t) => ReconnectPolicy.liveHlsStall(
          playing: true,
          processingState: ProcessingState.ready,
          hasLiveHlsLoaded: true,
          isCasting: false,
          isVideoOrPlaylistMode: false,
          silentStallPossible: true,
          now: at(t),
          s: p.timeline.healthSample(at(t)),
        );

    test('near-edge (instant) geometry: a single failed poll never fires', () {
      final o = _Origin(sigma: -126);
      final p = _Player(o, latency: 18)..start(o.t0);
      for (var t = o.t0 + 1; t < o.t0 + 200; t += 1) {
        final pollIndex = ((t - o.t0) / 10).floor();
        if ((t - o.t0) % 10 == 0) {
          pollIndex == 7
              ? p.timeline.onPollFailed(at(t))
              : p.timeline.onSnapshot(o.snapshot(t), at(t));
        }
        p.tick(t);
        expect(rule(p, t), LiveHlsStall.none, reason: 't=${t - o.t0}');
      }
    });

    /// Runs [p] for [seconds], serving the playlist frozen at
    /// [stallFrom] for [stallFor] seconds, and returns when (relative) the
    /// rule first said `pastLiveEdge`.
    double? firstPastLiveEdge(_Origin o, _Player p,
        {required double stallFrom,
        required double stallFor,
        double seconds = 200}) {
      for (var t = o.t0 + 1; t < o.t0 + seconds; t += 1) {
        final rel = t - o.t0;
        if (rel % 10 == 0) {
          final stalled = rel >= stallFrom && rel < stallFrom + stallFor;
          final s = stalled ? o.snapshot(o.t0 + stallFrom) : o.snapshot(t);
          p.timeline.onSnapshot(s, at(t));
        }
        p.tick(t);
        if (rule(p, t) == LiveHlsStall.pastLiveEdge) return rel;
      }
      return null;
    }

    /// When an instant-mode player 18 s behind runs out of the media
    /// published at [frozenAt] (relative): AVPlayer goes silent there.
    double mediaEndHeardAt(_Origin o, double frozenAt) {
      final last = o.snapshot(o.t0 + frozenAt).segments.last;
      return last.pdt + last.duration + o.sigma + 18 - o.t0;
    }

    test(
        'instant-mode origin stall shorter than the 18 s hold-back: no fire '
        '(the player never runs out of media)', () {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 18)..start(o.t0);
      expect(firstPastLiveEdge(o, p, stallFrom: 60, stallFor: 15), isNull);
    });

    test(
        'instant-mode origin stall of 25 s: fires once the playhead ran one '
        'target duration past the published media (AVPlayer is silent from '
        'there on and does not resume, R1.6 run i5)', () {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 18)..start(o.t0);
      final firedAt = firstPastLiveEdge(o, p, stallFrom: 60, stallFor: 25);
      final silentFrom = mediaEndHeardAt(o, 60);
      expect(firedAt, isNotNull);
      expect(firedAt! - silentFrom, inInclusiveRange(_Origin.seg, 9));
    });

    test(
        'instant-mode origin frozen for good: fires one target duration '
        'after the player ran out of media (R1.6 run i1)', () {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 18)..start(o.t0);
      final firedAt = firstPastLiveEdge(o, p, stallFrom: 60, stallFor: 1e9);
      final silentFrom = mediaEndHeardAt(o, 60);
      expect(firedAt, isNotNull);
      expect(firedAt! - silentFrom, inInclusiveRange(_Origin.seg, 9));
    });

    test(
        '2-min geometry: a frozen playlist fires when the playhead reaches '
        'the last 5 target durations (normal threshold)', () {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 138)..start(o.t0);
      const frozenAt = 40.0;
      double? firedAt;
      for (var t = o.t0 + 1; t < o.t0 + 300 && firedAt == null; t += 1) {
        final rel = t - o.t0;
        if (rel % 10 == 0) {
          final s =
              rel >= frozenAt ? o.snapshot(o.t0 + frozenAt) : o.snapshot(t);
          p.timeline.onSnapshot(s, at(t));
        }
        p.tick(t);
        if (rule(p, t) == LiveHlsStall.pastLiveEdge) firedAt = rel;
      }
      // Frozen at 40 s with ~138 s of media ahead: fires ~30 s before the end.
      expect(firedAt, closeTo(frozenAt + 138 - 30, 7));
    });

    /// Every poll fails from [deadAt] on; the player stops loading too
    /// unless [playerStillLoads] (only our requests fail).
    double? deadOriginFire({required bool playerStillLoads}) {
      final o = _Origin(sigma: 0);
      final p = _Player(o, latency: 50)..start(o.t0);
      const deadAt = 30.0;
      for (var t = o.t0 + 1; t < o.t0 + 200; t += 1) {
        final rel = t - o.t0;
        if (rel % 10 == 0) {
          rel >= deadAt
              ? p.timeline.onPollFailed(at(t))
              : p.timeline.onSnapshot(o.snapshot(t), at(t));
        }
        p.loading = playerStillLoads || rel < deadAt;
        p.tick(t);
        if (rule(p, t) == LiveHlsStall.pastLiveEdge) return rel;
      }
      return null;
    }

    test(
        'dead origin (every poll fails, the player loads nothing): '
        'pastLiveEdge once both stopped for 45 s', () {
      final firedAt = deadOriginFire(playerStillLoads: false);
      expect(firedAt, isNotNull);
      // Last success at 20 s, last load at 24 s: both 45 s old from 69 s.
      expect(firedAt, 69);
    });

    test(
        'our polls fail while the player keeps loading (its own requests '
        'succeed): failed polls alone never fire', () {
      expect(deadOriginFire(playerStillLoads: true), isNull);
    });
  });

  group('song boundaries vs an upstream stall on today\'s backend (R2)', () {
    test(
        'a 2-min listener\'s boundary does not fire early before it crosses '
        'the stall', () {
      // Today's PDT runs on through an encoder stall while the wall clock
      // does not: segments published after a 30 s stall carry σ + 30.
      // At t0 the listener hears segment ~93 and the edge is ~115; segment
      // 125 is published 30 s late (t0 + 86 instead of t0 + 56).
      final o = _Origin(sigma: 0, stallAtSeq: 125, stallSeconds: 30);
      final p = _Player(o, latency: 138)..start(o.t0);
      final queue = SongBoundaryQueue();
      // A song change in segment 120 (before the stall), announced with the
      // wall clock of that audio.
      final boundaryPdt = o.pdtOf(120) + 2;
      final boundary = at(boundaryPdt + o.sigma);
      queue.add([SongBoundary(boundary)]);
      DateTime? firedAt;
      double? audibleBeforeCrossing;
      for (var t = o.t0 + 1; t < o.t0 + 400 && firedAt == null; t += 1) {
        p.pollEvery10s(t);
        p.timeline.tick(at(t));
        final audible = p.timeline.audibleInstant(at(t))!;
        final heardPdt = p.timeline.playheadPdt(at(t))!;
        if (heardPdt < o.pdtOf(125)) {
          final error = secondsOf(audible) - (heardPdt + o.sigma);
          audibleBeforeCrossing = error;
          expect(error.abs(), lessThan(1.0),
              reason: 'σ of pre-stall segments must not include the stall');
        }
        if (queue.takeReached(audible) != null) firedAt = at(t);
      }
      expect(audibleBeforeCrossing, isNotNull);
      expect(firedAt, isNotNull);
      // Fired when the listener heard the boundary (± the 2 s tolerance).
      final heardAt = p.wallWhenHeard(boundaryPdt);
      expect(secondsOf(firedAt!) - heardAt, inInclusiveRange(-3.0, 1.0));
    });

    test('segments published after the stall map with the stepped σ', () {
      final o = _Origin(sigma: 0, stallAtSeq: 125, stallSeconds: 30);
      final p = _Player(o, latency: 138)..start(o.t0);
      for (var t = o.t0 + 1; t < o.t0 + 400; t += 1) {
        p.pollEvery10s(t);
        p.timeline.tick(at(t));
      }
      final t = o.t0 + 400;
      final heardPdt = p.timeline.playheadPdt(at(t))!;
      expect(heardPdt, greaterThan(o.pdtOf(130)));
      expect(secondsOf(p.timeline.audibleInstant(at(t))!) - heardPdt,
          closeTo(o.sigma + 30, 1.0));
    });
  });
}

/// A synthetic live origin: 6 s segments, a 110-segment window, PDT offset
/// [sigma] from the wall clock (wall = PDT + σ), Last-Modified at the
/// close of the newest segment. Optionally the encoder stalls for
/// [stallSeconds] before segment [stallAtSeq]: PDT runs on (today's
/// backend) but every later segment is published that much later.
class _Origin {
  final double sigma;
  final int? stallAtSeq;
  final double stallSeconds;

  /// Re-dates every segment by this much (a backend PDT re-anchor).
  final double pdtShift;
  final double t0 = 1791720000;
  static const double seg = 6;
  static const int window = 110;

  _Origin({
    required this.sigma,
    this.stallAtSeq,
    this.stallSeconds = 0,
    this.pdtShift = 0,
  });

  /// Segment 0 is the first one published after [t0] - 700 s.
  double get _p0 => t0 - 700 - sigma;

  double pdtOf(int k) => _p0 + seg * k;

  /// Wall time when segment [k] was published (its end, plus any stall).
  double publishedAt(int k) {
    final stalled = stallAtSeq != null && k >= stallAtSeq! ? stallSeconds : 0;
    return pdtOf(k) + seg + sigma + stalled;
  }

  int newestAt(double wall) {
    var k = 0;
    while (publishedAt(k + 1) <= wall) {
      k++;
    }
    return k;
  }

  HlsPlaylistSnapshot snapshot(double wall) {
    final newest = newestAt(wall);
    final first = (newest - window + 1).clamp(0, newest);
    return HlsPlaylistSnapshot(
      segments: [
        for (var k = first; k <= newest; k++)
          HlsSegmentRef(
              seq: k, uri: 'o-$k.ts', pdt: pdtOf(k) + pdtShift, duration: seg),
      ],
      mediaSequence: first,
      targetDuration: seg,
      fetchedAt: at(wall),
      lastModified: at(publishedAt(newest).floorToDouble()),
    );
  }
}

/// A player [latency] seconds behind the wall clock, anchored at start.
class _Player {
  final _Origin origin;
  final double latency;
  final HlsTimeline timeline = HlsTimeline();
  late double _startWall;
  late double _startPdt;

  _Player(this.origin, {required this.latency});

  /// Loads at [t]: the concurrent poll, then the native report.
  void start(double t) {
    final s = origin.snapshot(t);
    timeline.onSnapshot(s, at(t));
    _startWall = t;
    // Heard PDT = wall − σ − latency (pre-stall media).
    _startPdt = t - origin.sigma - latency;
    final position = _startPdt - s.windowStartPdt;
    event(t, playing: true, position: position);
    timeline.tick(at(t + 1.1));
  }

  void event(double t,
          {required bool playing, double position = 0, int buffered = 0}) =>
      timeline.onPlayerEvent(
        playing: playing,
        ready: true,
        updatePosition: Duration(microseconds: (position * 1e6).round()),
        updateTime: at(t),
        bufferedPosition: Duration(seconds: buffered),
        now: at(t),
      );

  /// Whether the player still loads segments (its buffered position moves).
  bool loading = true;

  /// One second of playback: while [loading], the player loads a segment
  /// every 6 s (its buffered position changes); the owner re-checks the
  /// timeline.
  void tick(double t) {
    final elapsed = (t - _startWall).round();
    if (loading && elapsed % 6 == 0) {
      event(t, playing: true, buffered: elapsed);
    }
    timeline.tick(at(t));
  }

  void pollEvery10s(double t) {
    if ((t - _startWall) % 10 != 0) return;
    timeline.onSnapshot(origin.snapshot(t), at(t));
  }

  /// Wall time at which this (always playing) player hears media [pdt],
  /// walking the segments (PDT is continuous here).
  double wallWhenHeard(double pdt) => _startWall + (pdt - _startPdt);
}
