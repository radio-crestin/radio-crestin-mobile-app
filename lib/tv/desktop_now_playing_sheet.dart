import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';
import 'package:url_launcher/url_launcher.dart';

import '../appAudioHandler.dart';
import '../components/FullAudioPlayer.dart'
    show songClipboardText, songSearchQuery;
import '../services/analytics_service.dart';
import '../services/playlist_controller.dart';
import '../services/share_service.dart';
import '../services/song_history_service.dart';
import '../services/song_like_service.dart';
import '../services/station_data_service.dart';
import '../services/video_playback_service.dart';
import '../types/Station.dart';
import '../types/playlist_item.dart';
import '../utils/romanian_count.dart';
import '../widgets/animated_play_button.dart';
import '../widgets/copied_toast.dart';
import '../widgets/player_video_surface.dart' show AudioOnlyChip;
import 'desktop/now_playing_about.dart';
import 'desktop/now_playing_controls.dart';
import 'desktop/now_playing_history_dialog.dart';
import 'desktop/now_playing_layout.dart';
import 'desktop/now_playing_share_menu.dart';
import 'desktop/now_playing_sleep_menu.dart';
import 'tv_theme.dart';
import 'tv_youtube_auto_advance.dart';
import 'widgets/tv_video_surface.dart';

/// The desktop now-playing panel, the player bar opened up (see
/// `DesktopNowPlayingRoute`).
///
/// It has what the iPhone's full player has: the artwork (or the live
/// video), the song, which a click searches on YouTube and a right click
/// copies, like and dislike, previous / play-pause / next with the
/// buffering spinner, and the favorite, sleep timer ("Somn") and share
/// actions. The transport and the actions share one row, the actions as
/// quiet icons, so the panel stays calm.
///
/// Under them it uses the room a desktop window has, in two columns when
/// wide enough: "Melodii recente", the station's last songs before the
/// one playing, from its song history, whose "Vezi tot" opens all of it;
/// and "Despre stație", its description and its links (site, Facebook,
/// e-mail).
///
/// Desktop affordances: every button lights up under the pointer, names
/// itself in a tooltip and takes the keyboard focus; the sleep timer and
/// share open menus at their buttons rather than phone sheets; Esc or the
/// close button closes the panel, and Space, ←/→, F, L and D play/pause,
/// skip, favorite, like and dislike. The artwork sits beside the details
/// in a wide window and above them in a narrow one; the content scrolls
/// rather than overflow when even that doesn't fit.
class DesktopNowPlayingSheet extends StatefulWidget {
  /// The shell's YouTube auto-advance, shown by the "up next" card.
  final ValueListenable<TvYoutubeCountdown?> youtubeCountdown;

  /// Fetches the songs a station played in the last hour; null when the
  /// request fails.
  final Future<List<SongHistoryItem>?> Function(String stationSlug)
      loadSongHistory;

  /// Opens a station's link outside the app.
  final Future<void> Function(Uri uri) openLink;

  const DesktopNowPlayingSheet({
    super.key,
    required this.youtubeCountdown,
    this.loadSongHistory = fetchRecentSongHistory,
    this.openLink = openExternally,
  });

  /// What confirms a copied link, and a copied e-mail address.
  static const String linkCopiedLabel = 'Link copiat';
  static const String addressCopiedLabel = 'Adresă copiată';

  /// Opens [uri] in the browser, or a "mailto:" link in the mail app.
  static Future<void> openExternally(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Nothing took the link; nothing else to offer from here.
    }
  }

  /// The last hour of [stationSlug]'s song history, as "Vezi tot" starts.
  static Future<List<SongHistoryItem>?> fetchRecentSongHistory(
    String stationSlug,
  ) async =>
      (await SongHistoryService.fetchHistory(stationSlug))?.history;

  @override
  State<DesktopNowPlayingSheet> createState() => _DesktopNowPlayingSheetState();
}

