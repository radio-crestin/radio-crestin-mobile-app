import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CarPlayService {
  FlutterCarplay? _flutterCarplay;
  FlutterAndroidAuto? _flutterAndroidAuto;
  final AppAudioHandler _audioHandler = GetIt.instance<AppAudioHandler>();
  final StationDataService _stationDataService = GetIt.instance<StationDataService>();

  // Track initialization state - once true, NEVER rebuild
  bool _carPlayInitialized = false;
  bool _androidAutoInitialized = false;

  /// Reactive stream for car connection state (single source of truth).
  /// Used by AppAudioHandler to enable/disable data saving mode while driving.
  final BehaviorSubject<bool> isCarConnected = BehaviorSubject.seeded(false);

  /// Synchronous getter for connection state.
  bool get isConnected => isCarConnected.value;

  // Track last known state to avoid redundant native calls
  String? _lastPlayingSlug;

  // Method channel for Now Playing buttons (iOS CarPlay)
  static const _nowPlayingChannel = MethodChannel('com.radiocrestin.nowplaying_buttons');

  // Subscriptions
  StreamSubscription? _currentStationSubscription;
  StreamSubscription? _favoritesSubscription;
  StreamSubscription? _connectionErrorSubscription;
  StreamSubscription? _networkRecoverySubscription;
  StreamSubscription? _carPlayPlaybackSubscription;
  StreamSubscription? _carPlayStationsSubscription;
  StreamSubscription? _carPlaySortOrderSubscription;
  StreamSubscription? _mediaItemSubscription;

  // Timers
  Timer? _carPlayWaitTimer;
  Timer? _connectionErrorDebounceTimer;

  // Whether an error alert is currently shown on CarPlay
  bool _isShowingConnectionError = false;

  // CarPlay list items by slug - for favorites tab (reused when updating)
  final Map<String, CPListItem> _favoriteListItems = {};

  // CarPlay list items by slug - for "Toate statiile" tab
  final Map<String, CPListItem> _allStationsListItems = {};

  // Store references to CarPlay templates for dynamic section updates
  CPListTemplate? _favoriteTemplate;
  CPListTemplate? _allStationsTemplate;

  // Android Auto state
  List<Station> _sortedAndroidAutoStations = [];
  StreamSubscription? _androidAutoStationSubscription; // single merged subscription
  String _activeAndroidAutoTabId = 'favorites';
  bool _isPlayerScreenVisible = false;

  // Track last player state to avoid unnecessary updates (prevents flickering)
  String? _lastPlayerStationSlug;
  String? _lastPlayerSongTitle;
  String? _lastPlayerArtist;
  bool? _lastPlayerIsPlaying;
  bool? _lastPlayerIsFavorite;

  // Track last Android Auto station list hash to skip no-op rebuilds
  int _lastAndroidAutoListHash = 0;


  ImageCacheService? get _imageCacheService {
    try {
      return GetIt.instance<ImageCacheService>();
    } catch (_) {
      return null;
    }
  }

  /// Returns file:// URI if cached, otherwise the original network URL.
  String? _cachedOrNetworkUrl(String? url) {
    if (url == null || url.isEmpty) return url;
    final cachedPath = _imageCacheService?.getCachedPath(url);
    if (cachedPath != null) return 'file://$cachedPath';
    return url;
  }

  static void _log(String message) {
    developer.log("CarPlayService: $message");
  }

  /// Auto-play the last station when car connects, if autoplay is enabled
  /// and not already playing. Detects whether the station is in favorites
  /// and passes the context so the correct tab/list is highlighted.
  ///
  /// If stations haven't loaded yet (e.g. cold start), waits up to 10 seconds
  /// for them before giving up.
  Future<void> _autoplayOnCarConnect() async {
    if (_audioHandler.playbackState.value.playing) {
      _log("Already playing, skipping car autoplay");
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final autoStart = prefs.getBool('_autoStartStation') ?? true;
      if (!autoStart) {
        _log("Autoplay disabled in settings, skipping car autoplay");
        return;
      }

      // Wait for stations to load if they haven't yet (cold start scenario).
      var station = await _audioHandler.getLastPlayedStation();
      if (station == null) {
        _log("Stations not loaded yet, waiting for them...");
        station = await _waitForLastPlayedStation();
      }

      if (station == null) {
        _log("No last played station after waiting, skipping car autoplay");
        return;
      }
      final fromFavorites = _isFavorite(station.slug);
      _log("Car connected — autoplaying station: ${station.slug} (fromFavorites=$fromFavorites)");
      _audioHandler.playStation(station, fromFavorites: fromFavorites);
    } catch (e) {
      _log("Error during car autoplay: $e");
    }
  }

  /// Waits up to 10 seconds for stations to load, then returns the last
  /// played station. Returns null if stations never load or no last played
  /// station is found.
  Future<Station?> _waitForLastPlayedStation() async {
    final completer = Completer<Station?>();
    Timer? timeout;
    StreamSubscription? sub;

    timeout = Timer(const Duration(seconds: 10), () {
      sub?.cancel();
      if (!completer.isCompleted) {
        _log("Timed out waiting for stations to load for autoplay");
        completer.complete(null);
      }
    });

    sub = _stationDataService.stations.stream.listen((stations) async {
      if (stations.isNotEmpty) {
        sub?.cancel();
        timeout?.cancel();
        final station = await _audioHandler.getLastPlayedStation();
        if (!completer.isCompleted) {
          completer.complete(station);
        }
      }
    });

    return completer.future;
  }

  /// Returns true if the device locale is Romanian.
  static bool get _isRomanian {
    final locale = ui.PlatformDispatcher.instance.locale;
    return locale.languageCode == 'ro';
  }

  /// Localized strings for Android Auto / CarPlay.
  static String get _favoriteStationsTitle => _isRomanian ? 'Stații Favorite' : 'Favorite Stations';
  static String get _allStationsTitle => _isRomanian ? 'Toate Stațiile' : 'All Stations';
  static String _favoritesTabTitle(int count) => _isRomanian ? 'Favorite ($count)' : 'Favorites ($count)';
  static String _allTabTitle(int count) => _isRomanian ? 'Toate ($count)' : 'All ($count)';
  static String get _loadingTitle => _isRomanian ? 'Se încarcă...' : 'Loading...';
  static String get _loadingStations => _isRomanian ? 'Se încarcă stațiile...' : 'Loading stations...';
  static String get _pleaseWait => _isRomanian ? 'Vă rugăm așteptați' : 'Please wait';
  static String get _noFavorites => _isRomanian ? 'Nicio stație favorită' : 'No favorite stations';
  static String get _addFavoritesHint => _isRomanian ? 'Adaugă stații la favorite din aplicație' : 'Add favorite stations from the app';

  Future<void> initialize() async {
    _log("Initializing CarPlay/Android Auto service");

    if (Platform.isIOS) {
      _initializeCarPlay();
      _setupNowPlayingButtonsHandler();
      _listenForConnectionErrors();
    } else if (Platform.isAndroid) {
      _initializeAndroidAuto();
    }

    _log("CarPlay/Android Auto service initialized");
  }

  /// Returns whether a station slug is currently favorited.
  /// This is the SINGLE source of truth for favorite state.
  bool _isFavorite(String slug) {
    return _stationDataService.favoriteStationSlugs.value.contains(slug);
  }

  void _setupNowPlayingButtonsHandler() {
    // Listen for button presses from native iOS CarPlay
    _nowPlayingChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFavoriteButtonPressed') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final isFavorite = args['isFavorite'] as bool;
        final currentStation = _audioHandler.currentStation.value;
        if (currentStation != null) {
          await _audioHandler.setStationIsFavorite(currentStation, isFavorite);
        }
      } else if (call.method == 'onLikeButtonPressed') {
        await _audioHandler.customAction('likeSong');
        // Sync the like/dislike state back to native (customAction toggles internally)
        _syncNowPlayingLikeState();
      } else if (call.method == 'onDislikeButtonPressed') {
        await _audioHandler.customAction('dislikeSong');
        _syncNowPlayingLikeState();
      } else if (call.method == 'onUpNextButtonTapped') {
        await _showCarPlaySongHistory();
      }
    });

    // Update CarPlay list playing indicator when station changes
    _currentStationSubscription = _audioHandler.currentStation.stream.listen((station) {
      if (station != null) {
        final slugChanged = _lastPlayingSlug != station.slug;
        _lastPlayingSlug = station.slug;
        _updateCarPlayListPlayingState(station.slug);
        if (slugChanged) {
          // Sync Now Playing favorite button for the new station
          _updateNowPlayingFavoriteState(_isFavorite(station.slug));
          // Reset like/dislike state for the new song
          _lastSyncedLikeStatus = null;
          _syncNowPlayingLikeState();
        }
      }
    });

    // Update CarPlay list playing indicator + Now Playing template when play/pause state changes
    _carPlayPlaybackSubscription = _audioHandler.playbackState.stream.listen((state) {
      final isPlaying = state.playing;
      final slug = _audioHandler.currentStation.value?.slug;
      _log("playbackState changed: playing=$isPlaying, slug=$slug, processing=${state.processingState}");
      if (slug != null) {
        _updateCarPlayListPlayingState(slug);
      }
      // Explicitly sync MPNowPlayingInfoCenter playback rate so
      // CPNowPlayingTemplate.shared shows correct play/pause state.
      // audio_service's native bridge may not propagate this in multi-scene CarPlay setups.
      _syncNowPlayingPlaybackState(isPlaying);
    });

    // Sync like/dislike state when song changes on the same station
    _mediaItemSubscription = _audioHandler.mediaItem.stream.listen((_) {
      _syncNowPlayingLikeState();
    });

    // Update favorite UI (Now Playing button + CarPlay lists) when favorites change
    _favoritesSubscription = _stationDataService.favoriteStationSlugs.stream.listen((_) {
      // Update Now Playing favorite button
      final currentStation = _audioHandler.currentStation.value;
      if (currentStation != null) {
        _updateNowPlayingFavoriteState(_isFavorite(currentStation.slug));
      }
      // Update CarPlay favorites list and star prefixes
      _updateCarPlayFavorites();
    });
  }

  Future<void> _syncNowPlayingPlaybackState(bool isPlaying) async {
    // Do NOT dedupe on the Dart side: audio_service's iOS bridge also
    // writes MPNowPlayingInfoCenter.playbackRate using its own cache.
    // When the two caches diverge (e.g. the user casts, the local
    // player's stop nudges audio_service to rate=0.0, but our sync
    // ran earlier with rate=1.0), a Dart-side dedupe blocks the
    // correcting write and the lock-screen icon gets stuck on the
    // wrong state. The native method is cheap — fire it every time.
    _log("syncNowPlayingPlaybackState: isPlaying=$isPlaying");
    try {
      await _nowPlayingChannel.invokeMethod('syncPlaybackState', {'isPlaying': isPlaying});
    } catch (e) {
      _log("Error syncing Now Playing playback state: $e");
    }
  }

  Future<void> _updateNowPlayingFavoriteState(bool isFavorite) async {
    try {
      await _nowPlayingChannel.invokeMethod('setFavoriteState', {'isFavorite': isFavorite});
    } catch (e) {
      _log("Error updating Now Playing favorite state: $e");
    }
  }

  /// Syncs the like/dislike button state on CarPlay Now Playing screen.
  void _syncNowPlayingLikeState() {
    final station = _audioHandler.currentStation.value;
    if (station == null) return;
    final songLikeService = GetIt.instance<SongLikeService>();
    final likeStatus = songLikeService.getLikeStatus(station.songId);
    _updateNowPlayingLikeDislikeState(likeStatus);
  }

  int? _lastSyncedLikeStatus;

  Future<void> _updateNowPlayingLikeDislikeState(int likeStatus) async {
    if (_lastSyncedLikeStatus == likeStatus) return;
    _lastSyncedLikeStatus = likeStatus;
    try {
      await _nowPlayingChannel.invokeMethod('setLikeDislikeState', {'likeStatus': likeStatus});
    } catch (e) {
      _log("Error updating Now Playing like/dislike state: $e");
    }
  }

  /// Shows the recently played song history as a CarPlay list template.
  Future<void> _showCarPlaySongHistory() async {
    final station = _audioHandler.currentStation.value;
    if (station == null) return;

    try {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final history = await SongHistoryService.fetchHistory(station.slug, toTimestamp: nowSeconds);
      if (history == null || history.history.isEmpty) {
        _log("No song history available for ${station.slug}");
        return;
      }

      final now = DateTime.now();
      final pastSongs = history.history
          .where((item) => item.hasSong && item.dateTime.isBefore(now))
          .toList()
        ..sort((a, b) => b.dateTime.compareTo(a.dateTime));
      final items = pastSongs
          .take(30)
          .map((item) {
            final time = item.dateTime.toLocal();
            final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
            final title = item.songName ?? (_isRomanian ? 'Necunoscut' : 'Unknown');
            final artist = item.artistName != null ? '$timeStr - ${item.artistName}' : timeStr;
            final thumbUrl = _cachedOrNetworkUrl(item.songThumbnailUrl ?? station.thumbnailUrl);
            return CPListItem(
              text: title,
              detailText: artist,
              image: thumbUrl,
            );
          })
          .toList();

      if (items.isEmpty) return;

      final title = _isRomanian ? 'Redate recent' : 'Recently played';
      final listTemplate = CPListTemplate(
        title: title,
        sections: [CPListSection(items: items)],
        systemIcon: "clock.arrow.circlepath",
      );

      await FlutterCarplay.push(template: listTemplate, animated: true);
    } catch (e) {
      _log("Error showing CarPlay song history: $e");
    }
  }

  void _updateCarPlayListPlayingState(String currentSlug) {
    final isPlaying = _audioHandler.playbackState.value.playing;
    bool anyChanged = false;
    for (final entry in _favoriteListItems.entries) {
      final shouldBePlaying = entry.key == currentSlug && isPlaying;
      if (entry.value.isPlaying != shouldBePlaying) {
        entry.value.setIsPlaying(shouldBePlaying);
        anyChanged = true;
      }
    }
    for (final entry in _allStationsListItems.entries) {
      final shouldBePlaying = entry.key == currentSlug && isPlaying;
      if (entry.value.isPlaying != shouldBePlaying) {
        entry.value.setIsPlaying(shouldBePlaying);
        anyChanged = true;
      }
    }
    if (anyChanged) {
      _flutterCarplay?.forceUpdateRootTemplate();
    }
  }

  void _updateCarPlayFavorites() {
    if (_favoriteTemplate == null || _flutterCarplay == null) return;

    final favoriteSlugs = _stationDataService.favoriteStationSlugs.value;
    final sortedStations = _stationDataService.getSortedStations();

    // Update star prefix in "Toate statiile" items
    for (final station in sortedStations) {
      final item = _allStationsListItems[station.slug];
      if (item == null) continue;
      final isFavorite = favoriteSlugs.contains(station.slug);
      item.setText(isFavorite ? "★ ${station.title}" : station.title);
    }

    // Get favorite items (reusing pre-created CPListItem objects)
    final favoriteItems = sortedStations
        .where((station) => favoriteSlugs.contains(station.slug))
        .map((station) => _favoriteListItems[station.slug])
        .whereType<CPListItem>()
        .toList();

    _flutterCarplay!.updateListTemplateSections(
      elementId: _favoriteTemplate!.uniqueId,
      sections: [CPListSection(items: favoriteItems)],
    );
    _flutterCarplay!.forceUpdateRootTemplate();
  }

  /// Reorders both CarPlay station lists (favorites + all stations) to match
  /// the new sort order after a sort cache invalidation.
  void _reorderCarPlayStations() {
    if (_favoriteTemplate == null || _allStationsTemplate == null || _flutterCarplay == null) return;

    final sortedStations = _stationDataService.getSortedStations();
    final favoriteSlugs = _stationDataService.favoriteStationSlugs.value;

    // Reorder favorites list
    final favoriteItems = sortedStations
        .where((s) => favoriteSlugs.contains(s.slug))
        .map((s) => _favoriteListItems[s.slug])
        .whereType<CPListItem>()
        .toList();

    _flutterCarplay!.updateListTemplateSections(
      elementId: _favoriteTemplate!.uniqueId,
      sections: [CPListSection(items: favoriteItems)],
    );

    // Reorder all-stations list
    final allItems = sortedStations
        .map((s) => _allStationsListItems[s.slug])
        .whereType<CPListItem>()
        .toList();

    _flutterCarplay!.updateListTemplateSections(
      elementId: _allStationsTemplate!.uniqueId,
      sections: [CPListSection(items: allItems)],
    );

    _flutterCarplay!.forceUpdateRootTemplate();
    _log("CarPlay station lists reordered after sort change");
  }

  void _initializeCarPlay() {
    _log("Initializing iOS CarPlay");
    _flutterCarplay = FlutterCarplay();

    _flutterCarplay!.addListenerOnConnectionChange((status) {
      _log("CarPlay connection status changed: $status");
      final wasConnected = isCarConnected.value;
      // Car is still connected when CarPlay goes to background
      // (user switched to Maps/other CarPlay app). Only treat
      // explicit disconnection as "not connected".
      final connected = status != ConnectionStatusTypes.disconnected;
      isCarConnected.add(connected);
      SeekModeManager.changeCarConnected(connected);

      if (connected && !wasConnected) {
        // Fresh CarPlay connection.
        _log(">>> CARPLAY CONNECTED (wasPlaying=${_audioHandler.playbackState.value.playing})");
        final wasPlaying = _audioHandler.playbackState.value.playing;
        _audioHandler.refreshCurrentMetadata();
        if (wasPlaying) {
          // Already playing from phone — don't interrupt the stream.
          // Just refresh station metadata for the new seek offset.
          _audioHandler.stationDataService.refreshStations();
          _log("Already playing, skipping autoplay — refreshed metadata only");
        } else {
          // Not playing — try to autoplay the last station.
          _autoplayOnCarConnect();
        }
      } else if (!connected && wasConnected) {
        _log(">>> CARPLAY DISCONNECTED (wasPlaying=${_audioHandler.playbackState.value.playing})");
        if (_audioHandler.playbackState.value.playing) {
          _log("Pausing playback due to CarPlay disconnect");
          _audioHandler.pause();
        }
      } else if (connected) {
        // Returning from background — just refresh metadata.
        _log(">>> CARPLAY FOREGROUND (returning from background)");
        _audioHandler.refreshCurrentMetadata();
      }
    });

    _trySetupCarPlayStations();
  }

  void _trySetupCarPlayStations() {
    if (_carPlayInitialized) {
      _log("CarPlay already initialized, skipping");
      return;
    }

    // Use filteredStations which is properly sorted by order (same as app)
    final stations = _stationDataService.filteredStations.value;
    if (stations.isEmpty) {
      _log("Stations not loaded yet, setting up listener");
      _setLoadingTemplate();
      // Wait for stations to load
      _waitForStations();
      return;
    }

    _setupCarPlayWithStations(stations);
  }

  void _setLoadingTemplate() {
    final listTemplate = CPListTemplate(
      title: "Radio Crestin",
      sections: [
        CPListSection(
          items: [
            CPListItem(
              text: _loadingStations,
              detailText: _pleaseWait,
            ),
          ],
        ),
      ],
      systemIcon: "music.note.list",
    );

    FlutterCarplay.setRootTemplate(
      rootTemplate: listTemplate,
      animated: false,
    );
    _flutterCarplay?.forceUpdateRootTemplate();
  }

  void _waitForStations() {
    _carPlayWaitTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_carPlayInitialized) {
        timer.cancel();
        return;
      }

      final stations = _stationDataService.filteredStations.value;
      if (stations.isNotEmpty) {
        timer.cancel();
        _setupCarPlayWithStations(stations);
      }
    });
  }

  void _setupCarPlayWithStations(List<Station> stations) {
    if (_carPlayInitialized) {
      _log("CarPlay already initialized, skipping setup");
      return;
    }

    try {
    _log("Setting up CarPlay with ${stations.length} stations");

    final favoriteSlugs = _stationDataService.favoriteStationSlugs.value;
    final sortedStations = _stationDataService.getSortedStations();

    final currentSlug = _audioHandler.currentStation.value?.slug;
    final isCurrentlyPlaying = _audioHandler.playbackState.value.playing;

    _favoriteListItems.clear();
    _allStationsListItems.clear();

    // Pre-create CPListItem objects for ALL stations (for favorites tab)
    for (final station in sortedStations) {
      final item = CPListItem(
        text: station.title,
        detailText: station.displaySubtitle.isNotEmpty ? station.displaySubtitle : null,
        image: _cachedOrNetworkUrl(station.thumbnailUrl),
        isPlaying: station.slug == currentSlug && isCurrentlyPlaying,
        onPress: (complete, item) async {
          _log("CarPlay: Favorite station selected: ${station.title}");
          complete();
          FlutterCarplay.showSharedNowPlaying(animated: true);
          await _audioHandler.playStation(station, fromFavorites: true);
        },
      );
      _favoriteListItems[station.slug] = item;
    }

    // Get initial favorite items
    final favoriteItems = sortedStations
        .where((station) => favoriteSlugs.contains(station.slug))
        .map((station) => _favoriteListItems[station.slug]!)
        .toList();

    _favoriteTemplate = CPListTemplate(
      title: _isRomanian ? "Favorite" : "Favorites",
      sections: [CPListSection(items: favoriteItems)],
      emptyViewTitleVariants: [_noFavorites],
      emptyViewSubtitleVariants: [_addFavoritesHint],
      systemIcon: "heart.fill",
    );

    // Create "Toate statiile" tab with separate CPListItem objects
    final allStationsItems = sortedStations.map((station) {
      final isFavorite = favoriteSlugs.contains(station.slug);
      final item = CPListItem(
        text: isFavorite ? "★ ${station.title}" : station.title,
        detailText: station.displaySubtitle.isNotEmpty ? station.displaySubtitle : null,
        image: _cachedOrNetworkUrl(station.thumbnailUrl),
        isPlaying: station.slug == currentSlug && isCurrentlyPlaying,
        onPress: (complete, item) async {
          _log("CarPlay: Station selected: ${station.title}");
          complete();
          FlutterCarplay.showSharedNowPlaying(animated: true);
          await _audioHandler.playStation(station, fromFavorites: false);
        },
      );
      _allStationsListItems[station.slug] = item;
      return item;
    }).toList();

    _allStationsTemplate = CPListTemplate(
      title: _allStationsTitle,
      sections: [
        CPListSection(items: allStationsItems),
      ],
      systemIcon: "music.note.list",
    );

    final tabBarTemplate = CPTabBarTemplate(
      templates: [_favoriteTemplate!, _allStationsTemplate!],
    );

    FlutterCarplay.setRootTemplate(
      rootTemplate: tabBarTemplate,
      animated: true,
    );
    _flutterCarplay?.forceUpdateRootTemplate();

    // Mark as initialized - this template will NEVER be replaced
    _carPlayInitialized = true;
    _log("CarPlay setup complete - template locked");

    // Listen for station metadata changes (song title, artist from 10s polls)
    // and update CarPlay list item detail text accordingly.
    _carPlayStationsSubscription = _stationDataService.stations.stream.listen((updatedStations) {
      _updateCarPlayStationMetadata(updatedStations);
    });

    // Listen for sort order changes (manual refresh, sort option change)
    // and reorder the CarPlay station lists.
    _carPlaySortOrderSubscription = _stationDataService.sortOrderChanged.stream.listen((_) {
      _reorderCarPlayStations();
    });
    } catch (e) {
      _log("Error setting up CarPlay: $e");
    }
  }

  /// Updates CarPlay list item detail text with current song metadata.
  void _updateCarPlayStationMetadata(List<Station> updatedStations) {
    final stationMap = <String, Station>{};
    for (final s in updatedStations) {
      stationMap[s.slug] = s;
    }

    for (final slug in _favoriteListItems.keys) {
      final station = stationMap[slug];
      if (station == null) continue;
      final subtitle = station.displaySubtitle;
      _favoriteListItems[slug]!.setDetailText(subtitle);
    }

    for (final slug in _allStationsListItems.keys) {
      final station = stationMap[slug];
      if (station == null) continue;
      final subtitle = station.displaySubtitle;
      _allStationsListItems[slug]!.setDetailText(subtitle);
    }

    _flutterCarplay?.forceUpdateRootTemplate();
  }

  // iOS CarPlay only: listen for connection errors and network state.
  void _listenForConnectionErrors() {
    _connectionErrorSubscription = _audioHandler.connectionError.listen((error) {
      if (!isConnected) return;
      // Debounce rapid errors (e.g. user taps multiple stations quickly)
      _connectionErrorDebounceTimer?.cancel();
      _connectionErrorDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (isConnected) {
          _showCarPlayConnectionError(error);
        }
      });
    });

    // Show alert immediately when network drops; dismiss when it recovers
    _networkRecoverySubscription = NetworkService.instance.isOffline.stream.listen((offline) {
      if (!isConnected) return;
      if (offline) {
        _showCarPlayConnectionError(const ConnectionError(
          stationName: '',
          reason: ConnectionErrorReason.network,
        ));
      } else if (_isShowingConnectionError) {
        _dismissConnectionErrorAlert();
      }
    });
  }

  Future<void> _dismissConnectionErrorAlert() async {
    if (!_isShowingConnectionError) return;
    _isShowingConnectionError = false;
    _connectionErrorDebounceTimer?.cancel();
    try {
      await FlutterCarplay.popModal(animated: true);
    } catch (e) {
      _log("Failed to dismiss CarPlay error alert: $e");
    }
  }

  Future<void> _showCarPlayConnectionError(ConnectionError error) async {
    // Dismiss any existing modal before showing a new one
    if (_isShowingConnectionError || FlutterCarPlayController.currentPresentTemplate != null) {
      try {
        await FlutterCarplay.popModal(animated: false);
      } catch (e) {
        _log("Failed to dismiss existing CarPlay modal: $e");
      }
    }

    final stationPart = error.stationName.isNotEmpty
        ? '"${error.stationName}"'
        : 'stația radio';
    final String message;
    switch (error.reason) {
      case ConnectionErrorReason.timeout:
        message = 'Conexiunea la $stationPart a expirat.';
        break;
      case ConnectionErrorReason.network:
        message = 'Verifică conexiunea la internet.';
        break;
      case ConnectionErrorReason.httpError:
        message = 'Serverul $stationPart a returnat eroarea ${error.details ?? "necunoscută"}.';
        break;
      case ConnectionErrorReason.unknown:
        message = 'Nu s-a putut conecta la $stationPart.';
        break;
    }

    final alertTemplate = CPAlertTemplate(
      titleVariants: [message],
      actions: [
        CPAlertAction(
          title: 'OK',
          onPress: () {
            _isShowingConnectionError = false;
          },
        ),
      ],
    );

    try {
      await FlutterCarplay.showAlert(template: alertTemplate);
      _isShowingConnectionError = true;
    } catch (e) {
      _log("Failed to show CarPlay connection error alert: $e");
    }
  }

  void _initializeAndroidAuto() {
    _log("Initializing Android Auto");
    _flutterAndroidAuto = FlutterAndroidAuto();

    _flutterAndroidAuto!.addListenerOnConnectionChange((status) {
      _log("Android Auto connection status changed: $status");
      final connected = status == ConnectionStatusTypes.connected;
      // Deduplicate: native side already filters, but guard against edge cases
      if (isCarConnected.value == connected) return;
      isCarConnected.add(connected);
      SeekModeManager.changeCarConnected(connected);
      _audioHandler.reapplySeekOffset();
      _audioHandler.refreshCurrentMetadata();
      if (connected) {
        // Android Auto just connected — rebuild the template now that
        // the MainScreen is available on the native side.
        _rebuildAndroidAutoTemplate();
        _autoplayOnCarConnect();
      } else {
        // Session destroyed — clean up player state so stale references
        // don't leak across reconnections.
        _isPlayerScreenVisible = false;
        _lastPlayerStationSlug = null;
        _lastPlayerSongTitle = null;
        _lastPlayerArtist = null;
        _lastPlayerIsPlaying = null;
        _lastPlayerIsFavorite = null;
        if (_audioHandler.playbackState.value.playing) {
          _log("Android Auto disconnected while playing, pausing");
          _audioHandler.pause();
        }
      }
    });

    // FAB handler: opens Now Playing screen if playing, otherwise starts playback.
    FlutterAndroidAuto.onFabPressed = ({String? action}) async {
      _log("Android Auto: FAB pressed, action=$action");
      final station = _audioHandler.currentStation.value;
      if (station != null) {
        if (!_isPlayerScreenVisible) {
          await _pushAndroidAutoPlayer(station);
        }
        if (!_audioHandler.playbackState.value.playing) {
          _audioHandler.play();
        }
      } else {
        final lastStation = await _audioHandler.getLastPlayedStation();
        if (lastStation != null) {
          _pushAndroidAutoPlayer(lastStation);
          _audioHandler.playStation(lastStation);
        }
      }
    };

    // Wire up player screen event callbacks
    _setupAndroidAutoPlayerCallbacks();

    _trySetupAndroidAutoStations();
  }

  void _setupAndroidAutoPlayerCallbacks() {
    _flutterAndroidAuto!.addListenerOnPlayerPlayPause(() {
      _log("Android Auto: Player play/pause pressed");
      if (_audioHandler.playbackState.value.playing) {
        _audioHandler.pause();
      } else {
        _audioHandler.play();
      }
    });

    _flutterAndroidAuto!.addListenerOnPlayerNext(() {
      _log("Android Auto: Player next pressed");
      _audioHandler.skipToNext();
    });

    _flutterAndroidAuto!.addListenerOnPlayerPrevious(() {
      _log("Android Auto: Player previous pressed");
      _audioHandler.skipToPrevious();
    });

    _flutterAndroidAuto!.addListenerOnPlayerFavoriteToggle(() {
      _log("Android Auto: Player favorite toggle pressed");
      final currentStation = _audioHandler.currentStation.value;
      if (currentStation != null) {
        final isFav = _isFavorite(currentStation.slug);
        _audioHandler.setStationIsFavorite(currentStation, !isFav);
      }
    });

    _flutterAndroidAuto!.addListenerOnPlayerClosed(() {
      _log("Android Auto: Player closed");
      _isPlayerScreenVisible = false;
      _lastPlayerStationSlug = null;
      _lastPlayerSongTitle = null;
      _lastPlayerArtist = null;
      _lastPlayerIsPlaying = null;
      _lastPlayerIsFavorite = null;
    });

    _flutterAndroidAuto!.addListenerOnSearchTextChanged((query) {
      _log("Android Auto: Search query: $query");
      // Search is handled via audio_service's MediaBrowserService onSearch().
      // The native SearchTemplate sends results back from the Dart handler.
      _audioHandler.search(query).then((results) {
        _log("Android Auto: Search returned ${results.length} results");
        // TODO: Send results back to native SearchScreen via method channel
      });
    });
  }

  Future<void> _pushAndroidAutoPlayer(Station station) async {
    final isFav = _isFavorite(station.slug);
    final isPlaying = _audioHandler.playbackState.value.playing;

    try {
      await FlutterAndroidAuto.pushPlayer(
        stationTitle: station.title,
        songTitle: station.songTitle,
        songArtist: station.artist,
        imageUrl: _cachedOrNetworkUrl(station.thumbnailUrl),
        isPlaying: isPlaying,
        isFavorite: isFav,
      );
      _isPlayerScreenVisible = true;
    } catch (e) {
      _log("Error pushing Android Auto player: $e");
    }
  }

  Future<void> _updateAndroidAutoPlayer() async {
    if (!_isPlayerScreenVisible) return;

    final station = _audioHandler.currentStation.value;
    if (station == null) return;

    // Find the latest station data from the sorted list (has up-to-date song metadata)
    final latestStation = _sortedAndroidAutoStations.firstWhere(
      (s) => s.slug == station.slug,
      orElse: () => station,
    );

    final isFav = _isFavorite(station.slug);
    final isPlaying = _audioHandler.playbackState.value.playing;
    final songTitle = latestStation.songTitle;
    final artist = latestStation.artist;

    // Skip update if nothing changed (prevents flickering on periodic polls)
    if (_lastPlayerStationSlug == station.slug &&
        _lastPlayerSongTitle == songTitle &&
        _lastPlayerArtist == artist &&
        _lastPlayerIsPlaying == isPlaying &&
        _lastPlayerIsFavorite == isFav) {
      return;
    }

    _lastPlayerStationSlug = station.slug;
    _lastPlayerSongTitle = songTitle;
    _lastPlayerArtist = artist;
    _lastPlayerIsPlaying = isPlaying;
    _lastPlayerIsFavorite = isFav;

    try {
      await FlutterAndroidAuto.updatePlayer(
        stationTitle: latestStation.title,
        songTitle: songTitle,
        songArtist: artist,
        imageUrl: _cachedOrNetworkUrl(latestStation.thumbnailUrl),
        isPlaying: isPlaying,
        isFavorite: isFav,
      );
    } catch (e) {
      _log("Error updating Android Auto player: $e");
    }
  }

  void _trySetupAndroidAutoStations() {
    if (_androidAutoInitialized) {
      _log("Android Auto already initialized, skipping");
      return;
    }

    // Use filteredStations which is properly sorted by order (same as app)
    final stations = _stationDataService.filteredStations.value;
    if (stations.isEmpty) {
      _log("Stations not loaded yet for Android Auto");
      _setAndroidAutoLoadingTemplate();
      _waitForAndroidAutoStations();
      return;
    }

    _setupAndroidAutoWithStations(stations);
  }

  void _setAndroidAutoLoadingTemplate() {
    final listTemplate = AAListTemplate(
      title: "Radio Crestin",
      sections: [
        AAListSection(
          title: _loadingTitle,
          items: [
            AAListItem(
              title: _loadingStations,
              subtitle: _pleaseWait,
            ),
          ],
        ),
      ],
    );

    try {
      FlutterAndroidAuto.setRootTemplate(
        template: listTemplate,
      );
    } on PlatformException catch (e) {
      _log("Android Auto loading template failed: ${e.message}");
    }
  }

  void _waitForAndroidAutoStations() {
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_androidAutoInitialized) {
        timer.cancel();
        return;
      }

      final stations = _stationDataService.filteredStations.value;
      if (stations.isNotEmpty) {
        timer.cancel();
        _setupAndroidAutoWithStations(stations);
      }
    });
  }

  void _setupAndroidAutoWithStations(List<Station> stations) {
    if (_androidAutoInitialized) {
      _log("Android Auto already initialized, skipping setup");
      return;
    }

    try {
      _log("Setting up Android Auto with ${stations.length} stations");

      _updateSortedAndroidAutoStations();
      _rebuildAndroidAutoTemplate();

      // Listen for tab selection events from Android Auto
      _flutterAndroidAuto!.addListenerOnTabSelected((contentId) {
        _log("Android Auto: Tab selected: $contentId");
        _activeAndroidAutoTabId = contentId;
      });

      // Single merged listener for ALL state changes that affect Android Auto.
      // Any change to favorites, current station, playback state, or station metadata
      // triggers a rebuild check + player update from the centralized state.
      _androidAutoStationSubscription = Rx.merge([
        _stationDataService.favoriteStationSlugs.stream.map((_) => 'favorites'),
        _audioHandler.currentStation.stream.map((_) => 'station'),
        _audioHandler.playbackState.stream.map((_) => 'playback'),
        _stationDataService.stations.stream.map((_) => 'metadata'),
        _stationDataService.sortOrderChanged.stream.map((_) => 'sort'),
      ]).listen((source) {
        // Refresh sorted stations from single source of truth
        _updateSortedAndroidAutoStations();

        // Determine if list rebuild is needed
        bool shouldRebuild = false;

        if (source == 'favorites' || source == 'station' || source == 'sort') {
          shouldRebuild = true;
        } else if (source == 'metadata') {
          final hash = _computeStationListHash(_sortedAndroidAutoStations);
          if (hash != _lastAndroidAutoListHash) {
            _lastAndroidAutoListHash = hash;
            shouldRebuild = true;
          }
        }

        if (shouldRebuild) {
          _rebuildAndroidAutoTemplate();
        }
        _updateAndroidAutoPlayer();
      });

      _androidAutoInitialized = true;
      _log("Android Auto setup complete");
    } catch (e) {
      _log("Error setting up Android Auto: $e");
    }
  }

  void _updateSortedAndroidAutoStations() {
    _sortedAndroidAutoStations = _stationDataService.getSortedStations();
  }

  // Android Auto hard limit: max 100 items per GridTemplate/ListTemplate
  static const _maxAndroidAutoItems = 100;

  // Debounce timer for Android Auto rebuilds
  Timer? _androidAutoRebuildTimer;

  // Serialize setRootTemplate calls to prevent out-of-order native completions
  bool _isAndroidAutoRebuilding = false;
  bool _needsAndroidAutoRebuild = false;

  void _rebuildAndroidAutoTemplate() {
    // Debounce rapid rebuilds (BehaviorSubject replays cause 3-4 immediate calls)
    _androidAutoRebuildTimer?.cancel();
    _androidAutoRebuildTimer = Timer(const Duration(milliseconds: 100), () {
      _doRebuildAndroidAutoTemplate();
    });
  }

  /// Builds a ListTemplate with full-width rows for Android Auto tabs.
  /// Each row shows the station thumbnail, title, and current song metadata.
  AAListTemplate _buildStationListTemplate({
    required String title,
    required List<Station> stations,
    bool isFavorites = false,
  }) {
    final stationsToShow = stations.length > _maxAndroidAutoItems
        ? stations.sublist(0, _maxAndroidAutoItems)
        : stations;
    final currentSlug = _audioHandler.currentStation.value?.slug;

    return AAListTemplate(
      title: title,
      sections: [
        AAListSection(
          items: stationsToShow.map((station) {
            // Mark the active station regardless of play/pause state.
            // The play/pause state is shown on the player screen, not the list.
            final isActive = station.slug == currentSlug;
            final subtitle = station.displaySubtitle.isNotEmpty
                ? station.displaySubtitle
                : null;
            return AAListItem(
              title: isActive ? "▶ ${station.title}" : station.title,
              subtitle: subtitle,
              imageUrl: _cachedOrNetworkUrl(station.thumbnailUrl),
              onPress: (complete, item) async {
                _log("Android Auto: Station selected: ${station.title} (isFavorites=$isFavorites)");
                complete();
                // On API 8+: pushPlayer uses MediaPlaybackTemplate (system renders
                // YouTube Music-style Now Playing from MediaSession automatically).
                // On API < 8: pushPlayer uses PaneTemplate as fallback.
                _pushAndroidAutoPlayer(station);
                await _audioHandler.playStation(station, fromFavorites: isFavorites);
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Future<void> _doRebuildAndroidAutoTemplate() async {
    // Don't try to set templates before Android Auto is connected
    // (MainScreen won't exist yet on the native side)
    if (!isCarConnected.value) return;

    // Serialize: if a rebuild is in flight, queue one more and return
    if (_isAndroidAutoRebuilding) {
      _needsAndroidAutoRebuild = true;
      return;
    }
    _isAndroidAutoRebuilding = true;
    final favoriteSlugs = _stationDataService.favoriteStationSlugs.value;

    // Split stations into favorites and all
    final favoriteStations = _sortedAndroidAutoStations
        .where((s) => favoriteSlugs.contains(s.slug))
        .toList();

    if (_sortedAndroidAutoStations.isEmpty) {
      _log("Android Auto: No stations to display");
      _isAndroidAutoRebuilding = false;
      return;
    }

    // Build list content for each tab
    final favoritesList = _buildStationListTemplate(
      title: _favoriteStationsTitle,
      stations: favoriteStations,
      isFavorites: true,
    );

    final allStationsList = _buildStationListTemplate(
      title: _allStationsTitle,
      stations: _sortedAndroidAutoStations,
    );

    // Build a TabTemplate with two tabs
    final tabTemplate = AATabTemplate(
      activeTabContentId: _activeAndroidAutoTabId,
      tabs: [
        AATab(
          contentId: 'favorites',
          title: _favoritesTabTitle(favoriteStations.length),
          content: favoritesList,
        ),
        AATab(
          contentId: 'all_stations',
          title: _allTabTitle(_sortedAndroidAutoStations.length),
          content: allStationsList,
        ),
      ],
    );

    try {
      await FlutterAndroidAuto.setRootTemplate(template: tabTemplate);
    } on PlatformException catch (e) {
      _log("Android Auto setRootTemplate failed: ${e.message}");
    } finally {
      _isAndroidAutoRebuilding = false;
    }

    // If another rebuild was requested while we were busy, run it now
    if (_needsAndroidAutoRebuild) {
      _needsAndroidAutoRebuild = false;
      _doRebuildAndroidAutoTemplate();
    }
  }

  /// Computes a lightweight hash of the station list's visible data.
  /// Used to skip Android Auto rebuilds when nothing the user can see has changed.
  int _computeStationListHash(List<Station> stations) {
    var hash = 0;
    for (final s in stations) {
      hash = hash ^ s.id.hashCode ^ s.songId.hashCode ^ s.songTitle.hashCode ^ (s.totalListeners ?? 0).hashCode;
    }
    return hash;
  }

  void dispose() {
    _log("Disposing CarPlay/Android Auto service");

    _carPlayWaitTimer?.cancel();
    _connectionErrorDebounceTimer?.cancel();
    _currentStationSubscription?.cancel();
    _favoritesSubscription?.cancel();
    _carPlayPlaybackSubscription?.cancel();
    _carPlayStationsSubscription?.cancel();
    _carPlaySortOrderSubscription?.cancel();
    _mediaItemSubscription?.cancel();
    _connectionErrorSubscription?.cancel();
    _networkRecoverySubscription?.cancel();
    _androidAutoStationSubscription?.cancel();
    _androidAutoRebuildTimer?.cancel();

    if (Platform.isIOS) {
      _flutterCarplay?.removeListenerOnConnectionChange();
    } else if (Platform.isAndroid) {
      _flutterAndroidAuto?.removeListenerOnConnectionChange();
    }
  }
}
