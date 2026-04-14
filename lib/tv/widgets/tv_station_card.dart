import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_theme.dart';

/// Compact station card for the immersive list card rows.
/// 16:9 aspect ratio. Focus scales + border. Select to play.
class TvStationCard extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback onSelect;
  final VoidCallback onFavoriteToggle;
  final ValueChanged<Station>? onFocus;
  final bool autofocus;

  static const double cardWidth = 200.0;
  static const double cardHeight = 112.0; // ~16:9

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
      width: cardWidth + 8,
      height: cardHeight + 36, // Card + text below
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  scale: isFocused ? 1.03 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: child,
                ),
              );
            },
            child: Container(
              width: cardWidth,
              height: cardHeight,
              decoration: BoxDecoration(
                color: TvColors.surfaceVariant,
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  station.displayThumbnail(
                      cacheWidth: (cardWidth * 2).toInt()),
                  // Playing indicator
                  if (isPlaying)
                    Positioned(
                      bottom: 6,
                      left: 6,
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
                                color: Colors.white, size: 12),
                            SizedBox(width: 2),
                            Text('LIVE',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 9)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Title below card
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              station.title,
              style: TvTypography.label.copyWith(
                color: isPlaying ? TvColors.primary : TvColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
