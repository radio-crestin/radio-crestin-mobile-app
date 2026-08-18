import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/video_clock_stall_policy.dart';

/// Unit tests for [VideoClockStallPolicy] — the frozen-clock detector for
/// video mode (TV channels and video playlist items).
///
/// The buffering watchdog only fires when the engine admits it is stuck. This
/// one catches the stall it never admits to: "playing, not buffering", clock
/// standing still. The escalation mirrors the Apple TV app's
/// `StallRecoveryPolicy`, so a frozen HLS stream recovers the same way on both
/// platforms.
void main() {
  group('VideoClockStallPolicy.moved', () {
    test('a clock that advanced a second counts as moving', () {
      // Arrange + Act + Assert.
      expect(
        VideoClockStallPolicy.moved(
          previous: const Duration(seconds: 10),
          current: const Duration(seconds: 11),
        ),
        isTrue,
      );
    });

    test('an identical position counts as frozen', () {
      expect(
        VideoClockStallPolicy.moved(
          previous: const Duration(seconds: 10),
          current: const Duration(seconds: 10),
        ),
        isFalse,
      );
    });

    test('jitter below the threshold still counts as frozen', () {
      // 20ms of wobble is reporting noise, not playback.
      expect(
        VideoClockStallPolicy.moved(
          previous: const Duration(seconds: 10),
          current: const Duration(seconds: 10, milliseconds: 20),
        ),
        isFalse,
      );
    });

    test('a backwards jump (seek) counts as movement, not a stall', () {
      expect(
        VideoClockStallPolicy.moved(
          previous: const Duration(seconds: 30),
          current: const Duration(seconds: 10),
        ),
        isTrue,
      );
    });
  });

  group('VideoClockStallPolicy.isStalled', () {
    test('a short freeze is the engine rebuffering — left alone', () {
      expect(VideoClockStallPolicy.isStalled(const Duration(seconds: 4)),
          isFalse);
    });

    test('past the grace period it is a stall worth acting on', () {
      expect(
          VideoClockStallPolicy.isStalled(const Duration(seconds: 6)), isTrue);
      expect(
          VideoClockStallPolicy.isStalled(const Duration(seconds: 30)), isTrue);
    });

    test('the grace period is 6 seconds', () {
      expect(VideoClockStallPolicy.stallGrace, const Duration(seconds: 6));
    });
  });

  group('VideoClockStallPolicy.action — escalation', () {
    test('first stall → the cheap live-edge seek (connection kept)', () {
      expect(VideoClockStallPolicy.action(1), FrozenClockAction.seekToLiveEdge);
    });

    test('second stall → reload the media in place', () {
      expect(VideoClockStallPolicy.action(2), FrozenClockAction.reload);
    });

    test('third and later stalls → hand over to the audio fallback', () {
      expect(VideoClockStallPolicy.action(3), FrozenClockAction.giveUp);
      expect(VideoClockStallPolicy.action(9), FrozenClockAction.giveUp);
    });
  });
}
