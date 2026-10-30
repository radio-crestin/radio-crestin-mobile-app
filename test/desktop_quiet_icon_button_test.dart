import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/tv/desktop/desktop_quiet_icon_button.dart';
import 'package:radio_crestin/tv/tv_theme.dart';

void main() {
  var presses = 0;

  Future<void> pumpButton(WidgetTester tester) async {
    presses = 0;
    await tester.pumpWidget(MaterialApp(
      theme: desktopTheme,
      home: Scaffold(
        body: Center(
          child: DesktopQuietIconButton(
            icon: const Icon(Icons.skip_next_rounded),
            tooltip: 'Stația următoare',
            onPressed: () => presses++,
          ),
        ),
      ),
    ));
  }

  Color? iconColor(WidgetTester tester) =>
      IconTheme.of(tester.element(find.byIcon(Icons.skip_next_rounded)))
          .color;

  testWidgets('under the pointer the icon lightens, with nothing behind it',
      (tester) async {
    await pumpButton(tester);
    expect(iconColor(tester), TvColors.textSecondary);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(IconButton)));
    await tester.pumpAndSettle();

    expect(
      iconColor(tester),
      Color.lerp(TvColors.textSecondary, Colors.white,
          DesktopQuietIconButton.hoverLightening),
    );
    final style = tester.widget<IconButton>(find.byType(IconButton)).style!;
    for (final state in [WidgetState.hovered, WidgetState.pressed]) {
      expect(style.overlayColor!.resolve({state}), Colors.transparent,
          reason: '$state');
    }

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(iconColor(tester), TvColors.textSecondary);

    await tester.tap(find.byType(IconButton));
    expect(presses, 1);
  });

  testWidgets('the keyboard on it turns the icon the focus pink',
      (tester) async {
    await pumpButton(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(iconColor(tester), DesktopTokens.focusRing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(presses, 1);
  });
}
