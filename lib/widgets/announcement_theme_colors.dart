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

  /// The announcement's hue for its icon tile and tag: the button's color,
  /// else the category's (spec: "Accent hue on the icon tile and tag").
  /// Null keeps both neutral.
  Color? announcementHue(Announcement item) =>
      item.button?.color ?? item.category.color;

  /// The card's surface, behind the tile and the tag.
  Color get announcementCardSurface =>
      Color.alphaBlend(cardColor, scaffoldBackgroundColor);

  bool get _isDark => brightness == Brightness.dark;

  /// A soft tint of [hue]: the icon tile's and the tag's fill.
  Color _tint(Color hue) => hue.withValues(alpha: _isDark ? 0.16 : 0.12);

  /// The icon tile's fill: a soft tint of the hue, or the neutral control
  /// surface.
  Color announcementIconTileColor(Announcement item) {
    final hue = announcementHue(item);
    return hue == null ? announcementColors.control : _tint(hue);
  }

  /// The icon tile's outline: the hue, faint, or the neutral border.
  Color announcementIconTileBorder(Announcement item) {
    final hue = announcementHue(item);
    if (hue == null) return announcementColors.border;
    return hue.withValues(alpha: _isDark ? 0.3 : 0.25);
  }

  /// The glyph on the icon tile: the hue, lighter in dark and darker in
  /// light, or secondary text.
  Color announcementGlyphColor(Announcement item) {
    final hue = announcementHue(item);
    if (hue == null) return announcementColors.muted;
    return _isDark
        ? Color.lerp(hue, Colors.white, 0.35)!
        : Color.lerp(hue, Colors.black, 0.45)!;
  }

  /// A tag's fill: the same tint as the icon tile, or the neutral control
  /// surface.
  Color announcementTagColor(Announcement item) {
    final hue = announcementHue(item);
    return hue == null ? announcementColors.control : _tint(hue);
  }

  /// A tag's text: the hue mixed half with white in dark and 55% with
  /// black in light, then further until it reads at AA (4.5:1) on its fill
  /// over [surface] (the card's, unless given); secondary text without a
  /// hue.
  Color announcementTagLabel(Announcement item, {Color? surface}) {
    final hue = announcementHue(item);
    if (hue == null) return announcementColors.muted;
    final background = Color.alphaBlend(
        _tint(hue), surface ?? announcementCardSurface);
    final toward = _isDark ? Colors.white : Colors.black;
    var mix = _isDark ? 0.5 : 0.55;
    var label = Color.lerp(hue, toward, mix)!;
    while (contrastRatio(label, background) < minTextContrast && mix < 1) {
      mix = (mix + 0.05).clamp(0, 1);
      label = Color.lerp(hue, toward, mix)!;
    }
    return label;
  }
}

/// WCAG's AA minimum for body text.
const double minTextContrast = 4.5;

/// WCAG's contrast ratio between two opaque colors, 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final (light, dark) = la > lb ? (la, lb) : (lb, la);
  return (light + 0.05) / (dark + 0.05);
}
