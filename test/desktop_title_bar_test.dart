import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/desktop_menu_service.dart';
import 'package:radio_crestin/tv/desktop/desktop_title_bar_inset.dart';

void main() {
  group('DesktopTitleBar.fromMap', () {
    test('reads where the window buttons sit', () {
      expect(
        DesktopTitleBar.fromMap({'height': 52.0, 'leading': 79.0}),
        const DesktopTitleBar(height: 52, leading: 79),
      );
    });

    test('hidden buttons, as in full screen, leave a bar without them', () {
      final titleBar = DesktopTitleBar.fromMap({'height': 0, 'leading': 0});
      expect(titleBar.hasWindowButtons, isFalse);
      expect(titleBar.height, DesktopTitleBar.defaultHeight);
    });

    test('a height the bar can\'t take, or nothing, falls back', () {
      expect(DesktopTitleBar.fromMap({'height': 200, 'leading': 79}).height,
          DesktopTitleBar.defaultHeight);
      expect(DesktopTitleBar.fromMap(null), const DesktopTitleBar());
    });
  });

  group('DesktopTitleBarInset', () {
    tearDown(() => DesktopMenuService.titleBar.value = const DesktopTitleBar());

    Future<Rect> dialogRect(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => DesktopTitleBarInset(child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const Dialog(
                child: SizedBox(key: Key('dialog'), height: 5000),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return tester.getRect(find.byKey(const Key('dialog')));
    }

    testWidgets('a dialog opens below the window buttons', (tester) async {
      DesktopMenuService.titleBar.value =
          const DesktopTitleBar(height: 52, leading: 79);
      final rect = await dialogRect(tester);
      // The dialog's own 24 of room, under the 52 of the top bar.
      expect(rect.top, 52 + 24);
    });

    testWidgets('without the buttons, it uses the whole window',
        (tester) async {
      final rect = await dialogRect(tester);
      expect(rect.top, 24);
    });
  });
}
