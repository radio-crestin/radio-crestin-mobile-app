import 'package:flutter/material.dart';

/// Height of the collapsed mini player bar shown at the bottom of the
/// HomePage while a station is selected.
///
/// Shared between the `SlidingUpPanel.minHeight` and the station list's bottom
/// scroll inset so the two values can never drift apart.
const double kMiniPlayerCollapsedHeight = 96.0;

/// A trailing sliver spacer that keeps the last station rows clear of the
/// collapsed mini player.
///
/// The mini player only appears while a station is selected, so the spacer
/// animates its height between `0` (no mini player) and
/// [kMiniPlayerCollapsedHeight] (mini player visible). The list smoothly
/// reveals the extra room as playback starts and reclaims it when it stops.
///
/// Belongs exactly once, at the very end of the `CustomScrollView` slivers —
/// never per-section — so every list (favorites, all stations) is cleared by
/// the same single inset.
class MiniPlayerBottomInset extends StatelessWidget {
  const MiniPlayerBottomInset({super.key, required this.visible});

  /// Whether the collapsed mini player is currently on screen.
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        height: visible ? kMiniPlayerCollapsedHeight : 0.0,
      ),
    );
  }
}
