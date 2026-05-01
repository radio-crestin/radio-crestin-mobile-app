import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../tv_theme.dart';
import 'tv_station_card.dart';

/// Horizontal scrollable row of square station cards with category title.
class TvStationRow extends StatelessWidget {
  final String title;
  final List<Station> stations;
  final Station? currentStation;
  final List<String> favoriteSlugs;
  final bool autofocusFirst;
  final ValueChanged<Station>? onStationSelected;
  final ValueChanged<Station>? onStationFocused;

  const TvStationRow({
    super.key,
    required this.title,
    required this.stations,
    required this.currentStation,
    required this.favoriteSlugs,
    this.autofocusFirst = false,
    this.onStationSelected,
    this.onStationFocused,
  });

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: TvSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(
              left: TvSpacing.marginHorizontal,
              bottom: TvSpacing.xs,
            ),
            child: Text(
              title,
              style: TvTypography.headline.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // Extra vertical room (24px top, 18px bottom) lets the focused
          // card's scaled border and glow render outside the column's natural
          // height. The horizontal ListView uses Clip.none so the glow on
          // the leftmost / rightmost focused card isn't sliced off either.
          SizedBox(
            height: TvStationCard.cardSize + 68 + 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: EdgeInsets.fromLTRB(
                TvSpacing.marginHorizontal,
                24,
                TvSpacing.marginHorizontal,
                18,
              ),
              itemCount: stations.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: TvSpacing.md),
              itemBuilder: (context, index) {
                final station = stations[index];
                final isPlaying = currentStation?.id == station.id;
                final isFavorite = favoriteSlugs.contains(station.slug);
                return TvStationCard(
                  station: station,
                  isPlaying: isPlaying,
                  isFavorite: isFavorite,
                  autofocus: autofocusFirst && index == 0,
                  onSelect: () => onStationSelected?.call(station),
                  onFavoriteToggle: () {},
                  onFocus: onStationFocused,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
