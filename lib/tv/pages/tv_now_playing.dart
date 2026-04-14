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

/// Default TV view — full-screen Now Playing.
/// Shows blurred artwork background, station metadata, and playback controls.
/// Press BACK or D-pad DOWN → opens browse overlay.
class TvNowPlaying extends StatefulWidget {
  final VoidCallback onBrowse;

  const TvNowPlaying({super.key, required this.onBrowse});

  @override
  State<TvNowPlaying> createState() => _TvNowPlayingState();
}

class _TvNowPlayingState extends State<TvNowPlaying> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];
  final _playButtonKey = GlobalKey<AnimatedPlayButtonState>();

  Station? _station;
  List<String> _favoriteSlugs = [];
  final List<_SongEntry> _songHistory = [];

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
            _songHistory.insert(
                0,
                _SongEntry(
                    title: newStation.songTitle,
                    artist: newStation.songArtist));
            if (_songHistory.length > 10) {
              _songHistory.removeRange(10, _songHistory.length);
            }
          }
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

  bool get _isFavorite =>
      _station != null && _favoriteSlugs.contains(_station!.slug);

  /// Previous songs (skip index 0 = current song)
  List<_SongEntry> get _prevSongs =>
      _songHistory.length > 1 ? _songHistory.sublist(1) : [];

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // BACK or DOWN → open browse
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      widget.onBrowse();
      return KeyEventResult.handled;
    }
    // Media keys
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
      _audioHandler.playbackState.value.playing
          ? _audioHandler.pause()
          : _audioHandler.play();
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

  Widget _controlBtn({
    required IconData icon,
    required VoidCallback onSelect,
    Color? color,
    double size = 48,
    double iconSize = 24,
    bool autofocus = false,
  }) {
    return DpadFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.1,
        borderColor: TvColors.primary,
        borderWidth: 2,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: TvColors.surfaceVariant.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color ?? TvColors.textSecondary, size: iconSize),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;

    // No station loaded yet — show loading
    if (station == null) {
      return const Center(
        child: CircularProgressIndicator(color: TvColors.primary),
      );
    }

    final prevSongs = _prevSongs;

    return Focus(
      onKeyEvent: _onKeyEvent,
      autofocus: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Blurred artwork background
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: SizedBox.expand(
              key: ValueKey('np-bg-${station.id}-${station.artUri}'),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    Colors.black.withValues(alpha: 0.65),
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
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: TvSpacing.marginHorizontal,
                vertical: TvSpacing.marginVertical,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // LEFT: Artwork
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
                                borderRadius:
                                    BorderRadius.circular(TvSpacing.radiusLg),
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        Colors.black.withValues(alpha: 0.5),
                                    blurRadius: 40,
                                    spreadRadius: 5,
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(TvSpacing.radiusLg),
                                child:
                                    station.displayThumbnail(cacheWidth: 600),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: TvSpacing.lg),
                  // RIGHT: Metadata + controls + prev songs
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Station name
                        Text(
                          station.title,
                          style: TvTypography.body.copyWith(
                              color: TvColors.textSecondary, fontSize: 17),
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
                              key: ValueKey('song-${station.songId}'),
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
                                key: ValueKey('artist-${station.songId}'),
                                style: TvTypography.title
                                    .copyWith(color: TvColors.textSecondary),
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
                                size: 16, color: TvColors.textTertiary),
                            const SizedBox(width: TvSpacing.xs),
                            Text('${station.totalListeners ?? 0} ascultători',
                                style: TvTypography.caption),
                          ],
                        ),
                        const SizedBox(height: TvSpacing.xl),
                        // Controls: like, prev, play/pause, next, dislike, fav
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _controlBtn(
                              icon: _isFavorite
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: _isFavorite
                                  ? TvColors.primary
                                  : TvColors.textSecondary,
                              onSelect: () =>
                                  _audioHandler.customAction('toggleFavorite'),
                            ),
                            const SizedBox(width: TvSpacing.md),
                            _controlBtn(
                              icon: Icons.thumb_up_alt_rounded,
                              iconSize: 20,
                              onSelect: () =>
                                  _audioHandler.customAction('likeSong'),
                            ),
                            const SizedBox(width: TvSpacing.md),
                            _controlBtn(
                              icon: Icons.skip_previous_rounded,
                              color: TvColors.textPrimary,
                              iconSize: 28,
                              size: 52,
                              onSelect: () {
                                _playButtonKey.currentState?.notifyWillPlay();
                                _audioHandler.skipToPrevious();
                              },
                            ),
                            const SizedBox(width: TvSpacing.md),
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
                            _controlBtn(
                              icon: Icons.skip_next_rounded,
                              color: TvColors.textPrimary,
                              iconSize: 28,
                              size: 52,
                              autofocus: true,
                              onSelect: () {
                                _playButtonKey.currentState?.notifyWillPlay();
                                _audioHandler.skipToNext();
                              },
                            ),
                            const SizedBox(width: TvSpacing.md),
                            _controlBtn(
                              icon: Icons.thumb_down_alt_rounded,
                              iconSize: 20,
                              onSelect: () =>
                                  _audioHandler.customAction('dislikeSong'),
                            ),
                          ],
                        ),
                        // Previous songs
                        if (prevSongs.isNotEmpty) ...[
                          const SizedBox(height: TvSpacing.lg),
                          Text('Melodii recente',
                              style:
                                  TvTypography.title.copyWith(fontSize: 14)),
                          const SizedBox(height: TvSpacing.xs),
                          ...List.generate(
                            prevSongs.length.clamp(0, 3),
                            (i) {
                              final s = prevSongs[i];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  '${s.title}${s.artist.isNotEmpty ? ' - ${s.artist}' : ''}',
                                  style: TvTypography.caption
                                      .copyWith(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Bottom hint
          Positioned(
            bottom: TvSpacing.md,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedOpacity(
                opacity: 0.5,
                duration: const Duration(milliseconds: 300),
                child: Text(
                  'Apasă ◄ pentru a schimba postul',
                  style: TvTypography.caption.copyWith(fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SongEntry {
  final String title;
  final String artist;
  _SongEntry({required this.title, required this.artist});
}
