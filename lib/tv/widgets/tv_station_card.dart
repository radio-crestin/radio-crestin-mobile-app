import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_theme.dart';

/// A focusable station card for TV.
/// Select → play station. Focus border uses primary color.
/// No favorite icon on the card — favorites managed from Now Playing.
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
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width + 14,
      height: widget.height + 48,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main card — focusable, select to play
          DpadFocusable(
            autofocus: widget.autofocus,
            onSelect: widget.onSelect,
            onFocus: () => widget.onFocus?.call(widget.station),
            builder: (context, isFocused, child) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isFocused ? TvColors.primary : Colors.transparent,
                    width: 3,
                  ),
                  borderRadius:
                      BorderRadius.circular(TvSpacing.radiusMd + 4),
                ),
                child: child,
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
          const SizedBox(height: TvSpacing.xs + 2),
          // Station title — bigger, left-aligned
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              widget.station.title,
              style: TvTypography.label.copyWith(
                color: widget.isPlaying
                    ? TvColors.primary
                    : TvColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Song info
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Align(
                alignment: Alignment.centerLeft,
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
          ),
        ],
      ),
    );
  }
}
