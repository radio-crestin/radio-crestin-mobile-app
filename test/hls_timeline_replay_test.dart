import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/hls_timeline.dart';

import 'helpers/hls_fixtures.dart';

/// Production timeline + liveness rules replayed against recorded reality.
///
/// Fixtures (`test/fixtures/hls_traces/*.jsonl`) were converted from the
/// client-timeline probe runs: a real just_audio 0.10.5 player (macOS
/// AVPlayer = the iOS code; Android emulator ExoPlayer) playing production
/// stations, the app-side playlist polls, and the player's own playhead PDT
/// once per second as ground truth (`AVPlayerItem.currentDate`, ExoPlayer
/// `windowStartTimeMs + position`). Fault runs went through a proxy that
/// froze the playlist (stale), served 503 (dead), 404'd new segments
/// (seg404) or truncated the window (jump) 90 s after the start. The `i*`
/// runs (review R1.6) repeat the AVPlayer faults in instant geometry
/// (offset 0), plus transient stalls: the playlist frozen for 25 s or 40 s,
/// then live again.
void main() {
  group('playhead clock vs player ground truth', () {
    for (final label in [
      'h1_popular_120',
      'h2_emanuel_0',
      'h3_biblia_300',
      'h4_popular_120_pause',
      'a1_popular_120',
    ]) {
      test('$label: playhead error < 0.5 s (healthy, pause, instant, 300 s)',
          () {
        final r = _Replay(_Trace.load(label)).run();
        expect(r.errors.length, greaterThan(200),
            reason: 'the clock must anchor within seconds of the load');
        expect(r.maxAbsError, lessThan(0.5));
      });
    }

    for (final label in [
      'f1_stale_suceava',
      'f2_seg404_suceava',
      'f3_jump_suceava',
      'f4_dead_suceava',
      'a_stale_suceava_120',
      'a_jump_suceava_120',
      ..._Trace.instantFaultLabels,
    ]) {
      test('$label: playhead error < 0.5 s before the fault', () {
        final trace = _Trace.load(label);
        final r = _Replay(trace).run(scoreUntil: trace.faultAt);
        expect(r.errors.length, greaterThan(60));
        expect(r.maxAbsError, lessThan(0.5));
      });
    }

    test('anchors exactly within ~2 s of the load on every run', () {
      for (final label in _Trace.allLabels) {
        final trace = _Trace.load(label);
        final r = _Replay(trace).run();
        expect(r.anchoredAfter, isNotNull, reason: label);
        expect(r.anchoredAfter!, lessThan(2.5), reason: label);
        expect(r.anchorQuality, HlsAnchorQuality.exact, reason: label);
      }
    });

    test('audible latency is offset + hold-back (C3: per-station PDT skew)',
        () {
      // biblia: PDT 4531 s behind the wall clock; emanuel: 126 s ahead.
      final biblia = _Replay(_Trace.load('h3_biblia_300')).run();
      final emanuel = _Replay(_Trace.load('h2_emanuel_0')).run();
      expect(biblia.latencyAtEnd!, closeTo(300 + 18, 3));
      expect(emanuel.latencyAtEnd!, closeTo(18, 3));
    });
  });

  group('liveness rules on recorded runs', () {
    for (final label in [
      'h1_popular_120',
      'h2_emanuel_0',
      'h3_biblia_300',
      'h4_popular_120_pause',
      'a1_popular_120',
    ]) {
      test('$label: healthy run never fires (even with the Darwin gate off)',
          () {
        final r = _Replay(_Trace.load(label), silentStallPossible: true).run();
        expect(r.fires, isEmpty);
      });
    }

    test(
        'ExoPlayer fault runs never fire on Android (a_stale goes idle by '
        'itself, a_jump keeps playing)', () {
      for (final label in ['a_stale_suceava_120', 'a_jump_suceava_120']) {
        final r = _Replay(_Trace.load(label)).run();
        expect(r.fires, isEmpty, reason: label);
      }
    });

    test('f1 frozen playlist → pastLiveEdge within 2 s of the real death', () {
      final trace = _Trace.load('f1_stale_suceava');
      final r = _Replay(trace).run();
      final death = trace.groundTruthDeath()!;
      expect(r.fires.first.stall, LiveHlsStall.pastLiveEdge);
      expect((r.fires.first.at - death).abs(), lessThanOrEqualTo(2.0));
    });

    test('f4 playlist 503 → pastLiveEdge within 2 s of the real death', () {
      final trace = _Trace.load('f4_dead_suceava');
      final r = _Replay(trace).run();
      final death = trace.groundTruthDeath()!;
      expect(r.fires.first.stall, LiveHlsStall.pastLiveEdge);
      expect((r.fires.first.at - death).abs(), lessThanOrEqualTo(2.0));
    });

    test('f2 new segments 404 → starving before the buffer runs dry', () {
      final trace = _Trace.load('f2_seg404_suceava');
      final r = _Replay(trace).run();
      final death = trace.groundTruthDeath()!;
      expect(r.fires.first.stall, LiveHlsStall.starving);
      expect(r.fires.first.at, lessThan(death));
      expect(r.fires.first.at, greaterThan(trace.faultAt!));
    });

    test('f3 window reset → evicted within one poll', () {
      final trace = _Trace.load('f3_jump_suceava');
      final r = _Replay(trace).run();
      expect(r.fires.first.stall, LiveHlsStall.evicted);
      final firstPollAfterFault = trace.records
          .firstWhere((x) => x.kind == 'snap' && x.w > trace.faultAt!)
          .w;
      expect(r.fires.first.at, lessThanOrEqualTo(firstPollAfterFault + 1.0));
    });
  });

  group('instant geometry faults (review R1.6)', () {
    // One target duration: the margin past the end of the published media.
    const td = HlsTimeline.defaultTargetDuration;

    test(
        'AVPlayer plays to the end of the published media, then stays '
        'silent for good, even when the playlist grows again', () {
      for (final label in [
        'i1_stale_suceava_0',
        'i5_stall25_suceava_0',
        'i6_stall40_suceava_0',
      ]) {
        final trace = _Trace.load(label);
        final death = trace.groundTruthDeath()!;
        expect(death - trace.faultAt!, closeTo(18, 1.5),
            reason: '$label: the 3-TD hold-back runs out');
        expect(trace.playsAgainAfter(death), isFalse, reason: label);
      }
    });

    test(
        'frozen playlist and 25 s / 40 s stalls → pastLiveEdge one target '
        'duration after the real death, never before it', () {
      for (final label in [
        'i1_stale_suceava_0',
        'i5_stall25_suceava_0',
        'i6_stall40_suceava_0',
      ]) {
        final trace = _Trace.load(label);
        final r = _Replay(trace).run();
        final death = trace.groundTruthDeath()!;
        expect(r.fires.first.stall, LiveHlsStall.pastLiveEdge, reason: label);
        expect(r.fires.first.at, greaterThan(death), reason: label);
        expect(r.fires.first.at - death, lessThanOrEqualTo(td + 2),
            reason: label);
      }
    });

    test(
        'playlist 503 → pastLiveEdge once polls failed for 45 s and the '
        'player loaded nothing for 45 s', () {
      final trace = _Trace.load('i4_dead_suceava_0');
      final r = _Replay(trace).run();
      final death = trace.groundTruthDeath()!;
      expect(r.fires.first.stall, LiveHlsStall.pastLiveEdge);
      expect(r.fires.first.at, greaterThan(death));
      expect(r.fires.first.at - trace.faultAt!,
          lessThanOrEqualTo(ReconnectPolicy.originUnreachableAfter.inSeconds));
    });

    test('new segments 404 → starving after the real death', () {
      final trace = _Trace.load('i2_seg404_suceava_0');
      final r = _Replay(trace).run();
      expect(r.fires.first.stall, LiveHlsStall.starving);
      expect(r.fires.first.at, greaterThan(trace.groundTruthDeath()!));
    });
  });

  group('network outage (tunnel) while the buffer plays', () {
    // h1 (AVPlayer, 2-min offset) with the network cut: the player loads
    // nothing and the app's polls fail, then the player resumes loading
    // 1 s (requests that hung, then went through) or 5 s (AVPlayer's own
    // retry backoff) after the network is back. Measured: AVPlayer plays
    // its buffer through and never stalls. A fire would reload that
    // healthy stream right as the network returns: an audible gap.
    for (final resumeLag in [1.0, 5.0]) {
      test('20-90 s outages never fire (player resumes ${resumeLag}s after)',
          () {
        for (final secs in [20.0, 30.0, 40.0, 45.0, 50.0, 60.0, 90.0]) {
          // Every 10 s poll phase.
          for (var from = 60.0; from < 70.0; from += 1) {
            final trace = _Trace.load('h1_popular_120')
                .withOutage(from: from, secs: secs, resumeLag: resumeLag);
            final r = _Replay(trace).run();
            expect(r.fires, isEmpty, reason: '${secs}s outage at +${from}s');
          }
        }
      });
    }
  });

  group('lost polls never fire (reviewer R1)', () {
    test('h2 instant mode with any single poll removed: no fire', () {
      final trace = _Trace.load('h2_emanuel_0');
      final polls = trace.pollIndexes;
      for (var i = 2; i < polls.length; i++) {
        final r = _Replay(trace, failedPolls: {polls[i]}).run();
        expect(r.fires, isEmpty, reason: 'poll #$i removed');
      }
    });

    test('h2 instant mode with two consecutive polls removed: no fire', () {
      final trace = _Trace.load('h2_emanuel_0');
      final polls = trace.pollIndexes;
      for (var i = 2; i + 1 < polls.length; i++) {
        final r = _Replay(trace, failedPolls: {polls[i], polls[i + 1]}).run();
        expect(r.fires, isEmpty, reason: 'polls #$i,#${i + 1} removed');
      }
    });

    test('h1 2-min mode with two consecutive polls removed: no fire', () {
      final trace = _Trace.load('h1_popular_120');
      final polls = trace.pollIndexes;
      for (var i = 2; i + 1 < polls.length; i++) {
        final r = _Replay(trace, failedPolls: {polls[i], polls[i + 1]}).run();
        expect(r.fires, isEmpty, reason: 'polls #$i,#${i + 1} removed');
      }
    });

    test(
        'first poll fails and no retry succeeds: projected anchor within '
        '12 s, off by less than one segment (R3)', () {
      final trace = _Trace.load('h1_popular_120');
      final r = _Replay(trace, failedPolls: {trace.pollIndexes.first}).run();
      expect(r.anchorQuality, HlsAnchorQuality.projected);
      expect(r.anchoredAfter, lessThanOrEqualTo(12));
      expect(r.maxAbsError, lessThan(HlsTimeline.defaultTargetDuration));
      expect(r.fires, isEmpty);
    });
  });

  group('post-B1 playlists (backend sim, forward PDT jump + DISCONTINUITY)',
      () {
    test('the clock reads each segment\'s own PDT across a +10.19 s jump', () {
      final b1 = _B1Fixture.load();
      final timeline = HlsTimeline();
      // Anchor 3 s into the first window, playing from its fetch.
      final first = b1.snapshots.first;
      final t0 = secondsOf(first.fetchedAt);
      timeline.onSnapshot(first, first.fetchedAt);
      timeline.onPlayerEvent(
        playing: true,
        ready: true,
        updatePosition: const Duration(seconds: 3),
        updateTime: at(t0),
        bufferedPosition: const Duration(seconds: 6),
        now: at(t0),
      );
      timeline.tick(at(t0 + 1.5));
      expect(timeline.isExactlyAnchored, isTrue);
      final startPos = first.locate(3);

      var crossed = false;
      var nextSnapshot = 1;
      var maxPdtError = 0.0;
      var maxAudibleStep = 0.0;
      double? lastAudibleError;
      for (var t = t0 + 2; t < b1.endAt; t += 1) {
        var fed = false;
        while (nextSnapshot < b1.snapshots.length &&
            secondsOf(b1.snapshots[nextSnapshot].fetchedAt) <= t) {
          final s = b1.snapshots[nextSnapshot++];
          timeline.onSnapshot(s, s.fetchedAt);
          fed = true;
        }
        final truth = b1.truthPdt(startPos, t - t0)!;
        maxPdtError =
            math.max(maxPdtError, (timeline.playheadPdt(at(t))! - truth).abs());
        // Post-B1 PDT is the wall clock, so the audible error is A - PDT.
        final audibleError = secondsOf(timeline.audibleInstant(at(t))!) - truth;
        if (lastAudibleError != null && !fed) {
          maxAudibleStep =
              math.max(maxAudibleStep, (audibleError - lastAudibleError).abs());
        }
        lastAudibleError = audibleError;
        // Integrating in the PDT domain would stay at anchor PDT + elapsed.
        if (truth - (b1.pdtOf(startPos)! + (t - t0)) > 10) crossed = true;
      }
      expect(crossed, isTrue, reason: 'the run must cross the PDT jump');
      expect(maxPdtError, lessThan(0.2));
      expect(maxAudibleStep, lessThan(0.2),
          reason: 'the audible instant must not step when the playhead '
              'crosses the jump');
    });

    test('the parser reads the post-B1 tags (DISCONTINUITY, START -18)', () {
      final s = _B1Fixture.load().snapshots.last;
      expect(s.mediaSequence, 1791723225);
      final jumpAt = s.segments.indexWhere((x) => x.seq == 1791723261);
      final before = s.segments[jumpAt - 1];
      expect(s.segments[jumpAt].pdt - before.end, closeTo(10.19, 0.01));
      expect(s.metadataChangedAt,
          DateTime.fromMillisecondsSinceEpoch(1791723553000, isUtc: true));
      // Contiguous sequence across the DISCONTINUITY.
      for (var i = 1; i < s.segments.length; i++) {
        expect(s.segments[i].seq, s.segments[i - 1].seq + 1);
      }
    });
  });
}

