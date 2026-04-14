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
import '../widgets/tv_immersive_list.dart';
import '../widgets/tv_station_row.dart';

/// TV main page using the Android TV Immersive List pattern.
///
/// Full-screen artwork background (subject aligned top-right).
/// Cinematic scrim: dark on left + dark on bottom.
/// Content block (station name, song, artist) bottom-left above card rows.
/// Card rows pinned to bottom: Favorites → All → Categories.
/// Focusing a card crossfades the background + updates metadata.
class TvMainPage extends StatefulWidget {
  const TvMainPage({super.key});

  @override
  State<TvMainPage> createState() => _TvMainPageState();
}

class _TvMainPageState extends State<TvMainPage> {
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
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      _audioHandler.skipToNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      _audioHandler.skipToPrevious();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (_audioHandler.playbackState.value.playing) {
        _audioHandler.pause();
      } else {
        _audioHandler.play();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _audioHandler.customAction('toggleFavorite');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL) {
      _audioHandler.customAction('likeSong');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyD) {
      _audioHandler.customAction('dislikeSong');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onStationFocused(Station station) {
    setState(() => _focusedStation = station);
  }

  void _onStationSelected(Station station) {
    _audioHandler.playStation(station);
  }

  @override
  Widget build(BuildContext context) {
    final hero = _hero;

    return Focus(
      onKeyEvent: _onKeyEvent,
      child: TvImmersiveList(
        // Background: full-screen station artwork
        backgroundBuilder: (_) {
          if (hero == null) return const ColoredBox(color: TvColors.background);
          return TvImmersiveBackground(
            childKey: ValueKey('bg-${hero.id}-${hero.artUri}'),
            child: SizedBox(
              width: 960,
              height: 540,
              child: hero.displayThumbnail(cacheWidth: 960),
            ),
          );
        },
        // Content block: metadata overlaid bottom-left
        contentBlock: hero != null
            ? _ContentBlock(
                station: hero,
                isPlaying: _isHeroPlaying,
              )
            : const SizedBox.shrink(),
        // Card rows at bottom
        cardRows: [
          if (_favoriteStations.isNotEmpty)
            TvStationRow(
              title: 'Favorite',
              stations: _favoriteStations,
              currentStation: _currentStation,
              favoriteSlugs: _favoriteSlugs,
              autofocusFirst: true,
              onStationSelected: _onStationSelected,
              onStationFocused: _onStationFocused,
            ),
          TvStationRow(
            title: 'Alese pentru tine',
            stations: _allStations,
            currentStation: _currentStation,
            favoriteSlugs: _favoriteSlugs,
            autofocusFirst: _favoriteStations.isEmpty,
            onStationSelected: _onStationSelected,
            onStationFocused: _onStationFocused,
          ),
          ..._groupedStations.entries.map((entry) {
            return TvStationRow(
              title: entry.key,
              stations: entry.value,
              currentStation: _currentStation,
              favoriteSlugs: _favoriteSlugs,
              onStationSelected: _onStationSelected,
              onStationFocused: _onStationFocused,
            );
          }),
        ],
      ),
    );
  }
}

/// Content block for the immersive list — bottom-left metadata.
/// Shows station tags, title (large), description.
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
        key: ValueKey('content-${station.id}-${station.songId}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tags row: station name + playing status + listeners
          Row(
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
                              fontSize: 10)),
                    ],
                  ),
                ),
                const SizedBox(width: TvSpacing.sm),
              ],
              Text(
                station.title,
                style: TvTypography.caption.copyWith(
                  color: TvColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              if (station.totalListeners != null &&
                  station.totalListeners > 0) ...[
                Text(
                  '  •  ${station.totalListeners} ascultători',
                  style: TvTypography.caption.copyWith(fontSize: 12),
                ),
              ],
            ],
          ),
          const SizedBox(height: TvSpacing.sm),
          // Title — large, prominent
          Text(
            station.songTitle.isNotEmpty ? station.songTitle : station.title,
            style: TvTypography.displayMedium.copyWith(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              height: 1.15,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // Description / artist
          if (station.songArtist.isNotEmpty ||
              station.displaySubtitle.isNotEmpty) ...[
            const SizedBox(height: TvSpacing.xs),
            Text(
              station.songArtist.isNotEmpty
                  ? station.songArtist
                  : station.displaySubtitle,
              style: TvTypography.body.copyWith(
                fontSize: 15,
                color: TvColors.textSecondary,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
