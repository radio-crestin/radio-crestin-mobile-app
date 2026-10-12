import 'dart:async';
import 'dart:developer' as developer;

import 'package:app_links/app_links.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import '../services/analytics_service.dart';
import '../services/background_polling_policy.dart';
import '../services/network_service.dart';
import '../services/playlist_controller.dart';
import '../services/station_data_service.dart';
import '../types/Station.dart';
import 'desktop_shell.dart';
import 'tv_lifecycle.dart';
import 'tv_platform.dart';
import 'tv_theme.dart';
import 'tv_youtube_auto_advance.dart';
import 'pages/tv_now_playing.dart';
import 'pages/tv_home.dart';
import 'pages/tv_settings.dart';

/// Song history entry with real timestamp.
class TvSongEntry {
  final String title;
  final String artist;
  final DateTime timestamp;
  TvSongEntry({required this.title, required this.artist, DateTime? at})
      : timestamp = at ?? DateTime.now();
}

/// TV app — two pages: station page + station list.
/// Song history tracked here so it persists across page switches.
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> with WidgetsBindingObserver {
  late bool _browsing;
  bool _showSettings = false;
  bool _autoPlayDone = false;

  /// Remembers which browse card was focused so returning from the player
  /// lands on the same card / scroll position (TvBrowse is recreated on swap).
  String? _browseFocusKey;

  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];
  final TvLifecycleTracker _lifecycle = TvLifecycleTracker();
  late final TvYoutubeAutoAdvance _youtubeAutoAdvance;
  Station? _currentStation;

  /// Song history persisted across page switches.
  /// Index 0 = current song, 1+ = previous songs.
  final List<TvSongEntry> songHistory = [];

  @override
  void initState() {
    super.initState();
    // Lock to landscape only on actual Android TV — desktop handles its own window
    if (TvPlatform.isAndroidTV) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    _audioHandler = GetIt.instance<AppAudioHandler>();
    _stationDataService = GetIt.instance<StationDataService>();
    _currentStation = _audioHandler.currentStation.value;
    WidgetsBinding.instance.addObserver(this);

    // TV and desktop cannot embed YouTube. This shell is always mounted
    // (unlike Now Playing and its "up next" card), so it owns moving the
    // playlist past those items.
    final playlist = GetIt.instance<PlaylistController>();
    _youtubeAutoAdvance = TvYoutubeAutoAdvance(
      requests: playlist.youtubeRequest.stream,
      // Paused by the user (remote, media keys, mini player): wait.
      shouldPlay: playlist.youtubeShouldPlay.stream,
      onAdvance: (itemId) => playlist.notifyYoutubeItemEnded(itemId: itemId),
    );

    _browsing = _currentStation == null;

    if (_currentStation != null && !_audioHandler.playbackState.value.playing) {
      _audioHandler.play();
      _autoPlayDone = true;
    }

    // Handle deep links (e.g. from TV home screen channel programs)
    _initDeepLinks();

    // Track station changes
    _subscriptions.add(
      _audioHandler.currentStation.stream.listen((station) {
        if (mounted) {
          final oldStation = _currentStation;
          _currentStation = station;
          // The pages subscribe themselves; this build only depends on
          // whether a station exists (TvHome's BACK behaviour), so skip the
          // whole-tree rebuild on every station-list publish.
          if ((oldStation == null) != (station == null)) setState(() {});
          // Track song history
          if (station != null &&
              station.songTitle.isNotEmpty &&
              (oldStation == null ||
                  oldStation.songId != station.songId)) {
            songHistory.insert(0,
                TvSongEntry(title: station.songTitle, artist: station.songArtist));
            if (songHistory.length > 20) {
              songHistory.removeRange(20, songHistory.length);
            }
          }
        }
      }),
    );

    // Auto-play first station if none loaded
    if (_currentStation == null) {
      _subscriptions.add(
        _stationDataService.stations.stream.listen((stations) {
          if (!_autoPlayDone && stations.isNotEmpty && mounted) {
            _autoPlayDone = true;
            _audioHandler.playStation(stations.first);
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _youtubeAutoAdvance.dispose();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  /// The lifecycle duties `HomePage` performs on mobile, minus the
  /// video/audio handoff and the stop on detach, which stay product
  /// decisions on TV and desktop.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _audioHandler.recordLifecycleTransition(state.name);
    switch (_lifecycle.onTransition(state)) {
      case TvLifecycleAction.returnedToForeground:
        _onReturnedToForeground();
      case TvLifecycleAction.enteredBackground:
        _pausePollingIfUnwatched();
      case TvLifecycleAction.detached:
        _onDetached();
      case TvLifecycleAction.none:
        break;
    }
  }

  void _onReturnedToForeground() {
    // Only while the handler reports playing: a reconnect calls play(), and
    // a video or playlist item the user paused must stay paused.
    if (_audioHandler.playbackState.value.playing) {
      _audioHandler.reconnectIfNeeded(
          trigger: ReconnectTrigger.lifecycleResumed);
    }
    // Full refresh + resume polling (picks up changes made while away).
    _stationDataService.onAppResumed();
  }

  void _pausePollingIfUnwatched() {
    final pause = BackgroundPollingPolicy.shouldPause(
      carConnected: _audioHandler.isCarConnected,
      casting: _audioHandler.isCasting,
      onMobileData: GetIt.instance<NetworkService>().isOnMobileData.value,
      // The broadcast state, so media_kit video mode counts as playing.
      playing: _audioHandler.playbackState.value.playing,
    );
    if (pause) _stationDataService.pausePolling();
  }

  void _onDetached() {
    // On Android TV the audio service can outlive the activity and keep
    // playing, and onTaskRemoved already ends the session when the task is
    // swiped away. On desktop, detaching means the app is exiting.
    if (TvPlatform.isDesktop) {
      AnalyticsService.instance.endListening(reason: 'app_killed');
    }
    AnalyticsService.instance.flush();
  }

  void _initDeepLinks() {
    final appLinks = AppLinks();

    // Handle initial link (cold start from TV channel program)
    appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleDeepLink(uri);
    });

    // Handle links while running
    _subscriptions.add(
      appLinks.uriLinkStream.listen(
        (uri) => _handleDeepLink(uri),
        onError: (err) {
          developer.log('Deep link error: $err', name: 'TvShell');
        },
      ),
    );
  }

  void _handleDeepLink(Uri uri) {
    developer.log('TV deep link: $uri', name: 'TvShell');

    // Extract station slug from URI
    String slug;
    if (uri.scheme == 'radiocrestin') {
      // radiocrestin://{slug}
      slug = uri.host;
    } else {
      // https://www.radiocrestin.ro/radio/{slug}
      final segments = uri.pathSegments;
      slug = segments.isNotEmpty ? segments.last : '';
    }

    if (slug.isEmpty) return;

    // Find and play the station
    final allStations = _stationDataService.stations.value;
    final station = allStations.cast<Station?>().firstWhere(
      (s) => s!.slug == slug,
      orElse: () => null,
    );

    if (station != null) {
      _audioHandler.playStation(station);
      if (mounted) setState(() => _browsing = false);
    } else {
      developer.log('Station not found for slug: $slug', name: 'TvShell');
    }
  }

  void _openBrowse() {
    // Returning to the list (e.g. BACK from the player) — refresh station data
    // so the browse content is current when it reappears.
    _stationDataService.refreshStations();
    setState(() => _browsing = true);
  }

  void _closeBrowse() => setState(() => _browsing = false);

  void _openSettings() => setState(() => _showSettings = true);
  void _closeSettings() => setState(() => _showSettings = false);

  void _onStationSelected(Station station) {
    _audioHandler.playStation(station);
    setState(() => _browsing = false);
  }

  @override
  Widget build(BuildContext context) {
    // Desktop gets its own shell (browse + bottom mini player + drawer)
    if (TvPlatform.isDesktop) {
      return DesktopShell(
        songHistory: songHistory,
        youtubeCountdown: _youtubeAutoAdvance.countdown,
      );
    }

    // TV: D-pad navigable two-page layout.
    //
    // The DpadNavigator key is bound to the current page identity so that
    // swapping between Browse and Now Playing fully recreates the navigator
    // subtree (its region manager and focus history). Without this key the
    // navigator persists across swaps, holding stale `np-controls` region
    // entries from the disposed play button — which left the Browse home
    // page with a card that *looked* focused but no D-pad routing.
    return KeyedSubtree(
      key: ValueKey(_showSettings
          ? 'tv-settings'
          : (_browsing ? 'tv-browse' : 'tv-now-playing')),
      child: DpadNavigator(
      enabled: true,
      regionNavigation: const RegionNavigationOptions(
        enabled: true,
        rules: [
          // Now Playing: bridge top bar (back + heart) ↔ controls row.
          // The vertical gap is too large for the geometric heuristic; an
          // explicit rule keeps both regions reachable without dead-ends.
          RegionNavigationRule(
            fromRegion: 'np-top',
            toRegion: 'np-controls',
            direction: TraversalDirection.down,
            strategy: RegionNavigationStrategy.fixedEntry,
            bidirectional: true,
            reverseStrategy: RegionNavigationStrategy.memory,
          ),
        ],
      ),
      child: Scaffold(
        backgroundColor: TvColors.background,
        body: _showSettings ? TvSettings(onClose: _closeSettings) : _browsing
            ? TvHome(
                onStationSelected: _onStationSelected,
                onOpenNowPlaying: _closeBrowse,
                onOpenSettings: _openSettings,
                initialFocusKey: _browseFocusKey,
                onCardFocused: (key) => _browseFocusKey = key,
              )
            : TweenAnimationBuilder<double>(
                // One-shot slide-up + fade so the player feels like it opens
                // "on top of" the list. Purely visual (the page isn't a
                // scrollable, so it doesn't affect D-pad focus/scroll).
                key: const ValueKey('np-enter'),
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                builder: (context, t, child) => Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, (1 - t) * 48),
                    child: child,
                  ),
                ),
                child: TvNowPlaying(
                  onBrowse: _openBrowse,
                  songHistory: songHistory,
                  youtubeCountdown: _youtubeAutoAdvance.countdown,
                ),
              ),
      ),
      ),
    );
  }
}
