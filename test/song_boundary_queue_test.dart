import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/hls_timeline.dart';

/// [SongBoundaryQueue]: every announced song change waits for the audible
/// instant (C6), with one refresh per reached boundary.
void main() {
  final base = DateTime.utc(2026, 10, 11, 12);
  DateTime t(double seconds) =>
      base.add(Duration(microseconds: (seconds * 1e6).round()));
  SongBoundary b(double seconds, {SongBoundaryHint? hint}) =>
      SongBoundary(t(seconds), hint: hint);

  late SongBoundaryQueue q;
  setUp(() => q = SongBoundaryQueue());

  test(
      'keeps several boundaries ahead (5-min offset with 30 s and 18 s '
      'items) and fires each in order (C6)', () {
    // biblia at 300 s: four boundaries ahead of the audible instant at once.
    q.add([b(120.5), b(150.6), b(324.6), b(342.5)]);
    final wallNow = t(400);
    var audible = t(100);
    final fired = <DateTime>[];
    while (true) {
      final delay = q.delayUntilNext(audible, wallNow);
      if (delay == null) break;
      audible = audible.add(delay);
      fired.add(q.takeReached(audible)!.at);
    }
    expect(fired, [t(120.5), t(150.6), t(324.6), t(342.5)]);
    expect(q.pending, isEmpty);
  });

  test('dedupes EPOCH vs END-DATE vs START-DATE within 2 s', () {
    q.add([b(100), b(100.389), b(101.2), b(160)]);
    expect(q.pending.map((x) => x.at), [t(100), t(160)]);
  });

  test('does not re-add known boundaries from later polls', () {
    q.add([b(100), b(160)]);
    q.takeReached(t(120)); // 100 consumed
    for (var i = 0; i < 12; i++) {
      q.add([b(100), b(160)]); // the 11-min window repeats them
    }
    expect(q.pending.map((x) => x.at), [t(160)]);
  });

  test('upgrades the hint of an already-known boundary (B14 two sightings)',
      () {
    const hint = SongBoundaryHint(title: 'Am fost lutul', songId: 123);
    q.add([b(200)]); // first sighting: EPOCH without X-* attributes
    q.add([b(200, hint: hint)]); // seconds later: with them
    expect(q.pending.single.hint, hint);
    // A later sighting without attributes never removes the hint.
    q.add([b(200)]);
    expect(q.pending.single.hint, hint);
    // The DATERANGE START-DATE of the same change merges with it too.
    q.add([b(200.4)]);
    expect(q.pending.single.hint, hint);
    expect(q.takeReached(t(199))!.hint, hint);
  });

  test('a hint arriving for a consumed boundary is kept for a reopen', () {
    const hint = SongBoundaryHint(title: 'X', songId: 1);
    q.add([b(100)]);
    q.takeReached(t(100));
    q.add([b(100, hint: hint)]);
    expect(q.pending, isEmpty);
    expect(q.reopenAfter(t(95)), isTrue);
    expect(q.pending.single.hint, hint);
  });

  test('dropHeard at anchor drops everything already heard', () {
    q.add([b(10), b(50), b(90), b(200)]);
    q.dropHeard(t(91));
    expect(q.pending.map((x) => x.at), [t(200)]);
  });

  test(
      'dropHeard keeps a boundary within the 2 s tolerance after the anchor '
      'instant, so the next takeReached refreshes for it (the anchor '
      'resolves the song before it)', () {
    q.add([b(50), b(91.5), b(200)]);
    q.dropHeard(t(90));
    expect(q.pending.map((x) => x.at), [t(91.5), t(200)]);
    expect(q.takeReached(t(90))!.at, t(91.5));
    expect(q.pending.map((x) => x.at), [t(200)]);
  });

  test(
      'takeReached returns only the newest of several reached (one refresh '
      'after a late timer)', () {
    q.add([b(10), b(50), b(90), b(200)]);
    expect(q.takeReached(t(100))!.at, t(90));
    expect(q.takeReached(t(100)), isNull);
  });

  test(
      'lag of 321 s (300 s offset + 18 s hold-back + 3 s) schedules, not '
      'skip (old maxScheduleLag bug)', () {
    final wallNow = t(1000);
    final audible = wallNow.subtract(const Duration(seconds: 321));
    q.add([SongBoundary(wallNow.subtract(const Duration(seconds: 2)))]);
    expect(q.delayUntilNext(audible, wallNow), const Duration(seconds: 319));
  });

  test(
      'boundary > wallNow + 30 s waits (aheadOfWallClock) and is '
      're-evaluated, never dropped (skipUnsafe never retried)', () {
    q.add([b(1100)]);
    expect(q.delayUntilNext(t(900), t(1000)), isNull);
    expect(q.takeReached(t(900)), isNull);
    expect(q.pending, hasLength(1));
    // The wall clock catches up: now schedulable.
    expect(q.delayUntilNext(t(900), t(1080)), const Duration(seconds: 200));
  });

  test('caps pending at 32 (the furthest ahead are forgotten)', () {
    q.add([for (var i = 0; i < 40; i++) b(100.0 + 10 * i)]);
    expect(q.pending, hasLength(SongBoundaryQueue.maxPending));
    expect(q.pending.last.at, t(100.0 + 10 * 31));
    // Room again: a later poll can bring a forgotten one back.
    q.takeReached(t(150));
    q.add([b(100.0 + 10 * 35)]);
    expect(q.pending.last.at, t(100.0 + 10 * 35));
  });

  group('reopenAfter', () {
    test(
        'A steps back 3 s → a boundary fired within that span is pending '
        'again and fires next', () {
      q.add([b(100)]);
      expect(q.takeReached(t(99)), isNotNull); // A = 99 (+2 s tolerance)
      expect(q.reopenAfter(t(96)), isTrue);
      expect(q.pending.map((x) => x.at), [t(100)]);
      expect(q.delayUntilNext(t(96), t(500)), const Duration(seconds: 4));
    });

    test('no step → nothing reopened', () {
      q.add([b(100)]);
      q.takeReached(t(99));
      expect(q.reopenAfter(t(99)), isFalse);
      expect(q.reopenAfter(t(105)), isFalse);
      expect(q.pending, isEmpty);
    });

    test('a boundary consumed at B ≤ A + 2 s stays consumed', () {
      q.add([b(100)]);
      q.takeReached(t(98.5));
      expect(q.reopenAfter(t(98.2)), isFalse);
    });

    test('skew warm-up flip-flop (new → old → new) ends on the right song', () {
      // Truth: the listener hears B at audible 100. During warm-up A runs
      // 3.5 s late: the anchor (truth 97.5) sees A = 101 and drops B — the
      // anchored refresh shows the new title early.
      q.add([b(100)]);
      q.dropHeard(t(101));
      expect(q.pending, isEmpty);
      // σ settles at the next poll: A = 97.5 (correct). B reopens and the
      // re-sync refresh shows the old title again.
      expect(q.reopenAfter(t(97.5)), isTrue);
      expect(q.delayUntilNext(t(97.5), t(500)),
          const Duration(milliseconds: 2500));
      // The timer fires when the listener really hears B.
      expect(q.takeReached(t(100))!.at, t(100));
      // Final state: consumed, nothing pending, no further reopen.
      expect(q.pending, isEmpty);
      expect(q.reopenAfter(t(100)), isFalse);
    });
  });

  test('clear forgets pending, consumed and known boundaries', () {
    q.add([b(100), b(200)]);
    q.takeReached(t(150));
    q.clear();
    expect(q.pending, isEmpty);
    expect(q.reopenAfter(t(0)), isFalse);
    q.add([b(100)]);
    expect(q.pending, hasLength(1));
  });
}
