import 'dart:async';
import 'dart:developer' as developer;

import 'package:app_links/app_links.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../appAudioHandler.dart';
import '../services/station_data_service.dart';
import '../types/Station.dart';
import 'desktop_shell.dart';
import 'tv_platform.dart';
import 'tv_theme.dart';
import 'pages/tv_now_playing.dart';
import 'pages/tv_home.dart';

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

class _TvShellState extends State<TvShell> {
  late bool _browsing;
  bool _autoPlayDone = false;

  late final AppAudioHandler _audioHandler;
  late final StationDataService _stationDataService;
  final List<StreamSubscription> _subscriptions = [];
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
          setState(() => _currentStation = station);
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
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
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

  void _openBrowse() => setState(() => _browsing = true);
  void _closeBrowse() => setState(() => _browsing = false);

  void _onStationSelected(Station station) {
    _audioHandler.playStation(station);
    setState(() => _browsing = false);
  }

  @override
  Widget build(BuildContext context) {
    // Desktop gets its own shell (browse + bottom mini player + drawer)
    if (TvPlatform.isDesktop) {
      return DesktopShell(songHistory: songHistory);
    }

    // TV: D-pad navigable two-page layout
    return DpadNavigator(
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
        body: _browsing
            ? TvHome(
                onStationSelected: _onStationSelected,
                onOpenNowPlaying: _closeBrowse,
              )
            : TvNowPlaying(
                onBrowse: _openBrowse,
                songHistory: songHistory,
              ),
      ),
    );
  }
}
