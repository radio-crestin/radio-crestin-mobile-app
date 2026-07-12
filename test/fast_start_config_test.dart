import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/appAudioHandler.dart';

/// Tests for the fast-start tuning policy: minimal start thresholds for both
/// live and VOD (one shared player, one global value), with a greedy fill
/// window so VOD items buffer to the end after starting.
void main() {
  group('FastStartConfig.androidBufferForPlayback', () {
    test('both live and VOD use the minimal ~0.5-1s start threshold', () {
      final live = FastStartConfig.androidBufferForPlayback(isLive: true);
      final vod = FastStartConfig.androidBufferForPlayback(isLive: false);
      expect(live, const Duration(seconds: 1));
      expect(vod, const Duration(seconds: 1));
      for (final d in [live, vod]) {
        expect(d, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
        expect(d, lessThanOrEqualTo(const Duration(seconds: 1)));
      }
    });
  });

  group('FastStartConfig greedy fill windows', () {
    test('forward windows are large enough to fetch a whole typical track',
        () {
      // 10 minutes covers virtually all playlist VOD items, so once playing
      // the file downloads to the end and later seeks never stall.
      expect(FastStartConfig.androidMaxBuffer,
          greaterThanOrEqualTo(const Duration(minutes: 10)));
      expect(FastStartConfig.darwinPreferredForwardBuffer,
          greaterThanOrEqualTo(const Duration(minutes: 10)));
    });

    test('start threshold is far below the fill goal (start fast, fill deep)',
        () {
      expect(
        FastStartConfig.androidBufferForPlayback(isLive: false) * 10,
        lessThan(FastStartConfig.androidMaxBuffer),
      );
    });
  });

  group('FastStartConfig.darwinAutomaticallyWaits', () {
    test('live begins ASAP (does not wait), VOD keeps the safe default', () {
      expect(FastStartConfig.darwinAutomaticallyWaits(isLive: true), isFalse);
      expect(FastStartConfig.darwinAutomaticallyWaits(isLive: false), isTrue);
    });
  });
}
