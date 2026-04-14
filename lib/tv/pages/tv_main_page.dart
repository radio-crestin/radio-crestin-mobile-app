import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../queries/getStations.graphql.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../../widgets/animated_play_button.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_row.dart';

/// Android TV Immersive List layout.
///
/// Full-screen artwork of the focused station fills the background.
/// Metadata (station name, song, controls) overlaid on the left, above card rows.
/// Station rows anchored to the bottom. Focusing a card updates the background.
class TvMainPage extends StatefulWidget {
  const TvMainPage({super.key});

  @override
  State<TvMainPage> createState() => _TvMainPageState();
}

class _TvMainPageState extends State<TvMainPage> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];
  final _playButtonKey = GlobalKey<AnimatedPlayButtonState>();

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
            List<Query$GetStations$station_groups> groups) {
          return (current, all, favs, groups);
        },
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

  /// The station whose artwork fills the background.
  /// Focused station takes priority, falls back to currently playing.
  Station? get _heroStation =>
      _focusedStation ?? _currentStation ?? _allStations.firstOrNull;

  bool get _isFavorite =>
      _heroStation != null && _favoriteSlugs.contains(_heroStation!.slug);

  bool get _isHeroPlaying =>
      _heroStation != null && _currentStation?.id == _heroStation!.id;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      _playButtonKey.currentState?.notifyWillPlay();
      _audioHandler.skipToNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      _playButtonKey.currentState?.notifyWillPlay();
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
    final hero = _heroStation;

    return Focus(
      onKeyEvent: _onKeyEvent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // === LAYER 1: Full-screen artwork background ===
          if (hero != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              child: SizedBox.expand(
                key: ValueKey('bg-${hero.id}-${hero.artUri}'),
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: 800,
                    height: 450,
                    child: hero.displayThumbnail(cacheWidth: 800),
                  ),
                ),
              ),
            ),

          // === LAYER 2: Gradient scrim (dark at bottom for cards) ===
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.1),
                    Colors.black.withValues(alpha: 0.3),
                    Colors.black.withValues(alpha: 0.85),
                    Colors.black.withValues(alpha: 0.95),
                  ],
                  stops: const [0.0, 0.35, 0.6, 1.0],
                ),
              ),
            ),
          ),

          // === LAYER 3: Content (metadata + card rows) ===
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top spacer — pushes metadata to lower portion
                const Spacer(),

                // Metadata overlay — left aligned, above the card rows
                if (hero != null)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: TvSpacing.marginHorizontal,
                      right: TvSpacing.marginHorizontal,
                      bottom: TvSpacing.md,
                    ),
                    child: _ImmersiveMetadata(
                      station: hero,
                      isPlaying: _isHeroPlaying,
                      isFavorite: _isFavorite,
                      audioHandler: _audioHandler,
                      playButtonKey: _playButtonKey,
                    ),
                  ),

                // Station card rows — anchored to bottom
                _buildStationRows(),

                const SizedBox(height: TvSpacing.sm),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStationRows() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Favorites row
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
        // All stations
        TvStationRow(
          title: 'Alese pentru tine',
          stations: _allStations,
          currentStation: _currentStation,
          favoriteSlugs: _favoriteSlugs,
          autofocusFirst: _favoriteStations.isEmpty,
          onStationSelected: _onStationSelected,
          onStationFocused: _onStationFocused,
        ),
        // Category rows — only the first 2 visible initially
        ..._groupedStations.entries.take(2).map((entry) {
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
    );
  }
}

/// Metadata overlay for the immersive list hero area.
/// Shows station name, song, artist, listeners, and compact controls.
class _ImmersiveMetadata extends StatelessWidget {
  final Station station;
  final bool isPlaying;
  final bool isFavorite;
  final AppAudioHandler audioHandler;
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;

  const _ImmersiveMetadata({
    required this.station,
    required this.isPlaying,
    required this.isFavorite,
    required this.audioHandler,
    required this.playButtonKey,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Station name + playing indicator
        Row(
          children: [
            if (isPlaying) ...[
              const Icon(Icons.equalizer_rounded,
                  color: TvColors.primary, size: 16),
              const SizedBox(width: TvSpacing.xs),
            ],
            if (isFavorite) ...[
              const Icon(Icons.favorite_rounded,
                  color: TvColors.primary, size: 14),
              const SizedBox(width: TvSpacing.xs),
            ],
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  station.title,
                  key: ValueKey('meta-station-${station.id}'),
                  style: TvTypography.label.copyWith(
                    color: TvColors.textSecondary,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (station.totalListeners != null &&
                station.totalListeners > 0) ...[
              const SizedBox(width: TvSpacing.md),
              Text(
                '${station.totalListeners} ascultători',
                style: TvTypography.caption,
              ),
            ],
          ],
        ),
        const SizedBox(height: TvSpacing.xs),
        // Song title — large
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              station.songTitle.isNotEmpty ? station.songTitle : station.title,
              key: ValueKey('meta-song-${station.id}-${station.songId}'),
              style: TvTypography.displayMedium.copyWith(fontSize: 28),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        // Artist
        if (station.songArtist.isNotEmpty) ...[
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              station.songArtist,
              key: ValueKey('meta-artist-${station.id}-${station.songId}'),
              style: TvTypography.body.copyWith(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
