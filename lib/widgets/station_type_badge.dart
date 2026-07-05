import 'package:flutter/material.dart';
import 'package:radio_crestin/theme.dart';

import '../types/Station.dart';

/// Compact badge marking a station's playback kind.
///
/// Radio stations render nothing (they are the default and need no marker).
/// TV stations get a filled brand-pink "TV" pill; playlist stations get a
/// small playlist glyph. Used in the station list, the mini player and the
/// TV/desktop cards so users can tell live TV and on-demand playlists apart at
/// a glance. [color] defaults to the brand pink but can be overridden for the
/// dark TV surfaces.
class StationTypeBadge extends StatelessWidget {
  const StationTypeBadge({
    super.key,
    required this.type,
    this.color = AppColors.primary,
    this.contentColor,
    this.compact = false,
  });

  /// The station's playback kind.
  final StationMediaType type;

  /// Background color of the badge. Brand pink by default.
  final Color color;

  /// Color of the label/icon. Defaults to white for the filled TV pill and to
  /// [color] for the tinted playlist glyph. Override for colored surfaces (e.g.
  /// a white pill on the brand-colored mini player bar).
  final Color? contentColor;

  /// Slightly tighter sizing for dense rows (mini player, list title row).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case StationMediaType.tv:
        final fg = contentColor ?? Colors.white;
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 5 : 6,
            vertical: compact ? 1.5 : 2,
          ),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.live_tv_rounded, size: compact ? 10 : 12, color: fg),
              const SizedBox(width: 3),
              Text(
                'TV',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w800,
                  fontSize: compact ? 9 : 10,
                  letterSpacing: 0.5,
                  height: 1.0,
                ),
              ),
            ],
          ),
        );
      case StationMediaType.playlist:
        final fg = contentColor ?? color;
        return Container(
          padding: EdgeInsets.all(compact ? 2 : 2.5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: contentColor != null ? 0.9 : 0.16),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            Icons.queue_music_rounded,
            size: compact ? 12 : 14,
            color: fg,
          ),
        );
      case StationMediaType.radio:
        return const SizedBox.shrink();
    }
  }
}
