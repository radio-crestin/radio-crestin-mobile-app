import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/tv/widgets/tv_top_tab_bar.dart';

void main() {
  group('TvTopTabBar', () {
    Widget wrap(Widget child) {
      return DpadNavigator(
        enabled: true,
        child: MaterialApp(home: Scaffold(body: child)),
      );
    }

    final tabItems = const <TvTopTabItem>[
      TvTopTabItem(icon: Icons.radio_rounded, label: 'Stații'),
      TvTopTabItem(icon: Icons.favorite_rounded, label: 'Favorite'),
      TvTopTabItem(icon: Icons.history_rounded, label: 'Recente'),
      TvTopTabItem(icon: Icons.settings_rounded, label: 'Setări'),
    ];

    testWidgets('renders all four items + brand wordmark', (tester) async {
      await tester.pumpWidget(wrap(
        TvTopTabBar(items: tabItems, selectedIndex: 0, onSelect: (_) {}),
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
      await tester.pumpWidget(wrap(
        TvTopTabBar(items: tabItems, selectedIndex: 0, onSelect: (_) {}),
      ));
      await tester.pump();
      final focuses = find.byWidgetPredicate(
          (w) => w is Focus && (w.canRequestFocus));
      expect(focuses.evaluate().length, greaterThanOrEqualTo(tabItems.length));
    });

    testWidgets('selected item shows distinct color/weight', (tester) async {
      Widget build(int sel) => wrap(
            TvTopTabBar(items: tabItems, selectedIndex: sel, onSelect: (_) {}),
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
