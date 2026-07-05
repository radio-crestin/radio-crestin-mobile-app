import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/appAudioHandler.dart';

/// Tests for the fast-start tuning policy: the live-vs-VOD buffer/stall config
/// selection that trades a snappier live start for the same conservative VOD
/// pre-roll.
void main() {
  group('FastStartConfig.androidBufferForPlayback', () {
    test('live starts sooner than VOD', () {
      expect(
        FastStartConfig.androidBufferForPlayback(isLive: true),
        const Duration(milliseconds: 1500),
      );
      expect(
        FastStartConfig.androidBufferForPlayback(isLive: false),
        const Duration(seconds: 3),
      );
      expect(
        FastStartConfig.liveAndroidBufferForPlayback,
        lessThan(FastStartConfig.vodAndroidBufferForPlayback),
      );
    });

    test('live pre-roll stays in the defensible 1.5-2s band', () {
      final live = FastStartConfig.liveAndroidBufferForPlayback;
      expect(live, greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
      expect(live, lessThanOrEqualTo(const Duration(seconds: 2)));
    });
  });

  group('FastStartConfig.darwinAutomaticallyWaits', () {
    test('live begins ASAP (does not wait), VOD keeps the safe default', () {
      expect(FastStartConfig.darwinAutomaticallyWaits(isLive: true), isFalse);
      expect(FastStartConfig.darwinAutomaticallyWaits(isLive: false), isTrue);
    });
  });
}
