import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../appAudioHandler.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import 'tv_station_card.dart';

/// A horizontal scrollable row of station cards with a category title.
class TvStationRow extends StatelessWidget {
  final String title;
  final List<Station> stations;
  final Station? currentStation;
  final List<String> favoriteSlugs;
  final bool autofocusFirst;
  final VoidCallback? onOpenNowPlaying;
  final ValueChanged<Station>? onStationFocused;

  const TvStationRow({
    super.key,
    required this.title,
    required this.stations,
    required this.currentStation,
    required this.favoriteSlugs,
    this.autofocusFirst = false,
    this.onOpenNowPlaying,
    this.onStationFocused,
  });

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) return const SizedBox.shrink();

    final audioHandler = GetIt.instance<AppAudioHandler>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: TvSpacing.lg,
            bottom: TvSpacing.sm,
          ),
          child: Text(title, style: TvTypography.headline),
        ),
        SizedBox(
          height: TvSpacing.stationCardHeight + 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: TvSpacing.lg),
            itemCount: stations.length,
            separatorBuilder: (_, __) =>
                const SizedBox(width: TvSpacing.gutter),
            itemBuilder: (context, index) {
              final station = stations[index];
              final isPlaying = currentStation?.id == station.id;
              final isFavorite = favoriteSlugs.contains(station.slug);
              return TvStationCard(
                station: station,
                isPlaying: isPlaying,
                isFavorite: isFavorite,
                autofocus: autofocusFirst && index == 0,
                onSelect: () {
                  audioHandler.playStation(station);
                  onOpenNowPlaying?.call();
                },
                onFavoriteToggle: () {
                  audioHandler.customAction('toggleFavorite');
                },
                onFocus: onStationFocused,
              );
            },
          ),
        ),
      ],
    );
  }
}
