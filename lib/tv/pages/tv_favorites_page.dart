import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_card.dart';

/// TV Favorites page with a grid of favorite stations.
class TvFavoritesPage extends StatefulWidget {
  final VoidCallback? onOpenNowPlaying;

  const TvFavoritesPage({super.key, this.onOpenNowPlaying});

  @override
  State<TvFavoritesPage> createState() => _TvFavoritesPageState();
}

class _TvFavoritesPageState extends State<TvFavoritesPage> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  List<Station> _allStations = [];
  Station? _currentStation;
  List<String> _favoriteSlugs = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest3(
        _stationDataService.stations.stream,
        _audioHandler.currentStation.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (List<Station> stations, Station? current, List<String> favs) =>
            (stations, current, favs),
      ).listen((data) {
        if (mounted) {
          setState(() {
            _allStations = data.$1;
            _currentStation = data.$2;
            _favoriteSlugs = data.$3;
          });
        }
      }),
    );
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  List<Station> get _favorites =>
      _allStations.where((s) => _favoriteSlugs.contains(s.slug)).toList();

  @override
  Widget build(BuildContext context) {
    final favorites = _favorites;

    if (favorites.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.favorite_border_rounded,
              size: 64,
              color: TvColors.textTertiary,
            ),
            const SizedBox(height: TvSpacing.md),
            Text(
              'Nu ai posturi favorite',
              style: TvTypography.headline.copyWith(
                color: TvColors.textSecondary,
              ),
            ),
            const SizedBox(height: TvSpacing.sm),
            Text(
              'Adaugă posturi la favorite din pagina principală',
              style: TvTypography.body,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(TvSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Posturi Favorite', style: TvTypography.displayMedium),
          const SizedBox(height: TvSpacing.sm),
          Text(
            '${favorites.length} posturi',
            style: TvTypography.body,
          ),
          const SizedBox(height: TvSpacing.lg),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                crossAxisSpacing: TvSpacing.gutter,
                mainAxisSpacing: TvSpacing.gutter,
                childAspectRatio: 196 / 248,
              ),
              itemCount: favorites.length,
              itemBuilder: (context, index) {
                final station = favorites[index];
                final isPlaying = _currentStation?.id == station.id;
                return TvStationCard(
                  station: station,
                  isPlaying: isPlaying,
                  isFavorite: true,
                  autofocus: index == 0,
                  onTap: () {
                    _audioHandler.playStation(station, fromFavorites: true);
                    widget.onOpenNowPlaying?.call();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
