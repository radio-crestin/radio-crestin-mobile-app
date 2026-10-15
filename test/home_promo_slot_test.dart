import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/home_promo_slot.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const carPlayId = 'carplay_android_auto_v1';
  const gap = HomePromoSlot.gapActions;

  late SharedPreferences prefs;

  String reviewStatus(int actionsMade) =>
      json.encode({'actions_made': actionsMade});

  Future<HomePromoSlot> build(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    prefs = await SharedPreferences.getInstance();
    return HomePromoSlot(prefs);
  }

  Future<void> setActions(int actionsMade) =>
      prefs.setString('_reviewStatus', reviewStatus(actionsMade));

  Matcher isCarPlay() => isA<NotificationPromo>().having(
      (promo) => promo.notification.id, 'notification id', carPlayId);

  test('shows no card before the CarPlay card is due', () async {
    final slot = await build({'_reviewStatus': reviewStatus(24)});
    expect(await slot.current(), isNull);
  });

  test('shows the CarPlay card once it is due', () async {
    final slot = await build({'_reviewStatus': reviewStatus(25)});
    expect(await slot.current(), isCarPlay());
  });

  test('keeps the CarPlay card alone past the share card threshold',
      () async {
    final slot = await build({'_reviewStatus': reviewStatus(25)});
    await slot.current();

    await setActions(HomePromoSlot.shareMinActions + 30);

    expect(await slot.current(), isCarPlay());
    expect(prefs.getBool('show_share_promotion'), isNull);
  });

  test('a share card already on keeps the slot over the CarPlay card',
      () async {
    final slot = await build({
      '_reviewStatus': reviewStatus(100),
      'show_share_promotion': true,
      'share_promotion_auto_enabled': true,
    });
    expect(await slot.current(), isA<SharePromo>());
  });

  test('the share card waits the gap after the CarPlay card is closed',
      () async {
    final slot = await build({'_reviewStatus': reviewStatus(30)});
    await slot.close((await slot.current())!);

    await setActions(30 + gap - 1);
    expect(await slot.current(), isNull);

    await setActions(30 + gap);
    expect(await slot.current(), isA<SharePromo>());
    expect(prefs.getBool('show_share_promotion'), isTrue);
    expect(prefs.getBool('share_promotion_auto_enabled'), isTrue);
  });

  test('the share card waits for its own threshold after the gap', () async {
    final slot = await build({
      '_reviewStatus': reviewStatus(25),
      'promo_notifications_dismissed': <String>[carPlayId],
      'promo_card_closed_at_actions': 5,
    });
    expect(await slot.current(), isNull);

    await setActions(HomePromoSlot.shareMinActions);
    expect(await slot.current(), isA<SharePromo>());
  });

  test('the CarPlay card waits the gap after the share card is closed',
      () async {
    final slot = await build({
      '_reviewStatus': reviewStatus(100),
      'show_share_promotion': true,
      'share_promotion_auto_enabled': true,
    });
    await slot.close(const SharePromo());
    expect(prefs.getBool('show_share_promotion'), isFalse);

    await setActions(100 + gap - 1);
    expect(await slot.current(), isNull);

    await setActions(100 + gap);
    expect(await slot.current(), isCarPlay());
  });

  test('closing the CarPlay card dismisses it for good', () async {
    final slot = await build({'_reviewStatus': reviewStatus(30)});
    final promo = await slot.current();
    await slot.close(promo!);

    expect(prefs.getStringList('promo_notifications_dismissed'),
        contains(carPlayId));
    expect(prefs.getInt('promo_card_closed_at_actions'), 30);
  });

  test('the share card shows only once', () async {
    final slot = await build({
      '_reviewStatus': reviewStatus(200),
      'promo_notifications_dismissed': <String>[carPlayId],
      'show_share_promotion': false,
      'share_promotion_auto_enabled': true,
    });
    expect(await slot.current(), isNull);
  });

  test('a card closed before the gap existed lets the next one show',
      () async {
    final slot = await build({
      '_reviewStatus': reviewStatus(41),
      'promo_notifications_dismissed': <String>[carPlayId],
    });
    expect(await slot.current(), isA<SharePromo>());
  });
}
