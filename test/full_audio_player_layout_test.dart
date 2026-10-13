import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/components/FullAudioPlayer.dart';

/// Reproduction + regression suite for the highest-volume production crash:
///
///   ArgumentError: Invalid argument(s): 140.0
///   at _FullAudioPlayerState.build (FullAudioPlayer.dart:109)
///   → double.clamp
///
/// (PostHog issue 019d8f95…, 1100+ occurrences, iOS.)
///
/// Root cause: the full player computed
///   `(panelHeight - fixedBudget).clamp(140.0, 300.0).clamp(140.0, maxThumbWidth)`
/// where `maxThumbWidth = screenWidth - 64`. When iOS laid the panel out before
/// the window had real dimensions (`MediaQuery.size == Size.zero`, common during
/// launch / return-from-background), `maxThumbWidth` went negative, the upper
/// clamp limit dropped below the 140 lower limit, and `num.clamp` threw
/// `ArgumentError(lowerLimit)` — rendered as "Invalid argument(s): 140.0" — on
/// every rebuild.
///
/// Fix: the sizing math is now a pure `computePlayerLayout` that floors every
/// upper bound at 140 so `clamp` is always well-formed.
void main() {
  group('computePlayerLayout', () {
    test('degenerate Size.zero does not throw (regression: ArgumentError 140.0)',
        () {
      expect(
        () => computePlayerLayout(
            screenWidth: 0, screenHeight: 0, textScale: 1.0),
        returnsNormally,
      );

      final m =
          computePlayerLayout(screenWidth: 0, screenHeight: 0, textScale: 1.0);
      expect(m.thumbSize, 140.0);
      expect(m.infoWidth, 140.0);
      expect(m.playIconSize, 48.0);
      expect(m.skipIconSize, 34.0);
      expect(m.skipSpacing, 24.0);
    });

    test('very narrow width clamps thumb to the 140 floor without throwing',
        () {
      expect(
        () => computePlayerLayout(
            screenWidth: 100, screenHeight: 800, textScale: 1.0),
        returnsNormally,
      );
      final m = computePlayerLayout(
          screenWidth: 100, screenHeight: 800, textScale: 1.0);
      expect(m.thumbSize, 140.0);
    });

    test('typical phone caps the artwork at 70% of the width', () {
      // iPhone-ish: 390 x 844. The height left (759.6 - 390) is more than
      // 70% of the width, so the cap sizes the artwork; the song info still
      // spans the width between the side margins.
      final m = computePlayerLayout(
          screenWidth: 390, screenHeight: 844, textScale: 1.0);
      expect(m.thumbSize, closeTo(390 * 0.7, 0.001));
      expect(m.infoWidth, 390 - 48);
      expect(m.playIconSize, 62.0);
      expect(m.skipIconSize, 40.0);
      expect(m.skipSpacing, 36.0);
    });

    test('large phone keeps the same 70% share', () {
      final m = computePlayerLayout(
          screenWidth: 440, screenHeight: 956, textScale: 1.0);
      expect(m.thumbSize, closeTo(440 * 0.7, 0.001));
      expect(m.infoWidth, 440 - 48);
    });

    test('short phone shrinks the artwork and the controls', () {
      // iPhone SE: 375 x 667.
      final m = computePlayerLayout(
          screenWidth: 375, screenHeight: 667, textScale: 1.0);
      expect(m.thumbSize, closeTo(667 * 0.9 - 390, 0.001));
      expect(m.playIconSize, 48.0);
      expect(m.skipIconSize, 34.0);
    });

    test('short phone keeps the song info as wide as the side margins', () {
      final m = computePlayerLayout(
          screenWidth: 375, screenHeight: 667, textScale: 1.0);
      expect(m.thumbSize, lessThan(375 - 48));
      expect(m.infoWidth, 375 - 48);
    });

    test('tablet stops at the 480 artwork cap', () {
      final m = computePlayerLayout(
          screenWidth: 820, screenHeight: 1180, textScale: 1.0);
      expect(m.thumbSize, 480.0);
      expect(m.infoWidth, 480.0);
    });

    test('thumb never exceeds usable width (width-bound case)', () {
      final m = computePlayerLayout(
          screenWidth: 220, screenHeight: 900, textScale: 1.0);
      expect(m.thumbSize, lessThanOrEqualTo(220 - 48));
      expect(m.thumbSize, closeTo(220 * 0.7, 0.001));
    });

    test('extreme text scale is clamped and never yields a negative thumb', () {
      // scale clamps 3.0 → 2.0 ⇒ budget 480; panelHeight 540 ⇒ only 60 left
      // ⇒ thumb floored at 140.
      final m = computePlayerLayout(
          screenWidth: 390, screenHeight: 600, textScale: 3.0);
      expect(m.thumbSize, 140.0);
    });

    test('larger text leaves less room for the artwork', () {
      // 390 x 700: height-bound, so the text's extra height comes out of the
      // artwork.
      final normal = computePlayerLayout(
          screenWidth: 390, screenHeight: 700, textScale: 1.0);
      final large = computePlayerLayout(
          screenWidth: 390, screenHeight: 700, textScale: 1.3);
      expect(large.thumbSize, closeTo(normal.thumbSize - 90 * 0.3, 0.001));
    });

    test('control sizes interpolate monotonically with available space', () {
      final small = computePlayerLayout(
          screenWidth: 390, screenHeight: 700, textScale: 1.0);
      final big = computePlayerLayout(
          screenWidth: 390, screenHeight: 800, textScale: 1.0);

      expect(big.thumbSize, greaterThan(small.thumbSize));
      expect(big.playIconSize, greaterThan(small.playIconSize));
      expect(big.skipIconSize, greaterThan(small.skipIconSize));
      expect(big.skipSpacing, greaterThan(small.skipSpacing));

      // Bounds of the interpolation.
      expect(small.playIconSize, inInclusiveRange(48.0, 62.0));
      expect(small.skipIconSize, inInclusiveRange(34.0, 40.0));
      expect(small.skipSpacing, inInclusiveRange(24.0, 36.0));
    });
  });
}
