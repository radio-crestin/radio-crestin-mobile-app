import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/song_search_tip.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SongSearchTipMemory', () {
    /// Preferences as the app keeps them, with [actions] user actions made.
    void setActions(int actions) => SharedPreferences.setMockInitialValues({
          '_reviewStatus': jsonEncode({
            'review_completed': false,
            'actions_made': actions,
          }),
        });

    test('is not due before the user made a few actions', () async {
      setActions(SongSearchTipMemory.minActions - 1);

      expect(await SongSearchTipMemory.isDue(), isFalse);
    });

    test('is not due without an actions count', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await SongSearchTipMemory.isDue(), isFalse);
    });

    test('is due from the threshold until it is marked seen', () async {
      setActions(SongSearchTipMemory.minActions);
      expect(await SongSearchTipMemory.isDue(), isTrue);

      await SongSearchTipMemory.markSeen();

      expect(await SongSearchTipMemory.isDue(), isFalse);
    });

    test('is due at once for a long-time user', () async {
      setActions(350);

      expect(await SongSearchTipMemory.isDue(), isTrue);
    });
  });

  group('SongSearchTip', () {
    late int dismissals;
    late int outsideTaps;

    setUp(() {
      dismissals = 0;
      outsideTaps = 0;
    });

    /// Pumps the tip over a song line in the middle of the screen, with a
    /// button below it to tap outside the bubble.
    Future<void> pumpTip(WidgetTester tester, {required bool visible}) {
      return tester.pumpWidget(
        MaterialApp(
          theme: darkTheme,
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SongSearchTip(
                  visible: visible,
                  onDismiss: () => dismissals++,
                  child: const Text('Casa mea'),
                ),
                const SizedBox(height: 40),
                TextButton(
                  onPressed: () => outsideTaps++,
                  child: const Text('alt buton'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('shows the bubble above the song only while visible',
        (tester) async {
      await pumpTip(tester, visible: false);
      expect(find.text(SongSearchTip.title), findsNothing);

      await pumpTip(tester, visible: true);
      await tester.pumpAndSettle();
      expect(find.text(SongSearchTip.title), findsOneWidget);
      expect(
        tester.getRect(find.text(SongSearchTip.dismissLabel)).bottom,
        lessThan(tester.getRect(find.text('Casa mea')).top),
      );

      await pumpTip(tester, visible: false);
      await tester.pumpAndSettle();
      expect(find.text(SongSearchTip.title), findsNothing);
    });

    testWidgets('"Am înțeles" dismisses it', (tester) async {
      await pumpTip(tester, visible: true);
      await tester.pumpAndSettle();

      await tester.tap(find.text(SongSearchTip.dismissLabel));

      expect(dismissals, greaterThanOrEqualTo(1));
    });

    testWidgets('a tap outside dismisses it and still reaches its target',
        (tester) async {
      await pumpTip(tester, visible: true);
      await tester.pumpAndSettle();

      await tester.tap(find.text('alt buton'));

      expect(dismissals, 1);
      expect(outsideTaps, 1);
    });
  });
}
