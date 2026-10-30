import 'package:flutter/material.dart';

import 'tv_platform.dart';

/// TV/Desktop design tokens following Android TV design guidelines.
/// Design base: 960×540dp (MDPI), scaled to 1080p.
/// On desktop, reduced overscan margins since monitors don't clip edges.
class TvColors {
  // Brand
  static const Color primary = Color(0xFFE91E63);
  static const Color primaryLight = Color(0xFFF8BBD0);
  static const Color primaryDark = Color(0xFF8F0133);

  // Surfaces - dark only for TV (power efficient, better contrast)
  static const Color background = Color(0xFF0A0A0A);
  static const Color surface = Color(0xFF1A1A1A);
  static const Color surfaceVariant = Color(0xFF252525);
  static const Color surfaceHigh = Color(0xFF2C2C2C);

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB3FFFFFF); // 70%
  static const Color textTertiary = Color(0x80FFFFFF); // 50%

  // Focus
  static const Color focusBorder = primary;
  static const Color focusGlow = Color(0x40E91E63); // 25% primary

  // States
  static const Color success = Color(0xFF4CAF50);
  static const Color offline = Color(0xFFEF5350);
  static const Color divider = Color(0x1AFFFFFF); // 10%
}

/// TV/Desktop spacing following Android TV layout grid.
/// Grid: 12 columns × 52dp + 20dp gutters + 58dp margins = 960dp.
/// Desktop uses smaller margins since monitors don't have overscan.
class TvSpacing {
  // Safe area margins — smaller on desktop (no overscan)
  static double get marginHorizontal => TvPlatform.isDesktop ? 24.0 : 48.0;
  static double get marginVertical => TvPlatform.isDesktop ? 12.0 : 27.0;

  // Grid
  static const double gutter = 20.0;
  static const double columnWidth = 52.0;

  // Component spacing
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;

  // Card sizes
  static const double stationCardWidth = 196.0;
  static const double stationCardHeight = 196.0; // 1:1 for radio logos
  static const double wideCardWidth = 268.0;
  static const double wideCardHeight = 151.0; // 16:9

  // Focus scale
  static const double focusScale = 1.05;
  static const double focusScaleLarge = 1.08;

  // Navigation drawer
  static const double drawerCollapsedWidth = 56.0;
  static const double drawerExpandedWidth = 220.0;

  // Mini player
  static const double miniPlayerHeight = 72.0;

  // Border radius
  static const double radiusSm = 8.0;
  static const double radiusMd = 12.0;
  static const double radiusLg = 16.0;
}

/// Shared header band used by both the left rail (brand mark) and the
/// browse pane (category selector) so they sit on the same baseline and
/// stay pinned at the top while the grid scrolls underneath.
class TvHeaderBar {
  static const double height = 64.0;
}

/// Design tokens of the desktop (macOS, Windows, Linux) browse screen.
///
/// Desktop only: Android TV never reads them. The screen shares
/// [TvColors] and [TvTypography] with TV and adds these on top for a
/// mouse-and-keyboard layout read from up close.
class DesktopTokens {
  DesktopTokens._();

  /// Space between the window's edges and the content.
  static const double gutter = 24;

  /// Height of the row of categories under the top bar.
  static const double categoryBarHeight = 52;

  /// Height of a section's header ("Favorite", "Toate stațiile").
  static const double sectionHeaderHeight = 52;

  /// Space between the cards of the station grid, both ways.
  static const double gridSpacing = 16;

  /// The widest a card of the station grid gets: the grid adds a column
  /// rather than stretch its cards past it.
  static const double cardMaxWidth = 220;

  /// Padding inside a card, around its artwork and text.
  static const double cardPadding = 8;

  static const double cardRadius = 14;
  static const double artworkRadius = 10;

  /// The widest the search results get, centered in wider windows.
  static const double resultsMaxWidth = 880;

  /// Height of a search result row.
  static const double resultRowHeight = 68;

  /// Height of the mini player bar, its margins left out.
  static const double miniPlayerHeight = 72;

  /// Duration of hover, focus and selection changes.
  static const Duration hoverDuration = Duration(milliseconds: 150);

