import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

      test('marks rating dialog as shown at interval 20', () async {
        SharedPreferences.setMockInitialValues({
          '_reviewStatus': json.encode({
            'actions_made': 19,
            'review_completed': false,
          }),
        });

        await Utils.incrementActionsMade();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('rating_dialog_shown_at_20'), true);
      });
    });

    group('resetDialogTracking', () {
      test('removes rating dialog flags', () async {
        SharedPreferences.setMockInitialValues({
          'rating_dialog_shown_at_20': true,
          'rating_dialog_shown_at_100': true,
          'rating_dialog_shown_at_200': true,
          'rating_dialog_shown_at_400': true,
        });

        await Utils.resetDialogTracking();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('rating_dialog_shown_at_20'), isNull);
        expect(prefs.getBool('rating_dialog_shown_at_100'), isNull);
        expect(prefs.getBool('rating_dialog_shown_at_200'), isNull);
        expect(prefs.getBool('rating_dialog_shown_at_400'), isNull);
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
          'rating_dialog_shown_at_100': false,
        });

        final status = await Utils.getDialogTrackingStatus();
        final ratingDialogs = status['rating_dialogs_shown'] as Map<int, bool>;
        expect(ratingDialogs[20], true);
        expect(ratingDialogs[100], false);
        expect(ratingDialogs[200], false);
        expect(ratingDialogs[400], false);
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