/// One recorded record of a trace.
class _Rec {
  final String kind;
  final double w;
  final Map<String, dynamic> data;

  _Rec(this.kind, this.w, this.data);
}

class _Trace {
  static const allLabels = [
    'h1_popular_120',
    'h2_emanuel_0',
    'h3_biblia_300',
    'h4_popular_120_pause',
    'f1_stale_suceava',
    'f2_seg404_suceava',
    'f3_jump_suceava',
    'f4_dead_suceava',
    'a1_popular_120',
    'a_stale_suceava_120',
    'a_jump_suceava_120',
    ...instantFaultLabels,
  ];

  /// Review R1.6: AVPlayer fault runs at offset 0.
  static const instantFaultLabels = [
    'i1_stale_suceava_0',
    'i2_seg404_suceava_0',
    'i4_dead_suceava_0',
    'i5_stall25_suceava_0',
    'i6_stall40_suceava_0',
  ];

  final String label;
  final bool isDarwin;
  final double loaded;
  final double end;
  final double? faultAt;
  final List<_Rec> records;

  _Trace(this.label, this.isDarwin, this.loaded, this.end, this.faultAt,
      this.records);

  factory _Trace.load(String label) {
    final lines = const LineSplitter()
        .convert(readFixture('hls_traces/$label.jsonl'))
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    final meta = lines.first;
    return _Trace(
      label,
      meta['platform'] == 'darwin',
      (meta['loaded'] as num).toDouble(),
      (meta['end'] as num).toDouble(),
      (meta['faultAt'] as num?)?.toDouble(),
      [
        for (final l in lines.skip(1))
          _Rec(l['t'] as String, (l['w'] as num).toDouble(), l),
      ],
    );
  }

