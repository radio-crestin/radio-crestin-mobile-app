import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/station_actions_menu.dart';

void main() {
  late int plays;
  late int favoriteToggles;
  late int shares;
  late int confirmations;
  late int hides;
  late bool confirmAnswer;

  /// The listener's answer while they are still asked, in place of
  /// [confirmAnswer].
  Completer<bool>? pendingAnswer;

  setUp(() {
    plays = 0;
    favoriteToggles = 0;
    shares = 0;
    confirmations = 0;
    hides = 0;
    confirmAnswer = true;
    pendingAnswer = null;
  });

  final row = find.text('Radio Test');
  final favoriteItem = find.text(StationActionsMenu.addFavoriteLabel);
  final shareItem = find.text(StationActionsMenu.shareLabel);
  final hideItem = find.text(StationActionsMenu.hideLabel);

  Future<void> pumpRow(WidgetTester tester, {bool isFavorite = false}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 100,
              child: StationActionsMenu(
                isFavorite: isFavorite,
                onToggleFavorite: () => favoriteToggles++,
                onShare: () => shares++,
                confirmHide: () async {
                  confirmations++;
                  final pending = pendingAnswer;
                  return pending == null
                      ? confirmAnswer
                      : await pending.future;
                },
                onHide: () => hides++,
                child: GestureDetector(
                  onTap: () => plays++,
                  child: const ColoredBox(
                    color: Colors.white,
                    child: Center(child: Text('Radio Test')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  const bothPlatforms = TargetPlatformVariant(
    {TargetPlatform.iOS, TargetPlatform.android},
  );

  testWidgets('a tap plays the station without opening the menu',
      (tester) async {
    await pumpRow(tester);

    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(plays, 1);
    expect(hideItem, findsNothing);
  }, variant: bothPlatforms);

  testWidgets('a long press opens the menu with the three actions',
      (tester) async {
    await pumpRow(tester);

    await tester.longPress(row);
    await tester.pumpAndSettle();

    expect(favoriteItem, findsOneWidget);
    expect(shareItem, findsOneWidget);
    expect(hideItem, findsOneWidget);
    expect(plays, 0, reason: 'the long press is not also a tap');
  }, variant: bothPlatforms);

  testWidgets('a favorite offers to leave the favorites', (tester) async {
    await pumpRow(tester, isFavorite: true);

    await tester.longPress(row);
    await tester.pumpAndSettle();

    expect(find.text(StationActionsMenu.removeFavoriteLabel), findsOneWidget);
    expect(favoriteItem, findsNothing);
  }, variant: bothPlatforms);

  testWidgets('the favorite and share actions run and close the menu',
      (tester) async {
    await pumpRow(tester);

    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(favoriteItem);
    await tester.pumpAndSettle();
    expect(favoriteToggles, 1);
    expect(favoriteItem, findsNothing);

    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(shareItem);
    await tester.pumpAndSettle();
    expect(shares, 1);
    expect(hides, 0);
  }, variant: bothPlatforms);

  testWidgets('hiding asks, then hides', (tester) async {
    await pumpRow(tester);

    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(hideItem);
    await tester.pumpAndSettle();

    expect(hideItem, findsNothing);
    expect(confirmations, 1);
    expect(hides, 1);
    expect(plays, 0);
  }, variant: bothPlatforms);

  testWidgets('a screen reader hides without a menu, and only once',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpRow(tester);

    void hideAction() {
      final node = tester.getSemantics(row);
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: StationActionsMenu.hideLabel),
        ),
      );
    }

    hideAction();
    await tester.pump();
    hideAction();
    await tester.pump();

    expect(hides, 1, reason: 'the station is already on its way out');
    semantics.dispose();
  });

  testWidgets('a declined confirmation keeps the station', (tester) async {
    confirmAnswer = false;
    await pumpRow(tester);

    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(hideItem);
    await tester.pumpAndSettle();

    expect(confirmations, 1);
    expect(hides, 0);

    await tester.tap(row);
    expect(plays, 1, reason: 'the row is usable again');
  }, variant: bothPlatforms);

  group('the row stays sunk', () {
    double rowScale(WidgetTester tester) => tester
        .widget<AnimatedScale>(
            find.ancestor(of: row, matching: find.byType(AnimatedScale)))
        .scale;

    /// Holds the row, picks "Ascunde stația" and checks every frame while
    /// the menu closes and the listener is asked.
    Future<void> askToHide(WidgetTester tester) async {
      pendingAnswer = Completer<bool>();
      await pumpRow(tester, isFavorite: true);
      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(rowScale(tester), lessThan(1));

      await tester.tap(hideItem);
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(rowScale(tester), lessThan(1), reason: 'frame $frame');
      }
      expect(hideItem, findsNothing);
      expect(confirmations, 1);
    }

    testWidgets('while hiding it waits for the listener, and rises when '
        'they decline', (tester) async {
      await askToHide(tester);

      pendingAnswer!.complete(false);
      await tester.pumpAndSettle();

      expect(rowScale(tester), 1);
      expect(hides, 0);
    }, variant: bothPlatforms);

    testWidgets('once hiding is confirmed, as it plays out', (tester) async {
      await askToHide(tester);

      pendingAnswer!.complete(true);
      await tester.pumpAndSettle();

      expect(hides, 1);
      expect(rowScale(tester), lessThan(1));
    }, variant: bothPlatforms);
  });

  testWidgets('a tap on the row while the menu is open only closes it',
      (tester) async {
    await pumpRow(tester);

    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(row, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(hideItem, findsNothing);
    expect(plays, 0);
  }, variant: bothPlatforms);

  group('in a list', () {
    late ScrollController scroll;
    late List<int> played;

    Future<void> pumpList(WidgetTester tester) {
      scroll = ScrollController();
      addTearDown(scroll.dispose);
      played = [];
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(
                    height: 100,
                    child: StationActionsMenu(
                      isFavorite: false,
                      onToggleFavorite: () => favoriteToggles++,
                      onShare: () => shares++,
                      confirmHide: () async => true,
                      onHide: () => hides++,
                      child: GestureDetector(
                        onTap: () => played.add(i),
                        child: Center(child: Text('Row $i')),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    /// Drags the list up from another row; resolves to how far it moved.
    Future<double> dragList(WidgetTester tester) async {
      final before = scroll.offset;
      await tester.drag(find.text('Row 4'), const Offset(0, -60));
      await tester.pump();
      return scroll.offset - before;
    }

    testWidgets('a touch on another row only closes the menu',
        (tester) async {
      await pumpList(tester);

      await tester.longPress(find.text('Row 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Row 4'));
      await tester.pumpAndSettle();

      expect(hideItem, findsNothing);
      expect(played, isEmpty);
    }, variant: bothPlatforms);

    testWidgets('the list scrolls as soon as the menu starts closing',
        (tester) async {
      await pumpList(tester);

      await tester.longPress(find.text('Row 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Row 4'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(await dragList(tester), greaterThan(0),
          reason: 'closed by a touch outside');
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Row 1'));
      await tester.pumpAndSettle();
      await tester.tap(shareItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(shares, 1);
      expect(await dragList(tester), greaterThan(0),
          reason: 'closed by an action');
    }, variant: bothPlatforms);
  });

  testWidgets('screen readers reach every action', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpRow(tester);

    final node = tester.getSemantics(row);
    final labels = [
      for (final id in node.getSemanticsData().customSemanticsActionIds ?? [])
        CustomSemanticsAction.getAction(id)!.label,
    ];
    expect(labels, [
      StationActionsMenu.addFavoriteLabel,
      StationActionsMenu.shareLabel,
      StationActionsMenu.hideLabel,
    ]);
    semantics.dispose();
  });
}
