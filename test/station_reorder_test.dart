import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/widgets/station_actions_menu.dart';
import 'package:radio_crestin/widgets/station_reorder.dart';

import 'helpers/station_factory.dart';

/// Opening the menu needs no handler; these tests never play a station.
class _FakeAudioHandler extends Fake implements AppAudioHandler {}

/// The Favorite section as the home page shows it: the listener holds a
/// row, moves it, and the order they leave it in is saved.
void main() {
  const rowHeight = 105.0;
  const bothPlatforms = TargetPlatformVariant(
    {TargetPlatform.iOS, TargetPlatform.android},
  );

  late List<List<String>> saved;
  late StationReorder reorder;
  late ScrollController scroll;

  Station station(int id) => StationFactory.createStation(
      id: id, slug: 's$id', title: 'Station $id', thumbnailUrl: null);

  /// Pumps [count] favorites in a list [height] tall. Like the app, the
  /// saved order reaches the list only after the drop, and only when
  /// [applySaved] is true.
  Future<void> pumpFavorites(
    WidgetTester tester, {
    int count = 5,
    double height = 874,
    bool applySaved = true,
  }) async {
    tester.view.physicalSize = Size(402, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    saved = [];
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    var stations = [for (var id = 1; id <= count; id++) station(id)];
    late StateSetter setHostState;
    reorder = StationReorder(onReorder: (order) {
      saved.add(order);
      if (!applySaved) return;
      // A frame after the drop, as the saved order comes through streams.
      WidgetsBinding.instance.addPostFrameCallback((_) => setHostState(() {
            final bySlug = {for (final s in stations) s.slug: s};
            stations = [for (final slug in order) bySlug[slug]!];
          }));
    });
    addTearDown(reorder.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          setHostState = setState;
          return CustomScrollView(
            controller: scroll,
            slivers: [
              StationsList(
                stations: stations,
                audioHandler: _FakeAudioHandler(),
                panelController: null,
                favoriteSlugs: [for (final s in stations) s.slug],
                isFavoritesList: true,
                reorder: reorder,
              ),
            ],
          );
        }),
      ),
    ));
  }

  /// The row of [title] in the list, where it is drawn (the lifted copy
  /// has no menu).
  Finder rowOf(String title) => find
      .ancestor(of: find.text(title), matching: find.byType(StationActionsMenu))
      .first;

  double topOf(WidgetTester tester, String title) =>
      tester.getTopLeft(rowOf(title)).dy;

  /// The titles top to bottom, as the list shows them.
  List<String> shownOrder(WidgetTester tester, int count) {
    final titles = [for (var id = 1; id <= count; id++) 'Station $id'];
    return titles
      ..sort((a, b) => topOf(tester, a).compareTo(topOf(tester, b)));
  }

  /// Holds the row of [title] until its menu opens.
  Future<TestGesture> hold(WidgetTester tester, String title) async {
    final gesture = await tester.startGesture(tester.getCenter(rowOf(title)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    return gesture;
  }

  /// Moves the finger by [dy], in steps as a finger does.
  Future<void> moveBy(WidgetTester tester, TestGesture gesture, double dy,
      {int steps = 10}) async {
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, dy / steps));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  final hideItem = find.text(StationActionsMenu.hideLabel);

  testWidgets('held, then moved two rows down, a favorite lands there and '
      'the order is saved', (tester) async {
    await pumpFavorites(tester);
    final slotTops = [
      for (var id = 1; id <= 5; id++) topOf(tester, 'Station $id'),
    ];

    final gesture = await hold(tester, 'Station 1');
    expect(hideItem, findsOneWidget, reason: 'held, the menu opens');

    await moveBy(tester, gesture, 2 * rowHeight);
    await tester.pump(const Duration(milliseconds: 800));
    expect(hideItem, findsNothing, reason: 'moved, the menu closed');
    expect(topOf(tester, 'Station 2'), slotTops[0],
        reason: 'the rows passed slid up out of the way');
    expect(topOf(tester, 'Station 3'), slotTops[1]);
    expect(topOf(tester, 'Station 4'), slotTops[3]);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(saved, [
      ['s2', 's3', 's1', 's4', 's5'],
    ]);
    expect(shownOrder(tester, 5), [
      'Station 2',
      'Station 3',
      'Station 1',
      'Station 4',
      'Station 5',
    ]);
    expect(topOf(tester, 'Station 1'), slotTops[2]);
    expect(find.text('Station 1'), findsOneWidget,
        reason: 'the lifted copy is gone');
  }, variant: bothPlatforms);

  testWidgets('it lands in its new place before the saved order reaches '
      'the list, without a jump', (tester) async {
    await pumpFavorites(tester, applySaved: false);
    final slotTops = [
      for (var id = 1; id <= 5; id++) topOf(tester, 'Station $id'),
    ];

    final gesture = await hold(tester, 'Station 4');
    await moveBy(tester, gesture, -2 * rowHeight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(topOf(tester, 'Station 2'), slotTops[2],
        reason: 'it made room for the moving row');
    await gesture.up();
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(topOf(tester, 'Station 2'), slotTops[2],
          reason: 'it stays put while the row lands, and after: never '
              'back in its old place for a frame');
      expect(topOf(tester, 'Station 3'), slotTops[3]);
    }

    expect(saved, [
      ['s1', 's4', 's2', 's3', 's5'],
    ]);
    expect(shownOrder(tester, 5), [
      'Station 1',
      'Station 4',
      'Station 2',
      'Station 3',
      'Station 5',
    ]);
  });

  testWidgets('let go without moving, the menu stays open and nothing '
      'moves', (tester) async {
    await pumpFavorites(tester);

    final gesture = await hold(tester, 'Station 2');
    await moveBy(tester, gesture, 6, steps: 3);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(hideItem, findsOneWidget,
        reason: 'a finger that only wobbled keeps the menu');
    expect(saved, isEmpty);
  }, variant: bothPlatforms);

  testWidgets('a favorite stays within the list: pulled past the top, it '
      'goes first', (tester) async {
    await pumpFavorites(tester);
    final firstTitle = tester.getTopLeft(find.text('Station 1')).dy;

    final gesture = await hold(tester, 'Station 3');
    await moveBy(tester, gesture, -900);
    await tester.pump(const Duration(milliseconds: 300));
    final lifted = tester.getTopLeft(find.text('Station 3').last).dy;
    expect(lifted, moreOrLessEquals(firstTitle, epsilon: 4),
        reason: 'the lifted row stops at the first slot');
    await gesture.up();
    await tester.pumpAndSettle();

    expect(saved.single.first, 's3');
  });

  testWidgets('held at the bottom of the view, the list scrolls on and the '
      'favorite goes further down', (tester) async {
    await pumpFavorites(tester, count: 12, height: 500);
    final bottom = tester.getBottomLeft(find.byType(CustomScrollView)).dy;

    final gesture = await hold(tester, 'Station 1');
    final start = tester.getCenter(rowOf('Station 1')).dy;
    await moveBy(tester, gesture, bottom - start - 10);
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(saved.single.indexOf('s1'), greaterThan(5));
  });

  testWidgets('screen readers move a favorite up or down', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpFavorites(tester);

    void act(String title, String label) {
      final node = tester.getSemantics(find.text(title));
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
            CustomSemanticsAction(label: label)),
      );
    }

    act('Station 1', StationActionsMenu.moveDownLabel);
    await tester.pumpAndSettle();
    expect(saved.last, ['s2', 's1', 's3', 's4', 's5']);

    act('Station 5', StationActionsMenu.moveUpLabel);
    await tester.pumpAndSettle();
    expect(saved.last, ['s2', 's1', 's3', 's5', 's4']);
    semantics.dispose();
  });

  testWidgets('the first and last offer only the way they can go',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpFavorites(tester, count: 3);

    List<String> labels(String title) => [
          for (final id in tester
                  .getSemantics(find.text(title))
                  .getSemanticsData()
                  .customSemanticsActionIds ??
              <int>[])
            CustomSemanticsAction.getAction(id)!.label ?? '',
        ];

    expect(labels('Station 1'), isNot(contains('Mută mai sus')));
    expect(labels('Station 1'), contains('Mută mai jos'));
    expect(labels('Station 3'), contains('Mută mai sus'));
    expect(labels('Station 3'), isNot(contains('Mută mai jos')));
    semantics.dispose();
  });
}
