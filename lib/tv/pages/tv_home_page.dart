import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../queries/getStations.graphql.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_row.dart';

/// TV Home page — full-screen immersive browse.
///
/// - Immersive hero at top showing the currently focused station
/// - Horizontal station rows below (Favorites, All, by group)
/// - Floating bottom bar showing focused station thumbnail + metadata
/// - Select a station → play + open full-screen Now Playing
/// - Favorite toggle button on each card when focused
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

  /// The station currently focused by D-pad navigation.
  Station? _focusedStation;

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
        (List<Station> stations, Station? current, List<String> favs,
            List<Query$GetStations$station_groups> groups) {
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

  Map<String, List<Station>> get _groupedStations {
    final stationMap = {for (final s in _allStations) s.id: s};
    final map = <String, List<Station>>{};
    for (final group in _groups) {
      final stationIds =
          group.station_to_station_groups.map((e) => e.station_id).toSet();
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

  void _onStationFocused(Station station) {
    setState(() => _focusedStation = station);
  }

  @override
  Widget build(BuildContext context) {
    // Hero shows the focused station, falling back to current or first
    final hero = _focusedStation ?? _currentStation ?? _allStations.firstOrNull;
    final isHeroPlaying = hero != null && _currentStation?.id == hero.id;

    return Stack(
      children: [
        // Main scrollable content
        CustomScrollView(
          slivers: [
            // Immersive hero area — updates as user focuses different stations
            SliverToBoxAdapter(
              child: _TvHeroArea(
                station: hero,
                isPlaying: isHeroPlaying,
              ),
            ),
            // Favorite stations row
            if (_favoriteStations.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: TvSpacing.md),
                  child: TvStationRow(
                    title: 'Favorite',
                    stations: _favoriteStations,
                    currentStation: _currentStation,
                    favoriteSlugs: _favoriteSlugs,
                    autofocusFirst: true,
                    onOpenNowPlaying: widget.onOpenNowPlaying,
                    onStationFocused: _onStationFocused,
                  ),
                ),
              ),
            // All stations row
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: TvSpacing.md),
                child: TvStationRow(
                  title: 'Toate Posturile',
                  stations: _allStations,
                  currentStation: _currentStation,
                  favoriteSlugs: _favoriteSlugs,
                  autofocusFirst: _favoriteStations.isEmpty,
                  onOpenNowPlaying: widget.onOpenNowPlaying,
                  onStationFocused: _onStationFocused,
                ),
              ),
            ),
            // Grouped rows
            ..._groupedStations.entries.map((entry) {
              return SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: TvSpacing.md),
                  child: TvStationRow(
                    title: entry.key,
                    stations: entry.value,
                    currentStation: _currentStation,
                    favoriteSlugs: _favoriteSlugs,
                    onOpenNowPlaying: widget.onOpenNowPlaying,
                    onStationFocused: _onStationFocused,
                  ),
                ),
              );
            }),
            // Bottom padding to not clip behind the floating bar
            const SliverToBoxAdapter(
              child: SizedBox(height: 100),
            ),
          ],
        ),

        // Floating bottom info bar — shows focused station details
        if (_focusedStation != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _TvBottomInfoBar(
              station: _focusedStation!,
              isPlaying: _currentStation?.id == _focusedStation!.id,
              isFavorite: _favoriteSlugs.contains(_focusedStation!.slug),
            ),
          ),
      ],
    );
  }
}

/// Immersive hero area — large background with station info overlay.
/// Dynamically updates as the user focuses different station cards.
class _TvHeroArea extends StatelessWidget {
  final Station? station;
  final bool isPlaying;

  const _TvHeroArea({
    required this.station,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    if (station == null) {
      return const SizedBox(height: 280);
    }

    return SizedBox(
      height: 280,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background artwork (darkened)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: SizedBox.expand(
              key: ValueKey('hero-bg-${station!.id}-${station!.artUri}'),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.55),
                  BlendMode.darken,
                ),
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: 400,
                    height: 400,
                    child: station!.displayThumbnail(cacheWidth: 800),
                  ),
                ),
              ),
            ),
          ),
          // Gradient scrim
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    TvColors.background.withValues(alpha: 0.7),
                    TvColors.background,
                  ],
                  stops: const [0.0, 0.65, 1.0],
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
                // Thumbnail
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: ClipRRect(
                    key: ValueKey('hero-thumb-${station!.id}'),
                    borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                    child: SizedBox(
                      width: 120,
                      height: 120,
                      child: station!.displayThumbnail(cacheWidth: 240),
                    ),
                  ),
                ),
                const SizedBox(width: TvSpacing.lg),
                // Metadata
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPlaying)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Floating bottom info bar — appears while browsing stations.
/// Shows the focused station's thumbnail, name, song, and status.
class _TvBottomInfoBar extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final bool isFavorite;

  const _TvBottomInfoBar({
    required this.station,
    required this.isPlaying,
    required this.isFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            TvColors.background.withValues(alpha: 0.95),
            TvColors.background,
          ],
          stops: const [0.0, 0.3, 1.0],
        ),
      ),
      padding: const EdgeInsets.only(
        left: TvSpacing.marginHorizontal,
        right: TvSpacing.marginHorizontal,
        top: TvSpacing.xl,
        bottom: TvSpacing.md,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Row(
          key: ValueKey('bar-${station.id}'),
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
              child: SizedBox(
                width: 48,
                height: 48,
                child: station.displayThumbnail(cacheWidth: 96),
              ),
            ),
            const SizedBox(width: TvSpacing.md),
            // Station name
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    station.title,
                    style: TvTypography.label.copyWith(
                      color: TvColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    station.songTitle.isNotEmpty
                        ? '${station.songTitle}${station.songArtist.isNotEmpty ? ' • ${station.songArtist}' : ''}'
                        : '${station.totalListeners ?? 0} ascultători',
                    style: TvTypography.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Status indicators
            if (isFavorite) ...[
              const SizedBox(width: TvSpacing.sm),
              const Icon(Icons.favorite_rounded,
                  color: TvColors.primary, size: 18),
            ],
            if (isPlaying) ...[
              const SizedBox(width: TvSpacing.sm),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: TvColors.primary,
                  borderRadius: BorderRadius.circular(TvSpacing.radiusSm),
                ),
                child: Text(
                  'REDĂ',
                  style: TvTypography.caption.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
            const SizedBox(width: TvSpacing.md),
            // Hint
            Text(
              'Apasă OK pentru a reda',
              style: TvTypography.caption.copyWith(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
