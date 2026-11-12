import 'package:shared_preferences/shared_preferences.dart';

import 'announcements_service.dart';
import 'promo_notification_service.dart';

/// A card the home screen shows above the station list.
sealed class HomePromo {
  const HomePromo();
}

/// The card asking the user to share the app with friends.
class SharePromo extends HomePromo {
  const SharePromo();
}

/// A [PromoNotification] card, such as the CarPlay and Android Auto one.
class NotificationPromo extends HomePromo {
  const NotificationPromo(this.notification);

  final PromoNotification notification;
}

/// The announcements from the API, which take the slot whenever there
/// are any.
class AnnouncementPromo extends HomePromo {
  const AnnouncementPromo(this.announcements);

  final AnnouncementList announcements;
}

/// Picks the one promo card the home screen shows above the station list.
///
/// Two cards at once push the stations off the screen, so they take
/// turns: the card on screen stays until the user closes it, and the next
/// one waits [gapActions] more actions, so closing a card never brings
/// another one right away.
class HomePromoSlot {
  HomePromoSlot(this._prefs)
      : _notifications = PromoNotificationService(_prefs);

  /// User actions between closing one card and showing the next.
  static const int gapActions = 20;

  /// User actions after which the share card shows, once.
  static const int shareMinActions = 40;

  static const _shareOnKey = 'show_share_promotion';
  static const _shareAutoEnabledKey = 'share_promotion_auto_enabled';
  static const _closedAtKey = 'promo_card_closed_at_actions';

  final SharedPreferences _prefs;
  final PromoNotificationService _notifications;

  /// The card to show now, or null; turns the share card on when its
  /// turn comes.
  ///
  /// [announcements] from the API come first: they are what the team
  /// wants seen now. Otherwise a share card already on keeps the slot:
  /// users who had both cards keep the share card, which most of them got
  /// first, and see the other one after closing it.
  Future<HomePromo?> current({
    AnnouncementList announcements = AnnouncementList.empty,
  }) async {
    if (announcements.items.isNotEmpty) {
      return AnnouncementPromo(announcements);
    }
    if (_prefs.getBool(_shareOnKey) ?? false) return const SharePromo();
    final actions = _notifications.actionsMade;
    final closedAt = _prefs.getInt(_closedAtKey);
    if (closedAt != null && actions < closedAt + gapActions) return null;
    final notification = _notifications.getNextNotification();
    if (notification != null) return NotificationPromo(notification);
    final shareShown = _prefs.getBool(_shareAutoEnabledKey) ?? false;
    if (shareShown || actions < shareMinActions) return null;
    await _prefs.setBool(_shareOnKey, true);
    await _prefs.setBool(_shareAutoEnabledKey, true);
    return const SharePromo();
  }

  /// Hides [promo] for good and starts the wait before the next card.
  ///
  /// An [AnnouncementPromo] closes one announcement at a time, on the
  /// card; this only starts the wait once the last one is gone.
  Future<void> close(HomePromo promo) async {
    switch (promo) {
      case AnnouncementPromo():
        break;
      case SharePromo():
        await _prefs.setBool(_shareOnKey, false);
      case NotificationPromo(:final notification):
        await _notifications.dismiss(notification.id);
    }
    await _prefs.setInt(_closedAtKey, _notifications.actionsMade);
  }
}
