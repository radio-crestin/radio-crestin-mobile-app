import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/hls_timeline.dart';

import 'helpers/hls_fixtures.dart';

/// [HlsPlayheadClock]: settle-then-anchor on a native position report, then
/// media-time integration while playing && ready.
void main() {
  const t0 = 1791720000.0;
  const w0 = 1791719000.0; // first PDT of the window
  const seq0 = 5000;

  late HlsSegmentLedger ledger;
  late HlsPlayheadClock clock;

  HlsPlaylistSnapshot snap(double fetchedAt, {int slide = 0}) => windowSnapshot(
        seq: seq0 + slide,
        w0: w0 + 6.0 * slide,
        windowSeconds: 660,
        fetchedAt: fetchedAt,
      );

  void addToLedger(HlsPlaylistSnapshot s) =>
      ledger.merge(s, epoch: 0, sample: 0);

  void event(double when, {required bool advancing, required double position}) {
    clock.onPlayerEvent(
      advancing: advancing,
      updatePosition: Duration(microseconds: (position * 1e6).round()),
      updateTime: at(when),
      at: at(when),
    );
  }

  double pdt(double t) {
    final pos = clock.positionAt(at(t))!;
    return ledger[pos.seq]!.pdt + pos.offset;
  }

  setUp(() {
    ledger = HlsSegmentLedger();
    clock = HlsPlayheadClock(ledger);
  });

  test(
      'does not anchor on the Dart-synthesized play event (Android instant: '
      'updatePosition 0) — anchors on the native 647.986 after 1 s', () {
    final s = snap(t0);
    addToLedger(s);
    event(t0, advancing: true, position: 0); // synthesized at ready
    expect(clock.tryAnchor(at(t0 + 0.05), [s]), isFalse);
    event(t0 + 0.093, advancing: true, position: 647.986); // native
    expect(clock.tryAnchor(at(t0 + 0.5), [s]), isFalse, reason: 'settle');
    expect(clock.tryAnchor(at(t0 + 1.1), [s]), isTrue);
    expect(clock.quality, HlsAnchorQuality.exact);
    expect(pdt(t0 + 1.1), closeTo(w0 + 647.986 + (1.1 - 0.093), 1e-6));
  });

  test('seek mode: anchors to snapshot.locate(seekTarget)', () {
    final s = snap(t0);
    addToLedger(s);
    event(t0, advancing: false, position: 522.003); // seek, still paused
    event(t0 + 0.02, advancing: true, position: 522.003);
    expect(clock.tryAnchor(at(t0 + 1.2), [s]), isTrue);
    expect(pdt(t0 + 1.2), closeTo(w0 + 522.003 + 1.18, 1e-6));
  });

  test(
      'picks the snapshot nearest the native updateTime; none within 5 s → '
      'stays unanchored', () {
    final early = snap(t0 - 20);
    final near = snap(t0 + 2, slide: 1);
    addToLedger(early);
    addToLedger(near);
    event(t0, advancing: true, position: 600);
    expect(clock.tryAnchor(at(t0 + 1.5), [early, near]), isTrue);
    // Resolved in the window of `near` (one segment later).
    expect(pdt(t0 + 1.5), closeTo(w0 + 6 + 600 + 1.5, 1e-6));

    clock.beginLoad();
    event(t0, advancing: true, position: 600);
    expect(clock.tryAnchor(at(t0 + 1.5), [early]), isFalse);
    expect(clock.isAnchored, isFalse);
  });

  test(
      'advances 1:1 while playing && ready; freezes while buffering and '
      'paused', () {
    final s = snap(t0);
    addToLedger(s);
    event(t0, advancing: true, position: 500);
    clock.tryAnchor(at(t0 + 1), [s]);
    final p1 = pdt(t0 + 10);
    expect(p1, closeTo(w0 + 510, 1e-6));
    event(t0 + 10, advancing: false, position: 0); // buffering
    expect(pdt(t0 + 13), closeTo(p1, 1e-6));
    event(t0 + 13, advancing: true, position: 0);
    expect(pdt(t0 + 20), closeTo(p1 + 7, 1e-6));
    event(t0 + 20, advancing: false, position: 0); // paused
    expect(pdt(t0 + 65), closeTo(p1 + 7, 1e-6));
  });

  test(
      'never capped at player duration: 600 s of play advances 600 s (C1/C2 '
      'regression)', () {
    final s = snap(t0);
    addToLedger(s);
    for (var k = 1; k <= 100; k++) {
      addToLedger(snap(t0 + 6.0 * k, slide: k));
    }
    event(t0, advancing: true, position: 520);
    clock.tryAnchor(at(t0 + 1), [s]);
    final start = pdt(t0 + 1);
    clock.advanceTo(at(t0 + 601));
    expect(pdt(t0 + 601) - start, closeTo(600, 1e-6));
  });

  test(
      'ignores window-relative reports after anchoring (h4: pause synthetic '
      '641.852 then native 521.760 → no jump)', () {
    final s = snap(t0);
    addToLedger(s);
    event(t0, advancing: true, position: 522.003);
    clock.tryAnchor(at(t0 + 1), [s]);
    final atPause = pdt(t0 + 120);
    event(t0 + 120, advancing: false, position: 641.852);
    event(t0 + 120.001, advancing: false, position: 521.760);
    expect(clock.tryAnchor(at(t0 + 121), [s]), isFalse);
    expect(pdt(t0 + 165), closeTo(atPause, 0.01));
    event(t0 + 165, advancing: true, position: 521.760);
    expect(clock.tryAnchor(at(t0 + 167), [snap(t0 + 165, slide: 7)]), isFalse);
    expect(pdt(t0 + 175), closeTo(atPause + 10, 0.01));
  });

  test(
      'projects after 10 s without a matching snapshot, then upgrades to '
      'exact at the next native report', () {
    final late = snap(t0 + 11, slide: 2);
    addToLedger(late);
    event(t0, advancing: true, position: 600);
    expect(clock.tryAnchor(at(t0 + 9), [late]), isFalse);
    expect(clock.tryAnchor(at(t0 + 11.5), [late]), isTrue);
    expect(clock.quality, HlsAnchorQuality.projected);
    // The window slid 11 s (2 segments = 12 s really): off by < 1 segment.
    expect((pdt(t0 + 11.5) - (w0 + 600 + 11.5)).abs(), lessThan(6));

    // Pause, then resume: the new native report matches a fresh snapshot.
    event(t0 + 30, advancing: false, position: 0);
    final fresh = snap(t0 + 40, slide: 6);
    addToLedger(fresh);
    // Truly paused at w0 + 630: 594 s into the window that starts at w0 + 36.
    event(t0 + 40, advancing: true, position: 594);
    expect(clock.tryAnchor(at(t0 + 41.5), [late, fresh]), isTrue);
    expect(clock.quality, HlsAnchorQuality.exact);
    expect(pdt(t0 + 41.5), closeTo(w0 + 631.5, 1e-6));
  });

  test('beginLoad forgets the previous anchor', () {
    final s = snap(t0);
    addToLedger(s);
    event(t0, advancing: true, position: 500);
    clock.tryAnchor(at(t0 + 1), [s]);
    clock.beginLoad();
    expect(clock.isAnchored, isFalse);
    expect(clock.quality, isNull);
    expect(clock.positionAt(at(t0 + 2)), isNull);
  });
}
