import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/video_mode_decision.dart';

void main() {
  group('VideoModeDecision.shouldUseVideoMode', () {
    bool decide({
      required bool video,
      required bool fg,
      required bool car,
      required bool cast,
    }) =>
        VideoModeDecision.shouldUseVideoMode(
          isVideoContent: video,
          isForeground: fg,
          isCarConnected: car,
          isCasting: cast,
        );

    test('video + foreground + no car + no cast → video mode', () {
      expect(decide(video: true, fg: true, car: false, cast: false), isTrue);
    });

    test('audio content is never video mode (any conditions)', () {
      for (final fg in [true, false]) {
        for (final car in [true, false]) {
          for (final cast in [true, false]) {
            expect(
              decide(video: false, fg: fg, car: car, cast: cast),
              isFalse,
              reason: 'audio fg=$fg car=$car cast=$cast',
            );
          }
        }
      }
    });

    test('backgrounded video content → audio-only (no video mode)', () {
      expect(decide(video: true, fg: false, car: false, cast: false), isFalse);
    });

    test('car connected forces audio-only even for foreground video', () {
      expect(decide(video: true, fg: true, car: true, cast: false), isFalse);
    });

    test('casting forces audio-only even for foreground video', () {
      expect(decide(video: true, fg: true, car: false, cast: true), isFalse);
    });

    test('car + cast both connected → audio-only', () {
      expect(decide(video: true, fg: true, car: true, cast: true), isFalse);
    });

    test('full matrix: video mode iff video && fg && !car && !cast', () {
      for (final video in [true, false]) {
        for (final fg in [true, false]) {
          for (final car in [true, false]) {
            for (final cast in [true, false]) {
              final expected = video && fg && !car && !cast;
              expect(
                decide(video: video, fg: fg, car: car, cast: cast),
                expected,
                reason: 'video=$video fg=$fg car=$car cast=$cast',
              );
            }
          }
        }
      }
    });
  });
}
