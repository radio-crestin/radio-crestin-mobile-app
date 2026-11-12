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

  /// A category tag's fill: quiet, as the button is the card's one accent
  /// (spec: "Color hierarchy by importance"). A faint tint of the
  /// category's color, or the neutral control surface when it has none.
  Color announcementTagColor(AnnouncementCategory category) {
    final color = category.color;
    if (color == null) return announcementColors.control;
    final alpha = brightness == Brightness.dark ? 0.2 : 0.14;
    return color.withValues(alpha: alpha);
  }

  /// A category tag's text: the category's color made readable on its
  /// tint, or secondary text when it has none.
  Color announcementTagLabel(AnnouncementCategory category) {
    final color = category.color;
    final colors = announcementColors;
    if (color == null) return colors.muted;
    return colors.isDark
        ? colors.inkOf(color)
        : Color.lerp(color, colors.strong, 0.25)!;
  }

  /// The icon tile's fill: the neutral control surface, faintly tinted by
  /// an explicit category color.
  Color announcementIconTileColor(AnnouncementCategory category) {
    final color = category.color;
    return color == null
        ? announcementColors.control
        : color.withValues(alpha: 0.1);
  }
}
