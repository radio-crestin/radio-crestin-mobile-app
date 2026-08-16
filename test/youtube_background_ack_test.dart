import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/youtube_background_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('shouldShowYoutubeBackgroundWarning (one-time decision)', () {
    test('shows when not acknowledged and a YouTube item is playing', () {
      expect(
        shouldShowYoutubeBackgroundWarning(
            acknowledged: false, isYoutubePlaying: true),
        isTrue,
      );
    });

    test('never shows once acknowledged', () {
      expect(
        shouldShowYoutubeBackgroundWarning(
            acknowledged: true, isYoutubePlaying: true),
        isFalse,
      );
    });

    test('does not show when no YouTube item is playing', () {
      expect(
        shouldShowYoutubeBackgroundWarning(
            acknowledged: false, isYoutubePlaying: false),
        isFalse,
      );
    });
  });

  group('SharedPreferences acknowledgment persistence', () {
    test('defaults to not acknowledged', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(youtubeBackgroundWarningAcknowledged(prefs), isFalse);
    });

    test('acknowledge persists under the documented key', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await acknowledgeYoutubeBackgroundWarning(prefs);

      expect(youtubeBackgroundWarningAcknowledged(prefs), isTrue);
      expect(prefs.getBool(youtubeBackgroundWarningAckKey), isTrue);
    });

    test('reads a pre-existing acknowledged flag', () async {
      SharedPreferences.setMockInitialValues(
          {youtubeBackgroundWarningAckKey: true});
      final prefs = await SharedPreferences.getInstance();
      expect(youtubeBackgroundWarningAcknowledged(prefs), isTrue);
    });
  });

  group('showYoutubeBackgroundWarningDialog widget', () {
    testWidgets('shows the modal and acknowledges on confirm', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var acknowledgeCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showYoutubeBackgroundWarningDialog(
                    context,
                    onAcknowledge: () async {
                      acknowledgeCalls++;
                      await acknowledgeYoutubeBackgroundWarning(prefs);
                    },
                  ),
                  child: const Text('open'),
                ),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Dialog is visible with the Romanian copy + single confirm button.
      expect(find.text('Videoclipurile YouTube'), findsOneWidget);
      expect(find.text('Am înțeles'), findsOneWidget);

      await tester.tap(find.text('Am înțeles'));
      await tester.pumpAndSettle();

      // Dismissed, acknowledgment invoked once and persisted.
      expect(find.text('Am înțeles'), findsNothing);
      expect(acknowledgeCalls, 1);
      expect(youtubeBackgroundWarningAcknowledged(prefs), isTrue);
    });
  });
}
