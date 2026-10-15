import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

void main() {
  const collapsedKey = Key('collapsed');

  // The panel travels 400px between closed (0.0) and open (1.0).
  Future<PanelController> pump(WidgetTester tester) async {
    final controller = PanelController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidingUpPanel(
            controller: controller,
            minHeight: 100,
            maxHeight: 500,
            collapsed: const SizedBox.expand(key: collapsedKey),
            panelBuilder: () => const SizedBox.expand(),
            body: const SizedBox.expand(),
          ),
        ),
      ),
    );
    return controller;
  }

  // Drags the closed panel up by [dy], 20px every 16ms.
  Future<TestGesture> dragUp(WidgetTester tester, double dy) async {
    final gesture =
        await tester.startGesture(tester.getCenter(find.byKey(collapsedKey)));
    var time = Duration.zero;
    for (var moved = 0.0; moved < dy; moved += 20) {
      time += const Duration(milliseconds: 16);
      await gesture.moveBy(const Offset(0, -20), timeStamp: time);
      await tester.pump(const Duration(milliseconds: 16));
    }
    return gesture;
  }

  // Lets the system take the touch away, as the iOS home gesture does.
  Future<void> cancel(WidgetTester tester, TestGesture gesture) async {
    await gesture.cancel();
    await tester.pumpAndSettle();
  }

  group('SlidingUpPanel touch cancel', () {
    testWidgets('a fast short drag flings the panel open when released',
        (tester) async {
      final controller = await pump(tester);
      final gesture = await dragUp(tester, 60);

      await gesture.up(timeStamp: const Duration(milliseconds: 64));
      await tester.pumpAndSettle();

      expect(controller.panelPosition, 1.0);
    });

    testWidgets('the same drag cancelled settles back closed', (tester) async {
      final controller = await pump(tester);

      await cancel(tester, await dragUp(tester, 60));

      expect(controller.panelPosition, 0.0);
    });

    testWidgets('a cancelled drag past halfway settles open', (tester) async {
      final controller = await pump(tester);

      await cancel(tester, await dragUp(tester, 300));

      expect(controller.panelPosition, 1.0);
    });
  });
}
