import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../../widgets/animated_play_button.dart';
import '../tv_theme.dart';

/// Full-screen TV now playing page.
/// Layout: Large artwork on left, metadata + controls + recent songs on right.
class TvNowPlayingPage extends StatefulWidget {
  final VoidCallback onBack;

  const TvNowPlayingPage({super.key, required this.onBack});

  @override
  State<TvNowPlayingPage> createState() => _TvNowPlayingPageState();
}

class _TvNowPlayingPageState extends State<TvNowPlayingPage> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];
  final _playButtonKey = GlobalKey<AnimatedPlayButtonState>();

  Station? _station;
  List<String> _favoriteSlugs = [];
  List<_SongHistoryEntry> _songHistory = [];

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();

    _subscriptions.add(
      Rx.combineLatest2(
        _audioHandler.currentStation.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (Station? station, List<String> favs) => (station, favs),
      ).listen((data) {
        if (mounted) {
          final newStation = data.$1;
          final oldStation = _station;
          setState(() {
            _station = newStation;
            _favoriteSlugs = data.$2;
          });
          // Track song changes for history
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
          stationTitle: station.title,
          timestamp: DateTime.now(),
        ),
      );
      if (_songHistory.length > 20) {
        _songHistory = _songHistory.sublist(0, 20);
      }
    });
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

  @override
  Widget build(BuildContext context) {
    final station = _station;
    if (station == null) {
      return const Center(
        child: Text('Nu se redă nimic', style: TvTypography.headline),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TvSpacing.marginHorizontal,
          vertical: TvSpacing.marginVertical,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // LEFT: Large artwork
            Expanded(
              flex: 4,
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: ClipRRect(
                      key: ValueKey('np-art-${station.artUri}'),
                      borderRadius:
                          BorderRadius.circular(TvSpacing.radiusLg),
                      child: station.displayThumbnail(cacheWidth: 600),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: TvSpacing.xxl),
            // RIGHT: Metadata + controls + song history
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Station name
                  Text(
                    station.title,
                    style: TvTypography.headline.copyWith(
                      color: TvColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: TvSpacing.sm),
                  // Song title
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      station.songTitle.isNotEmpty
                          ? station.songTitle
                          : 'Live Radio',
                      key: ValueKey('np-song-${station.songId}'),
                      style: TvTypography.displayMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (station.songArtist.isNotEmpty) ...[
                    const SizedBox(height: TvSpacing.xs),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(
                        station.songArtist,
                        key: ValueKey('np-artist-${station.songId}'),
                        style: TvTypography.title.copyWith(
                          color: TvColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  const SizedBox(height: TvSpacing.sm),
                  // Listener count
                  Row(
                    children: [
                      const Icon(
                        Icons.headphones_rounded,
                        size: 16,
                        color: TvColors.textTertiary,
                      ),
                      const SizedBox(width: TvSpacing.xs),
                      Text(
                        '${station.totalListeners ?? 0} ascultători',
                        style: TvTypography.caption,
                      ),
                    ],
                  ),
                  const SizedBox(height: TvSpacing.xl),
                  // Transport controls
                  _buildControls(),
                  const SizedBox(height: TvSpacing.xl),
                  // Recent songs section
                  if (_songHistory.isNotEmpty) ...[
                    Text(
                      'Melodii recente',
                      style: TvTypography.title.copyWith(fontSize: 18),
                    ),
                    const SizedBox(height: TvSpacing.sm),
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _songHistory.length.clamp(0, 8),
                        itemBuilder: (context, index) {
                          final entry = _songHistory[index];
                          return _SongHistoryTile(entry: entry);
                        },
                      ),
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
        decoration: const BoxDecoration(
          color: TvColors.surfaceVariant,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: iconColor ?? TvColors.textSecondary,
          size: iconSize,
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Favorite
        _buildControlButton(
          icon: _isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          iconColor: _isFavorite ? TvColors.primary : TvColors.textSecondary,
          onSelect: () => _audioHandler.customAction('toggleFavorite'),
        ),
        const SizedBox(width: TvSpacing.lg),
        // Skip previous
        _buildControlButton(
          icon: Icons.skip_previous_rounded,
          iconColor: TvColors.textPrimary,
          iconSize: 32,
          size: 56,
          onSelect: () {
            _playButtonKey.currentState?.notifyWillPlay();
            _audioHandler.skipToPrevious();
          },
        ),
        const SizedBox(width: TvSpacing.md),
        // Play/Pause
        AnimatedPlayButton(
          key: _playButtonKey,
          playbackStateStream: _audioHandler.playbackState,
          iconSize: 40,
          iconColor: Colors.white,
          backgroundColor: TvColors.primary,
          onPlay: _audioHandler.play,
          onPause: _audioHandler.pause,
          onStop: _audioHandler.stop,
        ),
        const SizedBox(width: TvSpacing.md),
        // Skip next
        _buildControlButton(
          icon: Icons.skip_next_rounded,
          iconColor: TvColors.textPrimary,
          iconSize: 32,
          size: 56,
          onSelect: () {
            _playButtonKey.currentState?.notifyWillPlay();
            _audioHandler.skipToNext();
          },
        ),
        const SizedBox(width: TvSpacing.lg),
        // Like song
        _buildControlButton(
          icon: Icons.thumb_up_alt_rounded,
          autofocus: true,
          onSelect: () => _audioHandler.customAction('likeSong'),
        ),
      ],
    );
  }
}

class _SongHistoryEntry {
  final String songTitle;
  final String songArtist;
  final String stationTitle;
  final DateTime timestamp;

  _SongHistoryEntry({
    required this.songTitle,
    required this.songArtist,
    required this.stationTitle,
    required this.timestamp,
  });
}

class _SongHistoryTile extends StatelessWidget {
  final _SongHistoryEntry entry;

  const _SongHistoryTile({required this.entry});

  String get _timeAgo {
    final diff = DateTime.now().difference(entry.timestamp);
    if (diff.inMinutes < 1) return 'acum';
    if (diff.inMinutes < 60) return 'acum ${diff.inMinutes} min';
    return 'acum ${diff.inHours}h';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TvSpacing.xs),
      child: Row(
        children: [
          const Icon(
            Icons.music_note_rounded,
            size: 16,
            color: TvColors.textTertiary,
          ),
          const SizedBox(width: TvSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.songTitle,
                  style: TvTypography.label.copyWith(
                    color: TvColors.textPrimary,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.songArtist.isNotEmpty)
                  Text(
                    entry.songArtist,
                    style: TvTypography.caption.copyWith(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Text(
            _timeAgo,
            style: TvTypography.caption.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
