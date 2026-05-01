import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/promo_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PromoNotificationService', () {
    late SharedPreferences prefs;

    Future<PromoNotificationService> build({
      Map<String, Object> initial = const {},
    }) async {
      SharedPreferences.setMockInitialValues(initial);
      prefs = await SharedPreferences.getInstance();
      return PromoNotificationService(prefs);
    }

    String reviewStatus(int actionsMade) =>
        json.encode({'actions_made': actionsMade});

    test('returns null when no review actions have been made', () async {
      final service = await build();
      expect(service.getNextNotification(), isNull);
    });

    test('returns null when actions count is below minActions threshold',
        () async {
      final service = await build(initial: {
        '_reviewStatus': reviewStatus(24),
      });
      expect(service.getNextNotification(), isNull);
    });

    test('returns the carplay notification once threshold is reached',
        () async {
      final service = await build(initial: {
        '_reviewStatus': reviewStatus(25),
      });
      final notification = service.getNextNotification();
      expect(notification, isNotNull);
      expect(notification!.id, 'carplay_android_auto_v1');
      expect(notification.title, contains('Radio Creștin'));
      expect(notification.minActions, 25);
    });

    test('dismissed notification is skipped even when threshold met', () async {
      final service = await build(initial: {
        '_reviewStatus': reviewStatus(100),
        'promo_notifications_dismissed': <String>['carplay_android_auto_v1'],
      });
      expect(service.getNextNotification(), isNull);
    });

    test('dismiss() persists the id to SharedPreferences', () async {
      final service = await build(initial: {
        '_reviewStatus': reviewStatus(100),
      });

      // Initially returned
      expect(service.getNextNotification()?.id, 'carplay_android_auto_v1');

      await service.dismiss('carplay_android_auto_v1');

      // Now suppressed for the same instance
      expect(service.getNextNotification(), isNull);

      // And persisted
      expect(
        prefs.getStringList('promo_notifications_dismissed'),
        contains('carplay_android_auto_v1'),
      );
    });

    test('dismiss() is idempotent — same id added once only', () async {
      final service = await build(initial: {
        '_reviewStatus': reviewStatus(100),
        'promo_notifications_dismissed': <String>['carplay_android_auto_v1'],
      });

      await service.dismiss('carplay_android_auto_v1');

      final stored = prefs.getStringList('promo_notifications_dismissed') ?? [];
      // Set semantics — only one entry
      expect(stored.where((id) => id == 'carplay_android_auto_v1').length, 1);
    });

    test('action count survives malformed review status JSON', () async {
      final service = await build(initial: {
        '_reviewStatus': 'not-a-json-string',
      });
      // Should fall through to 0, hence below threshold => null
      expect(service.getNextNotification(), isNull);
    });

    test('action count handles missing actions_made key', () async {
      final service = await build(initial: {
        '_reviewStatus': json.encode({'something_else': 5}),
      });
      expect(service.getNextNotification(), isNull);
    });
  });

  group('PromoNotification model', () {
    test('default minActions is 0', () {
      const n = PromoNotification(id: 'x', title: 't', message: 'm');
      expect(n.minActions, 0);
    });

    test('stores all fields', () {
      const n = PromoNotification(
        id: 'id',
        title: 'T',
        message: 'M',
        minActions: 7,
      );
      expect(n.id, 'id');
      expect(n.title, 'T');
      expect(n.message, 'M');
      expect(n.minActions, 7);
    });
  });
}
