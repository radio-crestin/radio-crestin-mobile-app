import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/hls_timeline.dart';

/// Tests for the song-boundary → refresh alignment policy.
///
/// Why alignment matters: SeekModeManager lets the user listen 2–5 min
/// behind the live edge. The backend announces a song change on the live
/// timeline, so the app sees "song changed at B" before the listener hears
/// it. Refreshing immediately would flash the new title while the previous
/// song is still audible. The decision compares B with the audible instant
/// A (server wall clock of what the listener hears), never with
/// `player.position`.
void main() {
  final wallNow = DateTime.utc(2026, 10, 11, 12);
  DateTime ago(double seconds) =>
      wallNow.subtract(Duration(microseconds: (seconds * 1e6).round()));

  MetadataAlignmentDecision decide(DateTime? audible, DateTime boundary) =>
      MetadataChangeAlignment.decide(
          audibleNow: audible, boundary: boundary, wallNow: wallNow);

  group('MetadataChangeAlignment constants', () {
    test('nowTolerance is 2 s (smaller than the 10 s playlist poll)', () {
      expect(MetadataChangeAlignment.nowTolerance, const Duration(seconds: 2));
    });

    test('futureGuard is 30 s past the wall clock', () {
      expect(MetadataChangeAlignment.futureGuard, const Duration(seconds: 30));
    });
  });

  group('waitForClock', () {
    test('no audible instant yet (timeline anchoring) → wait, never live', () {
      expect(
          decide(null, ago(10)).action, MetadataAlignmentAction.waitForClock);
    });
  });

  group('refreshNow', () {
    test('boundary already heard', () {
      expect(decide(ago(100), ago(130)).action,
          MetadataAlignmentAction.refreshNow);
    });

    test('boundary exactly at the audible instant', () {
      expect(decide(ago(138), ago(138)).action,
          MetadataAlignmentAction.refreshNow);
    });

    test('boundary 2 s ahead (tolerance edge) still refreshes now', () {
      expect(decide(ago(140), ago(138)).action,
          MetadataAlignmentAction.refreshNow);
    });
  });

  group('scheduleAfterDelay', () {
    test('boundary just past the tolerance schedules', () {
      final d = decide(ago(140), ago(137.9));
      expect(d.action, MetadataAlignmentAction.scheduleAfterDelay);
      expect(d.delay, const Duration(milliseconds: 2100));
    });

    test('2-min listener: the delay is B − A', () {
      final d = decide(ago(138), ago(8));
      expect(d.action, MetadataAlignmentAction.scheduleAfterDelay);
      expect(d.delay, const Duration(seconds: 130));
    });

    test('no fixed cap: a 5-min listener still schedules (321 s ahead)', () {
      final d = decide(ago(321), wallNow);
      expect(d.action, MetadataAlignmentAction.scheduleAfterDelay);
      expect(d.delay, const Duration(seconds: 321));
    });

    test('a boundary up to 30 s past the wall clock still schedules', () {
      final d = decide(ago(18), wallNow.add(const Duration(seconds: 30)));
      expect(d.action, MetadataAlignmentAction.scheduleAfterDelay);
    });
  });

  group('aheadOfWallClock', () {
    test('a boundary more than 30 s past the wall clock waits', () {
      final d = decide(
          ago(18), wallNow.add(const Duration(seconds: 30, milliseconds: 1)));
      expect(d.action, MetadataAlignmentAction.aheadOfWallClock);
    });
  });
}
