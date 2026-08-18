import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../appAudioHandler.dart';
import '../../services/playlist_controller.dart';
import '../../services/station_data_service.dart';
import '../../types/Station.dart';
import '../../types/playlist_item.dart';
import '../../widgets/video_overlay_controls.dart' show shouldShowVideoControls;
import '../../widgets/youtube_iframe_player.dart';
import '../tv_platform.dart';
import '../tv_shell.dart';
import '../tv_theme.dart';
import '../widgets/tv_video_surface.dart';

/// TV-only now-playing page.
/// Back (top-left) and favorite (top-right) span full width.
/// Below: artwork left, metadata + recent songs + controls right.
class TvNowPlaying extends StatefulWidget {
  final VoidCallback onBrowse;
  final List<TvSongEntry> songHistory;

  const TvNowPlaying({
    super.key,
    required this.onBrowse,
    required this.songHistory,
  });

  @override
  State<TvNowPlaying> createState() => _TvNowPlayingState();
}

class _TvNowPlayingState extends State<TvNowPlaying> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  late final PlaylistController _playlistController;
  final List<StreamSubscription> _subscriptions = [];

  Station? _station;
  List<String> _favoriteSlugs = [];
  bool _liked = false;
  bool _disliked = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isVideoMode = false;
  // Active YouTube playlist item (cannot be embedded on TV/desktop — shown as
  // an "up next" card that auto-advances).
  PlaylistItem? _youtubeItem;
  PlaylistItem? _playlistItem;
  int _playlistIndex = -1;
  int _playlistCount = 0;
  // Optimistic "user wants it playing" intent: set the instant the user taps
  // play (or picks a station) so the button flips to pause immediately, before
  // the stream confirms. Cleared once playback settles into a real paused state.
  bool _pressedPlay = false;
  int _lastSongId = -1;

  // ── Full-bleed video chrome auto-hide ──────────────────────────────────
  // The idle timer's own state. Effective visibility ([_videoChromeVisible])
  // additionally pins the chrome while paused or buffering, so a still
  // picture never strands the user without a transport.
  bool _chromeIdleVisible = true;
  Timer? _chromeHideTimer;

  /// Holds focus while the chrome is hidden, so the next remote press has
  /// somewhere to land and can bring the chrome back.
  final FocusNode _chromeCatcher =
      FocusNode(debugLabel: 'tv-video-chrome-catcher');

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();
    _playlistController = GetIt.instance<PlaylistController>();

    // Seed synchronously from the in-memory streams so the first frame shows
    // the current station + correct play state instead of a spinner flash.
    _station = _audioHandler.currentStation.valueOrNull;
    _favoriteSlugs = _stationDataService.favoriteStationSlugs.value;
    if (_station != null) _lastSongId = _station!.songId;
    final pb = _audioHandler.playbackState.value;
    _isPlaying = pb.playing;
    _isBuffering = pb.processingState == AudioProcessingState.loading ||
        pb.processingState == AudioProcessingState.buffering;
    _pressedPlay = pb.playing;
    _isVideoMode = _audioHandler.isVideoMode.value;
    _youtubeItem = _playlistController.youtubeRequest.valueOrNull;
    _playlistItem = _playlistController.currentItem.valueOrNull;
    _playlistIndex = _playlistController.currentIndex.value;
    _playlistCount = _playlistController.itemCount;

    _subscriptions.add(_audioHandler.isVideoMode.stream.listen((v) {
      if (!mounted) return;
      setState(() => _isVideoMode = v);
      // Entering video mode starts the idle countdown; leaving it drops the
      // timer and leaves the chrome ready for the next time.
      _revealChrome();
    }));
    _subscriptions.add(_playlistController.youtubeRequest.stream.listen((v) {
      if (!mounted) return;
      setState(() => _youtubeItem = v);
      // Arriving on (or leaving) an embedded YouTube item starts/stops the
      // same idle countdown the video surface uses.
      _revealChrome();
    }));
    _subscriptions.add(_playlistController.currentItem.stream.listen((v) {
      if (mounted) setState(() => _playlistItem = v);
    }));
    _subscriptions.add(_playlistController.currentIndex.stream.listen((v) {
      if (mounted) setState(() => _playlistIndex = v);
    }));
    _subscriptions.add(_playlistController.items.stream.listen((v) {
      if (mounted) setState(() => _playlistCount = v.length);
    }));

    _subscriptions.add(
      Rx.combineLatest2(
        _audioHandler.currentStation.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (Station? station, List<String> favs) => (station, favs),
      ).listen((data) {
        if (mounted) {
          final newStation = data.$1;
          setState(() {
            _station = newStation;
            _favoriteSlugs = data.$2;
          });
          if (newStation != null && newStation.songId != _lastSongId) {
            _lastSongId = newStation.songId;
            _liked = false;
            _disliked = false;
          }
        }
      }),
    );

    _subscriptions.add(
      _audioHandler.playbackState.stream.listen((state) {
        if (!mounted) return;
        final loading =
            state.processingState == AudioProcessingState.loading ||
                state.processingState == AudioProcessingState.buffering;
        final wasMoving = _videoPictureMoving;
        setState(() {
          _isPlaying = state.playing;
          _isBuffering = loading;
          if (state.playing) _pressedPlay = true;
          // Settled into a real paused state → drop the optimistic intent.
          if (!loading && !state.playing) _pressedPlay = false;
        });
        // Only a real start/stop of the picture touches the idle countdown —
        // playbackState also ticks for position updates, and re-arming on
        // every tick would keep the chrome up forever.
        if (_videoPictureMoving != wasMoving) _revealChrome();
      }),
    );
  }

  /// Show the pause icon whenever the user intends playback — actually
  /// playing, buffering toward play, or just-tapped (optimistic) — so the
  /// control never flickers back to "play" while a stream is connecting.
  bool get _showPause => _isPlaying || _isBuffering || _pressedPlay;

  /// Spinner while connecting/buffering toward playback.
  bool get _showSpinner => _isBuffering || (_pressedPlay && !_isPlaying);

  void _togglePlayback() {
    if (_showPause) {
      setState(() => _pressedPlay = false);
      _audioHandler.pauseFromUser();
    } else {
      setState(() => _pressedPlay = true);
      _audioHandler.play();
    }
  }

  /// True when the page is showing a full-bleed picture: the video engine
  /// (live TV / video playlist item) or an embedded YouTube item.
  bool get _fullBleedPlayerActive =>
      _isVideoMode || (_youtubeItem != null && TvPlatform.canEmbedYoutube);

  /// True while there is a moving picture to look at — the only state in
  /// which the chrome is allowed to fade itself out.
  bool get _videoPictureMoving =>
      _fullBleedPlayerActive && _isPlaying && !_showSpinner;

  /// Whether the full-bleed video chrome is on screen right now. Paused or
  /// buffering pins it: nothing is moving, so hiding it would leave the user
  /// staring at a still frame with no way to tell what happened.
  bool get _videoChromeVisible => shouldShowVideoControls(
        userVisible: _chromeIdleVisible,
        playing: _isPlaying,
        buffering: _showSpinner,
      );

  /// Brings the chrome back (if hidden) and restarts the idle countdown.
  void _revealChrome() {
    _chromeHideTimer?.cancel();
    if (!_chromeIdleVisible) {
      if (mounted) setState(() => _chromeIdleVisible = true);
    }
    if (!_videoPictureMoving) return;
    _chromeHideTimer = Timer(kTvVideoChromeAutoHideDelay, () {
      if (!mounted || !_videoPictureMoving) return;
      setState(() => _chromeIdleVisible = false);
      // The chrome's focusables are gone — park focus on the catcher so the
      // next remote press still reaches this page.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_videoChromeVisible && !_chromeCatcher.hasFocus) {
          _chromeCatcher.requestFocus();
        }
      });
    });
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _chromeHideTimer?.cancel();
    _chromeCatcher.dispose();
    super.dispose();
  }

  bool get _isFavorite =>
      _station != null && _favoriteSlugs.contains(_station!.slug);

  List<TvSongEntry> get _prevSongs =>
      widget.songHistory.length > 1 ? widget.songHistory.sublist(1) : [];

  /// Keys that keep acting even on the press that wakes the hidden chrome:
  /// transport (the remote's own media keys) and BACK, which must never need
  /// two presses to leave the player.
  static final Set<LogicalKeyboardKey> _alwaysActingKeys = {
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
    LogicalKeyboardKey.mediaPause,
    LogicalKeyboardKey.mediaTrackNext,
    LogicalKeyboardKey.mediaTrackPrevious,
    LogicalKeyboardKey.goBack,
    LogicalKeyboardKey.escape,
  };

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Any remote press wakes the hidden video chrome and restarts its idle
    // countdown. The waking press itself is swallowed — except for the media
    // and BACK keys, which must always do their job — so a blind D-pad press
    // can never trigger a control the user cannot see yet.
    if (_fullBleedPlayerActive) {
      final wasHidden = !_videoChromeVisible;
      _revealChrome();
      if (wasHidden && !_alwaysActingKeys.contains(key)) {
        return KeyEventResult.handled;
      }
    }
    // BACK is intentionally NOT handled here. Android TV delivers one BACK
    // press as both a raw goBack KeyEvent AND a route pop; handling it here
    // too caused a double navigation (Now Playing → Browse → bounce back).
    // It now flows through this page's PopScope only (see build).
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      _audioHandler.skipToNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      _audioHandler.skipToPrevious();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlayback();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _audioHandler.customAction('toggleFavorite');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL) {
      setState(() { _liked = !_liked; if (_liked) _disliked = false; });
      _audioHandler.customAction('likeSong');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyD) {
      setState(() { _disliked = !_disliked; if (_disliked) _liked = false; });
      _audioHandler.customAction('dislikeSong');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _btn({
    required IconData icon,
    required VoidCallback onSelect,
    Color? color,
    double size = 48,
    double iconSize = 24,
    bool autofocus = false,
    Color? bg,
    String? region,
    bool isEntryPoint = false,
    bool enabled = true,
  }) {
    return DpadFocusable(
      autofocus: autofocus,
      enabled: enabled,
      onSelect: onSelect,
      region: region,
      isEntryPoint: isEntryPoint,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.1,
        borderColor: TvColors.primary,
        borderWidth: 3,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg ?? TvColors.surfaceVariant.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color ?? TvColors.textSecondary, size: iconSize),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final station = _station;
    if (station == null) {
      return const Center(
        child: CircularProgressIndicator(color: TvColors.primary),
      );
    }

    // Playlist reached a YouTube item — cannot embed on TV/desktop, show the
    // auto-advancing "up next" card instead.
    if (_youtubeItem != null) return _wrap(_buildYoutubeLayout(station));
    // TV video mode (live TV or a playlist video item) — full-bleed video.
    if (_isVideoMode) return _wrap(_buildVideoLayout(station));

    final prevSongs = _prevSongs;
    return _wrap(
      // No autofocus on the parent: it would steal focus from the play
      // button below, which is the intended landing target so the user
      // can pause/resume immediately when opening a station.
      Stack(
        fit: StackFit.expand,
        children: [
          // Blurred artwork background
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: SizedBox.expand(
              key: ValueKey('bg-${station.id}-${station.artUri}'),
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
              padding: EdgeInsets.symmetric(
                horizontal: TvSpacing.marginHorizontal,
                vertical: TvSpacing.md,
              ),
              child: Column(
                children: [
                  // Top row: back + favorite
                  Row(
                    children: [
                      _btn(
                        icon: Icons.arrow_back_rounded,
                        size: 40,
                        iconSize: 22,
                        color: Colors.white,
                        bg: Colors.black.withValues(alpha: 0.4),
                        onSelect: widget.onBrowse,
                        region: 'np-top',
                      ),
                      const Spacer(),
                      _btn(
                        icon: _isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 40,
                        iconSize: 22,
                        color: _isFavorite ? TvColors.primary : Colors.white,
                        bg: Colors.black.withValues(alpha: 0.4),
                        onSelect: () =>
                            _audioHandler.customAction('toggleFavorite'),
                        region: 'np-top',
                        isEntryPoint: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: TvSpacing.sm),
                  // Main: artwork + metadata/controls
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Artwork
                        Expanded(
                          flex: 4,
                          child: Padding(
                            padding: const EdgeInsets.all(TvSpacing.md),
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 400),
                                  child: Container(
                                    key: ValueKey('art-${station.artUri}'),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(TvSpacing.radiusLg),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.5),
                                          blurRadius: 40,
                                          spreadRadius: 5,
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(TvSpacing.radiusLg),
                                      child: station.displayThumbnail(cacheWidth: 600),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: TvSpacing.lg),
                        // Right side
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                station.title,
                                style: TvTypography.body.copyWith(
                                    color: TvColors.textSecondary, fontSize: 17),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: TvSpacing.sm),
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
                                  Text(
                                      '${station.totalListeners ?? 0} ascultători',
                                      style: TvTypography.caption),
                                ],
                              ),
                              // Recent songs
                              if (prevSongs.isNotEmpty) ...[
                                const SizedBox(height: TvSpacing.lg),
                                Text('Melodii recente',
                                    style: TvTypography.title.copyWith(fontSize: 15)),
                                const SizedBox(height: TvSpacing.sm),
                                ...List.generate(
                                  prevSongs.length.clamp(0, 3),
                                  (i) => _SongTile(entry: prevSongs[i]),
                                ),
                              ],
                              const SizedBox(height: TvSpacing.xl),
                              // Controls
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _btn(
                                    icon: _liked
                                        ? Icons.thumb_up_alt_rounded
                                        : Icons.thumb_up_alt_outlined,
                                    iconSize: 20,
                                    color: _liked ? TvColors.primary : null,
                                    region: 'np-controls',
                                    onSelect: () {
                                      setState(() {
                                        _liked = !_liked;
                                        if (_liked) _disliked = false;
                                      });
                                      _audioHandler.customAction('likeSong');
                                    },
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  _btn(
                                    icon: Icons.skip_previous_rounded,
                                    color: TvColors.textPrimary,
                                    iconSize: 28,
                                    size: 52,
                                    region: 'np-controls',
                                    onSelect: () => _audioHandler.skipToPrevious(),
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  DpadFocusable(
                                    autofocus: true,
                                    region: 'np-controls',
                                    isEntryPoint: true,
                                    onSelect: _togglePlayback,
                                    builder: FocusEffects.scaleWithBorder(
                                      scale: 1.12,
                                      borderColor: Colors.white,
                                      borderWidth: 4,
                                      borderRadius: BorderRadius.circular(36),
                                    ),
                                    child: SizedBox(
                                      width: 64,
                                      height: 64,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          const DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: TvColors.primary,
                                              shape: BoxShape.circle,
                                            ),
                                            child: SizedBox.expand(),
                                          ),
                                          if (_showSpinner)
                                            const Padding(
                                              padding: EdgeInsets.all(3),
                                              child: SizedBox.expand(
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2.5,
                                                  valueColor:
                                                      AlwaysStoppedAnimation(
                                                          Colors.white),
                                                ),
                                              ),
                                            ),
                                          AnimatedSwitcher(
                                            duration: const Duration(
                                                milliseconds: 150),
                                            child: Icon(
                                              _showPause
                                                  ? Icons.pause_rounded
                                                  : Icons.play_arrow_rounded,
                                              key: ValueKey(_showPause),
                                              color: Colors.white,
                                              size: 36,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  _btn(
                                    icon: Icons.skip_next_rounded,
                                    color: TvColors.textPrimary,
                                    iconSize: 28,
                                    size: 52,
                                    region: 'np-controls',
                                    onSelect: () => _audioHandler.skipToNext(),
                                  ),
                                  const SizedBox(width: TvSpacing.md),
                                  _btn(
                                    icon: _disliked
                                        ? Icons.thumb_down_alt_rounded
                                        : Icons.thumb_down_alt_outlined,
                                    iconSize: 20,
                                    color: _disliked ? TvColors.primary : null,
                                    region: 'np-controls',
                                    onSelect: () {
                                      setState(() {
                                        _disliked = !_disliked;
                                        if (_disliked) _liked = false;
                                      });
                                      _audioHandler.customAction('dislikeSong');
                                    },
                                  ),
                                ],
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
          ),
        ],
      ),
    );
  }

  /// Wraps a page layout in the shared BACK handling + key-event focus.
  Widget _wrap(Widget child) {
    return PopScope(
      // System BACK on Now Playing returns to Browse, not exit.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBrowse();
      },
      child: Focus(onKeyEvent: _onKeyEvent, child: child),
    );
  }

  /// The primary play/pause control (brand circle + optimistic spinner).
  Widget _bigPlayButton({required bool autofocus, bool enabled = true}) {
    return DpadFocusable(
      autofocus: autofocus,
      enabled: enabled,
      region: 'np-controls',
      isEntryPoint: true,
      onSelect: _togglePlayback,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.12,
        borderColor: Colors.white,
        borderWidth: 4,
        borderRadius: BorderRadius.circular(36),
      ),
      child: SizedBox(
        width: 64,
        height: 64,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                color: TvColors.primary,
                shape: BoxShape.circle,
              ),
              child: SizedBox.expand(),
            ),
            if (_showSpinner)
              const Padding(
                padding: EdgeInsets.all(3),
                child: SizedBox.expand(
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Icon(
                _showPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(_showPause),
                color: Colors.white,
                size: 36,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Full-bleed video layout for TV video mode (live TV / playlist video item)
  /// with an overlay scrim carrying the title, LIVE pill, playlist counter and
  /// transport controls.
  ///
  /// The chrome auto-hides after [kTvVideoChromeAutoHideDelay] of remote
  /// inactivity so the picture is left alone, and comes back on any press.
  Widget _buildVideoLayout(Station station) => _fullBleedPlayer(
        station,
        surface: TvVideoSurface(videoService: _audioHandler.videoService),
      );

  /// The full-bleed player shell: [surface] (video engine or YouTube iframe)
  /// under the auto-hiding chrome and its focus catcher.
  Widget _fullBleedPlayer(Station station, {required Widget surface}) {
    return Stack(
      fit: StackFit.expand,
      children: [surface, _chromeLayer(station)],
    );
  }

  /// The auto-hiding chrome plus its focus catcher, as one layer.
  Widget _chromeLayer(Station station) {
    final chromeVisible = _videoChromeVisible;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Focus catcher. While the chrome is hidden it is the only focusable
        // on screen, so remote presses still reach [_onKeyEvent] — which is
        // what wakes the chrome back up.
        Focus(
          focusNode: _chromeCatcher,
          canRequestFocus: !chromeVisible,
          child: const SizedBox.expand(),
        ),
        // The chrome fades as one layer. Its controls stop being focusable
        // (and hit-testable) the instant it starts fading out, so a
        // half-transparent button can never be activated by mistake. The
        // subtree is re-keyed on visibility so the transport remounts when
        // the chrome returns and its `autofocus` seats focus again.
        IgnorePointer(
          ignoring: !chromeVisible,
          child: AnimatedOpacity(
            opacity: chromeVisible ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            child: KeyedSubtree(
              key: ValueKey(chromeVisible),
              child: _videoChrome(station, enabled: chromeVisible),
            ),
          ),
        ),
      ],
    );
  }

  /// Back button, title scrim and transport row drawn over the video.
  /// [enabled] gates focus: it is false while the chrome is hidden or fading.
  Widget _videoChrome(Station station, {required bool enabled}) {
    final isPlaylist = station.isPlaylist;
    final counter = _playlistCount > 0 && _playlistIndex >= 0
        ? '${_playlistIndex + 1} / $_playlistCount'
        : '';
    return Stack(
      fit: StackFit.expand,
      children: [
        // Back button, top-left.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(TvSpacing.md),
            child: Align(
              alignment: Alignment.topLeft,
              child: _btn(
                icon: Icons.arrow_back_rounded,
                size: 40,
                iconSize: 22,
                color: Colors.white,
                bg: Colors.black.withValues(alpha: 0.55),
                onSelect: widget.onBrowse,
                region: 'np-top',
                enabled: enabled,
              ),
            ),
          ),
        ),
        // Bottom scrim: metadata + transport.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(TvSpacing.marginHorizontal,
                TvSpacing.xl, TvSpacing.marginHorizontal, TvSpacing.lg),
            // The scrim has to carry white text over ARBITRARY video — a
            // bright frame (a white slide, a snow shot) would otherwise
            // swallow the title. It darkens early rather than only at the
            // very bottom, so the whole chrome band sits on a readable base.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0.9),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (station.isTv) ...[
                      const TvLivePill(),
                      const SizedBox(width: TvSpacing.sm),
                    ],
                    Expanded(
                      child: Text(
                        station.title,
                        style: TvTypography.title.copyWith(
                          fontSize: 20,
                          shadows: const [
                            Shadow(color: Colors.black87, blurRadius: 8),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (isPlaylist && _playlistItem != null) ...[
                  const SizedBox(height: TvSpacing.xs),
                  Row(
                    children: [
                      if (counter.isNotEmpty) ...[
                        Text(counter,
                            style: TvTypography.caption.copyWith(
                                color: TvColors.primary,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: TvSpacing.sm),
                      ],
                      Expanded(
                        child: Text(
                          _playlistItem!.title,
                          style: TvTypography.body
                              .copyWith(color: TvColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: TvSpacing.md),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _btn(
                      icon: Icons.skip_previous_rounded,
                      color: TvColors.textPrimary,
                      iconSize: 28,
                      size: 52,
                      region: 'np-controls',
                      enabled: enabled,
                      onSelect: () => _audioHandler.skipToPrevious(),
                    ),
                    const SizedBox(width: TvSpacing.md),
                    _bigPlayButton(autofocus: true, enabled: enabled),
                    const SizedBox(width: TvSpacing.md),
                    _btn(
                      icon: Icons.skip_next_rounded,
                      color: TvColors.textPrimary,
                      iconSize: 28,
                      size: 52,
                      region: 'np-controls',
                      enabled: enabled,
                      onSelect: () => _audioHandler.skipToNext(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Layout shown when a playlist reaches a YouTube item.
  ///
  /// Android TV plays it for real: the system WebView is there, so the same
  /// `youtube_player_iframe` the phone uses is embedded full-bleed under this
  /// page's own D-pad chrome (the iframe's touch overlay is switched off, and
  /// the webview is kept out of the focus tree so every remote press still
  /// reaches the transport). The desktop shells have no webview, so they keep
  /// the "up next" card that counts down and skips the item.
  Widget _buildYoutubeLayout(Station station) {
    final item = _youtubeItem!;
    if (!TvPlatform.canEmbedYoutube) return _youtubeUnplayableLayout(item);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: YoutubeIframePlayer(
          key: const ValueKey('tv-youtube'),
          item: item,
          controller: _playlistController,
          showInlineOverlay: false,
          overlayBuilder: (_) => _chromeLayer(station),
        ),
      ),
    );
  }

  /// The "cannot be embedded here" card: shown on shells without a webview.
  Widget _youtubeUnplayableLayout(PlaylistItem item) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: TvColors.background),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(TvSpacing.md),
            child: Align(
              alignment: Alignment.topLeft,
              child: _btn(
                icon: Icons.arrow_back_rounded,
                size: 40,
                iconSize: 22,
                color: Colors.white,
                bg: Colors.black.withValues(alpha: 0.4),
                onSelect: widget.onBrowse,
                region: 'np-top',
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(
              horizontal: TvSpacing.marginHorizontal, vertical: TvSpacing.xl),
          child: TvYoutubeUpNextCard(
            item: item,
            onAutoAdvance: _playlistController.notifyYoutubeItemEnded,
          ),
        ),
      ],
    );
  }
}

class _SongTile extends StatelessWidget {
  final TvSongEntry entry;
  const _SongTile({required this.entry});

  String get _timeAgo {
    final diff = DateTime.now().difference(entry.timestamp);
    if (diff.inSeconds < 30) return 'acum';
    if (diff.inSeconds < 60) return 'acum ${diff.inSeconds}s';
    if (diff.inMinutes == 1) return 'acum 1 minut';
    if (diff.inMinutes < 60) return 'acum ${diff.inMinutes} minute';
    if (diff.inHours == 1) return 'acum 1 oră';
    if (diff.inHours < 24) return 'acum ${diff.inHours} ore';
    return 'acum ${diff.inDays} zile';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TvSpacing.sm),
      child: Row(
        children: [
          const Icon(Icons.music_note_rounded,
              size: 16, color: TvColors.textTertiary),
          const SizedBox(width: TvSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.title,
                  style: TvTypography.label
                      .copyWith(fontSize: 14, color: TvColors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.artist.isNotEmpty)
                  Text(
                    entry.artist,
                    style: TvTypography.caption.copyWith(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: TvSpacing.md),
          Text(_timeAgo, style: TvTypography.caption.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}
