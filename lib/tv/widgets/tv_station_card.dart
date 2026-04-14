import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_theme.dart';

/// Square station card for TV browse.
/// Shows thumbnail (1:1), station title, and current song below.
/// Focus: primary color border + subtle scale. Select to play.
class TvStationCard extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback onSelect;
  final VoidCallback onFavoriteToggle;
  final ValueChanged<Station>? onFocus;
  final bool autofocus;

  static const double cardSize = 140.0; // 1:1 square

  const TvStationCard({
    super.key,
    required this.station,
    required this.isPlaying,
    required this.isFavorite,
    required this.onSelect,
    required this.onFavoriteToggle,
    this.onFocus,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: cardSize + 12,
      height: cardSize + 50, // thumbnail + title + song
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Thumbnail — square, focusable
          DpadFocusable(
            autofocus: autofocus,
            onSelect: onSelect,
            onFocus: () => onFocus?.call(station),
            builder: (context, isFocused, child) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isFocused ? TvColors.primary : Colors.transparent,
                    width: 2.5,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: AnimatedScale(
                  scale: isFocused ? 1.04 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: child,
                ),
              );
            },
            child: Container(
              width: cardSize,
              height: cardSize,
              decoration: BoxDecoration(
                color: TvColors.surfaceVariant,
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  station.displayThumbnail(
                      cacheWidth: (cardSize * 2).toInt()),
                  // Playing indicator — bottom left
                  if (isPlaying)
                    Positioned(
                      bottom: 5,
                      left: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: TvColors.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.equalizer_rounded,
                                color: Colors.white, size: 11),
                            SizedBox(width: 2),
                            Text('LIVE',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 8)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          // Station title
          SizedBox(
            width: cardSize,
            child: Text(
              station.title,
              style: TvTypography.label.copyWith(
                color: isPlaying ? TvColors.primary : TvColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Song name
          SizedBox(
            width: cardSize,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                station.songTitle.isNotEmpty
                    ? station.songTitle
                    : station.displaySubtitle.isNotEmpty
                        ? station.displaySubtitle
                        : '${station.totalListeners ?? 0} ascultători',
                key: ValueKey('${station.id}-${station.songId}'),
                style: TvTypography.caption.copyWith(
                  fontSize: 10,
                  color: TvColors.textTertiary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
