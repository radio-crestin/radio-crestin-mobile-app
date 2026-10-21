import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/PositionRetainedScrollPhysics.dart';
import 'package:radio_crestin/widgets/floating_sliver_header.dart';

const _headerHeight = 54.0;

/// A list like Home's: the header, rows, and a bottom inset that keeps the
/// last rows clear of the mini player and the navigation bar.
Widget _list(
  ValueNotifier<double> bottomInset, {
  bool pinned = false,
  Widget header = const Text('Radio Creștin'),
}) {
  return MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<double>(
        valueListenable: bottomInset,
        builder: (context, inset, _) => CustomScrollView(
          physics: const PositionRetainedScrollPhysics()
              .applyTo(const AlwaysScrollableScrollPhysics()),
          slivers: [
            FloatingSliverHeader(
              pinned: pinned,
              child: SizedBox(
                key: const ValueKey('header'),
                height: _headerHeight,
                child: header,
              ),
            ),
            SliverFixedExtentList.builder(
              itemExtent: 105,
              itemCount: 40,
              itemBuilder: (_, index) => Text('Station $index'),
            ),
            SliverToBoxAdapter(child: SizedBox(height: inset)),
          ],
        ),
      ),
    ),
  );
}

/// Where the header is, also once it is out of view.
Rect _header(WidgetTester tester) => tester
    .getRect(find.byKey(const ValueKey('header'), skipOffstage: false));

/// Scrolls on, then back a little, so the header comes back over the list.
Future<void> _showHeaderOverList(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
  await tester.pumpAndSettle();
  await tester.drag(find.byType(CustomScrollView), const Offset(0, 200));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('hides as the user scrolls on', (tester) async {
    await tester.pumpWidget(_list(ValueNotifier(144)));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();

    expect(_header(tester).bottom, lessThanOrEqualTo(0));
  });

  testWidgets('comes back over the list as the user scrolls back',
      (tester) async {
    await tester.pumpWidget(_list(ValueNotifier(144)));

    await _showHeaderOverList(tester);

    expect(_header(tester).top, 0);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    expect(position.pixels, greaterThan(_headerHeight));
  });

  testWidgets('stays as the list keeps its rows in place by itself',
      (tester) async {
    final bottomInset = ValueNotifier<double>(144);
    await tester.pumpWidget(_list(bottomInset));
    await _showHeaderOverList(tester);
    final row = tester.getRect(find.text('Station 8'));

    // The keyboard of the search dialog leaves the navigation bar out of
    // the bottom inset, then gives it back once it closes.
    bottomInset.value = 96;
    await tester.pumpAndSettle();
    bottomInset.value = 144;
    await tester.pumpAndSettle();

    expect(tester.getRect(find.text('Station 8')), row);
    expect(_header(tester).top, 0);
  });

  testWidgets('still snaps in or out after the user scrolls',
      (tester) async {
    await tester.pumpWidget(_list(ValueNotifier(144)));
    await _showHeaderOverList(tester);

    // Scrolling on by less than the header leaves it part shown, then it
    // snaps away.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -40));
    await tester.pumpAndSettle();

    expect(_header(tester).bottom, lessThanOrEqualTo(0));
  });

  testWidgets('stays in view while pinned, whichever way the list scrolls',
      (tester) async {
    await tester.pumpWidget(_list(ValueNotifier(144), pinned: true));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();

    expect(_header(tester).top, 0);
  });

  testWidgets('leaves the list in place as a field in it gets the keyboard',
      (tester) async {
    await tester.pumpWidget(_list(
      ValueNotifier(144),
      pinned: true,
      header: const TextField(),
    ));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final scrolled = position.pixels;

    // The field asks to be shown as it gets focus and as its text changes.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'elim');
    await tester.pumpAndSettle();

    expect(position.pixels, scrolled);
    expect(_header(tester).top, 0);
  });
}
