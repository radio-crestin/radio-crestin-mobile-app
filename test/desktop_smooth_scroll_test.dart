import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/tv/desktop/desktop_smooth_scroll.dart';

void main() {
  late DesktopScrollController controller;

  Future<void> pumpList(WidgetTester tester) async {
    controller = DesktopScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ListView.builder(
        controller: controller,
        itemExtent: 50,
        itemCount: 200,
        itemBuilder: (_, i) => Text('Row $i'),
      ),
    ));
  }

  Future<void> wheel(WidgetTester tester, double dy) =>
      tester.sendEventToBinding(PointerScrollEvent(
        position: const Offset(200, 200),
        scrollDelta: Offset(0, dy),
      ));

  testWidgets('a wheel notch glides rather than jumps', (tester) async {
    await pumpList(tester);

    await wheel(tester, 100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(100), reason: 'still on its way');

    await tester.pumpAndSettle();
    expect(controller.offset, 100);
  });

  testWidgets('quick notches add up', (tester) async {
    await pumpList(tester);

    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 50));
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 50));
    await wheel(tester, 100);
    await tester.pumpAndSettle();

    expect(controller.offset, 300);
  });

  testWidgets('it stops at the ends', (tester) async {
    await pumpList(tester);

    await wheel(tester, -100);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);

    final end = controller.position.maxScrollExtent;
    controller.jumpTo(end - 30);
    await wheel(tester, 100);
    await tester.pumpAndSettle();
    expect(controller.offset, end);
  });
}