  /// Indexes (into [records]) of the app's playlist polls, in order.
  List<int> get pollIndexes => [
        for (var i = 0; i < records.length; i++)
          if (records[i].kind == 'snap' || records[i].kind == 'fail') i,
      ];

  /// First ground-truth sample where the player stopped playing after it
  /// had played (the silent death in the AVPlayer fault runs).
  double? groundTruthDeath() {
    var played = false;
    for (final r in records.where((r) => r.kind == 'gt')) {
      if (r.data['play'] == 1) {
        played = true;
      } else if (played) {
        return r.w;
      }
    }
    return null;
  }

  /// Whether the player plays again after [death] (it resumed by itself).
  bool playsAgainAfter(double death) =>
      records.any((r) => r.kind == 'gt' && r.w > death && r.data['play'] == 1);

  /// This run with the network cut for [secs] from [from] s after the
  /// load: the player's buffered position stops growing until [resumeLag]
  /// after the network is back, and the app's polls in between fail. The
  /// player keeps playing (its buffer outlasts the outage).
  _Trace withOutage({
    required double from,
    required double secs,
    required double resumeLag,
  }) {
    final start = loaded + from;
    final back = start + secs;
    Object? frozen;
    final out = <_Rec>[];
    for (final r in records) {
      if (r.kind == 'ev' && r.w < start) {
        frozen = r.data['b'];
        out.add(r);
      } else if (r.kind == 'ev' && r.w < back + resumeLag) {
        out.add(_Rec('ev', r.w, {...r.data, 'b': frozen}));
      } else if (r.kind == 'snap' && r.w >= start && r.w < back) {
        out.add(_Rec('fail', r.w, r.data));
      } else {
        out.add(r);
      }
    }
    return _Trace(label, isDarwin, loaded, end, start, out);
  }
}

