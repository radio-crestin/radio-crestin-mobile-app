import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/panel_drag_region.dart';
import 'package:radio_crestin/widgets/song_actions_button.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

void main() {
  const minHeight = 100.0;
  const maxHeight = 500.0;
  const travel = maxHeight - minHeight;

  final song = find.text('Artist - Song');

  /// Pumps an open panel with the song, in a [PanelDragRegion], under its
  /// top edge, as the full player lays it out.
  Future<PanelController> pumpPanel(WidgetTester tester) async {
    final controller = PanelController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidingUpPanel(
            controller: controller,
            minHeight: minHeight,
            maxHeight: maxHeight,
            defaultPanelState: PanelState.OPEN,
            panelBuilder: () => Column(
              children: [
                const SizedBox(height: 120),
                PanelDragRegion(
                  controller: controller,
                  travel: travel,
                  child: SongActionsButton(
                    onSearch: () {},
                    onCopy: () {},
                    child: const SizedBox(
                      height: 60,
                      child: Text('Artist - Song'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('a long press on the song holds the panel still as the '
      'finger moves on', (tester) async {
    final controller = await pumpPanel(tester);

    final gesture = await tester.startGesture(tester.getCenter(song));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text(SongActionsButton.copyLabel), findsOneWidget);

    for (var step = 0; step < 6; step++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.panelPosition, 1.0);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.panelPosition, 1.0);
  }, variant: const TargetPlatformVariant(
    {TargetPlatform.iOS, TargetPlatform.android},
  ));

  testWidgets('a drag down from the song slides the panel with the finger',
      (tester) async {
    final controller = await pumpPanel(tester);

    final gesture = await tester.startGesture(tester.getCenter(song));
    // Past the touch slop: the drag wins, and the panel follows from here.
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    final dragStart = controller.panelPosition;
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();

    expect(controller.panelPosition, closeTo(dragStart - 100 / travel, 1e-6));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a slow drag past halfway closes the panel', (tester) async {
    final controller = await pumpPanel(tester);

    await tester.timedDrag(
      song,
      const Offset(0, 300),
      const Duration(seconds: 2),
    );
    await tester.pumpAndSettle();

    expect(controller.panelPosition, 0.0);
  });

  testWidgets('a slow short drag springs back open', (tester) async {
    final controller = await pumpPanel(tester);

    await tester.timedDrag(
      song,
      const Offset(0, 120),
      const Duration(seconds: 2),
    );
    await tester.pumpAndSettle();

    expect(controller.panelPosition, 1.0);
  });

  testWidgets('a quick flick down closes the panel from near the top',
      (tester) async {
    final controller = await pumpPanel(tester);

    await tester.fling(song, const Offset(0, 80), 1500);
    await tester.pumpAndSettle();

    expect(controller.panelPosition, 0.0);
  });
}
