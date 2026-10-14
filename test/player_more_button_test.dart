import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/player_more_button.dart';

void main() {
  const history = PlayerMoreButton.historyLabel;
  const youtube = PlayerMoreButton.youtubeLabel;

  late int opened;
  late int historyTaps;
  late int youtubeTaps;

  setUp(() {
    opened = 0;
    historyTaps = 0;
    youtubeTaps = 0;
  });

  /// Pumps the button where the player has it: the last quarter of a row at
  /// the bottom of a phone screen.
  Future<void> pumpButton(
    WidgetTester tester, {
    required TargetPlatform platform,
    bool canSearchYoutube = true,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 8, 58),
              child: SizedBox(
                width: 94,
                child: PlayerMoreButton(
                  onOpened: () => opened++,
                  onHistory: () => historyTaps++,
                  onYoutubeSearch: canSearchYoutube ? () => youtubeTaps++ : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.text('mai mult'));
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group('on ${platform.name}', () {
      testWidgets('opens a menu with the history and the YouTube search',
          (tester) async {
        await pumpButton(tester, platform: platform);
        expect(find.text(history), findsNothing);

        await openMenu(tester);

        expect(find.text(history), findsOneWidget);
        expect(find.text(youtube), findsOneWidget);
        expect(opened, 1);
      });

      testWidgets('the menu rises above the button, ending where it ends',
          (tester) async {
        await pumpButton(tester, platform: platform);
        await openMenu(tester);

        final button = tester.getRect(find.byType(PlayerMoreButton));
        final lastItem = tester.getRect(find.text(youtube));
        expect(lastItem.bottom, lessThanOrEqualTo(button.top));
        expect(lastItem.right, lessThanOrEqualTo(button.right));
        // Nearer the button's trailing edge than its leading one.
        expect(lastItem.right, greaterThan(button.center.dx));
      });

      testWidgets('an item runs its action and closes the menu',
          (tester) async {
        await pumpButton(tester, platform: platform);
        await openMenu(tester);

        await tester.tap(find.text(history));
        await tester.pumpAndSettle();

        expect(historyTaps, 1);
        expect(find.text(history), findsNothing);

        await openMenu(tester);
        await tester.tap(find.text(youtube));
        await tester.pumpAndSettle();

        expect(youtubeTaps, 1);
        expect(find.text(youtube), findsNothing);
      });

      testWidgets('a second tap on the button closes the menu',
          (tester) async {
        await pumpButton(tester, platform: platform);
        await openMenu(tester);

        await tester.tap(find.text('mai mult'));
        await tester.pumpAndSettle();

        expect(find.text(history), findsNothing);
        expect(opened, 1);
      });

      testWidgets('the YouTube search is disabled without a song',
          (tester) async {
        await pumpButton(tester, platform: platform, canSearchYoutube: false);
        await openMenu(tester);

        await tester.tap(find.text(youtube), warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(youtubeTaps, 0);
        expect(find.text(youtube), findsOneWidget);
      });
    });
  }
}