class _Fire {
  final double at;
  final LiveHlsStall stall;

  _Fire(this.at, this.stall);
}

class _ReplayResult {
  final List<double> errors;
  final List<_Fire> fires;
  final double? anchoredAfter;
  final HlsAnchorQuality? anchorQuality;
  final double? latencyAtEnd;

  _ReplayResult(this.errors, this.fires, this.anchoredAfter, this.anchorQuality,
      this.latencyAtEnd);

  double get maxAbsError => errors.map((e) => e.abs()).fold(0.0, math.max);
}

/// Drives the production [HlsTimeline] and [ReconnectPolicy.liveHlsStall]
/// like `AppAudioHandler` does: player events, playlist polls, and a 1 s
/// evaluation clock (the handler re-checks the anchor on timers and the
/// liveness rules every 5 s; 1 s resolution measures the rules themselves).
class _Replay {
  final _Trace trace;
  final bool silentStallPossible;
  final Set<int> failedPolls;

  _Replay(this.trace, {bool? silentStallPossible, this.failedPolls = const {}})
      : silentStallPossible = silentStallPossible ?? trace.isDarwin;

  _ReplayResult run({double? scoreUntil}) {
    final timeline = HlsTimeline();
    final errors = <double>[];
    final fires = <_Fire>[];
    double? anchoredAfter;
    var state = ProcessingState.idle;
    var playing = false;
    var next = 0;
    final records = trace.records;
    for (var t = trace.loaded; t <= trace.end; t += 1) {
      while (next < records.length && records[next].w <= t) {
        final r = records[next];
        final failed = failedPolls.contains(next);
        next++;
        switch (r.kind) {
          case 'ev':
            state = _state(r.data['s'] as String);
            playing = r.data['p'] as bool;
            timeline.onPlayerEvent(
              playing: playing,
              ready: state == ProcessingState.ready,
              updatePosition: _duration(r.data['u']),
              updateTime: at((r.data['ut'] as num).toDouble()),
              bufferedPosition: _duration(r.data['b']),
              now: at(r.w),
            );
          case 'snap':
            failed
                ? timeline.onPollFailed(at(r.w))
                : timeline.onSnapshot(_snapshot(r), at(r.w));
          case 'fail':
            timeline.onPollFailed(at(r.w));
        }
      }
      timeline.tick(at(t));
      if (timeline.takeJustAnchored()) anchoredAfter ??= t - trace.loaded;
      _score(timeline, t, scoreUntil, errors);
      final stall = ReconnectPolicy.liveHlsStall(
        playing: playing,
        processingState: state,
        hasLiveHlsLoaded: true,
        isCasting: false,
        isVideoOrPlaylistMode: false,
        silentStallPossible: silentStallPossible,
        now: at(t),
        s: timeline.healthSample(at(t)),
      );
      if (stall != LiveHlsStall.none &&
          (fires.isEmpty || t - fires.last.at > 30)) {
        fires.add(_Fire(t, stall));
      }
    }
    final audible = timeline.audibleInstant(at(trace.end));
    return _ReplayResult(
      errors,
      fires,
      anchoredAfter,
      timeline.anchorQuality,
      audible == null ? null : trace.end - secondsOf(audible),
    );
  }

