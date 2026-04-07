import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PromoNotification {
  final String id;
  final String title;
  final String message;
  final int minActions; // minimum user actions before showing

  const PromoNotification({
    required this.id,
    required this.title,
    required this.message,
    this.minActions = 0,
  });
}

class PromoNotificationService {
  static const String _dismissedKey = 'promo_notifications_dismissed';

  /// All registered notifications, in display order.
  /// Only one is shown per app session; dismissed ones are skipped.
  static const List<PromoNotification> _notifications = [
    PromoNotification(
      id: 'carplay_android_auto_v1',
      title: 'Ascultă Radio Creștin în mașină',
      message:
          'Conectează telefonul prin Apple CarPlay sau Android Auto și '
          'bucură-te de toate stațiile tale preferate pe drum.',
      minActions: 25,
    ),
  ];

  final SharedPreferences _prefs;

  PromoNotificationService(this._prefs);

  /// Returns the next notification that hasn't been dismissed and whose
  /// action threshold has been reached, or null.
  PromoNotification? getNextNotification() {
    final dismissed = _getDismissedIds();
    final actions = _getActionCount();
    for (final notification in _notifications) {
      if (dismissed.contains(notification.id)) continue;
      if (actions < notification.minActions) continue;
      return notification;
    }
    return null;
  }

  /// Mark a notification as dismissed so it won't show again.
  Future<void> dismiss(String notificationId) async {
    final dismissed = _getDismissedIds();
    dismissed.add(notificationId);
    await _prefs.setStringList(_dismissedKey, dismissed.toList());
  }

  Set<String> _getDismissedIds() {
    final list = _prefs.getStringList(_dismissedKey) ?? [];
    return list.toSet();
  }

  int _getActionCount() {
    final reviewStatusJson = _prefs.getString('_reviewStatus');
    if (reviewStatusJson == null) return 0;
    try {
      final status = json.decode(reviewStatusJson) as Map<String, dynamic>;
      return (status['actions_made'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
