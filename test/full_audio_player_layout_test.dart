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
/// Fix: the sizing math is now a pure `computePlayerLayout` that floors the
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
      expect(m.playIconSize, 48.0);
      expect(m.skipIconSize, 36.0);
      expect(m.skipSpacing, 20.0);
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

    test('typical phone produces an in-range square thumbnail', () {
      // iPhone-ish: 390 x 844. Height drives the size (326px of width is ample).
      final m = computePlayerLayout(
          screenWidth: 390, screenHeight: 844, textScale: 1.0);
      expect(m.thumbSize, inInclusiveRange(140.0, 300.0));
      expect(m.thumbSize, 300.0);
      expect(m.playIconSize, greaterThan(48.0));
    });

    test('thumb never exceeds usable width (width-bound case)', () {
      // 220px wide → maxThumbWidth = 156, so a tall panel is capped by width.
      final m = computePlayerLayout(
          screenWidth: 220, screenHeight: 900, textScale: 1.0);
      expect(m.thumbSize, lessThanOrEqualTo(220 - 64));
      expect(m.thumbSize, 156.0);
    });

    test('extreme text scale is clamped and never yields a negative thumb', () {
      // scale clamps 3.0 → 1.5 ⇒ fixedBudget 630; panelHeight 540 ⇒ negative
      // budget ⇒ thumb floored at 140.
      final m = computePlayerLayout(
          screenWidth: 390, screenHeight: 600, textScale: 3.0);
      expect(m.thumbSize, 140.0);
    });

    test('icon sizes interpolate monotonically with thumb size', () {
      final small = computePlayerLayout(
          screenWidth: 220, screenHeight: 900, textScale: 1.0);
      final big = computePlayerLayout(
          screenWidth: 400, screenHeight: 1000, textScale: 1.0);

      expect(big.thumbSize, greaterThan(small.thumbSize));
      expect(big.playIconSize, greaterThanOrEqualTo(small.playIconSize));
      expect(big.skipIconSize, greaterThanOrEqualTo(small.skipIconSize));
      expect(big.skipSpacing, greaterThanOrEqualTo(small.skipSpacing));

      // Bounds of the interpolation.
      expect(big.playIconSize, inInclusiveRange(48.0, 62.0));
      expect(big.skipIconSize, inInclusiveRange(36.0, 46.0));
      expect(big.skipSpacing, inInclusiveRange(20.0, 32.0));
    });
  });
}