  void _score(
      HlsTimeline timeline, double t, double? until, List<double> errors) {
    if (until != null && t >= until) return;
    final pdt = timeline.playheadPdt(at(t));
    if (pdt == null) return;
    _Rec? best;
    for (final r in trace.records) {
      if (r.kind != 'gt') continue;
      if (best == null || (r.w - t).abs() < (best.w - t).abs()) best = r;
    }
    if (best == null || (best.w - t).abs() > 1.5) return;
    if (best.data['play'] != 1) return;
    final truth = (best.data['cd'] as num).toDouble() + (t - best.w);
    errors.add(pdt - truth);
  }

  static HlsPlaylistSnapshot _snapshot(_Rec r) => windowSnapshot(
        seq: r.data['seq'] as int,
        w0: (r.data['w0'] as num).toDouble(),
        windowSeconds: (r.data['wl'] as num).toDouble(),
        fetchedAt: r.w,
        lastModified: (r.data['lm'] as num?)?.toDouble(),
      );

  static Duration _duration(Object? seconds) =>
      Duration(microseconds: ((seconds as num) * 1e6).round());

  static ProcessingState _state(String name) => ProcessingState.values
      .firstWhere((s) => s.name == name, orElse: () => ProcessingState.idle);
}

/// Index playlists captured from the backend's post-B1 rewriter simulation
/// (`backend/sim/run4`): wall-clock PDT, a +10.19 s forward jump after a
/// stall, and an ffmpeg restart behind a DISCONTINUITY.
class _B1Fixture {
  /// Spaced so the next playlist always arrives before the playhead (35-57 s
  /// behind the edge) runs out of known segments, like the 10 s poll.
  static const files = [
    '00009-1791723255.752-index.m3u8',
    '00021-1791723285.982-index.m3u8',
    '00039-1791723347.477-index.m3u8',
    '00045-1791723365.880-index.m3u8',
    '00051-1791723422.066-index.m3u8',
    '00061-1791723446.301-index.m3u8',
    '00073-1791723475.461-index.m3u8',
    '00081-1791723500.619-index.m3u8',
    '00089-1791723518.739-index.m3u8',
    '00099-1791723541.777-index.m3u8',
    '00105-1791723558.045-index.m3u8',
  ];

  final List<HlsPlaylistSnapshot> snapshots;

  _B1Fixture(this.snapshots);

  factory _B1Fixture.load() => _B1Fixture([
        for (final f in files)
          HlsPlaylistSnapshot.parse(readFixture('hls_b1/$f'),
              fetchedAt: at(double.parse(f.split('-')[1])))!,
      ]);

  double get endAt => secondsOf(snapshots.last.fetchedAt);

  /// PDT of [pos] per the final playlist (every segment since the boot).
  double? pdtOf(HlsMediaPosition pos) {
    for (final s in snapshots.last.segments) {
      if (s.seq == pos.seq) return s.pdt + pos.offset;
    }
    return null;
  }

  /// PDT of the media [elapsed] seconds after [start], walking the final
  /// playlist's segments; null beyond its end.
  double? truthPdt(HlsMediaPosition start, double elapsed) {
    final segs = snapshots.last.segments;
    var i = segs.indexWhere((s) => s.seq == start.seq);
    var offset = start.offset + elapsed;
    while (i < segs.length && offset >= segs[i].duration) {
      offset -= segs[i].duration;
      i++;
    }
    return i < segs.length ? segs[i].pdt + offset : null;
  }
}
