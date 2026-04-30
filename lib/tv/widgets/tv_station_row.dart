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
          SizedBox(
            height: TvStationCard.cardSize + 68,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                  horizontal: TvSpacing.marginHorizontal),
              itemCount: stations.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: TvSpacing.sm),
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
