import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_theme.dart';

/// A focusable station card for TV grids and rows.
/// Shows station thumbnail with title and current song overlay.
class TvStationCard extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback onTap;
  final bool autofocus;
  final double width;
  final double height;

  const TvStationCard({
    super.key,
    required this.station,
    required this.isPlaying,
    required this.isFavorite,
    required this.onTap,
    this.autofocus = false,
    this.width = TvSpacing.stationCardWidth,
    this.height = TvSpacing.stationCardHeight,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height + 52,
      child: DpadFocusable(
        autofocus: autofocus,
        onSelect: onTap,
        builder: FocusEffects.scaleWithBorder(
          scale: TvSpacing.focusScale,
          borderColor: TvColors.focusBorder,
          borderWidth: 3,
          borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: TvColors.surfaceVariant,
                borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                border: isPlaying
                    ? Border.all(color: TvColors.primary, width: 2)
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  station.displayThumbnail(cacheWidth: (width * 2).toInt()),
                  if (isPlaying)
                    Positioned(
                      bottom: TvSpacing.sm,
                      right: TvSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: TvColors.primary,
                          borderRadius:
                              BorderRadius.circular(TvSpacing.radiusSm),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.equalizer_rounded,
                              color: Colors.white,
                              size: 14,
                            ),
                            SizedBox(width: 3),
                            Text(
                              'LIVE',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (isFavorite)
                    const Positioned(
                      top: TvSpacing.sm,
                      right: TvSpacing.sm,
                      child: Icon(
                        Icons.favorite_rounded,
                        color: TvColors.primary,
                        size: 18,
                      ),
                    ),
                  if (!station.isUp)
                    Container(
                      color: Colors.black54,
                      child: Center(
                        child: Text(
                          'OFFLINE',
                          style: TvTypography.caption.copyWith(
                            color: TvColors.offline,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: TvSpacing.sm),
            SizedBox(
              width: width,
              child: Text(
                station.title,
                style: TvTypography.label.copyWith(
                  color: isPlaying ? TvColors.primary : TvColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: width,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  station.songTitle.isNotEmpty
                      ? station.songTitle
                      : '${station.totalListeners ?? 0} ascultători',
                  key: ValueKey('${station.id}-${station.songId}'),
                  style: TvTypography.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
