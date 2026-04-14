import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../queries/getStations.graphql.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_row.dart';

/// Browse page — Android TV Immersive List pattern.
///
/// Matches the native Kotlin implementation:
///   Box(height = 400.dp, fillMaxWidth) {
///     Background(aspectRatio = 20/7, fillMaxWidth)  // top
///     LazyRow(align = BottomEnd)                     // bottom
///   }
///
/// Full-screen background shows the focused station's artwork.
/// Station rows are pinned to the bottom.
/// Metadata (content block) sits just above the card rows.
/// BACK → returns to Now Playing. Select → plays station + returns.
class TvBrowse extends StatefulWidget {
  final VoidCallback onBack;
  final ValueChanged<Station> onStationSelected;

  const TvBrowse({
    super.key,
    required this.onBack,
    required this.onStationSelected,
  });

  @override
  State<TvBrowse> createState() => _TvBrowseState();
}

class _TvBrowseState extends State<TvBrowse> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];

  Station? _currentStation;
  Station? _focusedStation;
  List<Station> _allStations = [];
  List<String> _favoriteSlugs = [];
  List<Query$GetStations$station_groups> _groups = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest4(
        _audioHandler.currentStation.stream,
        _stationDataService.stations.stream,
        _stationDataService.favoriteStationSlugs.stream,
        _stationDataService.stationGroups.stream,
        (Station? current, List<Station> all, List<String> favs,
                List<Query$GetStations$station_groups> groups) =>
            (current, all, favs, groups),
      ).listen((data) {
        if (mounted) {
          setState(() {
            _currentStation = data.$1;
            _allStations = data.$2;
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

  Station? get _hero =>
      _focusedStation ?? _currentStation ?? _allStations.firstOrNull;

  bool get _isHeroPlaying =>
      _hero != null && _currentStation?.id == _hero!.id;

  List<Station> get _favoriteStations =>
      _allStations.where((s) => _favoriteSlugs.contains(s.slug)).toList();

  Map<String, List<Station>> get _groupedStations {
    final stationMap = {for (final s in _allStations) s.id: s};
    final map = <String, List<Station>>{};
    for (final group in _groups) {
      final ids =
          group.station_to_station_groups.map((e) => e.station_id).toSet();
      final list = ids
          .where((id) => stationMap.containsKey(id))
          .map((id) => stationMap[id]!)
          .toList();
      if (list.isNotEmpty) map[group.name] = list;
    }
    return map;
  }

  /// BACK key → return to Now Playing
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      widget.onBack();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onStationFocused(Station station) {
    setState(() => _focusedStation = station);
  }

  @override
  Widget build(BuildContext context) {
    final hero = _hero;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack();
      },
      child: Focus(
        onKeyEvent: _onKeyEvent,
        child: SizedBox.expand(
          // The immersive list container (full screen)
          child: Stack(
            fit: StackFit.expand,
            children: [
              // === Background: full-screen station artwork ===
              if (hero != null)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  switchInCurve: Curves.easeIn,
                  switchOutCurve: Curves.easeOut,
                  child: SizedBox.expand(
                    key: ValueKey('browse-bg-${hero.id}-${hero.artUri}'),
                    child: FittedBox(
                      fit: BoxFit.cover,
                      alignment: Alignment.topRight,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: 960,
                        height: 540,
                        child: hero.displayThumbnail(cacheWidth: 960),
                      ),
                    ),
                  ),
                ),

              // === Cinematic scrim ===
              // Left gradient: dark on left for text readability
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.black.withValues(alpha: 0.5),
                        Colors.black.withValues(alpha: 0.1),
                      ],
                      stops: const [0.0, 0.35, 0.65],
                    ),
                  ),
                ),
              ),
              // Bottom gradient: dark at bottom for card rows
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.7),
                        Colors.black.withValues(alpha: 0.95),
                      ],
                      stops: const [0.0, 0.3, 0.6, 0.85],
                    ),
                  ),
                ),
              ),

              // === Content: metadata + card rows, aligned to bottom ===
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Content block (metadata)
                      if (hero != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: TvSpacing.marginHorizontal,
                            right: TvSpacing.marginHorizontal,
                            bottom: TvSpacing.md,
                          ),
                          child: _ContentBlock(
                            station: hero,
                            isPlaying: _isHeroPlaying,
                          ),
                        ),
                      // Card rows (LazyRow equivalent)
                      if (_favoriteStations.isNotEmpty)
                        TvStationRow(
                          title: 'Favorite',
                          stations: _favoriteStations,
                          currentStation: _currentStation,
                          favoriteSlugs: _favoriteSlugs,
                          autofocusFirst: true,
                          onStationSelected: widget.onStationSelected,
                          onStationFocused: _onStationFocused,
                        ),
                      TvStationRow(
                        title: 'Alese pentru tine',
                        stations: _allStations,
                        currentStation: _currentStation,
                        favoriteSlugs: _favoriteSlugs,
                        autofocusFirst: _favoriteStations.isEmpty,
                        onStationSelected: widget.onStationSelected,
                        onStationFocused: _onStationFocused,
                      ),
                      ..._groupedStations.entries.take(2).map((entry) {
                        return TvStationRow(
                          title: entry.key,
                          stations: entry.value,
                          currentStation: _currentStation,
                          favoriteSlugs: _favoriteSlugs,
                          onStationSelected: widget.onStationSelected,
                          onStationFocused: _onStationFocused,
                        );
                      }),
                      const SizedBox(height: TvSpacing.sm),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Content block — metadata overlaid bottom-left above card rows.
/// Tags (station name, LIVE, listeners) + large title + artist.
class _ContentBlock extends StatelessWidget {
  final Station station;
  final bool isPlaying;

  const _ContentBlock({
    required this.station,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Column(
        key: ValueKey('cb-${station.id}-${station.songId}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tags row
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isPlaying) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.equalizer_rounded,
                          color: TvColors.primary, size: 12),
                      const SizedBox(width: 4),
                      Text('LIVE',
                          style: TvTypography.caption.copyWith(
                            color: TvColors.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                          )),
                    ],
                  ),
                ),
                const SizedBox(width: TvSpacing.sm),
              ],
              Text(
                station.title,
                style: TvTypography.caption.copyWith(
                    color: TvColors.textSecondary, fontSize: 13),
              ),
              if (station.totalListeners != null &&
                  station.totalListeners > 0)
                Text(
                  '  •  ${station.totalListeners} ascultători',
                  style: TvTypography.caption.copyWith(fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: TvSpacing.sm),
          // Song title — large
          Text(
            station.songTitle.isNotEmpty ? station.songTitle : station.title,
            style: TvTypography.displayMedium
                .copyWith(fontSize: 28, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Artist / subtitle
          if (station.songArtist.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              station.songArtist,
              style: TvTypography.body
                  .copyWith(fontSize: 15, color: TvColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
