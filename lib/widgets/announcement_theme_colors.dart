import 'package:flutter/material.dart';

import '../services/announcement.dart';
import '../theme.dart';

/// An announcement's colors: the admin's when set, otherwise the app's own
/// in this theme (the announcements spec, "Default colors come from each
/// client's theme").
extension AnnouncementThemeColors on ThemeData {
  /// The card's accent (icon tile, links, the page's quote bar): the
  /// button's color, else the category's, else the app's.
  Color announcementAccent(Announcement item) =>
      item.button?.color ?? item.category.color ?? AppColors.announcementButton;

  /// A button's fill.
  Color announcementButtonColor(AnnouncementButton button) =>
      button.color ?? AppColors.announcementButton;

  /// A button's label: the admin's, readable on the admin's fill, or the
  /// app's on its own fill.
  Color announcementButtonLabel(AnnouncementButton button) {
    final color = button.color;
    return button.textColor ??
        (color == null ? AppColors.announcementButtonLabel : readableOn(color));
  }

  /// A category tag's fill: the mini player's color when none is set.
  Color announcementTagColor(AnnouncementCategory category) =>
      category.color ?? bottomAppBarTheme.color ?? AppColors.primaryDark;

  /// A category tag's text.
  Color announcementTagLabel(AnnouncementCategory category) {
    final color = category.color;
    return category.textColor ??
        (color == null ? AppColors.announcementTagLabel : readableOn(color));
  }
}
