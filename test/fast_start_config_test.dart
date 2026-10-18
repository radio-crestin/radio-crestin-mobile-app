import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/appAudioHandler.dart';

/// Tests for the fast-start tuning policy: the player's buffer/stall config,
/// tuned for a snappy live start.
void main() {
  group('FastStartConfig.liveAndroidBufferForPlayback', () {
    test('live pre-roll stays in the defensible 1.5-2s band', () {
      final live = FastStartConfig.liveAndroidBufferForPlayback;
      expect(live, greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
      expect(live, lessThanOrEqualTo(const Duration(seconds: 2)));
    });
  });

  group('FastStartConfig.liveDarwinAutomaticallyWaits', () {
    test('live waits to minimize stalling, like VOD', () {
      expect(
        FastStartConfig.liveDarwinAutomaticallyWaits,
        isTrue,
        reason: 'false left resumed live streams silent while shown playing',
      );
    });
  });
}
