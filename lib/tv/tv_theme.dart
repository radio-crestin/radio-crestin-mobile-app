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
