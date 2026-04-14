import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_theme.dart';

/// A focusable station card for TV.
/// Select → play station. Favorite button overlaid at top-right when focused.
/// Focus border uses primary color with proper padding.
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
      width: widget.width + 12, // Extra for focus border padding
      height: widget.height + 56,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
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
            builder: (context, isFocused, child) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isFocused
                        ? TvColors.primary
                        : Colors.transparent,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(TvSpacing.radiusMd + 4),
                ),
                child: AnimatedScale(
                  scale: isFocused ? 1.02 : 1.0,
                  duration: const Duration(milliseconds: 200),
                  child: child,
                ),
              );
            },
            child: Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                color: TvColors.surfaceVariant,
                borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Thumbnail
                  widget.station
                      .displayThumbnail(cacheWidth: (widget.width * 2).toInt()),
                  // Playing indicator — bottom left
                  if (widget.isPlaying)
                    Positioned(
                      bottom: TvSpacing.sm,
                      left: TvSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
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
                  // Favorite button — top right corner, always visible if fav, interactive when focused
                  if (widget.isFavorite || _isFocused)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: GestureDetector(
                        onTap: widget.onFavoriteToggle,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.isFavorite
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: widget.isFavorite
                                ? TvColors.primary
                                : Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
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
          // Station title
          SizedBox(
            width: widget.width,
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
              textAlign: TextAlign.center,
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
                key: ValueKey('${widget.station.id}-${widget.station.songId}'),
                style: TvTypography.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
