import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/utils/api_utils.dart';
import 'package:radio_crestin/seek_mode_manager.dart';

/// Tests that verify the metadata timestamp synchronization logic matches
/// across mobile, web, and backend:
///
/// 1. getRoundedTimestamp with offset produces correct API timestamps
/// 2. SeekModeManager offsets are consistent with what the web app uses
/// 3. The offset calculation is compatible with the backend API expectations
void main() {
  group('Metadata timestamp sync', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    group('getRoundedTimestamp offset alignment', () {
      test('2-minute offset produces timestamp exactly 120s behind live', () {
        final live = getRoundedTimestamp();
        final offset = getRoundedTimestamp(offset: const Duration(minutes: 2));
        // Both are 10s-aligned, so the difference should be exactly 120
        expect(live - offset, equals(120));
      });

      test('5-minute offset produces timestamp exactly 300s behind live', () {
        final live = getRoundedTimestamp();
        final offset = getRoundedTimestamp(offset: const Duration(minutes: 5));
        expect(live - offset, equals(300));
      });

      test('zero offset equals live timestamp', () {
        final live = getRoundedTimestamp();
        final noOffset = getRoundedTimestamp(offset: Duration.zero);
        expect(live, equals(noOffset));
      });

      test('timestamp is a valid Unix epoch in seconds', () {
        final ts = getRoundedTimestamp();
        // Should be a reasonable Unix timestamp (after 2020, before 2040)
        expect(ts, greaterThan(1577836800)); // 2020-01-01
        expect(ts, lessThan(2208988800)); // 2040-01-01
      });

      test('timestamp is always a multiple of 10', () {
        for (int i = 0; i < 20; i++) {
          final ts = getRoundedTimestamp(offset: Duration(seconds: i * 7));
          expect(ts % 10, equals(0), reason: 'Timestamp $ts not aligned to 10s');
        }
      });
    });

    group('SeekMode offset values match web app constant', () {
      // The web app uses HLS_OFFSET_SECONDS = 120 (2 minutes).
      // The mobile app must have a matching mode.
      const webHlsOffsetSeconds = 120;

      test('twoMinutes mode matches web HLS_OFFSET_SECONDS', () {
        SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
        expect(
          SeekModeManager.currentOffset.inSeconds,
          equals(webHlsOffsetSeconds),
        );
      });

      test('fiveMinutes mode exceeds minimum offset', () {
        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
        expect(
          SeekModeManager.currentOffset.inSeconds,
          greaterThanOrEqualTo(webHlsOffsetSeconds),
        );
      });

      test('instant mode has zero offset', () {
        SeekModeManager.changeSeekMode(SeekMode.instant);
        expect(SeekModeManager.currentOffset, equals(Duration.zero));
      });
    });

    group('Offset timestamp API URL construction', () {
      test('addTimestampToUrl with 2-minute offset produces correct URL', () {
        final urlLive = addTimestampToUrl('https://api.radiocrestin.ro/api/v1/stations-metadata');
        final urlOffset = addTimestampToUrl(
          'https://api.radiocrestin.ro/api/v1/stations-metadata',
          offset: const Duration(minutes: 2),
        );

        final tsLive = int.parse(Uri.parse(urlLive).queryParameters['timestamp']!);
        final tsOffset = int.parse(Uri.parse(urlOffset).queryParameters['timestamp']!);

        // Offset timestamp should be exactly 120s behind live
        expect(tsLive - tsOffset, equals(120));
      });

      test('timestamp in URL is 10s-aligned', () {
        final url = addTimestampToUrl(
          'https://api.radiocrestin.ro/api/v1/stations-metadata',
          offset: const Duration(minutes: 2),
        );
        final ts = int.parse(Uri.parse(url).queryParameters['timestamp']!);
        expect(ts % 10, equals(0));
      });
    });

    group('Car/unstable connection forces 5-minute offset', () {
      setUp(() {
        SeekModeManager.changeCarConnected(false);
        SeekModeManager.changeUnstableConnection(false);
        SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
      });

      test('car connected overrides to 5 minutes regardless of seek mode', () {
        SeekModeManager.changeSeekMode(SeekMode.instant);
        SeekModeManager.changeCarConnected(true);
        expect(SeekModeManager.currentOffset, const Duration(minutes: 5));
      });

      test('unstable connection overrides to 5 minutes', () {
        SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
        SeekModeManager.changeUnstableConnection(true);
        expect(SeekModeManager.currentOffset, const Duration(minutes: 5));
      });

      test('effectiveSeekMode reflects override', () {
        SeekModeManager.changeSeekMode(SeekMode.instant);
        SeekModeManager.changeCarConnected(true);
        expect(SeekModeManager.effectiveSeekMode, SeekMode.fiveMinutes);
      });

      tearDown(() {
        SeekModeManager.changeCarConnected(false);
        SeekModeManager.changeUnstableConnection(false);
      });
    });

    group('Actual playback offset (duration - position)', () {
      // Simulates the getActualPlaybackOffset callback logic from AppAudioHandler.
      // The callback computes player.duration - player.position when playing HLS.

      Duration? simulateGetActualPlaybackOffset({
        required String? streamType,
        required bool playing,
        required Duration? duration,
        required Duration position,
      }) {
        if (streamType != 'HLS' || !playing) return null;
        if (duration == null || duration.inSeconds < 10) return null;
        final offset = duration - position;
        if (offset.inSeconds <= 0 || offset.inMinutes > 10) return null;
        return offset;
      }

      test('returns actual offset when playing HLS', () {
        // Player has 5 minutes of buffered content, position is at 3 minutes
        // → offset from live edge = 2 minutes
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: true,
          duration: const Duration(minutes: 5),
          position: const Duration(minutes: 3),
        );
        expect(offset, const Duration(minutes: 2));
      });

      test('returns null when not playing HLS', () {
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'direct_stream',
          playing: true,
          duration: const Duration(minutes: 5),
          position: const Duration(minutes: 3),
        );
        expect(offset, isNull);
      });

      test('returns null when player is not playing', () {
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: false,
          duration: const Duration(minutes: 5),
          position: const Duration(minutes: 3),
        );
        expect(offset, isNull);
      });

      test('returns null when duration is null', () {
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: true,
          duration: null,
          position: Duration.zero,
        );
        expect(offset, isNull);
      });

      test('returns null when duration is too short', () {
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: true,
          duration: const Duration(seconds: 5),
          position: Duration.zero,
        );
        expect(offset, isNull);
      });

      test('returns null when offset would be negative', () {
        // Position beyond duration (edge case)
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: true,
          duration: const Duration(minutes: 3),
          position: const Duration(minutes: 4),
        );
        expect(offset, isNull);
      });

      test('returns null when offset exceeds 10 minutes', () {
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: true,
          duration: const Duration(minutes: 15),
          position: const Duration(minutes: 2),
        );
        expect(offset, isNull);
      });

      test('produces valid timestamp when used with getRoundedTimestamp', () {
        final offset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: true,
          duration: const Duration(minutes: 5),
          position: const Duration(minutes: 3),
        );
        expect(offset, isNotNull);
        final live = getRoundedTimestamp();
        final offsetTs = getRoundedTimestamp(offset: offset!);
        // The offset is 2 minutes, so timestamp difference should be 120s
        expect(live - offsetTs, equals(120));
      });

      test('actual offset takes precedence over SeekModeManager', () {
        // This simulates the _pollMetadata logic:
        // final actualOffset = getActualPlaybackOffset?.call();
        // final offset = actualOffset ?? SeekModeManager.currentOffset;
        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);

        final actualOffset = simulateGetActualPlaybackOffset(
          streamType: 'HLS',
          playing: true,
          duration: const Duration(minutes: 5),
          position: const Duration(minutes: 3),
        );
        // Simulate the fallback logic
        final offset = actualOffset ?? SeekModeManager.currentOffset;
        // Should use the actual 2-minute offset, not the configured 5 minutes
        expect(offset.inSeconds, equals(120));
      });

      test('falls back to SeekModeManager when actual offset unavailable', () {
        SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
        SeekModeManager.changeCarConnected(false);
        SeekModeManager.changeUnstableConnection(false);

        final actualOffset = simulateGetActualPlaybackOffset(
          streamType: 'direct_stream',
          playing: true,
          duration: null,
          position: Duration.zero,
        );
        final offset = actualOffset ?? SeekModeManager.currentOffset;
        expect(offset.inSeconds, equals(120));
      });
    });

    group('EXT-X-PROGRAM-DATE-TIME playback timestamp', () {
      // Simulates the getHlsPlaybackTimestamp callback from AppAudioHandler.
      // firstSegmentEpoch is parsed from the playlist's first EXT-X-PROGRAM-DATE-TIME.
      // positionSec is player.position.inSeconds.

      int? simulateGetHlsPlaybackTimestamp({
        required String? streamType,
        required bool playing,
        required int? firstSegmentEpoch,
        required int positionSec,
      }) {
        if (streamType != 'HLS' || !playing) return null;
        if (firstSegmentEpoch == null) return null;
        final epoch = firstSegmentEpoch + positionSec;
        return (epoch ~/ 10) * 10;
      }

      test('computes correct timestamp from first segment epoch + position', () {
        // Playlist starts at epoch 1776247000, player is 180s into the buffer
        final ts = simulateGetHlsPlaybackTimestamp(
          streamType: 'HLS',
          playing: true,
          firstSegmentEpoch: 1776247000,
          positionSec: 180,
        );
        // 1776247000 + 180 = 1776247180 → aligned to 1776247180
        expect(ts, equals(1776247180));
      });

      test('aligns to 10-second boundary', () {
        final ts = simulateGetHlsPlaybackTimestamp(
          streamType: 'HLS',
          playing: true,
          firstSegmentEpoch: 1776247000,
          positionSec: 183,
        );
        // 1776247000 + 183 = 1776247183 → floor to 1776247180
        expect(ts, equals(1776247180));
        expect(ts! % 10, equals(0));
      });

      test('returns null when not playing HLS', () {
        final ts = simulateGetHlsPlaybackTimestamp(
          streamType: 'direct_stream',
          playing: true,
          firstSegmentEpoch: 1776247000,
          positionSec: 180,
        );
        expect(ts, isNull);
      });

      test('returns null when playlist not parsed yet', () {
        final ts = simulateGetHlsPlaybackTimestamp(
          streamType: 'HLS',
          playing: true,
          firstSegmentEpoch: null,
          positionSec: 180,
        );
        expect(ts, isNull);
      });

      test('takes precedence over offset-based timestamp', () {
        // Simulate the _pollMetadata priority chain:
        // 1. getHlsPlaybackTimestamp (from EXT-X-PROGRAM-DATE-TIME)
        // 2. getActualPlaybackOffset (from duration - position)
        // 3. SeekModeManager.currentOffset (configured fixed offset)
        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);

        final hlsTs = simulateGetHlsPlaybackTimestamp(
          streamType: 'HLS',
          playing: true,
          firstSegmentEpoch: 1776247000,
          positionSec: 180,
        );

        // The HLS timestamp is the direct epoch, not derived from wall clock
        expect(hlsTs, equals(1776247180));
        // This should NOT equal getRoundedTimestamp(offset: 5 minutes)
        final offsetTs = getRoundedTimestamp(offset: const Duration(minutes: 5));
        expect(hlsTs, isNot(equals(offsetTs)));
      });

      test('matches web app programDateTime extraction for same epoch', () {
        // Web app: Math.floor(programDateTimeMs / 10000) * 10
        // Mobile app: (firstSegmentEpoch + positionSec) ~/ 10 * 10
        // Both should produce the same result for the same epoch

        const firstSegEpoch = 1776247000; // epoch of first segment
        const positionSec = 180; // player position
        const expectedEpoch = firstSegEpoch + positionSec; // 1776247180

        // Mobile formula
        final mobileTs = simulateGetHlsPlaybackTimestamp(
          streamType: 'HLS',
          playing: true,
          firstSegmentEpoch: firstSegEpoch,
          positionSec: positionSec,
        );

        // Web formula (programDateTime is in milliseconds)
        final programDateTimeMs = expectedEpoch * 1000;
        final webTs = (programDateTimeMs ~/ 10000) * 10;

        expect(mobileTs, equals(webTs));
      });
    });

    group('EXT-X-PROGRAM-DATE-TIME playlist parsing', () {
      test('parses ISO 8601 date from EXT-X-PROGRAM-DATE-TIME tag', () {
        const line = '#EXT-X-PROGRAM-DATE-TIME:2026-04-15T12:00:00.000Z';
        final dateStr = line.substring('#EXT-X-PROGRAM-DATE-TIME:'.length).trim();
        final dt = DateTime.tryParse(dateStr);
        expect(dt, isNotNull);
        final epochSec = dt!.millisecondsSinceEpoch ~/ 1000;
        // 2026-04-15T12:00:00Z
        expect(epochSec, greaterThan(1776000000));
        expect(epochSec, lessThan(1777000000));
      });

      test('first EXT-X-PROGRAM-DATE-TIME in playlist gives window start', () {
        // 2026-04-15T12:00:00.000Z = epoch 1776254400
        const playlist = '''#EXTM3U
#EXT-X-VERSION:9
#EXT-X-TARGETDURATION:7
#EXT-X-MEDIA-SEQUENCE:296027376
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-PROGRAM-DATE-TIME:2026-04-15T12:00:00.000Z
#EXTINF:6.000000,
segments/1776254400.ts
#EXT-X-PROGRAM-DATE-TIME:2026-04-15T12:00:06.000Z
#EXTINF:6.000000,
segments/1776254406.ts''';

        int? firstEpoch;
        for (final line in playlist.split('\n')) {
          if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
            final dateStr = line.substring('#EXT-X-PROGRAM-DATE-TIME:'.length).trim();
            final dt = DateTime.tryParse(dateStr);
            if (dt != null) {
              firstEpoch = dt.millisecondsSinceEpoch ~/ 1000;
              break;
            }
          }
        }

        expect(firstEpoch, isNotNull);
        // The first segment's epoch from the filename
        expect(firstEpoch, equals(1776254400));
      });

      test('segment epoch matches EXT-X-PROGRAM-DATE-TIME exactly', () {
        // The playlist generator uses _epoch_to_pdt(seg_epoch) so they match exactly
        // 2026-04-15T12:00:00.000Z = epoch 1776254400
        const segEpoch = 1776254400;
        final pdt = DateTime.utc(2026, 4, 15, 12, 0, 0);
        final pdtEpoch = pdt.millisecondsSinceEpoch ~/ 1000;
        expect(segEpoch, equals(pdtEpoch));
      });
    });

    group('Cross-platform timestamp formula compatibility', () {
      // The web app computes: Math.floor((Date.now() / 1000 - offsetSeconds) / 10) * 10
      // The mobile app computes: (DateTime.now().subtract(offset).millisecondsSinceEpoch ~/ 1000 ~/ 10) * 10
      // These must produce identical results.

      test('mobile formula matches web formula for 0 offset', () {
        final now = DateTime.now();
        final epochSeconds = now.millisecondsSinceEpoch ~/ 1000;

        // Mobile formula
        final mobileResult = (epochSeconds ~/ 10) * 10;

        // Web formula (simulated)
        final webResult = ((now.millisecondsSinceEpoch / 1000 - 0) ~/ 10) * 10;

        expect(mobileResult, equals(webResult));
      });

      test('mobile formula matches web formula for 120s offset', () {
        final now = DateTime.now();
        const offsetSeconds = 120;

        // Mobile formula
        final mobileTime = now.subtract(const Duration(seconds: offsetSeconds));
        final mobileEpoch = mobileTime.millisecondsSinceEpoch ~/ 1000;
        final mobileResult = (mobileEpoch ~/ 10) * 10;

        // Web formula (simulated)
        final webResult =
            ((now.millisecondsSinceEpoch / 1000 - offsetSeconds) ~/ 10) * 10;

        expect(mobileResult, equals(webResult));
      });

      test('mobile formula matches web formula for 300s offset', () {
        final now = DateTime.now();
        const offsetSeconds = 300;

        final mobileTime = now.subtract(const Duration(seconds: offsetSeconds));
        final mobileEpoch = mobileTime.millisecondsSinceEpoch ~/ 1000;
        final mobileResult = (mobileEpoch ~/ 10) * 10;

        final webResult =
            ((now.millisecondsSinceEpoch / 1000 - offsetSeconds) ~/ 10) * 10;

        expect(mobileResult, equals(webResult));
      });
    });

    group('Offset metadata decision (HLS active + offset configured)', () {
      // Simulates the _pollMetadata decision logic:
      // Offset is used ONLY when HLS is active AND the configured offset is non-zero.
      // Non-HLS stations can't play behind live, so they always get live metadata.

      /// Returns true if dual-fetch (live + offset) should be used.
      bool shouldUseDualFetch({
        required bool hlsActive,
        required Duration configuredOffset,
        required int? hlsPlaybackTimestamp,
      }) {
        if (hlsPlaybackTimestamp != null) return true;
        return hlsActive && configuredOffset != Duration.zero;
      }

      test('dual-fetch when HLS active with 2-minute offset', () {
        expect(
          shouldUseDualFetch(
            hlsActive: true,
            configuredOffset: const Duration(minutes: 2),
            hlsPlaybackTimestamp: null,
          ),
          isTrue,
        );
      });

      test('dual-fetch when HLS active with 5-minute offset', () {
        expect(
          shouldUseDualFetch(
            hlsActive: true,
            configuredOffset: const Duration(minutes: 5),
            hlsPlaybackTimestamp: null,
          ),
          isTrue,
        );
      });

      test('no dual-fetch when HLS active with instant mode', () {
        expect(
          shouldUseDualFetch(
            hlsActive: true,
            configuredOffset: Duration.zero,
            hlsPlaybackTimestamp: null,
          ),
          isFalse,
        );
      });

      test('no dual-fetch when non-HLS even with 5-minute offset configured', () {
        expect(
          shouldUseDualFetch(
            hlsActive: false,
            configuredOffset: const Duration(minutes: 5),
            hlsPlaybackTimestamp: null,
          ),
          isFalse,
        );
      });

      test('no dual-fetch when non-HLS with instant mode', () {
        expect(
          shouldUseDualFetch(
            hlsActive: false,
            configuredOffset: Duration.zero,
            hlsPlaybackTimestamp: null,
          ),
          isFalse,
        );
      });

      test('dual-fetch when precise HLS timestamp available (overrides all)', () {
        // Even if configuredOffset is zero, a precise timestamp means HLS is active
        expect(
          shouldUseDualFetch(
            hlsActive: false, // doesn't matter when timestamp is available
            configuredOffset: Duration.zero,
            hlsPlaybackTimestamp: 1776254400,
          ),
          isTrue,
        );
      });

      test('non-HLS station shows live metadata even with offset configured', () {
        // When dual-fetch is NOT used, all stations get live metadata
        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
        SeekModeManager.changeCarConnected(false);
        SeekModeManager.changeUnstableConnection(false);

        final useDual = shouldUseDualFetch(
          hlsActive: false,
          configuredOffset: SeekModeManager.currentOffset,
          hlsPlaybackTimestamp: null,
        );
        // Non-HLS → no dual-fetch → all stations get live metadata
        expect(useDual, isFalse);
      });
    });

    group('Casting and background polling decisions', () {
      // Simulates the three places where pausePolling() is gated.
      // Each function returns true if polling should continue (NOT be paused).

      /// Simulates the disconnect timer check (appAudioHandler pause callback).
      bool shouldContinuePollingOnDisconnect({
        required bool carConnected,
        required bool casting,
      }) {
        // From appAudioHandler.dart disconnect timer:
        // if (!carConnected && !isCasting) pausePolling()
        return carConnected || casting;
      }

      /// Simulates the lifecycle check (HomePage.didChangeAppLifecycleState).
      bool shouldContinuePollingOnBackground({
        required bool carConnected,
        required bool casting,
        required bool onMobileData,
        required bool playerPlaying,
      }) {
        // From HomePage.dart:
        // if (!carConnected && !casting && (onMobileData || !playerPlaying)) pausePolling()
        if (carConnected || casting) return true;
        if (onMobileData || !playerPlaying) return false;
        return true;
      }

      test('continues polling when casting even if car not connected', () {
        expect(
          shouldContinuePollingOnDisconnect(carConnected: false, casting: true),
          isTrue,
        );
      });

      test('continues polling when car connected even if not casting', () {
        expect(
          shouldContinuePollingOnDisconnect(carConnected: true, casting: false),
          isTrue,
        );
      });

      test('pauses polling when neither car nor cast connected', () {
        expect(
          shouldContinuePollingOnDisconnect(carConnected: false, casting: false),
          isFalse,
        );
      });

      test('continues polling on background when casting (player.playing=false)', () {
        // During casting, player.playing is false because audio plays on Cast device
        expect(
          shouldContinuePollingOnBackground(
            carConnected: false,
            casting: true,
            onMobileData: false,
            playerPlaying: false, // not playing locally — playback is on Cast
          ),
          isTrue,
        );
      });

      test('continues polling on background when car connected', () {
        expect(
          shouldContinuePollingOnBackground(
            carConnected: true,
            casting: false,
            onMobileData: true,
            playerPlaying: false,
          ),
          isTrue,
        );
      });

      test('pauses polling on background on mobile data when not casting', () {
        expect(
          shouldContinuePollingOnBackground(
            carConnected: false,
            casting: false,
            onMobileData: true,
            playerPlaying: true,
          ),
          isFalse,
        );
      });

      test('continues polling on background on wifi when playing locally', () {
        expect(
          shouldContinuePollingOnBackground(
            carConnected: false,
            casting: false,
            onMobileData: false,
            playerPlaying: true,
          ),
          isTrue,
        );
      });

      test('pauses polling on background on wifi when not playing and not casting', () {
        expect(
          shouldContinuePollingOnBackground(
            carConnected: false,
            casting: false,
            onMobileData: false,
            playerPlaying: false,
          ),
          isFalse,
        );
      });
    });
  });
}
