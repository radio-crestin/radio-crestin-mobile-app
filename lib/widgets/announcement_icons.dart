import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../services/announcement.dart';

/// The glyphs of the announcements spec's icon names, for the card's tile
/// and for a button's chosen icon.
final Map<String, IconData> announcementIcons = {
  'whatsapp': FontAwesomeIcons.whatsapp.data,
  'calendar': Icons.event_rounded,
  'car': Icons.directions_car_outlined,
  'megaphone': Icons.campaign_outlined,
  'gift': Icons.card_giftcard_rounded,
  'heart': Icons.favorite_border_rounded,
  'bible': FontAwesomeIcons.bookBible.data,
  'info': Icons.info_outline_rounded,
  'warning': Icons.warning_amber_rounded,
  'play': Icons.play_arrow_rounded,
  'star': Icons.star_outline_rounded,
  'bell': Icons.notifications_none_rounded,
};

/// The icon a button shows after its label: the one chosen, or with
/// `auto` the one that says what the tap does (↗ leaves the app, › opens a
/// page, a window opens the in-app browser, ▶ plays a station).
IconData? announcementButtonIcon(AnnouncementButton button) =>
    switch (button.icon) {
      'none' => null,
      'auto' => actionIcon(button.action.type),
      final name => announcementIcons[name] ?? actionIcon(button.action.type),
    };

IconData? actionIcon(AnnouncementActionType type) => switch (type) {
      AnnouncementActionType.external ||
      AnnouncementActionType.androidIntent =>
        Icons.north_east_rounded,
      AnnouncementActionType.page ||
      AnnouncementActionType.form =>
        Icons.chevron_right_rounded,
      AnnouncementActionType.inAppBrowser => Icons.web_asset_rounded,
      AnnouncementActionType.station => Icons.play_arrow_rounded,
      AnnouncementActionType.none => null,
    };

/// A FontAwesome glyph is drawn larger than a Material one of the same
/// size; this scales it back so both look alike.
double announcementIconScale(IconData icon) =>
    icon.fontFamily == Icons.add.fontFamily ? 1 : 0.86;
