import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/bar_icon_button.dart';

void main() {
  late int presses;

  setUp(() => presses = 0);

  /// A button in a bar 54 high, as the app bar is.
  Future<Rect> pumpButton(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: BarIconButton(
            icon: Icons.search_rounded,
            tooltip: 'Caută',
            height: 54,
            onPressed: () => presses++,
          ),
        ),
      ),
    ));
    return tester.getRect(find.byType(BarIconButton));
  }

  Future<void> tapAt(WidgetTester tester, Offset point) async {
    await tester.tapAt(point);
    await tester.pumpAndSettle();
  }

  testWidgets('is 48 wide and as tall as its bar', (tester) async {
    final button = await pumpButton(tester);

    expect(button.size, const Size(48, 54));
  });

  testWidgets('takes touches in its corners, off the circle', (tester) async {
    final button = await pumpButton(tester);

    for (final corner in [
      button.topLeft + const Offset(2, 2),
      button.topRight + const Offset(-2, 2),
      button.bottomLeft + const Offset(2, -2),
      button.bottomRight + const Offset(-2, -2),
    ]) {
      await tapAt(tester, corner);
    }

    expect(presses, 4);
  });

  testWidgets('takes touches above and below the icon', (tester) async {
    final button = await pumpButton(tester);

    await tapAt(tester, button.topCenter + const Offset(0, 1));
    await tapAt(tester, button.bottomCenter - const Offset(0, 1));

    expect(presses, 2);
  });

  testWidgets('leaves touches beside it alone', (tester) async {
    final button = await pumpButton(tester);

    await tapAt(tester, button.centerRight + const Offset(4, 0));

    expect(presses, 0);
  });
}
