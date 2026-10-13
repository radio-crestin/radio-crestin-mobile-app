import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/globals.dart';
import 'package:radio_crestin/utils.dart';

void main() {
  group('Dialog tracking', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    group('incrementActionsMade', () {
      test('increments actions_made counter', () async {
        SharedPreferences.setMockInitialValues({
          '_reviewStatus': json.encode({'actions_made': 5}),
        });

        await Utils.incrementActionsMade();

        final prefs = await SharedPreferences.getInstance();
        final status = json.decode(prefs.getString('_reviewStatus')!);
        expect(status['actions_made'], 6);
      });

      test('starts from 0 when actions_made is not set', () async {
        SharedPreferences.setMockInitialValues({
          '_reviewStatus': json.encode({}),
        });

        await Utils.incrementActionsMade();

        final prefs = await SharedPreferences.getInstance();
        final status = json.decode(prefs.getString('_reviewStatus')!);
        expect(status['actions_made'], 1);
      });

      test('does nothing when no review status exists', () async {
        SharedPreferences.setMockInitialValues({});

        // Should not crash
        await Utils.incrementActionsMade();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('_reviewStatus'), isNull);
      });

      test('does not show dialog when review is completed', () async {
        SharedPreferences.setMockInitialValues({
          '_reviewStatus': json.encode({
            'actions_made': 19,
            'review_completed': true,
          }),
        });

        await Utils.incrementActionsMade();

        final prefs = await SharedPreferences.getInstance();
        // Rating dialog should not be triggered
        expect(prefs.getBool('rating_dialog_shown_at_20'), isNull);
      });

    });

    group('review dialog thresholds', () {
      const dialogTitle = 'Lasă-ne un review de 5 stele';

      Future<void> pumpHome(WidgetTester tester) => tester.pumpWidget(
            MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
          );

      void seedActions(int actionsMade, {Map<String, Object> extra = const {}}) {
        SharedPreferences.setMockInitialValues({
          '_reviewStatus': json.encode({
            'actions_made': actionsMade,
            'review_completed': false,
          }),
          ...extra,
        });
      }

      test('are 20, 80, 200, 400, 700 and 1000', () {
        expect(Utils.reviewDialogThresholds, [20, 80, 200, 400, 700, 1000]);
      });

      testWidgets('shows the dialog when the count reaches 20',
          (tester) async {
        seedActions(19);
        await pumpHome(tester);

        await Utils.incrementActionsMade();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('rating_dialog_shown_at_20'), true);
        expect(find.text(dialogTitle), findsOneWidget);
      });

      testWidgets('shows nothing between thresholds', (tester) async {
        seedActions(20, extra: {'rating_dialog_shown_at_20': true});
        await pumpHome(tester);

        await Utils.incrementActionsMade();
        await tester.pump(const Duration(seconds: 3));

        expect(find.text(dialogTitle), findsNothing);
      });

      testWidgets('keeps the threshold pending without a screen',
          (tester) async {
        // Android Auto's headless engine has no navigator.
        seedActions(19);

        await Utils.incrementActionsMade();
        await tester.pump(const Duration(seconds: 3));

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('rating_dialog_shown_at_20'), isNull);

        await pumpHome(tester);
        await Utils.incrementActionsMade();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        expect(prefs.getBool('rating_dialog_shown_at_20'), true);
        expect(find.text(dialogTitle), findsOneWidget);
      });

      testWidgets('waits while another route is on top', (tester) async {
        seedActions(19);
        await pumpHome(tester);
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        );
        await tester.pumpAndSettle();

        await Utils.incrementActionsMade();
        await tester.pump(const Duration(seconds: 3));

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('rating_dialog_shown_at_20'), isNull);
        expect(find.text(dialogTitle), findsNothing);
      });

      testWidgets('marks every reached threshold but shows one dialog',
          (tester) async {
        // A user updating with a count from the old thresholds.
        seedActions(999, extra: {'rating_dialog_shown_at_20': true});
        await pumpHome(tester);

        await Utils.incrementActionsMade();
        await Utils.incrementActionsMade();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        for (final threshold in Utils.reviewDialogThresholds) {
          expect(prefs.getBool('rating_dialog_shown_at_$threshold'), true);
        }
        expect(find.byType(AlertDialog), findsOneWidget);
      });

      testWidgets('never shows past 1000', (tester) async {
        seedActions(1500, extra: {
          for (final threshold in Utils.reviewDialogThresholds)
            'rating_dialog_shown_at_$threshold': true,
        });
        await pumpHome(tester);

        await Utils.incrementActionsMade();
        await tester.pump(const Duration(seconds: 3));

        expect(find.text(dialogTitle), findsNothing);
      });
    });

    group('resetDialogTracking', () {
      test('removes rating dialog flags', () async {
        SharedPreferences.setMockInitialValues({
          for (final threshold in Utils.reviewDialogThresholds)
            'rating_dialog_shown_at_$threshold': true,
        });

        await Utils.resetDialogTracking();

        final prefs = await SharedPreferences.getInstance();
        for (final threshold in Utils.reviewDialogThresholds) {
          expect(prefs.getBool('rating_dialog_shown_at_$threshold'), isNull);
        }
      });

      test('removes share dialog flags', () async {
        SharedPreferences.setMockInitialValues({
          'share_dialog_shown_at_40': true,
          'share_dialog_shown_at_150': true,
        });

        await Utils.resetDialogTracking();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('share_dialog_shown_at_40'), isNull);
        expect(prefs.getBool('share_dialog_shown_at_150'), isNull);
      });

      test('removes cancellation tracking from review status', () async {
        SharedPreferences.setMockInitialValues({
          '_reviewStatus': json.encode({
            'actions_made': 50,
            'last_rating_dialog_canceled': true,
            'last_rating_dialog_canceled_at': '2024-01-01',
          }),
        });

        await Utils.resetDialogTracking();

        final prefs = await SharedPreferences.getInstance();
        final status = json.decode(prefs.getString('_reviewStatus')!);
        expect(status['last_rating_dialog_canceled'], isNull);
        expect(status['last_rating_dialog_canceled_at'], isNull);
        expect(status['actions_made'], 50); // Preserved
      });
    });

    group('getDialogTrackingStatus', () {
      test('returns empty map when no data', () async {
        final status = await Utils.getDialogTrackingStatus();
        // Should have rating_dialogs_shown and share_dialogs_shown at minimum
        expect(status['rating_dialogs_shown'], isNotNull);
        expect(status['share_dialogs_shown'], isNotNull);
      });

      test('returns review status fields', () async {
        SharedPreferences.setMockInitialValues({
          '_reviewStatus': json.encode({
            'review_completed': true,
            'actions_made': 200,
            'last_rating_dialog_canceled': false,
          }),
        });

        final status = await Utils.getDialogTrackingStatus();
        expect(status['review_completed'], true);
        expect(status['actions_made'], 200);
        expect(status['last_rating_dialog_canceled'], false);
      });

      test('returns which rating dialogs have been shown', () async {
        SharedPreferences.setMockInitialValues({
          'rating_dialog_shown_at_20': true,
          'rating_dialog_shown_at_80': false,
        });

        final status = await Utils.getDialogTrackingStatus();
        final ratingDialogs = status['rating_dialogs_shown'] as Map<int, bool>;
        expect(ratingDialogs.keys, Utils.reviewDialogThresholds);
        expect(ratingDialogs[20], true);
        expect(ratingDialogs[80], false);
        expect(ratingDialogs[1000], false);
      });

      test('returns which share dialogs have been shown', () async {
        SharedPreferences.setMockInitialValues({
          'share_dialog_shown_at_40': true,
        });

        final status = await Utils.getDialogTrackingStatus();
        final shareDialogs = status['share_dialogs_shown'] as Map<int, bool>;
        expect(shareDialogs[40], true);
        expect(shareDialogs[150], false);
      });
    });
  });
}
