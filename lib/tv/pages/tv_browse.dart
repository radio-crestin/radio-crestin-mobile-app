import 'dart:async';
import 'dart:ui';

import 'package:dpad/dpad.dart';
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

/// Browse page — station browser with dark background.
///
/// Top: "Now Playing" bar showing current station + song.
/// Below: station preview for focused card + scrollable card rows.
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
    final currentlyPlaying = _currentStation;

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
            // Background: dark with subtle blurred artwork
            const ColoredBox(color: TvColors.background),
            if (hero != null)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child: SizedBox.expand(
                  key: ValueKey('bg-${hero.id}-${hero.artUri}'),
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: ColorFiltered(
                      colorFilter: ColorFilter.mode(
                        Colors.black.withValues(alpha: 0.82),
                        BlendMode.darken,
                      ),
                      child: FittedBox(
                        fit: BoxFit.cover,
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

            // Content
            SafeArea(
              child: Column(
                children: [
                  // === Now Playing bar at top — focusable, click to go back ===
                  if (currentlyPlaying != null)
                    _NowPlayingBar(
                      station: currentlyPlaying,
                      onTap: widget.onBack,
                    ),
                  // Divider
                  const Divider(color: TvColors.divider, height: 1),
                  // === Focused station preview ===
                  if (hero != null)
                    _StationPreview(
                      station: hero,
                      isPlaying:
                          _currentStation?.id == hero.id,
                    ),
                  // === Scrollable card rows ===
                  Expanded(
                    child: CustomScrollView(
                      slivers: [
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
          ],
        ),
      ),
    );
  }
}

/// Now Playing bar — focusable. Click/select to return to station page.
class _NowPlayingBar extends StatelessWidget {
  final Station station;
  final VoidCallback onTap;

  const _NowPlayingBar({required this.station, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      onSelect: onTap,
      builder: FocusEffects.border(
        focusColor: TvColors.primary,
        width: 2,
        borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TvSpacing.marginHorizontal,
          vertical: TvSpacing.md,
        ),
        child: Row(
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
            // Equalizer + station name
            const Icon(Icons.equalizer_rounded,
                color: TvColors.primary, size: 18),
            const SizedBox(width: TvSpacing.sm),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    station.title,
                    style: TvTypography.label.copyWith(
                      fontSize: 14,
                      color: TvColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (station.songTitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${station.songTitle}${station.songArtist.isNotEmpty ? ' • ${station.songArtist}' : ''}',
                      style: TvTypography.caption.copyWith(
                        fontSize: 12,
                        color: TvColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: TvSpacing.md),
            // Listeners
            Text(
              '${station.totalListeners ?? 0} ascultători',
              style: TvTypography.caption.copyWith(fontSize: 11),
            ),
            const SizedBox(width: TvSpacing.md),
            // Arrow hint
            const Icon(Icons.chevron_right_rounded,
                color: TvColors.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }
}

/// Preview of the focused station — artwork + metadata.
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
        padding: const EdgeInsets.symmetric(
          horizontal: TvSpacing.marginHorizontal,
          vertical: TvSpacing.md,
        ),
        child: Row(
          children: [
            // Artwork
            ClipRRect(
              borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
              child: SizedBox(
                width: 100,
                height: 100,
                child: station.displayThumbnail(cacheWidth: 200),
              ),
            ),
            const SizedBox(width: TvSpacing.lg),
            // Metadata
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Station name + status
                  Row(
                    children: [
                      if (isPlaying) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: TvColors.primary.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('REDĂ ACUM',
                              style: TvTypography.caption.copyWith(
                                color: TvColors.primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 9,
                              )),
                        ),
                        const SizedBox(width: TvSpacing.sm),
                      ],
                      Flexible(
                        child: Text(
                          station.title,
                          style: TvTypography.label.copyWith(
                            fontSize: 14,
                            color: TvColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: TvSpacing.xs),
                  // Song title
                  Text(
                    station.songTitle.isNotEmpty
                        ? station.songTitle
                        : station.title,
                    style: TvTypography.headline.copyWith(fontSize: 22),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (station.songArtist.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      station.songArtist,
                      style: TvTypography.body.copyWith(
                          fontSize: 14, color: TvColors.textSecondary),
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
