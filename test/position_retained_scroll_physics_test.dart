import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/PositionRetainedScrollPhysics.dart';

class _Metrics extends FixedScrollMetrics {
  _Metrics({
    required double minScrollExtent,
    required double maxScrollExtent,
    required double pixels,
    required double viewportDimension,
  }) : super(
          minScrollExtent: minScrollExtent,
          maxScrollExtent: maxScrollExtent,
          pixels: pixels,
          viewportDimension: viewportDimension,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1.0,
        );
}

void main() {
  group('PositionRetainedScrollPhysics', () {
    test('applyTo propagates parent', () {
      const parent = ClampingScrollPhysics();
      final physics = const PositionRetainedScrollPhysics()
          .applyTo(parent);
      expect(physics, isA<PositionRetainedScrollPhysics>());
      expect(physics.parent, isA<ClampingScrollPhysics>());
    });

    test('applyTo carries shouldRetain forward', () {
      const physics = PositionRetainedScrollPhysics(shouldRetain: false);
      final wrapped = physics.applyTo(const ClampingScrollPhysics());
      expect(wrapped.shouldRetain, false);
    });

    test('default shouldRetain is true', () {
      const physics = PositionRetainedScrollPhysics();
      expect(physics.shouldRetain, true);
    });

    test('compensates for new content prepended above current scroll position',
        () {
      const physics = PositionRetainedScrollPhysics(
        parent: ClampingScrollPhysics(),
      );

      final oldPos = _Metrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 200, // user has scrolled down 200px
        viewportDimension: 800,
      );
      // 300 pixels of new content prepended → maxScrollExtent grows by 300
      final newPos = _Metrics(
        minScrollExtent: 0,
        maxScrollExtent: 1300,
        pixels: 200,
        viewportDimension: 800,
      );

      final adjusted = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0.0,
      );

      // Should add the diff (300) so the user stays where they were visually.
      expect(adjusted, 200 + 300);
    });

    test('does not adjust when at the very top', () {
      const physics = PositionRetainedScrollPhysics(
        parent: ClampingScrollPhysics(),
      );

      final oldPos = _Metrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 0, // pinned at top
        viewportDimension: 800,
      );
      final newPos = _Metrics(
        minScrollExtent: 0,
        maxScrollExtent: 1300,
        pixels: 0,
        viewportDimension: 800,
      );

      final adjusted = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0.0,
      );

      expect(adjusted, 0);
    });

    test('does not adjust when shouldRetain is false', () {
      const physics = PositionRetainedScrollPhysics(
        parent: ClampingScrollPhysics(),
        shouldRetain: false,
      );

      final oldPos = _Metrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 200,
        viewportDimension: 800,
      );
      final newPos = _Metrics(
        minScrollExtent: 0,
        maxScrollExtent: 1300,
        pixels: 200,
        viewportDimension: 800,
      );

      final adjusted = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0.0,
      );

      // Falls through to parent — same pixels, no compensation.
      expect(adjusted, 200);
    });
  });
}
