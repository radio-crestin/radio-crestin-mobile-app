import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/song_actions_button.dart';

void main() {
  late int searches;
  late int copies;
  late int menuOpens;
  late int elsewhereTaps;

  setUp(() {
    searches = 0;
    copies = 0;
    menuOpens = 0;
    elsewhereTaps = 0;
  });

  final song = find.text('Artist - Song');
  final copyItem = find.text(SongActionsButton.copyLabel);
  final searchItem = find.text(SongActionsButton.searchLabel);
  final elsewhere = find.text('Elsewhere');

  /// Pumps the button over a song line, or over "Live" when [hasSong] is
  /// false, as the player does when the station named no song, with
  /// another button in a corner, away from the menu.
  Future<void> pumpButton(WidgetTester tester, {bool hasSong = true}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Center(
                child: SizedBox(
                  width: 300,
                  child: SongActionsButton(
                    onSearch: hasSong ? () => searches++ : null,
                    onCopy: hasSong ? () => copies++ : null,
                    onMenuOpened: () => menuOpens++,
                    child: const Text('Artist - Song'),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.topLeft,
                child: TextButton(
                  onPressed: () => elsewhereTaps++,
                  child: const Text('Elsewhere'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double textOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(of: song, matching: find.byType(AnimatedOpacity)),
      )
      .opacity;

  const bothPlatforms = TargetPlatformVariant(
    {TargetPlatform.iOS, TargetPlatform.android},
  );

  testWidgets('a tap searches the song without opening the menu',
      (tester) async {
    await pumpButton(tester);

    await tester.tap(song);
    await tester.pumpAndSettle();

    expect(searches, 1);
    expect(copyItem, findsNothing);
    expect(menuOpens, 0);
  }, variant: bothPlatforms);

  testWidgets('a long press opens the menu, whose copy copies the song',
      (tester) async {
    await pumpButton(tester);

    await tester.longPress(song);
    await tester.pumpAndSettle();

    expect(copyItem, findsOneWidget);
    expect(searchItem, findsOneWidget);
    expect(menuOpens, 1);
    expect(searches, 0, reason: 'the long press is not also a tap');

    await tester.tap(copyItem);
    await tester.pumpAndSettle();

    expect(copies, 1);
    expect(searches, 0);
    expect(copyItem, findsNothing);
  }, variant: bothPlatforms);

  testWidgets("the menu's search searches the song", (tester) async {
    await pumpButton(tester);

    await tester.longPress(song);
    await tester.pumpAndSettle();
    await tester.tap(searchItem);
    await tester.pumpAndSettle();

    expect(searches, 1);
    expect(copies, 0);
    expect(searchItem, findsNothing);
  }, variant: bothPlatforms);

  testWidgets('the text stays dimmed while the menu is open', (tester) async {
    await pumpButton(tester);

    await tester.longPress(song);
    await tester.pumpAndSettle();
    expect(textOpacity(tester), 0.5);

    // A tap outside closes the menu and goes no further.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(copyItem, findsNothing);
    expect(textOpacity(tester), 1);
  }, variant: bothPlatforms);

  testWidgets('a tap on the song while the menu is open only closes it',
      (tester) async {
    await pumpButton(tester);
    await tester.longPress(song);
    await tester.pumpAndSettle();
    expect(copyItem, findsOneWidget);

    await tester.tap(song);
    await tester.pumpAndSettle();

    expect(copyItem, findsNothing);
    expect(searches, 0);
    expect(textOpacity(tester), 1);

    // With the menu closed, a tap searches again.
    await tester.tap(song);
    await tester.pumpAndSettle();
    expect(searches, 1);
  }, variant: bothPlatforms);

  testWidgets('a tap elsewhere while the menu is open only closes it',
      (tester) async {
    await pumpButton(tester);
    await tester.longPress(song);
    await tester.pumpAndSettle();

    await tester.tap(elsewhere);
    await tester.pumpAndSettle();

    expect(copyItem, findsNothing);
    expect(elsewhereTaps, 0);
    expect(searches, 0);

    await tester.tap(elsewhere);
    expect(elsewhereTaps, 1);
  }, variant: bothPlatforms);

  for (final wait in const [0, 150, 400]) {
    testWidgets('a long press $wait ms after the menu closes opens it again',
        (tester) async {
      await pumpButton(tester);
      await tester.longPress(song);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(400, 590));
      await tester.pump();
      await tester.pump(Duration(milliseconds: wait));

      await tester.longPress(song);
      await tester.pumpAndSettle();

      expect(copyItem, findsOneWidget);
      expect(menuOpens, 2);
      expect(searches, 0);
    }, variant: bothPlatforms);
  }

  testWidgets(
      'on iOS, holding the song and sliding onto an option picks it on '
      'release', (tester) async {
    await pumpButton(tester);

    final gesture = await tester.startGesture(tester.getCenter(song));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(copyItem, findsOneWidget);

    final target = tester.getCenter(copyItem);
    final start = tester.getCenter(song);
    for (var step = 1; step <= 5; step++) {
      await gesture.moveTo(Offset.lerp(start, target, step / 5)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(copies, 1);
    expect(searches, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('without a song neither a tap nor a long press does anything',
      (tester) async {
    await pumpButton(tester, hasSong: false);

    await tester.tap(song, warnIfMissed: false);
    await tester.longPress(song, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(searches, 0);
    expect(menuOpens, 0);
    expect(copyItem, findsNothing);
    expect(textOpacity(tester), 1);
  }, variant: bothPlatforms);

  testWidgets('the menu closes when the song goes away', (tester) async {
    await pumpButton(tester);
    await tester.longPress(song);
    await tester.pumpAndSettle();
    expect(copyItem, findsOneWidget);

    await pumpButton(tester, hasSong: false);
    await tester.pumpAndSettle();

    expect(copyItem, findsNothing);
    expect(textOpacity(tester), 1);
  }, variant: bothPlatforms);

  testWidgets('screen readers hear the search and can copy the song',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpButton(tester);

    expect(
      tester.getSemantics(song),
      isSemantics(
        isButton: true,
        hint: SongActionsButton.searchLabel,
        hasTapAction: true,
        customActions: const [
          CustomSemanticsAction(label: SongActionsButton.copyLabel),
        ],
      ),
    );

    tester.semantics.customAction(
      find.semantics.byLabel('Artist - Song'),
      const CustomSemanticsAction(label: SongActionsButton.copyLabel),
    );
    expect(copies, 1);

    handle.dispose();
  });
}
