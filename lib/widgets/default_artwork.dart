import 'package:flutter/material.dart';

import '../theme.dart';

/// Branded placeholder artwork shown wherever a thumbnail URL is missing or
/// failed to load (playlist rows, audio artwork, HLS items that can't be
/// first-framed, …). It reads as an intentional brand tile — a soft pink
/// gradient with a centered glyph — never like a broken-image error state.
///
/// Themed for light AND dark via [Theme.of]: a brighter brand gradient in light
/// mode, a deeper one in dark mode, both carrying a high-contrast white glyph
/// (an icon, so the 3:1 large-graphic contrast bar applies, not the 4.5:1 text
/// bar). Fills its parent, so callers size and clip it (matching
/// [AppRadius.thumbnail] / [AppRadius.artwork]); pass [borderRadius] to have the
/// tile round itself when it isn't already clipped by an ancestor.
class DefaultArtwork extends StatelessWidget {
  const DefaultArtwork({
    super.key,
    this.icon = Icons.music_note_rounded,
    this.borderRadius,
  });

  /// Centered glyph. Defaults to a music note; callers can pass a
  /// type-appropriate icon (e.g. a movie or radio glyph).
  final IconData icon;

  /// When set, the tile clips itself to these corners. Omit when an ancestor
  /// already clips (the common case — the tile just fills the clipped box).
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Deeper, calmer gradient in dark mode; the brighter brand gradient in
    // light mode. White glyph stays legible over both.
    final gradientColors = isDark
        ? const [AppColors.primaryDark, Color(0xFF3A0016)]
        : const [AppColors.primary, AppColors.primaryDark];

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.biggest.shortestSide;
          final glyphSize =
              side.isFinite && side > 0 ? (side * 0.42).clamp(16.0, 72.0) : 24.0;
          return Center(
            child: Icon(
              icon,
              size: glyphSize,
              color: Colors.white.withValues(alpha: 0.92),
            ),
          );
        },
      ),
    );
  }
}
