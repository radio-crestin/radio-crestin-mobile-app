import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/mini_player_bottom_inset.dart';

void main() {
  // Pumps the spacer inside a real scroll view so the sliver gets laid out.
  Future<void> pump(WidgetTester tester, {required bool visible}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [MiniPlayerBottomInset(visible: visible)],
          ),
        ),
      ),
    );
  }

  // skipOffstage: false so the spacer is still found when it has collapsed to
  // zero height (a zero-extent sliver child is treated as offstage otherwise).
  Size spacerSize(WidgetTester tester) =>
      tester.getSize(find.byType(AnimatedContainer, skipOffstage: false));

  group('MiniPlayerBottomInset', () {
    testWidgets('reserves the mini player height when a station is selected',
        (tester) async {
      await pump(tester, visible: true);
      expect(spacerSize(tester).height, kMiniPlayerCollapsedHeight);
    });

    testWidgets('collapses to zero height when no station is selected',
        (tester) async {
      await pump(tester, visible: false);
      expect(spacerSize(tester).height, 0.0);
    });

    testWidgets('animates between the two heights when visibility toggles',
        (tester) async {
      await pump(tester, visible: false);
      expect(spacerSize(tester).height, 0.0);

      await pump(tester, visible: true);
      // Mid-animation the spacer is partway open, not yet at full height.
      await tester.pump(const Duration(milliseconds: 125));
      final midHeight = spacerSize(tester).height;
      expect(midHeight, greaterThan(0.0));
      expect(midHeight, lessThan(kMiniPlayerCollapsedHeight));

      // Settles at the full collapsed-player height.
      await tester.pumpAndSettle();
      expect(spacerSize(tester).height, kMiniPlayerCollapsedHeight);
    });
  });
}
