import 'dart:async';
import 'dart:ui';

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

/// Browse page — Android TV Immersive List.
///
/// Background: dark with the focused station's artwork as a subtle dimmed
/// backdrop (like seeing the station page through a dark overlay).
/// Content block + scrollable card rows fill the lower portion.
/// D-pad scrolls vertically through category rows.
/// BACK → Now Playing. Select station → plays + Now Playing.
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
        child: Stack(
          fit: StackFit.expand,
          children: [
            // === Background: dark base with dimmed station artwork ===
            const ColoredBox(color: TvColors.background),
            if (hero != null)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child: SizedBox.expand(
                  key: ValueKey('bg-${hero.id}-${hero.artUri}'),
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: ColorFiltered(
                      colorFilter: ColorFilter.mode(
                        Colors.black.withValues(alpha: 0.8),
                        BlendMode.darken,
                      ),
                      child: FittedBox(
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: 400,
                          height: 400,
                          child: hero.displayThumbnail(cacheWidth: 400),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // === Scrollable content: metadata + card rows ===
            SafeArea(
              child: CustomScrollView(
                slivers: [
                  // Top area: station preview (artwork + metadata)
                  SliverToBoxAdapter(
                    child: hero != null
                        ? _StationPreview(
                            station: hero, isPlaying: _isHeroPlaying)
                        : const SizedBox(height: 160),
                  ),
                  // Card rows — all scrollable via D-pad
                  if (_favoriteStations.isNotEmpty)
                    SliverToBoxAdapter(
                      child: TvStationRow(
                        title: 'Favorite',
                        stations: _favoriteStations,
                        currentStation: _currentStation,
                        favoriteSlugs: _favoriteSlugs,
                        autofocusFirst: true,
                        onStationSelected: widget.onStationSelected,
                        onStationFocused: _onStationFocused,
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: TvStationRow(
                      title: 'Alese pentru tine',
                      stations: _allStations,
                      currentStation: _currentStation,
                      favoriteSlugs: _favoriteSlugs,
                      autofocusFirst: _favoriteStations.isEmpty,
                      onStationSelected: widget.onStationSelected,
                      onStationFocused: _onStationFocused,
                    ),
                  ),
                  ..._groupedStations.entries.map((entry) {
                    return SliverToBoxAdapter(
                      child: TvStationRow(
                        title: entry.key,
                        stations: entry.value,
                        currentStation: _currentStation,
                        favoriteSlugs: _favoriteSlugs,
                        onStationSelected: widget.onStationSelected,
                        onStationFocused: _onStationFocused,
                      ),
                    );
                  }),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: TvSpacing.xxl),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Station preview shown at the top of the browse page.
/// Displays the focused station's artwork, name, song, and artist
/// in a compact layout — a dimmed "now playing" preview.
class _StationPreview extends StatelessWidget {
  final Station station;
  final bool isPlaying;

  const _StationPreview({
    required this.station,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Padding(
        key: ValueKey('preview-${station.id}-${station.songId}'),
        padding: const EdgeInsets.only(
          left: TvSpacing.marginHorizontal,
          right: TvSpacing.marginHorizontal,
          top: TvSpacing.lg,
          bottom: TvSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Station artwork
            ClipRRect(
              borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
              child: SizedBox(
                width: 120,
                height: 120,
                child: station.displayThumbnail(cacheWidth: 240),
              ),
            ),
            const SizedBox(width: TvSpacing.lg),
            // Metadata
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Tags
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPlaying) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: TvColors.primary.withValues(alpha: 0.2),
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
                      Flexible(
                        child: Text(
                          station.title,
                          style: TvTypography.caption.copyWith(
                              color: TvColors.textSecondary, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
                  // Song title
                  Text(
                    station.songTitle.isNotEmpty
                        ? station.songTitle
                        : station.title,
                    style: TvTypography.displayMedium.copyWith(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (station.songArtist.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      station.songArtist,
                      style: TvTypography.body.copyWith(
                          fontSize: 15, color: TvColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
