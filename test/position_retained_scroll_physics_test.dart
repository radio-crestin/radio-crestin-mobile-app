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

  group('SliverAnchor', () {
    // Home in miniature: a section above that comes and goes (Favorite),
    // the anchored sort row, then a long station list.
    late SliverAnchor anchor;
    late ScrollController controller;
    late StateSetter setAbove;
    late double above;
    late int stations;

    setUp(() {
      anchor = SliverAnchor();
      controller = ScrollController();
      above = 0;
      stations = 64;
    });
    tearDown(() => controller.dispose());

    Future<void> pumpList(WidgetTester tester) {
      return tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(builder: (context, setState) {
            setAbove = setState;
            return CustomScrollView(
              controller: controller,
              physics: PositionRetainedScrollPhysics(anchor: anchor)
                  .applyTo(const ClampingScrollPhysics()),
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: above)),
                SliverToBoxAdapter(
                  key: anchor.key,
                  child: const SizedBox(height: 60, child: Text('row')),
                ),
                SliverFixedExtentList.builder(
                  itemExtent: 105,
                  itemCount: stations,
                  itemBuilder: (_, i) => Text('station $i'),
                ),
              ],
            );
          }),
        ),
      );
    }

    Future<void> changeAbove(
      WidgetTester tester,
      double height, {
      int? stationCount,
    }) async {
      setAbove(() {
        above = height;
        stations = stationCount ?? stations;
      });
      await tester.pump();
    }

    double rowTop(WidgetTester tester) =>
        tester.getTopLeft(find.text('row')).dy;

    testWidgets('keeps the row in place when content comes back above it',
        (tester) async {
      await pumpList(tester);
      expect(rowTop(tester), 0);

      anchor.hold();
      await changeAbove(tester, 290);

      expect(rowTop(tester), 0);
      expect(controller.offset, 290);
    });

    testWidgets('keeps the row in place when content above it goes',
        (tester) async {
      above = 290;
      await pumpList(tester);
      controller.jumpTo(290);
      await tester.pump();

      // A category is chosen: Favorite hides and the list gets shorter.
      anchor.hold();
      await changeAbove(tester, 0, stationCount: 38);

      expect(rowTop(tester), 0);
      expect(controller.offset, 0);
    });

    testWidgets('lands on the row when the list was scrolled past it',
        (tester) async {
      await pumpList(tester);
      controller.jumpTo(1000);
      await tester.pump();

      anchor.hold();
      await changeAbove(tester, 290);

      expect(controller.offset, 290);
      expect(rowTop(tester), 0);
    });

    testWidgets('only holds for the next frame', (tester) async {
      await pumpList(tester);

      anchor.hold();
      await tester.pump();
      await changeAbove(tester, 290);

      // At the top, the physics leave the position alone as before.
      expect(controller.offset, 0);
      expect(rowTop(tester), 290);
    });
  });
}
