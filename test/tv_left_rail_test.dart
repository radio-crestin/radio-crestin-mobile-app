import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/tv/widgets/tv_left_rail.dart';

void main() {
  group('TvLeftRail', () {
    Widget _wrap(Widget child) {
      return DpadNavigator(
        enabled: true,
        child: MaterialApp(home: Scaffold(body: child)),
      );
    }

    final railItems = const <TvLeftRailItem>[
      TvLeftRailItem(icon: Icons.radio_rounded, label: 'Stații'),
      TvLeftRailItem(icon: Icons.favorite_rounded, label: 'Favorite'),
      TvLeftRailItem(icon: Icons.history_rounded, label: 'Recente'),
      TvLeftRailItem(icon: Icons.settings_rounded, label: 'Setări'),
    ];

    testWidgets('renders all four items + brand wordmark', (tester) async {
      await tester.pumpWidget(_wrap(
        TvLeftRail(items: railItems, selectedIndex: 0, onSelect: (_) {}),
      ));
      await tester.pump();

      expect(find.text('Radio Crestin'), findsOneWidget);
      expect(find.text('Stații'), findsOneWidget);
      expect(find.text('Favorite'), findsOneWidget);
      expect(find.text('Recente'), findsOneWidget);
      expect(find.text('Setări'), findsOneWidget);
    });

    testWidgets('renders the right number of focusable buttons',
        (tester) async {
      await tester.pumpWidget(_wrap(
        TvLeftRail(items: railItems, selectedIndex: 0, onSelect: (_) {}),
      ));
      await tester.pump();
      // Each rail item wraps a DesktopFocusable that produces an internal
      // Focus node — verify there is one focusable per item, regardless of
      // whether the test environment is in "desktop" or "TV" mode.
      final focuses = find.byWidgetPredicate(
          (w) => w is Focus && (w.canRequestFocus));
      expect(focuses.evaluate().length, greaterThanOrEqualTo(railItems.length));
    });

    testWidgets('selected item shows distinct color/weight', (tester) async {
      // We snapshot the same item twice — once when selectedIndex matches,
      // once when it doesn't — and verify the Text widget's style differs.
      Widget build(int sel) => _wrap(
            TvLeftRail(items: railItems, selectedIndex: sel, onSelect: (_) {}),
          );

      await tester.pumpWidget(build(1));
      await tester.pump();
      final selectedText = tester.widget<Text>(find.text('Favorite'));
      final selectedWeight = selectedText.style?.fontWeight;
      final selectedColor = selectedText.style?.color;

      await tester.pumpWidget(build(0));
      await tester.pump();
      final unselectedText = tester.widget<Text>(find.text('Favorite'));
      final unselectedWeight = unselectedText.style?.fontWeight;
      final unselectedColor = unselectedText.style?.color;

      expect(selectedWeight, isNot(equals(unselectedWeight)));
      expect(selectedColor, isNot(equals(unselectedColor)));
    });
  });
}
