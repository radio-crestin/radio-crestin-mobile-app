import 'package:flutter/material.dart';

import '../tv_theme.dart';

/// Flutter implementation of Android TV's ImmersiveList component.
/// (developer.android.com/design/ui/tv/guides/components/immersive-list)
///
/// Full-screen background that updates based on the focused item.
/// Content block (metadata) positioned at the bottom-left.
/// Card rows at the very bottom, overlaid on a dark gradient.
///
/// Anatomy:
///   1. Image background (full screen, subject aligned top-right)
///   2. Cinematic scrim (gradient: transparent top → dark bottom)
///   3. Content block (title, subtitle, description — bottom-left)
///   4. Card grid (horizontal scrollable rows — bottom)
class TvImmersiveList extends StatelessWidget {
  /// Builder for the full-screen background. Receives the focused index.
  /// Should return a full-screen widget (typically an image).
  final Widget Function(int focusedIndex) backgroundBuilder;

  /// Content block shown above the card rows (metadata, description).
  final Widget contentBlock;

  /// The card rows shown at the bottom of the screen.
  final List<Widget> cardRows;

  /// Height reserved for the card rows area.
  final double cardAreaHeight;

  const TvImmersiveList({
    super.key,
    required this.backgroundBuilder,
    required this.contentBlock,
    required this.cardRows,
    this.cardAreaHeight = 310,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: Full-screen background image
        Positioned.fill(
          child: backgroundBuilder(0),
        ),

        // Layer 2: Cinematic scrim
        // Left-to-right: dark on left (for text readability)
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.black.withValues(alpha: 0.85),
                  Colors.black.withValues(alpha: 0.4),
                  Colors.black.withValues(alpha: 0.15),
                ],
                stops: const [0.0, 0.4, 0.7],
              ),
            ),
          ),
        ),
        // Bottom gradient: dark at bottom for card readability
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.3),
                  Colors.black.withValues(alpha: 0.9),
                  Colors.black,
                ],
                stops: const [0.0, 0.4, 0.65, 0.85],
              ),
            ),
          ),
        ),

        // Layer 3: Content block + card rows pinned to bottom
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Metadata content block
              Padding(
                padding: const EdgeInsets.only(
                  left: TvSpacing.marginHorizontal,
                  right: TvSpacing.marginHorizontal,
                  bottom: TvSpacing.md,
                ),
                child: contentBlock,
              ),
              // Card rows
              ...cardRows,
              const SizedBox(height: TvSpacing.md),
            ],
          ),
        ),
      ],
    );
  }
}

/// Animated background for the immersive list.
/// Crossfades between station artworks as focus changes.
class TvImmersiveBackground extends StatelessWidget {
  final Widget child;
  final Key childKey;

  const TvImmersiveBackground({
    super.key,
    required this.child,
    required this.childKey,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      switchInCurve: Curves.easeIn,
      switchOutCurve: Curves.easeOut,
      child: SizedBox.expand(
        key: childKey,
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.topRight, // Subject aligned top-right (spec)
          clipBehavior: Clip.hardEdge,
          child: child,
        ),
      ),
    );
  }
}
