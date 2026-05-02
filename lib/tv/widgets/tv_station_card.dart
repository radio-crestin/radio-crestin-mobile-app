import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_platform.dart';
import '../tv_theme.dart';
import 'desktop_focusable.dart';

/// Square station card for TV browse.
/// Shows thumbnail (1:1), station title, and current song below.
class TvStationCard extends StatefulWidget {
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
  State<TvStationCard> createState() => _TvStationCardState();
}

class _TvStationCardState extends State<TvStationCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final station = widget.station;
    final isPlaying = widget.isPlaying;
    final isFavorite = widget.isFavorite;
    final autofocus = widget.autofocus;
    final region = widget.region;
    final isEntryPoint = widget.isEntryPoint;
    final cardSize = TvStationCard.cardSize;
    return MouseRegion(
      onEnter: (_) {
        if (TvPlatform.isDesktop && !_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (TvPlatform.isDesktop && _hover) setState(() => _hover = false);
      },
      child: SizedBox(
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
            onSelect: widget.onSelect,
            onFocus: () => widget.onFocus?.call(station),
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
              // Scale must wrap the bordered container (not its child), otherwise
              // the inner thumbnail visually overflows the border at the corners
              // — the same pattern dpad's FocusEffects.scaleWithBorder uses.
              // Outer radius = inner radius (10) + padding (3) so the border
              // stays concentric with the thumbnail rounding.
              return AnimatedScale(
                scale: isFocused ? 1.07 : 1.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isFocused ? TvColors.primary : Colors.transparent,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(13),
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
                  // Favorite heart overlay (desktop): always visible when
                  // favorited, fades in on hover otherwise. On TV, only
                  // shows when favorited (read-only state indicator).
                  if (isFavorite || (TvPlatform.isDesktop && _hover))
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _HeartButton(
                        isFavorite: isFavorite,
                        onTap: widget.onFavoriteToggle,
                        interactive: TvPlatform.isDesktop,
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
      ),
    );
  }
}

class _HeartButton extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onTap;
  final bool interactive;

  const _HeartButton({
    required this.isFavorite,
    required this.onTap,
    required this.interactive,
  });

  @override
  State<_HeartButton> createState() => _HeartButtonState();
}

class _HeartButtonState extends State<_HeartButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fav = widget.isFavorite;
    final btn = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: fav
            ? Colors.black.withValues(alpha: 0.45)
            : Colors.black.withValues(alpha: _hover ? 0.55 : 0.4),
        shape: BoxShape.circle,
        border: Border.all(
          color: fav
              ? TvColors.primary.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: _hover ? 0.35 : 0.2),
          width: 1,
        ),
      ),
      child: Icon(
        fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        size: 16,
        color: fav ? TvColors.primary : Colors.white,
      ),
    );

    if (!widget.interactive) return btn;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Tooltip(
          message: fav
              ? 'Elimină de la favorite'
              : 'Adaugă la favorite',
          child: btn,
        ),
      ),
    );
  }
}
