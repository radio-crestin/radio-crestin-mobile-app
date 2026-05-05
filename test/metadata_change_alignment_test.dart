import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/appAudioHandler.dart';

/// Tests for the EXT-X-RC-METADATA-CHANGED → refresh alignment policy.
///
/// Why alignment matters: SeekModeManager lets the user listen 2–4 min
/// behind live edge. The backend emits the marker on the live timeline,
/// so the mobile sees "song changed at epoch T" before the user actually
/// hears that song. Refreshing immediately would flash the new title
/// while the previous song is still audible.
void main() {
  group('MetadataChangeAlignment timing constants', () {
    test('nowTolerance is 2s (smaller than playlist poll cadence)', () {
      expect(MetadataChangeAlignment.nowTolerance,
          equals(const Duration(seconds: 2)));
    });

    test('maxScheduleLag is 5 minutes (1 min headroom over 4-min seek)', () {
      expect(MetadataChangeAlignment.maxScheduleLag,
          equals(const Duration(minutes: 5)));
    });
  });

  group('MetadataChangeAlignment.decide — no PDT anchor', () {
    test('refreshes immediately when first-segment epoch is unknown', () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: null,
        playerPosition: const Duration(seconds: 30),
        changedAtEpoch: 1700000000,
      );
      expect(d.action, MetadataAlignmentAction.refreshNow,
          reason: 'Without an anchor we cannot align — fall back to '
              'immediate refresh; next poll will retry with anchor');
      expect(d.delay, Duration.zero);
    });
  });

  group('MetadataChangeAlignment.decide — instant mode (no seek behind)', () {
    // Instant mode: playback_epoch ≈ wall_clock_epoch ≈ change_epoch.
    // Most users are here. Refresh should fire immediately.
    test('changed-at == playback-head → refreshes now', () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 60),
        changedAtEpoch: 1700000060, // == anchor + position
      );
      expect(d.action, MetadataAlignmentAction.refreshNow);
    });

    test('changed-at slightly behind playback (1s) → refreshes now', () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 60),
        changedAtEpoch: 1700000059, // playback_epoch - 1
      );
      expect(d.action, MetadataAlignmentAction.refreshNow);
    });

    test('changed-at long behind playback → refreshes now (already heard)',
        () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 60),
        changedAtEpoch: 1700000010, // 50s behind playback
      );
      expect(d.action, MetadataAlignmentAction.refreshNow);
    });

    test('changed-at within 2s tolerance ahead → refreshes now (clock skew)',
        () {
      // Network/clock skew can put the marker 1-2s ahead of our position.
      // Treating it as "now" avoids spurious deferral on every poll.
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 60),
        changedAtEpoch: 1700000062, // playback_epoch + 2 (boundary)
      );
      expect(d.action, MetadataAlignmentAction.refreshNow);
    });
  });

  group('MetadataChangeAlignment.decide — seeking behind live edge', () {
    test('30s behind live → schedules 30s refresh', () {
      // User in 2-min-behind mode, song change just hit live edge.
      // Audio still 30s behind the change → wait 30s before refreshing.
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 60),
        changedAtEpoch: 1700000090, // playback_epoch + 30
      );
      expect(d.action, MetadataAlignmentAction.scheduleAfterDelay);
      expect(d.delay, const Duration(seconds: 30));
    });

    test('2 min behind live → schedules 2 min refresh', () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 60),
        changedAtEpoch: 1700000180, // playback_epoch + 120
      );
      expect(d.action, MetadataAlignmentAction.scheduleAfterDelay);
      expect(d.delay, const Duration(seconds: 120));
    });

    test('exactly at maxScheduleLag (5 min) → schedules', () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 0),
        changedAtEpoch: 1700000300, // 300s ahead = exactly the cap
      );
      expect(d.action, MetadataAlignmentAction.scheduleAfterDelay);
      expect(d.delay, const Duration(seconds: 300));
    });
  });

  group('MetadataChangeAlignment.decide — sanity cap', () {
    test('lag > 5 min → skipUnsafe (stale anchor or future epoch)', () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 0),
        changedAtEpoch: 1700000301, // 5min + 1s ahead
      );
      expect(d.action, MetadataAlignmentAction.skipUnsafe,
          reason: 'Beyond max-seek + tolerance suggests a stale PDT '
              'anchor or backend bug; arming a 6-min timer that '
              'might fire during pause is worse than retrying on '
              'the next 10s poll');
    });

    test('lag = 1 hour → skipUnsafe', () {
      final d = MetadataChangeAlignment.decide(
        hlsFirstSegmentEpoch: 1700000000,
        playerPosition: const Duration(seconds: 0),
        changedAtEpoch: 1700003600,
      );
      expect(d.action, MetadataAlignmentAction.skipUnsafe);
    });
  });

  group('MetadataAlignmentAction taxonomy', () {
    test('all three actions are defined', () {
      expect(MetadataAlignmentAction.values, containsAll([
        MetadataAlignmentAction.refreshNow,
        MetadataAlignmentAction.scheduleAfterDelay,
        MetadataAlignmentAction.skipUnsafe,
      ]));
    });
  });
}
