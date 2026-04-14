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
import '../../widgets/animated_play_button.dart';
import '../tv_theme.dart';
import '../widgets/tv_station_row.dart';

/// Unified TV page: Now Playing background with station rows overlaid.
///
/// Layout (full screen, single scrollable view):
/// - Background: blurred artwork of current station
/// - Top: favorite button (right)
/// - Center: artwork (left) + metadata + controls (right)
/// - Bottom: station browse rows (Favorites, All, categories)
///   - D-pad down from controls reaches station rows
///   - Selecting a station switches playback, background updates
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

  Station? _station;
  List<Station> _allStations = [];
  List<String> _favoriteSlugs = [];
  List<Query$GetStations$station_groups> _groups = [];
  final List<_SongHistoryEntry> _songHistory = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest5(
        _audioHandler.currentStation.stream,
        _stationDataService.stations.stream,
        _stationDataService.favoriteStationSlugs.stream,
        _stationDataService.stationGroups.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (Station? station, List<Station> all, List<String> favs,
            List<Query$GetStations$station_groups> groups, _) {
          return (station, all, favs, groups);
        },
      ).listen((data) {
        if (mounted) {
          final newStation = data.$1;
          final oldStation = _station;
          setState(() {
            _station = newStation;
            _allStations = data.$2;
            _favoriteSlugs = data.$3;
            _groups = data.$4;
          });
          if (newStation != null &&
              newStation.songTitle.isNotEmpty &&
              (oldStation == null ||
                  oldStation.songId != newStation.songId)) {
            _addToHistory(newStation);
          }
        }
      }),
    );
  }

  void _addToHistory(Station station) {
    setState(() {
      _songHistory.insert(
        0,
        _SongHistoryEntry(
          songTitle: station.songTitle,
          songArtist: station.songArtist,
          timestamp: DateTime.now(),
        ),
      );
      if (_songHistory.length > 10) {
        _songHistory.removeRange(10, _songHistory.length);
      }
    });
  }

  List<_SongHistoryEntry> get _previousSongs =>
      _songHistory.length > 1 ? _songHistory.sublist(1) : [];

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

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  bool get _isFavorite =>
      _station != null && _favoriteSlugs.contains(_station!.slug);

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

  void _onStationSelected(Station station) {
    _audioHandler.playStation(station);
  }

  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onSelect,
    Color? iconColor,
    double iconSize = 24,
    double size = 48,
    bool autofocus = false,
  }) {
    return DpadFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.1,
        borderColor: TvColors.focusBorder,
        borderWidth: 2,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: TvColors.surfaceVariant.withValues(alpha: 0.6),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor ?? TvColors.textSecondary, size: iconSize),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    final prevSongs = _previousSongs;

    return Focus(
      onKeyEvent: _onKeyEvent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Blurred background — current station artwork
          if (station != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: SizedBox.expand(
                key: ValueKey('bg-${station.id}-${station.artUri}'),
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      Colors.black.withValues(alpha: 0.7),
                      BlendMode.darken,
                    ),
                    child: FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: 200,
                        height: 200,
                        child: station.displayThumbnail(cacheWidth: 400),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Scrollable content overlaid
          SafeArea(
            child: CustomScrollView(
              slivers: [
                // === NOW PLAYING SECTION ===
                if (station != null) ...[
                  // Top bar: favorite (right-aligned)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: TvSpacing.marginHorizontal,
                        right: TvSpacing.marginHorizontal,
                        top: TvSpacing.md,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          DpadFocusable(
                            onSelect: () =>
                                _audioHandler.customAction('toggleFavorite'),
                            builder: FocusEffects.scaleWithBorder(
                              scale: 1.1,
                              borderColor: TvColors.primary,
                              borderWidth: 2,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.4),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _isFavorite
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                color: _isFavorite
                                    ? TvColors.primary
                                    : Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Artwork + metadata + controls
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: TvSpacing.marginHorizontal,
                      ),
                      child: SizedBox(
                        height: 300,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Artwork
                            AspectRatio(
                              aspectRatio: 1,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 400),
                                child: Container(
                                  key: ValueKey('art-${station.artUri}'),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                        TvSpacing.radiusLg),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.5),
                                        blurRadius: 40,
                                        spreadRadius: 5,
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                        TvSpacing.radiusLg),
                                    child: station.displayThumbnail(
                                        cacheWidth: 600),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: TvSpacing.xl),
                            // Metadata + controls + prev songs
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    station.title,
                                    style: TvTypography.body.copyWith(
                                      color: TvColors.textSecondary,
                                      fontSize: 17,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: TvSpacing.sm),
                                  AnimatedSwitcher(
                                    duration:
                                        const Duration(milliseconds: 250),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        station.songTitle.isNotEmpty
                                            ? station.songTitle
                                            : 'Live Radio',
                                        key: ValueKey(
                                            'song-${station.songId}'),
                                        style: TvTypography.displayMedium,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  if (station.songArtist.isNotEmpty) ...[
                                    const SizedBox(height: TvSpacing.xs),
                                    AnimatedSwitcher(
                                      duration:
                                          const Duration(milliseconds: 250),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          station.songArtist,
                                          key: ValueKey(
                                              'artist-${station.songId}'),
                                          style:
                                              TvTypography.title.copyWith(
                                            color: TvColors.textSecondary,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: TvSpacing.sm),
                                  Row(
                                    children: [
                                      const Icon(Icons.headphones_rounded,
                                          size: 16,
                                          color: TvColors.textTertiary),
                                      const SizedBox(width: TvSpacing.xs),
                                      Text(
                                        '${station.totalListeners ?? 0} ascultători',
                                        style: TvTypography.caption,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: TvSpacing.lg),
                                  // Controls
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildControlButton(
                                        icon: Icons.thumb_up_alt_rounded,
                                        iconSize: 20,
                                        onSelect: () => _audioHandler
                                            .customAction('likeSong'),
                                      ),
                                      const SizedBox(width: TvSpacing.md),
                                      _buildControlButton(
                                        icon: Icons.skip_previous_rounded,
                                        iconColor: TvColors.textPrimary,
                                        iconSize: 28,
                                        size: 52,
                                        onSelect: () {
                                          _playButtonKey.currentState
                                              ?.notifyWillPlay();
                                          _audioHandler.skipToPrevious();
                                        },
                                      ),
                                      const SizedBox(width: TvSpacing.md),
                                      AnimatedPlayButton(
                                        key: _playButtonKey,
                                        playbackStateStream:
                                            _audioHandler.playbackState,
                                        iconSize: 48,
                                        iconColor: Colors.white,
                                        backgroundColor: TvColors.primary,
                                        onPlay: _audioHandler.play,
                                        onPause: _audioHandler.pause,
                                        onStop: _audioHandler.stop,
                                      ),
                                      const SizedBox(width: TvSpacing.md),
                                      _buildControlButton(
                                        icon: Icons.skip_next_rounded,
                                        iconColor: TvColors.textPrimary,
                                        iconSize: 28,
                                        size: 52,
                                        autofocus: true,
                                        onSelect: () {
                                          _playButtonKey.currentState
                                              ?.notifyWillPlay();
                                          _audioHandler.skipToNext();
                                        },
                                      ),
                                      const SizedBox(width: TvSpacing.md),
                                      _buildControlButton(
                                        icon: Icons.thumb_down_alt_rounded,
                                        iconSize: 20,
                                        onSelect: () => _audioHandler
                                            .customAction('dislikeSong'),
                                      ),
                                    ],
                                  ),
                                  // Previous songs
                                  if (prevSongs.isNotEmpty) ...[
                                    const SizedBox(height: TvSpacing.md),
                                    Text('Melodii recente',
                                        style: TvTypography.title
                                            .copyWith(fontSize: 14)),
                                    const SizedBox(height: TvSpacing.xs),
                                    ...List.generate(
                                      prevSongs.length.clamp(0, 3),
                                      (i) => _SongHistoryTile(
                                          entry: prevSongs[i]),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                // === STATION BROWSE ROWS ===
                // Favorites
                if (_favoriteStations.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: TvSpacing.lg),
                      child: TvStationRow(
                        title: 'Favorite',
                        stations: _favoriteStations,
                        currentStation: _station,
                        favoriteSlugs: _favoriteSlugs,
                        autofocusFirst: station == null,
                        onStationSelected: _onStationSelected,
                      ),
                    ),
                  ),
                // All stations
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: TvSpacing.md),
                    child: TvStationRow(
                      title: 'Alese pentru tine',
                      stations: _allStations,
                      currentStation: _station,
                      favoriteSlugs: _favoriteSlugs,
                      autofocusFirst:
                          station == null && _favoriteStations.isEmpty,
                      onStationSelected: _onStationSelected,
                    ),
                  ),
                ),
                // Categories
                ..._groupedStations.entries.map((entry) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: TvSpacing.md),
                      child: TvStationRow(
                        title: entry.key,
                        stations: entry.value,
                        currentStation: _station,
                        favoriteSlugs: _favoriteSlugs,
                        onStationSelected: _onStationSelected,
                      ),
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
    );
  }
}

class _SongHistoryEntry {
  final String songTitle;
  final String songArtist;
  final DateTime timestamp;

  _SongHistoryEntry({
    required this.songTitle,
    required this.songArtist,
    required this.timestamp,
  });
}

class _SongHistoryTile extends StatelessWidget {
  final _SongHistoryEntry entry;

  const _SongHistoryTile({required this.entry});

  String get _timeAgo {
    final diff = DateTime.now().difference(entry.timestamp);
    if (diff.inSeconds < 30) return 'acum';
    if (diff.inSeconds < 60) return 'acum ${diff.inSeconds}s';
    if (diff.inMinutes < 60) return 'acum ${diff.inMinutes} min';
    if (diff.inHours < 24) {
      final h = diff.inHours;
      final m = diff.inMinutes % 60;
      return m > 0 ? 'acum ${h}h ${m}min' : 'acum ${h}h';
    }
    return 'acum ${diff.inDays}z';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.music_note_rounded,
              size: 13, color: TvColors.textTertiary),
          const SizedBox(width: TvSpacing.sm),
          Expanded(
            child: Text(
              '${entry.songTitle}${entry.songArtist.isNotEmpty ? ' - ${entry.songArtist}' : ''}',
              style: TvTypography.caption.copyWith(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: TvSpacing.sm),
          Text(_timeAgo, style: TvTypography.caption.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}
