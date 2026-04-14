import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../appAudioHandler.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_card.dart';

/// TV Recently Played page with a grid of recently listened stations.
class TvRecentPage extends StatefulWidget {
  final VoidCallback? onOpenNowPlaying;

  const TvRecentPage({super.key, this.onOpenNowPlaying});

  @override
  State<TvRecentPage> createState() => _TvRecentPageState();
}

class _TvRecentPageState extends State<TvRecentPage> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  List<Station> _allStations = [];
  Station? _currentStation;
  List<String> _favoriteSlugs = [];
  List<String> _recentSlugs = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _loadRecentStations();

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

    // Track station changes for recents
    _subscriptions.add(
      _audioHandler.currentStation.stream.listen((station) {
        if (station != null) {
          _addRecent(station.slug);
        }
      }),
    );
  }

  Future<void> _loadRecentStations() async {
    final prefs = GetIt.instance<SharedPreferences>();
    final recent = prefs.getStringList('tv_recent_stations') ?? [];
    if (mounted) setState(() => _recentSlugs = recent);
  }

  Future<void> _addRecent(String slug) async {
    final prefs = GetIt.instance<SharedPreferences>();
    _recentSlugs.remove(slug);
    _recentSlugs.insert(0, slug);
    if (_recentSlugs.length > 30) {
      _recentSlugs = _recentSlugs.sublist(0, 30);
    }
    await prefs.setStringList('tv_recent_stations', _recentSlugs);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  List<Station> get _recentStations {
    final stationMap = {for (final s in _allStations) s.slug: s};
    return _recentSlugs
        .where((slug) => stationMap.containsKey(slug))
        .map((slug) => stationMap[slug]!)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final recents = _recentStations;

    if (recents.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_rounded,
              size: 64,
              color: TvColors.textTertiary,
            ),
            const SizedBox(height: TvSpacing.md),
            Text(
              'Niciun post redat recent',
              style: TvTypography.headline.copyWith(
                color: TvColors.textSecondary,
              ),
            ),
            const SizedBox(height: TvSpacing.sm),
            Text(
              'Posturile redate vor apărea aici',
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
          Text('Redate Recent', style: TvTypography.displayMedium),
          const SizedBox(height: TvSpacing.sm),
          Text(
            '${recents.length} posturi',
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
              itemCount: recents.length,
              itemBuilder: (context, index) {
                final station = recents[index];
                final isPlaying = _currentStation?.id == station.id;
                final isFavorite = _favoriteSlugs.contains(station.slug);
                return TvStationCard(
                  station: station,
                  isPlaying: isPlaying,
                  isFavorite: isFavorite,
                  autofocus: index == 0,
                  onSelect: () {
                    _audioHandler.playStation(station);
                    widget.onOpenNowPlaying?.call();
                  },
                  onFavoriteToggle: () {
                    _audioHandler.customAction('toggleFavorite');
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
