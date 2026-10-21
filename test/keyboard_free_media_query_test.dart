import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/PositionRetainedScrollPhysics.dart';
import 'package:radio_crestin/widgets/keyboard_free_media_query.dart';

/// The navigation bar, in physical pixels at the test's 3x.
const _navigationBar = FakeViewPadding(bottom: 144);

/// Opens the keyboard the way Android 10 reports it: the navigation bar
/// leaves both the padding and the view padding.
void _openKeyboard(WidgetTester tester) {
  tester.view.viewInsets = const FakeViewPadding(bottom: 900);
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewPadding = FakeViewPadding.zero;
}

void _closeKeyboard(WidgetTester tester) {
  tester.view.viewInsets = FakeViewPadding.zero;
  tester.view.padding = _navigationBar;
  tester.view.viewPadding = _navigationBar;
}

void main() {
  testWidgets('keeps the navigation bar and hides the keyboard',
      (tester) async {
    addTearDown(tester.view.reset);
    _closeKeyboard(tester);
    late MediaQueryData seen;
    await tester.pumpWidget(KeyboardFreeMediaQuery(
      child: Builder(builder: (context) {
        seen = MediaQuery.of(context);
        return const SizedBox();
      }),
    ));

    _openKeyboard(tester);
    await tester.pump();

    expect(seen.viewInsets.bottom, 0);
    expect(seen.padding.bottom, 48);
    expect(seen.viewPadding.bottom, 48);
  });

  testWidgets('follows the navigation bar while the keyboard is closed',
      (tester) async {
    addTearDown(tester.view.reset);
    _closeKeyboard(tester);
    late double bottom;
    await tester.pumpWidget(KeyboardFreeMediaQuery(
      child: Builder(builder: (context) {
        bottom = MediaQuery.paddingOf(context).bottom;
        return const SizedBox();
      }),
    ));

    // E.g. gesture navigation switched on.
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    await tester.pump();

    expect(bottom, 16);
  });

  testWidgets("doesn't rebuild the page for the keyboard", (tester) async {
    addTearDown(tester.view.reset);
    _closeKeyboard(tester);
    var builds = 0;
    await tester.pumpWidget(KeyboardFreeMediaQuery(
      child: Builder(builder: (context) {
        MediaQuery.paddingOf(context);
        MediaQuery.viewInsetsOf(context);
        builds++;
        return const SizedBox();
      }),
    ));

    _openKeyboard(tester);
    await tester.pump();
    _closeKeyboard(tester);
    await tester.pump();

    expect(builds, 1);
  });

  testWidgets('the list under the search dialog stays where it was',
      (tester) async {
    addTearDown(tester.view.reset);
    _closeKeyboard(tester);
    await tester.pumpWidget(MaterialApp(
      home: KeyboardFreeMediaQuery(
        child: Scaffold(
          body: Builder(
            builder: (context) => CustomScrollView(
              physics: const PositionRetainedScrollPhysics()
                  .applyTo(const AlwaysScrollableScrollPhysics()),
              slivers: [
                SliverFixedExtentList.builder(
                  itemExtent: 105,
                  itemCount: 40,
                  itemBuilder: (_, index) => Text('Station $index'),
                ),
                // Like Home's inset under the mini player.
                SliverToBoxAdapter(
                  child: SizedBox(
                      height: 96 + MediaQuery.paddingOf(context).bottom),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    final row = tester.getRect(find.text('Station 10'));

    _openKeyboard(tester);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Station 10')), row);

    _closeKeyboard(tester);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Station 10')), row);
  });
}