class _DesktopNowPlayingSheetState extends State<DesktopNowPlayingSheet> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  late final PlaylistController _playlistController;
  final List<StreamSubscription> _subscriptions = [];
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'desktop-np-keyboard');
  final GlobalKey<AnimatedPlayButtonState> _playButtonKey = GlobalKey();

  /// The panel, for a copy confirmation to rise inside it.
  final GlobalKey _panelKey = GlobalKey();

  Station? _station;
  List<String> _favoriteSlugs = [];
  bool _isPlaying = false;
  bool _isVideoMode = false;
  bool _audioOnlyFallback = false;
  PlaylistItem? _youtubeItem;

  /// The station's songs before the one playing, newest first, for
  /// "Melodii recente"; null while they load.
  List<SongHistoryItem>? _recentSongs;
  bool _recentSongsFailed = false;

  /// The station and song the recent songs were loaded for: another song
  /// loads them again.
  (String, int)? _recentSongsFor;

  /// Counts the loads, for an older one to arrive without effect.
  int _recentSongsLoads = 0;

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();
    _playlistController = GetIt.instance<PlaylistController>();

    // Seeded synchronously, so the first frame shows the station instead
    // of a spinner that the streams replace a frame later.
    _station = _audioHandler.currentStation.valueOrNull;
    _favoriteSlugs = _stationDataService.favoriteStationSlugs.value;
    _isPlaying = _audioHandler.playbackState.valueOrNull?.playing ?? false;
    _isVideoMode = _audioHandler.isVideoMode.value;
    _audioOnlyFallback = _audioHandler.audioOnlyFallback.value;
    _youtubeItem = _playlistController.youtubeRequest.valueOrNull;

    _listen(_audioHandler.isVideoMode, (v) => _isVideoMode = v);
    _listen(_audioHandler.audioOnlyFallback, (v) => _audioOnlyFallback = v);
    _listen(_playlistController.youtubeRequest, (v) => _youtubeItem = v);
    _listen(
      Rx.combineLatest2(
        _audioHandler.currentStation.stream,
        _stationDataService.favoriteStationSlugs.stream,
        (Station? s, List<String> f) => (s, f),
      ),
      (d) {
        _station = d.$1;
        _favoriteSlugs = d.$2;
        _loadRecentSongs();
      },
    );
    _subscriptions.add(
      _audioHandler.playbackState.stream.listen((s) {
        // playbackState re-emits on every position tick (video mode, and
        // media_kit audio on Windows/Linux); only the play flag matters here.
        if (!mounted || s.playing == _isPlaying) return;
        setState(() => _isPlaying = s.playing);
      }),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _refocus());
  }

  /// Rebuilds with [apply] for each value of [stream].
  void _listen<T>(Stream<T> stream, void Function(T value) apply) {
    _subscriptions.add(stream.listen((value) {
      if (mounted) setState(() => apply(value));
    }));
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _keyboardFocus.dispose();
    super.dispose();
  }

  bool get _isFavorite =>
      _station != null && _favoriteSlugs.contains(_station!.slug);

  /// Whether the station named its song, so it can be searched or copied.
  bool get _hasSong {
    final s = _station;
    return s != null && (s.songTitle.isNotEmpty || s.songArtist.isNotEmpty);
  }

  /// Loads the station's recent songs, again once it plays another song
  /// or another station is on.
  void _loadRecentSongs() {
    final station = _station;
    if (station == null) return;
    final String slug = station.slug;
    final key = (slug, station.songId);
    if (key == _recentSongsFor) return;
    if (slug != _recentSongsFor?.$1) {
      // Not the last station's songs meanwhile.
      _recentSongs = null;
      _recentSongsFailed = false;
    }
    _recentSongsFor = key;
    final load = ++_recentSongsLoads;
    widget.loadSongHistory(slug).then((history) {
      if (!mounted || load != _recentSongsLoads) return;
      setState(() {
        _recentSongsFailed = history == null;
        if (history != null) _recentSongs = _songsBefore(history, station);
        _recentSongs ??= const [];
      });
    });
  }

  /// The songs of [history] heard before the one [station] plays, newest
  /// first: the newest is that one, shown above, once the history has it.
  List<SongHistoryItem> _songsBefore(
    List<SongHistoryItem> history,
    Station station,
  ) {
    final heard = SongHistoryService.playedBefore(
      history,
      _stationDataService.playedCutoffFor(station.id),
    );
    if (heard.isNotEmpty && heard.first.songId == station.songId) {
      heard.removeAt(0);
    }
    return heard.take(_RecentSongs.slotCount).toList();
  }

  /// 1 liked, -1 disliked, 0 neither, for the song playing.
  int get _likeStatus {
    final songId = _station?.songId ?? -1;
    if (!GetIt.instance.isRegistered<SongLikeService>()) return 0;
    return GetIt.instance<SongLikeService>().getLikeStatus(songId);
  }

  /// Gives the keyboard back to the panel, for its shortcuts, once a menu
  /// or a dialog opened from it closed.
  void _refocus() {
    if (mounted) _keyboardFocus.requestFocus();
  }

  void _close() => Navigator.of(context).maybePop();

  void _track(String buttonName, [Map<String, Object?> extra = const {}]) {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': buttonName,
      'station_id': _station?.id,
      'station_slug': _station?.slug,
      ...extra,
    });
  }

  void _togglePlay() {
    if (_isPlaying) {
      _audioHandler.pause();
      return;
    }
    _playButtonKey.currentState?.notifyWillPlay();
    _audioHandler.play();
  }

  void _previous() {
    _playButtonKey.currentState?.notifyWillPlay();
    _audioHandler.skipToPrevious();
  }

  void _next() {
    _playButtonKey.currentState?.notifyWillPlay();
    _audioHandler.skipToNext();
  }

  void _toggleFavorite() {
    final station = _station;
    if (station == null) return;
    _track('favorite');
    _audioHandler.toggleStationFavorite(station);
  }

  /// Likes the song playing, or with [like] false dislikes it; a second
  /// click takes it back, as on the phone.
  Future<void> _rate({required bool like}) async {
    final station = _station;
    if (station == null || station.songId <= 0) return;
    _track(like ? 'like_song' : 'dislike_song', {'song_id': station.songId});
    await _audioHandler.customAction(like ? 'likeSong' : 'dislikeSong');
    if (mounted) setState(() {});
  }

  /// Searches YouTube for the song playing, in the browser.
  Future<void> _searchSong() async {
    final station = _station;
    if (station == null || !_hasSong) return;
    _track('youtube_search', {
      'song_id': station.songId,
      'song_title': station.songTitle,
    });
    final query = Uri.encodeQueryComponent(
      songSearchQuery(title: station.songTitle, artist: station.songArtist),
    );
    try {
      await launchUrl(
        Uri.parse('https://www.youtube.com/results?q=$query'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // No browser took the link; nothing else to offer from here.
    }
  }

  /// Opens one of the station's links, from "Despre stație".
  void _openLink(StationLink link) {
    _track('station_link', {'link_type': link.kind.name});
    unawaited(widget.openLink(link.uri));
  }

  /// Copies one of the station's links, or its e-mail address, and
  /// confirms it.
  Future<void> _copyLink(StationLink link) async {
    _track('copy_station_link', {'link_type': link.kind.name});
    try {
      await Clipboard.setData(ClipboardData(text: link.copyText));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    CopiedToast.show(
      context,
      message: link.kind == StationLinkKind.email
          ? DesktopNowPlayingSheet.addressCopiedLabel
          : DesktopNowPlayingSheet.linkCopiedLabel,
      bottom: _toastBottom(),
    );
  }

  /// Copies the song playing as "title - artist" and confirms it.
  Future<void> _copySong() async {
    final station = _station;
    if (station == null || !_hasSong) return;
    _track('copy_song', {
      'song_id': station.songId,
      'song_title': station.songTitle,
    });
    try {
      await Clipboard.setData(ClipboardData(
        text: songClipboardText(
          title: station.songTitle,
          artist: station.songArtist,
        ),
      ));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    CopiedToast.show(context,
        message: 'Melodie copiată', bottom: _toastBottom());
  }

  /// How far above the window's bottom edge a toast sits inside the
  /// panel, near its bottom; null when the panel isn't laid out.
  double? _toastBottom() {
    final box = _panelKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final panelBottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    return MediaQuery.sizeOf(context).height - panelBottom + 20;
  }

  void _showHistory() {
    final station = _station;
    if (station == null) return;
    _track('song_history');
    showDesktopSongHistory(
      context,
      stationSlug: station.slug,
      stationThumbnailUrl: station.thumbnailUrl,
      playedCutoff: () => _stationDataService.playedCutoffFor(station.id),
    ).whenComplete(_refocus);
  }

  /// Fetches the user's personal share link, for the share menu.
  Future<ShareLinkData?> _loadShareLink() =>
      ShareService(_audioHandler.graphqlClient).getPersonalShareLink();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Only while no button of the panel has the keyboard: there Space and
    // the arrows press and move between the buttons, and Esc closes the
    // menu a button opened.
    if (FocusManager.instance.primaryFocus != _keyboardFocus) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    // Leave ⌘, Ctrl and Alt combinations to the app's menus.
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final action = _shortcuts[event.logicalKey];
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  /// The panel's single-key shortcuts.
  late final Map<LogicalKeyboardKey, VoidCallback> _shortcuts = {
    LogicalKeyboardKey.escape: _close,
    LogicalKeyboardKey.space: _togglePlay,
    LogicalKeyboardKey.mediaPlayPause: _togglePlay,
    LogicalKeyboardKey.arrowLeft: _previous,
    LogicalKeyboardKey.mediaTrackPrevious: _previous,
    LogicalKeyboardKey.arrowRight: _next,
    LogicalKeyboardKey.mediaTrackNext: _next,
    LogicalKeyboardKey.keyF: _toggleFavorite,
    LogicalKeyboardKey.keyL: () => _rate(like: true),
    LogicalKeyboardKey.keyD: () => _rate(like: false),
  };

  @override
  Widget build(BuildContext context) {
    final station = _station;
    final Widget content;
    if (station == null) {
      content = const SizedBox(
        height: 240,
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: TvColors.primary,
          ),
        ),
      );
    } else if (_youtubeItem case final youtubeItem?) {
      // The playlist reached a YouTube item: the auto-advancing "up next".
      content = SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 4, 28, 32),
        child: TvYoutubeUpNextCard(
          // A fresh card per item (its own hover and focus state).
          key: ValueKey(youtubeItem.id),
          item: youtubeItem,
          countdown: widget.youtubeCountdown,
          // Scoped to this item, so a late click can't skip the next.
          onSkip: () => _playlistController.notifyYoutubeItemEnded(
              itemId: youtubeItem.id),
        ),
      );
    } else {
      content = LayoutBuilder(
        builder: (context, constraints) => _buildPlayer(
          station,
          computeDesktopNowPlayingLayout(
            width: math.min(
              constraints.maxWidth,
              DesktopNowPlayingLayout.maxContentWidth,
            ),
            height: constraints.maxHeight,
            isVideo: _isVideoMode,
          ),
        ),
      );
    }

    // The surface is the route's, grown out of the player bar.
    return Focus(
      focusNode: _keyboardFocus,
      onKeyEvent: _onKey,
      child: Column(
        key: _panelKey,
        children: [
          _TopBar(onClose: _close),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildPlayer(Station station, DesktopNowPlayingLayout layout) {
    final media = _isVideoMode
        ? _VideoBox(
            videoService: _audioHandler.videoService,
            isTv: station.isTv,
            width: layout.mediaWidth,
            height: layout.mediaHeight,
          )
        : _Artwork(
            station: station,
            size: layout.mediaWidth,
            audioOnly: _audioOnlyFallback,
          );
    final details = _buildDetails(station, layout);
    final info = _buildInfo(station, layout);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DesktopNowPlayingLayout.maxContentWidth,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: layout.horizontalPadding,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (layout.stacked) ...[
                  Center(child: media),
                  const SizedBox(height: 24),
                  details,
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      media,
                      const SizedBox(width: DesktopNowPlayingLayout.gap),
                      Expanded(child: details),
                    ],
                  ),
                if (info != null) ...[
                  const SizedBox(height: 36),
                  info,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "Melodii recente" and "Despre stație", side by side in a wide panel
  /// and one under the other in a narrow one; null with neither.
  Widget? _buildInfo(Station station, DesktopNowPlayingLayout layout) {
    // A station that names no songs has none to list.
    final songs = _hasSong || (_recentSongs?.isNotEmpty ?? false)
        ? _RecentSongs(
            songs: _recentSongs,
            failed: _recentSongsFailed,
            onShowAll: _showHistory,
          )
        : null;
    final about = StationAbout.of(station);
    final aboutSection = about.isEmpty
        ? null
        : AnimatedSwitcher(
            duration: DesktopTokens.contentDuration,
            layoutBuilder: _alignTopStart,
            child: NowPlayingAbout(
              key: ValueKey('np-about-${station.id}'),
              station: station,
              about: about,
              onOpenLink: _openLink,
              onCopyLink: _copyLink,
              onMenuClosed: _refocus,
            ),
          );
    if (songs == null && aboutSection == null) return null;
    if (songs != null && aboutSection != null && layout.infoSideBySide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: songs),
          const SizedBox(width: 40),
          Expanded(child: aboutSection),
        ],
      );
    }
    // Full width, so a narrower "Despre stație" lines up with the artwork
    // rather than in the middle.
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (songs != null) songs,
          if (songs != null && aboutSection != null)
            const SizedBox(height: 28),
          // Alone or under the songs, its lines stay short enough to read.
          if (aboutSection != null)
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: DesktopNowPlayingLayout.maxAboutWidth,
              ),
              child: aboutSection,
            ),
        ],
      ),
    );
  }

  Widget _buildDetails(Station station, DesktopNowPlayingLayout layout) {
    final likeStatus = _likeStatus;
    final canRate = station.songId > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _StationLine(station: station),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SongBlock(
                station: station,
                hasSong: _hasSong,
                onSearch: _searchSong,
                onCopy: _copySong,
                onMenuClosed: _refocus,
              ),
            ),
            // Nothing to rate without a song.
            if (canRate) ...[
              const SizedBox(width: 12),
              _RatingButtons(
                likeStatus: likeStatus,
                onLike: () => _rate(like: true),
                onDislike: () => _rate(like: false),
              ),
            ],
          ],
        ),
        const SizedBox(height: 22),
        // One row: the transport at the start, the actions at the end. A
        // panel too narrow for both puts the actions on a line of their own.
        // Full width, so the free space goes between them.
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              _Transport(
                playButtonKey: _playButtonKey,
                audioHandler: _audioHandler,
                onPrevious: _previous,
                onNext: _next,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  _FavoriteButton(
                    isFavorite: _isFavorite,
                    onPressed: _toggleFavorite,
                  ),
                  NowPlayingSleepMenu(
                    service: _audioHandler.sleepTimer,
                    labeled: false,
                    quiet: true,
                    onOpened: () => _track('sleep_timer'),
                    onClosed: _refocus,
                    onDurationChosen: (duration) => _track('sleep_timer_set', {
                      'duration_minutes': duration.inMinutes,
                    }),
                    onCancelled: () => _track('sleep_timer_cancel'),
                  ),
                  DesktopShareMenu(
                    station: station,
                    loader: _loadShareLink,
                    onOpened: () =>
                        _track('share', {'song_id': station.songId}),
                    onClosed: _refocus,
                    builder: (context, toggle, focusNode) =>
                        DesktopActionButton(
                      focusNode: focusNode,
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('Trimite'),
                      tooltip: 'Trimite stația unui prieten',
                      labeled: false,
                      quiet: true,
                      onPressed: toggle,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Pieces ────────────────────────────────────────────────────────────────

/// "Se redă acum" and the arrow that closes the panel back into the
/// player bar, as the bar's arrow opened it.
class _TopBar extends StatelessWidget {
  final VoidCallback onClose;

  const _TopBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 12, 0),
      child: Row(
        children: [
          const Icon(Icons.equalizer_rounded,
              size: 16, color: TvColors.primary),
          const SizedBox(width: 6),
          Text(
            'Se redă acum',
            style: TvTypography.caption.copyWith(
              color: TvColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          DesktopActionButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
            label: const SizedBox.shrink(),
            tooltip: 'Închide (Esc)',
            labeled: false,
            size: 36,
            accent: TvColors.textSecondary,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The station's name and how many listen to it.
class _StationLine extends StatelessWidget {
  final Station station;

  const _StationLine({required this.station});

  @override
  Widget build(BuildContext context) {
    final int listeners = station.totalListeners ?? 0;
    return Row(
      children: [
        Flexible(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            layoutBuilder: _alignTopStart,
            child: Text(
              station.displayTitle,
              key: ValueKey('np-station-${station.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: TvColors.textSecondary,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ),
        if (listeners > 0) ...[
          const SizedBox(width: 12),
          const Icon(Icons.headphones_rounded,
              size: 13, color: TvColors.textTertiary),
          const SizedBox(width: 5),
          Text(
            romanianCount(listeners, one: 'ascultător', many: 'ascultători'),
            style: TvTypography.caption.copyWith(fontSize: 12),
            maxLines: 1,
          ),
        ],
      ],
    );
  }
}

/// The song title and artist. A click searches YouTube for the song, a
/// right click opens a menu to copy it or search for it; with no song
/// named ("Live") the text is inert.
class _SongBlock extends StatefulWidget {
  final Station station;
  final bool hasSong;
  final VoidCallback onSearch;
  final VoidCallback onCopy;
  final VoidCallback onMenuClosed;

  const _SongBlock({
    required this.station,
    required this.hasSong,
    required this.onSearch,
    required this.onCopy,
    required this.onMenuClosed,
  });

  static const double _titleSize = 24;
  static const double _titleHeight = 1.2;
  static const double _artistSize = 15;
  static const double _artistHeight = 1.3;
  static const double _artistGap = 4;

  @override
  State<_SongBlock> createState() => _SongBlockState();
}

class _SongBlockState extends State<_SongBlock> {
  final MenuController _menu = MenuController();

  /// Takes the keyboard while the menu is open, so Esc closes the menu
  /// rather than the panel.
  final FocusNode _focus = FocusNode(
    debugLabel: 'desktop-np-song',
    skipTraversal: true,
  );
  bool _hovered = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  String get _title {
    final s = widget.station;
    if (s.songTitle.isNotEmpty) return s.songTitle;
    return s.isTv ? 'Transmisiune live' : 'Live';
  }

  @override
  Widget build(BuildContext context) {
    final station = widget.station;
    final active = widget.hasSong;
    final underline = active && _hovered;
    final song = AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      layoutBuilder: _alignTopStart,
      // The song and its artist change together, so they crossfade as one.
      child: Column(
        key: ValueKey(
          'np-song-${station.id}-${station.songTitle}-${station.songArtist}',
        ),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _SongBlock._titleSize,
              fontWeight: FontWeight.w700,
              height: _SongBlock._titleHeight,
              letterSpacing: -0.3,
              color: TvColors.textPrimary,
              decoration:
                  underline ? TextDecoration.underline : TextDecoration.none,
              decorationColor: TvColors.textSecondary,
            ),
          ),
          if (station.songArtist.isNotEmpty) ...[
            const SizedBox(height: _SongBlock._artistGap),
            // Quieter than the song: the song is what plays.
            Text(
              station.songArtist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: _SongBlock._artistSize,
                height: _SongBlock._artistHeight,
                fontWeight: FontWeight.w400,
                color: TvColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );

    // The same widgets with or without a song, so the text still
    // crossfades into the first song named. Only the text takes the
    // pointer, so it underlines under the pointer and not beside it.
    final text = MenuAnchor(
      controller: _menu,
      childFocusNode: _focus,
      style: DesktopMenuTheme.menuStyle,
      useRootOverlay: true,
      consumeOutsideTap: true,
      onClose: widget.onMenuClosed,
      menuChildren: [
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: widget.onCopy,
          child: const Text('Copiază melodia'),
        ),
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: const Icon(Icons.search_rounded, size: 18),
          onPressed: widget.onSearch,
          child: const Text('Caută pe YouTube'),
        ),
      ],
      builder: (context, controller, child) => Tooltip(
        message:
            active ? 'Caută pe YouTube · clic dreapta pentru mai multe' : '',
        waitDuration: DesktopTokens.tooltipWait,
        child: Focus(
          focusNode: _focus,
          child: MouseRegion(
            cursor: active ? SystemMouseCursors.click : MouseCursor.defer,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: active ? widget.onSearch : null,
              onSecondaryTapUp: active
                  ? (details) =>
                      controller.open(position: details.localPosition)
                  : null,
              child: child,
            ),
          ),
        ),
      ),
      child: song,
    );
    return SizedBox(
      // Room for a two-line title and the artist under it, so nothing below
      // moves when a song with a longer or shorter title comes on; the
      // artist stays right under the title either way.
      height: _SongBlock._titleSize * _SongBlock._titleHeight * 2 +
          2 +
          _SongBlock._artistGap +
          _SongBlock._artistSize * _SongBlock._artistHeight,
      width: double.infinity,
      child: Align(alignment: AlignmentDirectional.topStart, child: text),
    );
  }
}

/// Lays an [AnimatedSwitcher]'s outgoing and incoming text over each other
/// from the top start, so a crossfade never shifts either.
Widget _alignTopStart(Widget? current, List<Widget> previous) => Stack(
      alignment: AlignmentDirectional.topStart,
      children: [...previous, if (current != null) current],
    );

/// Like and dislike for the song playing: two outlined circles, the like
/// flooding with the brand pink, the dislike with a quiet tint. Only shown
/// while the station names a song.
class _RatingButtons extends StatelessWidget {
  final int likeStatus;
  final VoidCallback onLike;
  final VoidCallback onDislike;

  const _RatingButtons({
    required this.likeStatus,
    required this.onLike,
    required this.onDislike,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RatingButton(
          icon: Icons.thumb_up_alt_outlined,
          activeIcon: Icons.thumb_up_alt_rounded,
          tooltip: 'Îmi place (L)',
          isActive: likeStatus == 1,
          activeFill: TvColors.primary,
          onTap: onLike,
        ),
        const SizedBox(width: 8),
        _RatingButton(
          icon: Icons.thumb_down_alt_outlined,
          activeIcon: Icons.thumb_down_alt_rounded,
          tooltip: 'Nu-mi place (D)',
          isActive: likeStatus == -1,
          activeFill: const Color(0x33FFFFFF),
          onTap: onDislike,
        ),
      ],
    );
  }
}

class _RatingButton extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String tooltip;
  final bool isActive;
  final Color activeFill;
  final VoidCallback onTap;

  const _RatingButton({
    required this.icon,
    required this.activeIcon,
    required this.tooltip,
    required this.isActive,
    required this.activeFill,
    required this.onTap,
  });

  static const double _diameter = 40;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: DesktopTokens.tooltipWait,
      child: Semantics(
        button: true,
        toggled: isActive,
        label: tooltip,
        excludeSemantics: true,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: isActive ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          builder: (context, t, child) => Material(
            color: activeFill.withValues(alpha: activeFill.a * t),
            shape: CircleBorder(
              side: BorderSide(
                color: Color.lerp(const Color(0x3DFFFFFF), activeFill, t)!,
                width: 1.5,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              hoverColor: Colors.white.withValues(alpha: 0.08),
              focusColor: TvColors.primary.withValues(alpha: 0.3),
              splashFactory: NoSplash.splashFactory,
              child: SizedBox.square(
                dimension: _diameter,
                child: Center(child: child),
              ),
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, animation) =>
                child.key == const ValueKey(true)
                    ? ScaleTransition(
                        scale: animation.drive(
                          CurveTween(curve: Curves.easeOutBack),
                        ),
                        child: child,
                      )
                    : FadeTransition(opacity: animation, child: child),
            child: Icon(
              isActive ? activeIcon : icon,
              key: ValueKey(isActive),
              size: 19,
              color: isActive ? Colors.white : TvColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Previous, play/pause (with the buffering spinner) and next.
class _Transport extends StatelessWidget {
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;
  final AppAudioHandler audioHandler;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _Transport({
    required this.playButtonKey,
    required this.audioHandler,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DesktopActionButton(
          icon: const Icon(Icons.skip_previous_rounded, size: 26),
          label: const SizedBox.shrink(),
          tooltip: 'Stația anterioară (←)',
          labeled: false,
          size: 46,
          onPressed: onPrevious,
        ),
        const SizedBox(width: 14),
        Tooltip(
          message: 'Redă / Pauză (Spațiu)',
          waitDuration: DesktopTokens.tooltipWait,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x55E91E63),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: AnimatedPlayButton(
              key: playButtonKey,
              playbackStateStream: audioHandler.playbackState,
              iconSize: 36,
              iconColor: Colors.white,
              backgroundColor: TvColors.primary,
              onPlay: audioHandler.play,
              onPause: audioHandler.pause,
            ),
          ),
        ),
        const SizedBox(width: 14),
        DesktopActionButton(
          icon: const Icon(Icons.skip_next_rounded, size: 26),
          label: const SizedBox.shrink(),
          tooltip: 'Stația următoare (→)',
          labeled: false,
          size: 46,
          onPressed: onNext,
        ),
      ],
    );
  }
}

/// The favorite toggle: the heart pops in pink when the station becomes a
/// favorite.
class _FavoriteButton extends StatelessWidget {
  final bool isFavorite;
  final VoidCallback onPressed;

  const _FavoriteButton({
    required this.isFavorite,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DesktopActionButton(
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: animation.drive(CurveTween(curve: Curves.easeOutBack)),
          child: child,
        ),
        child: Icon(
          isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          key: ValueKey(isFavorite),
        ),
      ),
      label: const Text('Favorit'),
      tooltip:
          isFavorite ? 'Elimină din favorite (F)' : 'Adaugă la favorite (F)',
      labeled: false,
      quiet: true,
      active: isFavorite,
      onPressed: onPressed,
    );
  }
}

/// The station's artwork, crossfading as the song or station changes.
class _Artwork extends StatelessWidget {
  final Station station;
  final double size;

  /// Whether a TV channel fell back to its sound only.
  final bool audioOnly;

  const _Artwork({
    required this.station,
    required this.size,
    required this.audioOnly,
  });

  @override
  Widget build(BuildContext context) {
    // Decoded, and fetched from the image CDN, at the size it is drawn,
    // so it stays sharp on a Retina display; in steps, as the grid's are,
    // so resizing the window doesn't decode it again at every width.
    final pixels =
        (size * MediaQuery.devicePixelRatioOf(context) / 64).ceil() * 64;
    return SizedBox.square(
      dimension: size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: DecoratedBox(
          key: ValueKey('np-art-${station.id}-${station.songId}'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x8C000000),
                blurRadius: 36,
                spreadRadius: 4,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                station.displayThumbnail(
                  cacheWidth: pixels,
                  sourceWidth: pixels,
                ),
                if (audioOnly)
                  const Positioned(top: 10, left: 10, child: AudioOnlyChip()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 16:9 live video output for desktop video mode, with a LIVE pill for TV.
class _VideoBox extends StatelessWidget {
  final VideoPlaybackService videoService;
  final bool isTv;
  final double width;
  final double height;

  const _VideoBox({
    required this.videoService,
    required this.isTv,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            TvVideoSurface(videoService: videoService),
            if (isTv) const Positioned(top: 10, left: 10, child: TvLivePill()),
          ],
        ),
      ),
    );
  }
}

/// The station's last songs before the one playing, under a "Melodii
/// recente" header whose "Vezi tot" opens its whole song history. Five
/// rows always, so nothing under them moves: placeholders while the songs
/// load, a note when there are none.
class _RecentSongs extends StatelessWidget {
  /// Null while they load.
  final List<SongHistoryItem>? songs;
  final bool failed;
  final VoidCallback onShowAll;
  static const int slotCount = 5;
  static const double _rowHeight = 32.0;

  static const String noneLabel = 'Nicio altă melodie în ultima oră';
  static const String failedLabel = 'Melodiile nu s-au putut încărca';

  const _RecentSongs({
    required this.songs,
    required this.failed,
    required this.onShowAll,
  });

  Widget _slot(int index) {
    final songs = this.songs;
    if (songs == null) return const _EmptySongSlot();
    if (index < songs.length) return _SongRow(song: songs[index]);
    if (index == 0) return _SongsNote(failed ? failedLabel : noneLabel);
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          NowPlayingSectionHeader(
            title: 'Melodii recente',
            trailing: _ShowAllLink(onPressed: onShowAll),
          ),
          const SizedBox(height: 4),
          // Fixed-height slot list, every row always, to prevent layout
          // shift.
          SizedBox(
            height: _rowHeight * slotCount,
            child: AnimatedSwitcher(
              duration: DesktopTokens.contentDuration,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, if (current != null) current],
              ),
              child: Column(
                // Another list fades in; the same songs stay put.
                key: ValueKey(songs?.map((s) => s.timestamp).join('|')),
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < slotCount; i++)
                    SizedBox(height: _rowHeight, child: _slot(i)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Vezi tot ›": a link-styled button that opens the song history.
class _ShowAllLink extends StatelessWidget {
  final VoidCallback onPressed;

  const _ShowAllLink({required this.onPressed});

  static const String label = 'Vezi tot';

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Toate melodiile redate pe această stație',
      waitDuration: DesktopTokens.tooltipWait,
      child: TextButton.icon(
        onPressed: onPressed,
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.chevron_right_rounded, size: 18),
        label: const Text(label),
        style: TextButton.styleFrom(
          foregroundColor: DesktopTokens.focusRing,
          overlayColor: Colors.white,
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 4, 0),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class _EmptySongSlot extends StatelessWidget {
  const _EmptySongSlot();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.music_note_rounded,
            size: 14,
            color: TvColors.textTertiary.withValues(alpha: 0.35),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                color: NowPlayingPalette.card,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The note in place of the recent songs when there are none to show.
class _SongsNote extends StatelessWidget {
  final String text;
  const _SongsNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TvTypography.caption
            .copyWith(fontSize: 12, color: TvColors.textTertiary),
      ),
    );
  }
}

/// A song the station played, with the time it started, as "Vezi tot"
/// shows it.
class _SongRow extends StatelessWidget {
  final SongHistoryItem song;
  const _SongRow({required this.song});

  String get _time {
    final time = song.dateTime.toLocal();
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.music_note_rounded,
              size: 14, color: TvColors.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: song.displaySongName,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: TvColors.textPrimary,
                    ),
                  ),
                  if (song.displayArtistName case final artist?
                      when artist.isNotEmpty)
                    TextSpan(
                      text: '  ·  $artist',
                      style: TvTypography.caption.copyWith(
                        fontSize: 12,
                        color: TvColors.textSecondary,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _time,
            style: TvTypography.caption
                .copyWith(fontSize: 11, color: TvColors.textTertiary),
          ),
        ],
      ),
    );
  }
}
