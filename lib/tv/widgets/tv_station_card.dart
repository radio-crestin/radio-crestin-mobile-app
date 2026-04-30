import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_platform.dart';
import '../tv_theme.dart';
import 'desktop_focusable.dart';

/// Square station card for TV browse.
/// Shows thumbnail (1:1), station title, and current song below.
class TvStationCard extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback onSelect;
  final VoidCallback onFavoriteToggle;
  final ValueChanged<Station>? onFocus;
  final bool autofocus;
  final String? region;
  final bool isEntryPoint;

  static const double cardSize = 160.0;

  const TvStationCard({
    super.key,
    required this.station,
    required this.isPlaying,
    required this.isFavorite,
    required this.onSelect,
    required this.onFavoriteToggle,
    this.onFocus,
    this.autofocus = false,
    this.region,
    this.isEntryPoint = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: cardSize + 14,
      height: cardSize + 56,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Thumbnail
          DesktopFocusable(
            autofocus: autofocus,
            region: region,
            isEntryPoint: isEntryPoint,
            onSelect: onSelect,
            onFocus: () => onFocus?.call(station),
            builder: (context, isFocused, child) {
              if (TvPlatform.isDesktop) {
                // Desktop: scale only, no border
                return AnimatedScale(
                  scale: isFocused ? 1.05 : 1.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: isFocused ? 1.0 : 0.9,
                    duration: const Duration(milliseconds: 180),
                    child: child,
                  ),
                );
              }
              // TV: border + scale + glow for D-pad visibility from across the room.
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isFocused ? TvColors.primary : Colors.transparent,
                    width: 3.5,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: TvColors.primary.withValues(alpha: 0.45),
                            blurRadius: 18,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: AnimatedScale(
                  scale: isFocused ? 1.07 : 1.0,
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
          const SizedBox(height: 6),
          // Station title — left aligned, bigger
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              station.title,
              style: TvTypography.label.copyWith(
                color: isPlaying ? TvColors.primary : TvColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
            ),
          ),
          // Song name — left aligned, bigger
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  station.songTitle.isNotEmpty
                      ? station.songTitle
                      : station.displaySubtitle.isNotEmpty
                          ? station.displaySubtitle
                          : '',
                  key: ValueKey('${station.id}-${station.songId}'),
                  style: TvTypography.caption.copyWith(
                    fontSize: 12,
                    color: TvColors.textTertiary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
