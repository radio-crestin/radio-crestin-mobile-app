import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/PositionRetainedScrollPhysics.dart';
import 'package:radio_crestin/widgets/station_row_transition.dart';

void main() {
  const rowHeight = 100.0;
  late StationRowTransitions transitions;
  late int hides;
  late int taps;

  setUp(() {
    transitions = StationRowTransitions();
    hides = 0;
    taps = 0;
  });
  tearDown(() => transitions.dispose());

  Widget rowFor(String slug, {bool collapses = true}) => StationRowTransition(
        key: ValueKey(slug),
        slug: slug,
        transitions: transitions,
        collapses: collapses,
        child: SizedBox(
          height: rowHeight,
          child: GestureDetector(
            onTap: () => taps++,
            child: ColoredBox(
              color: Colors.white,
              child: Center(child: Text(slug.toUpperCase())),
            ),
          ),
        ),
      );

  /// A one-column list of [slugs], twice over with [twice] (the Favorite
  /// section and the full list).
  Future<void> pumpList(
    WidgetTester tester,
    List<String> slugs, {
    bool collapses = true,
    bool twice = false,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            for (var copy = 0; copy < (twice ? 2 : 1); copy++)
              SliverList(
                delegate: SliverChildListDelegate([
                  for (final slug in slugs)
                    KeyedSubtree(
                      key: ValueKey('$copy-$slug'),
                      child: rowFor(slug, collapses: collapses),
                    ),
                ]),
              ),
          ],
        ),
      ),
    ));
  }

  double opacityOf(WidgetTester tester, String text) => tester
      .widget<Opacity>(find
          .ancestor(of: find.text(text), matching: find.byType(Opacity))
          .first)
      .opacity;

  double topOf(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text).first).dy;

  void hideB() => transitions.leave('b', () => hides++);

  testWidgets('a hidden station shows the crossed eye, fades, then its slot '
      'closes and it is hidden once', (tester) async {
    await pumpList(tester, ['a', 'b', 'c']);
    final cTop = topOf(tester, 'C');

    hideB();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(tester, 'B'), 1, reason: 'the eye shows first');
    expect(topOf(tester, 'C'), cTop);

    await tester.pump(const Duration(milliseconds: 220));
    expect(opacityOf(tester, 'B'), moreOrLessEquals(0));
    expect(topOf(tester, 'C'), moreOrLessEquals(cTop),
        reason: 'the slot closes after the fade');

    await tester.pump(const Duration(milliseconds: 110));
    expect(topOf(tester, 'C'), lessThan(cTop));
    expect(topOf(tester, 'C'), greaterThan(cTop - rowHeight));
    expect(hides, 0);

    await tester.pump(const Duration(milliseconds: 120));
    expect(topOf(tester, 'C'), moreOrLessEquals(cTop - rowHeight));
    expect(hides, 1);
    expect(transitions.isLeaving('b'), isFalse);
  });

  testWidgets('every row of the station plays out, and it is hidden once',
      (tester) async {
    await pumpList(tester, ['a', 'b'], twice: true);

    hideB();
    await tester.pumpAndSettle();

    expect(hides, 1);
  });

  testWidgets('in a grid the slot stays: the row only fades', (tester) async {
    await pumpList(tester, ['a', 'b', 'c'], collapses: false);
    final cTop = topOf(tester, 'C');

    hideB();
    await tester.pumpAndSettle();

    expect(topOf(tester, 'C'), cTop);
    expect(opacityOf(tester, 'B'), 0);
    expect(hides, 1);
  });

  testWidgets('a row taken away mid-way still hides the station',
      (tester) async {
    await pumpList(tester, ['a', 'b']);

    hideB();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await pumpList(tester, ['a']);
    await tester.pump();

    expect(hides, 1);
  });

  testWidgets('a row playing out takes no touches', (tester) async {
    await pumpList(tester, ['a', 'b']);

    hideB();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('B'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(taps, 0);
  });

  testWidgets('a station shown again grows back into its slot',
      (tester) async {
    await pumpList(tester, ['a', 'c']);
    final cTop = topOf(tester, 'C');

    transitions.enter('b');
    await pumpList(tester, ['a', 'b', 'c']);
    expect(topOf(tester, 'C'), moreOrLessEquals(cTop),
        reason: 'the slot starts closed');

    await tester.pump(StationRowTransition.enterDuration ~/ 2);
    expect(topOf(tester, 'C'), greaterThan(cTop));
    expect(topOf(tester, 'C'), lessThan(cTop + rowHeight));

    await tester.pumpAndSettle();
    expect(topOf(tester, 'C'), moreOrLessEquals(cTop + rowHeight));
    expect(opacityOf(tester, 'B'), 1);
    expect(transitions.isEntering('b'), isFalse);
  });

  testWidgets('hiding a station that is growing in plays it out instead',
      (tester) async {
    transitions.enter('b');
    await pumpList(tester, ['a', 'b']);

    hideB();
    expect(transitions.isEntering('b'), isFalse);
    await tester.pumpAndSettle();

    expect(hides, 1);
  });

  group('a row leaving without hiding', () {
    late int left;
    setUp(() => left = 0);

    void leaveB() => transitions.leave('b', () => left++, hiding: false);

    Finder eye() => find.descendant(
          of: find.byType(StationRowTransition),
          matching: find.byType(CustomPaint),
        );

    testWidgets('goes the way rows come in, backwards, with no eye',
        (tester) async {
      await pumpList(tester, ['a', 'b', 'c']);
      final cTop = topOf(tester, 'C');

      leaveB();
      await tester.pump();
      await tester.pump(StationRowTransition.enterDuration ~/ 2);
      expect(eye(), findsNothing);
      expect(opacityOf(tester, 'B'), lessThan(1));
      expect(topOf(tester, 'C'), lessThan(cTop));
      expect(topOf(tester, 'C'), greaterThan(cTop - rowHeight));
      expect(left, 0);

      await tester.pumpAndSettle();
      expect(topOf(tester, 'C'), moreOrLessEquals(cTop - rowHeight));
      expect(left, 1);
      expect(transitions.isLeaving('b'), isFalse);
    });

    testWidgets('grows back when told to stay', (tester) async {
      await pumpList(tester, ['a', 'b', 'c']);
      final cTop = topOf(tester, 'C');

      leaveB();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      transitions.stay('b');
      await tester.pumpAndSettle();

      expect(topOf(tester, 'C'), moreOrLessEquals(cTop));
      expect(opacityOf(tester, 'B'), 1);
      expect(left, 0);
    });

    testWidgets('grows back once out if still listed', (tester) async {
      await pumpList(tester, ['a', 'b', 'c']);
      final cTop = topOf(tester, 'C');
      leaveB();
      await tester.pumpAndSettle();
      expect(left, 1);

      await pumpList(tester, ['a', 'b', 'c']);
      await tester.pumpAndSettle();

      expect(topOf(tester, 'C'), moreOrLessEquals(cTop));
      expect(opacityOf(tester, 'B'), 1);
    });

    testWidgets('leaves at once without a row built', (tester) async {
      await pumpList(tester, ['a']);

      transitions.leave('b', () => left++, hiding: false);

      expect(left, 1);
      expect(transitions.isLeaving('b'), isFalse);
      expect(transitions.hasRows('a'), isTrue);
      expect(transitions.hasRows('b'), isFalse);
    });
  });

  group('in a scrolled list', () {
    // Home in miniature: a section above (Favorite), then the full list,
    // on the app's scroll physics, in a 600 high view.
    late ScrollController controller;
    late StateSetter setLists;
    late List<String> above;
    late List<String> list;

    setUp(() {
      controller = ScrollController();
      above = [];
      list = [for (var i = 0; i < 40; i++) 's$i'];
    });
    tearDown(() => controller.dispose());

    Widget sliver(String name, List<String> slugs) {
      Key keyOf(String slug) => ValueKey('$name-$slug');
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) => KeyedSubtree(
            key: keyOf(slugs[i]),
            child: rowFor(slugs[i]),
          ),
          childCount: slugs.length,
          findChildIndexCallback: (key) {
            final index = slugs.indexWhere((slug) => keyOf(slug) == key);
            return index < 0 ? null : index;
          },
        ),
      );
    }

    Future<void> pumpLists(WidgetTester tester, {double scrolled = 0}) async {
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(builder: (context, setState) {
          setLists = setState;
          return CustomScrollView(
            controller: controller,
            physics: PositionRetainedScrollPhysics(
              rows: transitions.scrollAnchor,
            ).applyTo(const AlwaysScrollableScrollPhysics()),
            slivers: [sliver('above', above), sliver('list', list)],
          );
        }),
      ));
      controller.jumpTo(scrolled);
      await tester.pump();
    }

    /// Hides [slug] from both lists once its rows played out, as Home does.
    void hide(String slug) => transitions.leave(slug, () {
          hides++;
          setLists(() {
            above = [...above]..remove(slug);
            list = [...list]..remove(slug);
          });
        });

    /// Pumps frame by frame while [moving], checking [text] stays put.
    Future<void> expectStill(
      WidgetTester tester,
      String text,
      bool Function() moving,
    ) async {
      final top = topOf(tester, text);
      while (moving()) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(topOf(tester, text), top, reason: '$text moved');
      }
      await tester.pump();
      expect(topOf(tester, text), top, reason: '$text moved at the end');
    }

    testWidgets('the rows above a hidden row stay, the ones below move up',
        (tester) async {
      await pumpLists(tester, scrolled: 450);
      final s8 = topOf(tester, 'S8');

      hide('s7');
      await tester.pump();
      await expectStill(tester, 'S5', () => transitions.isLeaving('s7'));

      expect(topOf(tester, 'S8'), s8 - rowHeight);
      expect(controller.offset, 450);
      expect(hides, 1);
    });

    testWidgets('the first row in view hidden, the rows below move up into '
        'its place', (tester) async {
      // Its row leaves the list in the frame its slot closes, and is out of
      // the tree, though not yet gone, while that frame lays out.
      await pumpLists(tester, scrolled: 400);
      final s4 = topOf(tester, 'S4');

      hide('s4');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Within the last step of its slot, which closes as its row leaves.
      expect(topOf(tester, 'S5'), moreOrLessEquals(s4, epsilon: 3));
      expect(controller.offset, moreOrLessEquals(400, epsilon: 3));
      expect(hides, 1);
    });

    testWidgets('its row closing above the view moves nothing in view',
        (tester) async {
      // Hidden from the full list, while its Favorite row is above.
      above = ['f0', 's3'];
      await pumpLists(tester, scrolled: 350);
      final s4 = topOf(tester, 'S4');

      hide('s3');
      await tester.pump();
      await expectStill(tester, 'S2', () => transitions.isLeaving('s3'));

      expect(topOf(tester, 'S4'), s4 - rowHeight);
      expect(controller.offset, 350 - rowHeight);
    });

    testWidgets('a row leaving without hiding moves no row in view',
        (tester) async {
      await pumpLists(tester, scrolled: 450);
      final s8 = topOf(tester, 'S8');

      transitions.leave(
        's7',
        () => setLists(() => list = [...list]..remove('s7')),
        hiding: false,
      );
      await tester.pump();
      await expectStill(tester, 'S5', () => transitions.isLeaving('s7'));

      expect(topOf(tester, 'S8'), s8 - rowHeight);
      expect(controller.offset, 450);
    });

    testWidgets('a row coming back pushes only the rows below it down',
        (tester) async {
      list.remove('s7');
      await pumpLists(tester, scrolled: 450);
      final s8 = topOf(tester, 'S8');

      transitions.enter('s7');
      setLists(() => list = [...list]..insert(7, 's7'));
      await expectStill(tester, 'S5', () => transitions.isEntering('s7'));

      expect(topOf(tester, 'S8'), s8 + rowHeight);
      expect(controller.offset, 450);
    });

    testWidgets('at the top, a row coming back pushes the rest down',
        (tester) async {
      above = ['f1'];
      await pumpLists(tester);
      final f1 = topOf(tester, 'F1');

      transitions.enter('f0');
      setLists(() => above = ['f0', 'f1']);
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
      expect(topOf(tester, 'F0'), f1);
      expect(topOf(tester, 'F1'), f1 + rowHeight);
    });
  });
}
