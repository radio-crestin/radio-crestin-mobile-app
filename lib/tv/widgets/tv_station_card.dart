import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_theme.dart';

/// A focusable station card for TV.
/// Select → play station. Press [F] key or dedicated button → toggle favorite.
/// When focused, shows a small favorite toggle button below.
class TvStationCard extends StatefulWidget {
  final Station station;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback onSelect;
  final VoidCallback onFavoriteToggle;
  final ValueChanged<Station>? onFocus;
  final bool autofocus;
  final double width;
  final double height;

  const TvStationCard({
    super.key,
    required this.station,
    required this.isPlaying,
    required this.isFavorite,
    required this.onSelect,
    required this.onFavoriteToggle,
    this.onFocus,
    this.autofocus = false,
    this.width = TvSpacing.stationCardWidth,
    this.height = TvSpacing.stationCardHeight,
  });

  @override
  State<TvStationCard> createState() => _TvStationCardState();
}

class _TvStationCardState extends State<TvStationCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height + 56,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main card — focusable, select to play
          DpadFocusable(
            autofocus: widget.autofocus,
            onSelect: widget.onSelect,
            onFocus: () {
              setState(() => _isFocused = true);
              widget.onFocus?.call(widget.station);
            },
            onBlur: () => setState(() => _isFocused = false),
            builder: FocusEffects.scaleWithBorder(
              scale: TvSpacing.focusScale,
              borderColor: TvColors.focusBorder,
              borderWidth: 3,
              borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
            ),
            child: Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                color: TvColors.surfaceVariant,
                borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                border: widget.isPlaying
                    ? Border.all(color: TvColors.primary, width: 2)
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.station
                      .displayThumbnail(cacheWidth: (widget.width * 2).toInt()),
                  // Playing indicator
                  if (widget.isPlaying)
                    Positioned(
                      bottom: TvSpacing.sm,
                      left: TvSpacing.sm,
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
                            Icon(Icons.equalizer_rounded,
                                color: Colors.white, size: 14),
                            SizedBox(width: 3),
                            Text('LIVE',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
                  // Favorite badge (always visible if favorite)
                  if (widget.isFavorite)
                    const Positioned(
                      top: TvSpacing.sm,
                      right: TvSpacing.sm,
                      child: Icon(Icons.favorite_rounded,
                          color: TvColors.primary, size: 18),
                    ),
                  // Offline overlay
                  if (!widget.station.isUp)
                    Container(
                      color: Colors.black54,
                      child: Center(
                        child: Text('OFFLINE',
                            style: TvTypography.caption.copyWith(
                                color: TvColors.offline,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: TvSpacing.xs),
          // Station title + favorite toggle row
          SizedBox(
            width: widget.width,
            height: 20,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.station.title,
                    style: TvTypography.label.copyWith(
                      color: widget.isPlaying
                          ? TvColors.primary
                          : TvColors.textPrimary,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Favorite toggle — visible when card is focused
                if (_isFocused)
                  DpadFocusable(
                    onSelect: widget.onFavoriteToggle,
                    builder: FocusEffects.scale(scale: 1.3),
                    child: Icon(
                      widget.isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: widget.isFavorite
                          ? TvColors.primary
                          : TvColors.textTertiary,
                      size: 18,
                    ),
                  ),
              ],
            ),
          ),
          // Song info
          SizedBox(
            width: widget.width,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                widget.station.songTitle.isNotEmpty
                    ? widget.station.songTitle
                    : '${widget.station.totalListeners ?? 0} ascultători',
                key: ValueKey(
                    '${widget.station.id}-${widget.station.songId}'),
                style: TvTypography.caption,
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
