import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../queries/getStations.graphql.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_row.dart';

/// TV Home page with immersive hero area and horizontal station rows.
/// Follows Android TV immersive list pattern: large hero + browsable rows.
class TvHomePage extends StatefulWidget {
  final VoidCallback? onOpenNowPlaying;

  const TvHomePage({super.key, this.onOpenNowPlaying});

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  List<Station> _allStations = [];
  Station? _currentStation;
  List<String> _favoriteSlugs = [];
  List<Query$GetStations$station_groups> _groups = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest4(
        _stationDataService.stations.stream,
        _audioHandler.currentStation.stream,
        _stationDataService.favoriteStationSlugs.stream,
        _stationDataService.stationGroups.stream,
        (List<Station> stations, Station? current,
            List<String> favs, List<Query$GetStations$station_groups> groups) {
          return (stations, current, favs, groups);
        },
      ).listen((data) {
        if (mounted) {
          setState(() {
            _allStations = data.$1;
            _currentStation = data.$2;
            _favoriteSlugs = data.$3;
            _groups = data.$4;
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

  List<Station> get _favoriteStations {
    return _allStations
        .where((s) => _favoriteSlugs.contains(s.slug))
        .toList();
  }

  /// Get stations grouped by station_group using the group→station mapping.
  Map<String, List<Station>> get _groupedStations {
    final stationMap = {for (final s in _allStations) s.id: s};
    final map = <String, List<Station>>{};
    for (final group in _groups) {
      final stationIds = group.station_to_station_groups
          .map((e) => e.station_id)
          .toSet();
      final groupStations = stationIds
          .where((id) => stationMap.containsKey(id))
          .map((id) => stationMap[id]!)
          .toList();
      if (groupStations.isNotEmpty) {
        map[group.name] = groupStations;
      }
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final hero = _currentStation ?? _allStations.firstOrNull;

    return CustomScrollView(
      slivers: [
        // Immersive hero area
        SliverToBoxAdapter(
          child: _TvHeroArea(
            station: hero,
            isPlaying: hero != null && _currentStation?.id == hero.id,
            onPlay: () {
              if (hero != null) {
                _audioHandler.playStation(hero);
                widget.onOpenNowPlaying?.call();
              }
            },
          ),
        ),

        // Favorite stations row
        if (_favoriteStations.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: TvSpacing.lg),
              child: TvStationRow(
                title: 'Favorite',
                stations: _favoriteStations,
                currentStation: _currentStation,
                favoriteSlugs: _favoriteSlugs,
                autofocusFirst: true,
                onOpenNowPlaying: widget.onOpenNowPlaying,
              ),
            ),
          ),

        // All stations row
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: TvSpacing.lg),
            child: TvStationRow(
              title: 'Toate Posturile',
              stations: _allStations,
              currentStation: _currentStation,
              favoriteSlugs: _favoriteSlugs,
              autofocusFirst: _favoriteStations.isEmpty,
              onOpenNowPlaying: widget.onOpenNowPlaying,
            ),
          ),
        ),

        // Grouped station rows
        ..._groupedStations.entries.map((entry) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: TvSpacing.lg),
              child: TvStationRow(
                title: entry.key,
                stations: entry.value,
                currentStation: _currentStation,
                favoriteSlugs: _favoriteSlugs,
                onOpenNowPlaying: widget.onOpenNowPlaying,
              ),
            ),
          );
        }),

        const SliverToBoxAdapter(
          child: SizedBox(height: TvSpacing.xxl),
        ),
      ],
    );
  }
}

/// Immersive hero area showing a large station artwork + metadata.
/// 16:9 aspect ratio background with gradient scrim overlay.
class _TvHeroArea extends StatelessWidget {
  final Station? station;
  final bool isPlaying;
  final VoidCallback onPlay;

  const _TvHeroArea({
    required this.station,
    required this.isPlaying,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    if (station == null) {
      return const SizedBox(height: 320);
    }

    return SizedBox(
      height: 320,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background artwork (darkened)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: SizedBox(
              key: ValueKey('hero-bg-${station!.artUri}'),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.5),
                  BlendMode.darken,
                ),
                child: station!.displayThumbnail(cacheWidth: 800),
              ),
            ),
          ),
          // Gradient scrim from bottom
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    TvColors.background.withValues(alpha: 0.6),
                    TvColors.background,
                  ],
                  stops: const [0.0, 0.6, 1.0],
                ),
              ),
            ),
          ),
          // Content overlay
          Positioned(
            left: TvSpacing.marginHorizontal,
            bottom: TvSpacing.lg,
            right: TvSpacing.marginHorizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Station artwork
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: ClipRRect(
                    key: ValueKey('hero-thumb-${station!.id}'),
                    borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                    child: SizedBox(
                      width: 140,
                      height: 140,
                      child: station!.displayThumbnail(cacheWidth: 280),
                    ),
                  ),
                ),
                const SizedBox(width: TvSpacing.lg),
                // Text content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPlaying)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          margin: const EdgeInsets.only(bottom: TvSpacing.sm),
                          decoration: BoxDecoration(
                            color: TvColors.primary,
                            borderRadius:
                                BorderRadius.circular(TvSpacing.radiusSm),
                          ),
                          child: Text(
                            'SE REDĂ ACUM',
                            style: TvTypography.caption.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          station!.title,
                          key: ValueKey('hero-title-${station!.id}'),
                          style: TvTypography.displayMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: TvSpacing.xs),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          station!.displaySubtitle.isNotEmpty
                              ? station!.displaySubtitle
                              : '${station!.totalListeners ?? 0} ascultători',
                          key: ValueKey('hero-sub-${station!.songId}'),
                          style: TvTypography.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: TvSpacing.lg),
                // Play button
                DpadFocusable(
                  onSelect: onPlay,
                  builder: FocusEffects.scaleWithBorder(
                    scale: 1.1,
                    borderColor: Colors.white,
                    borderWidth: 3,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      color: TvColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
