import 'dart:async';
import 'dart:ui';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../../widgets/animated_play_button.dart';
import '../tv_theme.dart';

/// Full-screen TV now playing page.
/// Blurred artwork background. Artwork left, metadata + controls + 3 recent songs right.
/// Remote media keys bound directly.
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
  final List<_SongHistoryEntry> _songHistory = [];

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
      // Keep only last 10 in memory (display 3)
      if (_songHistory.length > 10) {
        _songHistory.removeRange(10, _songHistory.length);
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
      child: Focus(
        onKeyEvent: _onKeyEvent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Blurred artwork background
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: SizedBox.expand(
                key: ValueKey('np-bg-${station.id}-${station.artUri}'),
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      Colors.black.withValues(alpha: 0.55),
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
            // Content
            Padding(
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
                    child: Padding(
                      padding: const EdgeInsets.all(TvSpacing.lg),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 400),
                            child: Container(
                              key: ValueKey('np-art-${station.artUri}'),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                    TvSpacing.radiusLg),
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        Colors.black.withValues(alpha: 0.4),
                                    blurRadius: 30,
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
                      ),
                    ),
                  ),
                  const SizedBox(width: TvSpacing.lg),
                  // RIGHT: Metadata + controls + recent songs
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: TvSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Station name
                          Text(
                            station.title,
                            style: TvTypography.body.copyWith(
                              color: TvColors.textSecondary,
                              fontSize: 18,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: TvSpacing.sm),
                          // Song title
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: Align(
                              alignment: Alignment.centerLeft,
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
                          ),
                          if (station.songArtist.isNotEmpty) ...[
                            const SizedBox(height: TvSpacing.xs),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  station.songArtist,
                                  key: ValueKey(
                                      'np-artist-${station.songId}'),
                                  style: TvTypography.title.copyWith(
                                    color: TvColors.textSecondary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: TvSpacing.sm),
                          // Listener count
                          Row(
                            children: [
                              const Icon(Icons.headphones_rounded,
                                  size: 16, color: TvColors.textTertiary),
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
                          const Spacer(),
                          // Recent songs — last 3 only
                          Text(
                            'Melodii recente',
                            style: TvTypography.title.copyWith(fontSize: 16),
                          ),
                          const SizedBox(height: TvSpacing.sm),
                          if (_songHistory.isEmpty)
                            Text(
                              'Melodiile redate vor apărea aici',
                              style: TvTypography.caption,
                            )
                          else
                            ...List.generate(
                              _songHistory.length.clamp(0, 3),
                              (i) => _SongHistoryTile(
                                  entry: _songHistory[i]),
                            ),
                        ],
                      ),
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
          color: TvColors.surfaceVariant.withValues(alpha: 0.7),
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
        const SizedBox(width: TvSpacing.md),
        // Skip previous
        _buildControlButton(
          icon: Icons.skip_previous_rounded,
          iconColor: TvColors.textPrimary,
          iconSize: 28,
          size: 52,
          onSelect: () {
            _playButtonKey.currentState?.notifyWillPlay();
            _audioHandler.skipToPrevious();
          },
        ),
        const SizedBox(width: TvSpacing.md),
        // Play/Pause — large
        AnimatedPlayButton(
          key: _playButtonKey,
          playbackStateStream: _audioHandler.playbackState,
          iconSize: 48,
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
          iconSize: 28,
          size: 52,
          onSelect: () {
            _playButtonKey.currentState?.notifyWillPlay();
            _audioHandler.skipToNext();
          },
        ),
        const SizedBox(width: TvSpacing.md),
        // Like
        _buildControlButton(
          icon: Icons.thumb_up_alt_rounded,
          iconSize: 20,
          autofocus: true,
          onSelect: () => _audioHandler.customAction('likeSong'),
        ),
        const SizedBox(width: TvSpacing.sm),
        // Dislike
        _buildControlButton(
          icon: Icons.thumb_down_alt_rounded,
          iconSize: 20,
          onSelect: () => _audioHandler.customAction('dislikeSong'),
        ),
      ],
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const Icon(Icons.music_note_rounded,
              size: 14, color: TvColors.textTertiary),
          const SizedBox(width: TvSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
          const SizedBox(width: TvSpacing.sm),
          Text(
            _timeAgo,
            style: TvTypography.caption.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