  /// Duration of content changes (song lines, artwork, sections).
  static const Duration contentDuration = Duration(milliseconds: 250);

  /// How long the pointer rests on a control before its tooltip shows: long
  /// enough that tooltips don't flicker up while the pointer passes by.
  static const Duration tooltipWait = Duration(seconds: 2);

  /// The playing station's card or row: the brand pink at 12%.
  static const Color playingFill = Color(0x1FE91E63);

  /// The playing station's card outline: the brand pink at 45%.
  static const Color playingOutline = Color(0x73E91E63);

  /// Keyboard focus ring.
  static const Color focusRing = Color(0xFFF48FB1);

  /// Text on the playing station's card: pale pink, legible on the tint.
  static const Color playingText = TvColors.primaryLight;

  /// Fill of the search field, chips and small buttons at rest.
  static const Color controlFill = Color(0x0FFFFFFF);

  /// Fill of the search field, chips and small buttons under the pointer.
  static const Color controlHoverFill = Color(0x1AFFFFFF);

  /// Hairline around raised surfaces (menus, the mini player, chips).
  static const Color hairline = Color(0x14FFFFFF);

  /// Background of menus and the mini player.
  static const Color raisedSurface = Color(0xFF1C1C1E);

  /// A station's listeners dot while it is up.
  static const Color online = Color(0xFF4ADE80);

  /// The "possibly unavailable" line of a station that is down.
  static const Color warning = Color(0xFFF87171);

  /// The star of a station's rating, as on the phone.
  static const Color rating = Color(0xFFED8A19);

  /// The "Pentru tine" sort's icon, as on the phone.
  static const Color recommended = Color(0xFFF59E0B);
}

/// TV-specific typography - larger sizes for 10ft viewing distance.
/// Uses Roboto (Material default) for legibility on TV.
class TvTypography {
  static const TextStyle displayLarge = TextStyle(
    fontSize: 40,
    fontWeight: FontWeight.bold,
    color: TvColors.textPrimary,
    height: 1.2,
    letterSpacing: -0.5,
  );

  static const TextStyle displayMedium = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.bold,
    color: TvColors.textPrimary,
    height: 1.2,
  );

  static const TextStyle headline = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: TvColors.textPrimary,
    height: 1.3,
  );

  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w500,
    color: TvColors.textPrimary,
    height: 1.3,
  );

  static const TextStyle body = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    color: TvColors.textSecondary,
    height: 1.4,
  );

  static const TextStyle label = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: TvColors.textSecondary,
    height: 1.3,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: TvColors.textTertiary,
    height: 1.3,
  );
}

/// TV theme data for MaterialApp.
final ThemeData tvTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  primaryColor: TvColors.primary,
  scaffoldBackgroundColor: TvColors.background,
  canvasColor: TvColors.background,
  cardColor: TvColors.surface,
  dividerColor: TvColors.divider,
  colorScheme: const ColorScheme.dark(
    primary: TvColors.primary,
    secondary: TvColors.primary,
    surface: TvColors.surface,
    error: Color(0xFFD32F2F),
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: TvColors.textPrimary,
    onError: Colors.white,
  ),
  textTheme: const TextTheme(
    displayLarge: TvTypography.displayLarge,
    displayMedium: TvTypography.displayMedium,
    headlineMedium: TvTypography.headline,
    titleLarge: TvTypography.title,
    bodyLarge: TvTypography.body,
    bodyMedium: TvTypography.body,
    labelLarge: TvTypography.label,
    bodySmall: TvTypography.caption,
  ),
  iconTheme: const IconThemeData(
    color: Colors.white,
    size: 28,
  ),
);

/// The desktop shells' theme: the TV theme without Material's touch
/// ripples (a press shows as a quiet highlight, as on a Mac), and with
/// tooltips that wait for the pointer to rest a while.
final ThemeData desktopTheme = tvTheme.copyWith(
  splashFactory: NoSplash.splashFactory,
  highlightColor: const Color(0x14FFFFFF),
  tooltipTheme: const TooltipThemeData(
    waitDuration: DesktopTokens.tooltipWait,
  ),
);
