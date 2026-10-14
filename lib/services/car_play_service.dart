import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/car_play_layout.dart';
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/services/image_retry_signal.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/offline_alert_gate.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils/station_ui.dart';
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
  StreamSubscription? _carConnectedAlertSubscription;
  StreamSubscription? _audioPlayingAlertSubscription;
  StreamSubscription? _playRequestAlertSubscription;
  StreamSubscription? _carPlayPlaybackSubscription;
  StreamSubscription? _carPlayStationsSubscription;
  StreamSubscription? _carPlaySortOrderSubscription;
  StreamSubscription? _mediaItemSubscription;
  StreamSubscription? _imageRetrySubscription;

  // Timers
  Timer? _carPlayWaitTimer;
  Timer? _connectionErrorDebounceTimer;

  // Why the error alert shown on CarPlay is up; null while none is.
  ConnectionErrorReason? _shownErrorReason;
  bool get _isShowingConnectionError => _shownErrorReason != null;

  // When the car shows that the internet is out: CarPlay's alert,
  // Android Auto's error state.
  OfflineAlertGate? _offlineAlertGate;

  // What the running iOS supports (the pinned row needs iOS 26).
  CPCapabilities _carPlayCapabilities = CPCapabilities.fallback;

  // The CarPlay tabs: "Home" (a list) and "Categories" (a grid, left out
  // while the catalog has no groups), and what the pinned row and the grid
  // show, to skip updates that change nothing.
  CPTabBarTemplate? _carPlayTabBar;
  CPListTemplate? _homeTemplate;
  String? _pinnedSignature;
  String? _categoriesSignature;
  StreamSubscription? _carPlayGroupsSubscription;

  // Home rows by section, kept for live updates.
  late final _favoriteRows =
      _CarStationRows((s) => _carStationRow(s, fromFavorites: true));
  late final _allStationsRows = _CarStationRows(
    (s) => _carStationRow(s, fromFavorites: false, starIfFavorite: true),
    starsFavorites: true,
  );

  // Station lists pushed over a tab (a category, all favorites), by
  // template id; dropped once CarPlay pops them.
  final Map<String, _PushedStationList> _pushedLists = {};

  // Play counts as they were when the car connected: the pinned row keeps
  // its order for the whole drive instead of moving under the driver's
  // finger.
  Map<String, int> _carPlayCountsSnapshot = const {};

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

  /// Pure core for a car list/player image: a `file://` URI when
  /// [cachedPathFor] has the image on disk, otherwise [url] itself.
  ///
  /// An empty URL becomes null (no image). Native CarPlay treats any
  /// non-null image string it can't parse as a bundled asset name, and
  /// looking up a missing asset traps — at every iOS launch, since the
  /// templates are built whether or not a car is connected.
  static String? resolveCarImageUrl(
    String? url,
    String? Function(String url) cachedPathFor,
  ) {
    if (url == null || url.isEmpty) return null;
    final cachedPath = cachedPathFor(url);
    return cachedPath != null ? 'file://$cachedPath' : url;
  }

  /// Pure core for a song-history row's image source: the song artwork,
  /// or the station logo when the song has none. An empty string counts as
  /// "none" — `??` alone would let it through.
  static String? songHistoryThumbnailSource(
    String? songThumbnailUrl,
    String? stationThumbnailUrl,
  ) =>
      (songThumbnailUrl != null && songThumbnailUrl.isNotEmpty)
          ? songThumbnailUrl
          : stationThumbnailUrl;

  /// Returns file:// URI if cached, otherwise the original network URL.
  String? _cachedOrNetworkUrl(String? url) => resolveCarImageUrl(
        url,
        (u) => _imageCacheService?.getCachedPath(u),
      );

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
      // No list context: next/previous keep the persisted one, so a station
      // last picked from favorites keeps cycling through the favorites.
      _log("Car connected — autoplaying station: ${station.slug}");
      _audioHandler.playStation(station);
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

  // Car screens are in Romanian only, like the rest of the app.
  static const _favoriteStationsTitle = 'Stații Favorite';
  static const _allStationsTitle = 'Toate Stațiile';
  static String _favoritesTabTitle(int count) => 'Favorite ($count)';
  static String _allTabTitle(int count) => 'Toate ($count)';
  static const _loadingTitle = 'Se încarcă...';
  static const _loadingStations = 'Se încarcă stațiile...';
  static const _pleaseWait = 'Vă rugăm așteptați';
  static const _homeTitle = 'Acasă';
  static const _categoriesTitle = 'Categorii';
  static const _favoritesHeader = 'Favorite';
  static const _noFavoritesTitle = 'Nu ai stații favorite';
  static const _noFavoritesHint = 'Apasă ♡ în ecranul de redare';
  static const _allStationsHeader = 'Toate stațiile';
  static const _moreTitle = 'Mai multe';
  static const _moreCategoriesTitle = 'Mai multe categorii';

  /// The last picture of the "Favorite" row when not all of them fit: it
  /// opens every favorite. Short, as it sits under a picture.
  static String _allFavoritesTitle(int count) => 'Toate ($count)';

  /// "5 stații", "23 de stații" (Romanian puts "de" after 20 and up).
  static String stationCountText(int count, {required bool isRomanian}) {
    if (!isRomanian) return count == 1 ? '1 station' : '$count stations';
    if (count == 1) return '1 stație';
    final lastTwo = count % 100;
    final withDe = count >= 20 && (lastTwo == 0 || lastTwo >= 20);
    return withDe ? '$count de stații' : '$count stații';
  }

  // ---------------------------------------------------------------------------
  // Row / player display helpers (new station types: radio / tv / playlist)
  // ---------------------------------------------------------------------------

  /// Pure core for a station row's detail/subtitle text in the car lists.
  ///
  /// Radio/TV stations show their now-playing song line ([displaySubtitle],
  /// empty when idle). A "playlist" station has no now-playing song, so its
  /// [displaySubtitle] is always empty — fall back to a localized "Playlist"
  /// label so the row isn't blank and the station kind reads clearly in the car.
  ///
  /// Thin wrapper over the shared [computeStationSubtitle] so the car and the
  /// app share one implementation; the car keeps its historical behavior (no
  /// TV "live" fallback, no playlist item title/count).
  static String? computeStationListSubtitle({
    required String displaySubtitle,
    required bool isPlaylist,
    required bool isRomanian,
  }) {
    return computeStationSubtitle(
      type: isPlaylist ? StationMediaType.playlist : StationMediaType.radio,
      songLine: displaySubtitle,
      isRomanian: isRomanian,
    );
  }

  String? _stationListSubtitle(Station station) => computeStationListSubtitle(
        displaySubtitle: station.displaySubtitle,
        isPlaylist: station.isPlaylist,
        isRomanian: true,
      );

  /// Pure core for the Android Auto player screen's "now playing" fields.
  ///
  /// In playlist mode the "song" line is the current playlist ITEM title (with
  /// the station/playlist name as the secondary line), because a playlist
  /// station's own now-playing song is always empty. Radio/TV keep their
  /// now-playing song. [imageUrlSource] is a raw URL the caller resolves to a
  /// cached file:// path when available.
  static ({String songTitle, String songArtist, String? imageUrlSource})
      computePlayerFields({
    required bool inPlaylistMode,
    required String? playlistItemTitle,
    required String? playlistItemImageUrl,
    required String stationTitle,
    required String stationSongTitle,
    required String stationSongArtist,
    required String? stationThumbnailUrl,
  }) {
    if (inPlaylistMode) {
      return (
        songTitle: playlistItemTitle ?? '',
        songArtist: stationTitle,
        imageUrlSource: playlistItemImageUrl ?? stationThumbnailUrl,
      );
    }
    return (
      songTitle: stationSongTitle,
      songArtist: stationSongArtist,
      imageUrlSource: stationThumbnailUrl,
    );
  }

  /// Android Auto player fields for [station], playlist-aware. Reads the
  /// broadcast [MediaItem] (item title/artwork) when [station] is the active
  /// playlist station, then resolves the image to a cached path if present.
  ({String songTitle, String songArtist, String? imageUrl}) _playerFields(
    Station station,
  ) {
    final inPlaylist = _audioHandler.isPlaylistMode &&
        _audioHandler.currentStation.value?.id == station.id;
    final MediaItem? mi = inPlaylist ? _audioHandler.mediaItem.valueOrNull : null;
    final core = computePlayerFields(
      inPlaylistMode: inPlaylist,
      playlistItemTitle: mi?.displayTitle ?? mi?.title,
      playlistItemImageUrl: mi?.artUri?.toString(),
      stationTitle: station.title,
      stationSongTitle: station.songTitle,
      stationSongArtist: station.artist,
      stationThumbnailUrl: station.thumbnailUrl,
    );
    return (
      songTitle: core.songTitle,
      songArtist: core.songArtist,
      imageUrl: _cachedOrNetworkUrl(core.imageUrlSource),
    );
  }

  Future<void> initialize() async {
    _log("Initializing CarPlay/Android Auto service");

    if (Platform.isIOS) {
      _initializeCarPlay();
      _setupNowPlayingButtonsHandler();
      _listenForConnectionErrors();
      _retryFailedCarPlayImages();
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
      // Update the CarPlay lists (pinned row, sections, star prefixes)
      _refreshCarPlayLists();
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
      // The default window (last hour) is one URL per station shared at the
      // edge; a per-second `to_timestamp` would never be shared.
      final history = await SongHistoryService.fetchHistory(station.slug);
      if (history == null || history.history.isEmpty) {
        _log("No song history available for ${station.slug}");
        return;
      }

      // Only songs already heard: on time-shifted HLS the newest rows are
      // still ahead of the audible instant.
      final pastSongs = SongHistoryService.playedBefore(history.history,
          _audioHandler.stationDataService.playedCutoffFor(station.id));
      final items = pastSongs
          .take(30)
          .map((item) {
            final time = item.dateTime.toLocal();
            final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
            final title = item.songName ?? 'Necunoscut';
            final artist = item.artistName != null ? '$timeStr - ${item.artistName}' : timeStr;
            final thumbUrl = _cachedOrNetworkUrl(songHistoryThumbnailSource(
              item.songThumbnailUrl,
              station.thumbnailUrl,
            ));
            return CPListItem(
              text: title,
              detailText: artist,
              image: thumbUrl,
            );
          })
          .toList();

      if (items.isEmpty) return;

      const title = 'Redate recent';
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

  /// Every set of CarPlay station rows: Home sections, then pushed lists.
  /// Pushed lists CarPlay has popped are dropped first.
  Iterable<_CarStationRows> get _carStationRowSets sync* {
    _dropPoppedLists();
    yield _favoriteRows;
    yield _allStationsRows;
    for (final list in _pushedLists.values) {
      yield list.rows;
    }
  }

  void _dropPoppedLists() {
    _pushedLists.removeWhere((id, _) =>
        FlutterCarPlayController.getTemplateFromHistory<CPListTemplate>(id) ==
        null);
  }

  void _updateCarPlayListPlayingState(String currentSlug) {
    final isPlaying = _audioHandler.playbackState.value.playing;
    bool anyChanged = false;
    for (final rows in _carStationRowSets) {
      for (final entry in rows.items.entries) {
        final shouldBePlaying = entry.key == currentSlug && isPlaying;
        if (entry.value.isPlaying == shouldBePlaying) continue;
        if (!rows.isShown(entry.key)) {
          // Not on a native list: store the state only; it is sent with
          // the next section update.
          entry.value.isPlaying = shouldBePlaying;
          continue;
        }
        entry.value.setIsPlaying(shouldBePlaying);
        anyChanged = true;
      }
    }
    if (anyChanged) {
      _flutterCarplay?.forceUpdateRootTemplate();
    }
  }

  // ---------------------------------------------------------------------------
  // CarPlay Home and Categories tabs
  // ---------------------------------------------------------------------------

  /// The full catalog in the app's order: the phone's group filter can't be
  /// seen or changed from the car.
  List<Station> _carSortedStations() =>
      _stationDataService.getSortedStations(applyGroupFilter: false);

  /// Remembers play counts as they are now, for the order of the pinned
  /// row until the next connection.
  void _takeCarPlaySnapshots() {
    final playCounts = GetIt.instance.isRegistered<PlayCountService>()
        ? GetIt.instance<PlayCountService>()
        : null;
    playCounts?.refresh();
    _carPlayCountsSnapshot = Map.of(playCounts?.playCounts ?? const {});
  }

  CarHomeLayout _computeHomeLayout(List<Station> sorted) =>
      CarHomeLayout.compute(
        sortedSlugs: [for (final s in sorted) s.slug as String],
        favoriteSlugs: _stationDataService.favoriteStationSlugs.value.toSet(),
        playCounts: _carPlayCountsSnapshot,
        usePinnedRow: _carPlayCapabilities.supportsHeaderImageRow,
        maxPinned: _carPlayCapabilities.maximumHeaderImageRowCount,
      );

  /// The Home list sections: "Favorites" and "All stations". "Favorites"
  /// lists them only without the pinned row, and holds a hint on how to
  /// add one while there are none.
  List<CPListSection> _homeSections(
    CarHomeLayout layout,
    Map<String, Station> bySlug,
  ) {
    List<Station> stationsOf(List<String> slugs) =>
        [for (final slug in slugs) if (bySlug[slug] case final s?) s];
    final favorites = _favoriteRows.rowsFor(stationsOf(layout.favorites));
    final all = _allStationsRows.rowsFor(stationsOf(layout.all));
    return [
      if (favorites.isNotEmpty)
        CPListSection(header: _favoritesHeader, items: favorites)
      else if (!layout.hasFavorites)
        CPListSection(header: _favoritesHeader, items: [_noFavoritesRow()]),
      CPListSection(header: _allStationsHeader, items: all),
    ];
  }

  /// Tells a listener without favorites how to add one: the heart on Now
  /// Playing, which a tap opens while a station is loaded.
  CPListItem _noFavoritesRow() => CPListItem(
        text: _noFavoritesTitle,
        detailText: _noFavoritesHint,
        image: 'sf:heart',
        onPress: (complete, item) {
          complete();
          if (_audioHandler.currentStation.value == null) return;
          FlutterCarplay.showSharedNowPlaying(animated: true);
        },
      );

  /// The pinned row (iOS 26+): "Favorite" with the favorites, most played
  /// first. Null without favorites.
  CPImageRow? _pinnedRow(CarHomeLayout layout, Map<String, Station> bySlug) {
    if (layout.pinned.isEmpty) return null;
    final favoritesCount =
        layout.pinned.length + layout.hiddenFavoriteCount;
    return CPImageRow(
      title: _favoritesHeader,
      elements: [
        for (final slug in layout.pinned)
          if (bySlug[slug] case final station?)
            CPImageRowElement(
              title: station.title as String,
              image: _cachedOrNetworkUrl(station.thumbnailUrl) ?? 'sf:radio',
              onPress: () => _playFromCar(station, fromFavorites: true),
            ),
        if (layout.hiddenFavoriteCount > 0)
          CPImageRowElement(
            title: _allFavoritesTitle(favoritesCount),
            image: 'sf:ellipsis',
            onPress: _showAllFavorites,
          ),
      ],
      onTitlePress: _showAllFavorites,
    );
  }

  static String _pinnedSignatureOf(CarHomeLayout layout) => [
        layout.hiddenFavoriteCount,
        ...layout.pinned,
      ].join('|');

  /// A row for [station] in a car list. With [starIfFavorite], favorites
  /// get a star before the title, as in "All stations". See [_playFromCar]
  /// for [fromFavorites] and [fromGroup].
  CPListItem _carStationRow(
    Station station, {
    required bool fromFavorites,
    String? fromGroup,
    bool starIfFavorite = false,
  }) {
    final currentSlug = _audioHandler.currentStation.value?.slug;
    final starred = starIfFavorite && _isFavorite(station.slug);
    return CPListItem(
      text: starred ? "★ ${station.title}" : station.title,
      detailText: _stationListSubtitle(station),
      image: _cachedOrNetworkUrl(station.thumbnailUrl),
      isPlaying: station.slug == currentSlug &&
          _audioHandler.playbackState.value.playing,
      onPress: (complete, item) async {
        complete();
        await _playFromCar(
          station,
          fromFavorites: fromFavorites,
          fromGroup: fromGroup,
        );
      },
    );
  }

  /// Plays [station] picked on the car screen and opens Now Playing.
  /// [fromFavorites] keeps next/previous within the favorites, [fromGroup]
  /// (a category's slug) within that category.
  Future<void> _playFromCar(
    Station station, {
    required bool fromFavorites,
    String? fromGroup,
  }) async {
    final latest = _stationDataService.stations.value
            .where((s) => s.slug == station.slug)
            .firstOrNull ??
        station;
    _log("CarPlay: Station selected: ${latest.title} "
        "(fromFavorites=$fromFavorites, fromGroup=$fromGroup)");
    FlutterCarplay.showSharedNowPlaying(animated: true);
    await _audioHandler.playStation(
      latest,
      fromFavorites: fromFavorites,
      fromGroup: fromGroup,
    );
  }

  /// Brings the CarPlay lists in line with the favorites and the sort
  /// order: Home (pinned row and sections), stars, and pushed lists.
  ///
  /// Skipped while no car is connected: the lists are built at launch but
  /// nobody sees them, and connecting refreshes them.
  void _refreshCarPlayLists() {
    final home = _homeTemplate;
    final carplay = _flutterCarplay;
    if (home == null || carplay == null || !isCarConnected.value) return;

    final sorted = _carSortedStations();
    final bySlug = {for (final s in sorted) s.slug as String: s};
    final layout = _computeHomeLayout(sorted);

    // Home rows are sent again below, so their stars are only stored;
    // pushed rows stay on screen and are updated in place.
    _syncFavoriteStars(_allStationsRows, bySlug, updateNative: false);
    carplay.updateListTemplateSections(
      elementId: home.uniqueId,
      sections: _homeSections(layout, bySlug),
    );

    final signature = _pinnedSignatureOf(layout);
    if (signature != _pinnedSignature) {
      _pinnedSignature = signature;
      carplay.updateListTemplateHeaderImageRow(
        elementId: home.uniqueId,
        row: _pinnedRow(layout, bySlug),
      );
    }

    _dropPoppedLists();
    for (final entry in _pushedLists.entries) {
      _refreshPushedList(entry.key, entry.value, bySlug);
    }
    carplay.forceUpdateRootTemplate();
  }

  /// Updates a pushed list: its stars in place, and its rows when the
  /// stations it lists changed (a favorite removed, a new sort order).
  void _refreshPushedList(
    String templateId,
    _PushedStationList list,
    Map<String, Station> bySlug,
  ) {
    final stations = list.stations();
    final slugs = [for (final s in stations) s.slug as String];
    if (listEquals(slugs, list.rows.shown)) {
      _syncFavoriteStars(list.rows, bySlug, updateNative: true);
      return;
    }
    _syncFavoriteStars(list.rows, bySlug, updateNative: false);
    _flutterCarplay?.updateListTemplateSections(
      elementId: templateId,
      sections: [CPListSection(items: list.rows.rowsFor(stations))],
    );
  }

  /// Puts the favorite star on [rows] that need it and takes it off the
  /// others. With [updateNative], rows on screen change right away;
  /// otherwise the text waits for the next section update.
  void _syncFavoriteStars(
    _CarStationRows rows,
    Map<String, Station> bySlug, {
    required bool updateNative,
  }) {
    if (!rows.starsFavorites) return;
    for (final entry in rows.items.entries) {
      final station = bySlug[entry.key];
      if (station == null) continue;
      final text = _isFavorite(entry.key)
          ? "★ ${station.title}"
          : station.title as String;
      if (entry.value.text == text) continue;
      if (updateNative && rows.isShown(entry.key)) {
        entry.value.setText(text);
      } else {
        entry.value.text = text;
      }
    }
  }

  /// Pushes a list of [stations] over the current tab, kept up to date
  /// while it stays on screen; [stations] lists them again on updates.
  Future<void> _pushStationList({
    required String title,
    required List<Station> Function() stations,
    required bool fromFavorites,
    String? fromGroup,
    required bool starFavorites,
  }) async {
    final rows = _CarStationRows(
      (s) => _carStationRow(
        s,
        fromFavorites: fromFavorites,
        fromGroup: fromGroup,
        starIfFavorite: starFavorites,
      ),
      starsFavorites: starFavorites,
    );
    final template = CPListTemplate(
      title: title,
      sections: [CPListSection(items: rows.rowsFor(stations()))],
      systemIcon: 'music.note.list',
      sectionIndexEnabled: false,
    );
    try {
      if (await FlutterCarplay.push(template: template, animated: true)) {
        _pushedLists[template.uniqueId] = _PushedStationList(rows, stations);
      }
    } catch (e) {
      _log("Error pushing CarPlay list '$title': $e");
    }
  }

  /// Every favorite, in the app's order (the pinned row has no room).
  Future<void> _showAllFavorites() => _pushStationList(
        title: _favoritesHeader,
        stations: () => _carSortedStations()
            .where((s) => _isFavorite(s.slug))
            .toList(),
        fromFavorites: true,
        starFavorites: false,
      );

  /// The stations of [category]; next/previous then stay within them.
  Future<void> _showCategory(CarCategory category) => _pushStationList(
        title: category.name,
        stations: () => _carSortedStations()
            .where((s) => category.stationIds.contains(s.id))
            .toList(),
        fromFavorites: false,
        fromGroup: category.slug,
        starFavorites: true,
      );

  /// The categories without a grid button, as a list.
  Future<void> _showMoreCategories(List<CarCategory> categories) async {
    final template = CPListTemplate(
      title: _moreCategoriesTitle,
      sections: [
        CPListSection(items: [
          for (final category in categories)
            CPListItem(
              text: category.name,
              detailText: stationCountText(
                category.stationIds.length,
                isRomanian: true,
              ),
              accessoryType: CPListItemAccessoryTypes.disclosureIndicator,
              onPress: (complete, item) async {
                await _showCategory(category);
                complete();
              },
            ),
        ]),
      ],
      systemIcon: 'square.grid.2x2',
      sectionIndexEnabled: false,
    );
    try {
      await FlutterCarplay.push(template: template, animated: true);
    } catch (e) {
      _log("Error pushing CarPlay categories: $e");
    }
  }

  /// The station groups for the Categories grid, in the app's order.
  CarCategoryLayout _computeCategoryLayout() {
    final groups = _stationDataService.stationGroups.value;
    final indexed = [for (var i = 0; i < groups.length; i++) (i, groups[i])]
      ..sort((a, b) {
        final byOrder = a.$2.order.compareTo(b.$2.order);
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
    return CarCategoryLayout.compute(
      groups: [
        for (final (_, group) in indexed)
          CarCategory(
            id: group.id,
            slug: group.slug,
            name: group.name,
            stationIds: {
              for (final link in group.station_to_station_groups)
                link.station_id,
            },
          ),
      ],
      knownStationIds: {
        for (final s in _stationDataService.stations.value) s.id as int,
      },
    );
  }

  CPGridTemplate? _buildCategoriesTemplate(CarCategoryLayout layout) {
    if (layout.isEmpty) return null;
    return CPGridTemplate(
      title: _categoriesTitle,
      systemIcon: 'square.grid.2x2.fill',
      buttons: [
        for (final category in layout.onGrid)
          CPGridButton(
            titleVariants: [category.name],
            image: 'sf:${category.symbol}',
            onPress: () => _showCategory(category),
          ),
        if (layout.more.isNotEmpty)
          CPGridButton(
            titleVariants: [_moreTitle],
            image: 'sf:ellipsis',
            onPress: () => _showMoreCategories(layout.more),
          ),
      ],
    );
  }

  /// Rebuilds the Categories tab when a catalog refresh changed the
  /// groups it shows; adds or removes the tab when groups come or go.
  void _refreshCarPlayCategories() {
    final tabBar = _carPlayTabBar;
    final home = _homeTemplate;
    final carplay = _flutterCarplay;
    if (tabBar == null || home == null || carplay == null) return;

    final layout = _computeCategoryLayout();
    if (layout.signature == _categoriesSignature) return;
    _categoriesSignature = layout.signature;
    final categories = _buildCategoriesTemplate(layout);
    carplay.updateTabBarTemplates(
      elementId: tabBar.uniqueId,
      templates: [home, if (categories != null) categories],
    );
    _log("CarPlay categories updated: ${layout.onGrid.length} on the grid, "
        "${layout.more.length} under More");
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
        // A new drive: the pinned row follows the latest play counts.
        _takeCarPlaySnapshots();
        _refreshCarPlayLists();
        final wasPlaying = _audioHandler.playbackState.value.playing;
        _audioHandler.refreshCurrentMetadata();
        if (wasPlaying) {
          // Already playing from phone — don't interrupt the stream. The
          // audible clock follows the real stream, so the playing station
          // stays aligned; refresh the live list shown on the car screen.
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
        // The phone's Now Playing joins the song and its artist again.
        _audioHandler.refreshCurrentMetadata();
      } else if (connected) {
        // Returning from background — just refresh metadata.
        _log(">>> CARPLAY FOREGROUND (returning from background)");
        _audioHandler.refreshCurrentMetadata();
      }
    });

    _loadCarPlayCapabilitiesThenSetup();
  }

  /// Asks iOS what the templates support (the pinned row needs iOS 26)
  /// before the first lists are built.
  Future<void> _loadCarPlayCapabilitiesThenSetup() async {
    _carPlayCapabilities = await FlutterCarplay.getCapabilities();
    _log("CarPlay capabilities: pinned row="
        "${_carPlayCapabilities.supportsHeaderImageRow}, "
        "max pinned=${_carPlayCapabilities.maximumHeaderImageRowCount}");
    _trySetupCarPlayStations();
  }

  void _trySetupCarPlayStations() {
    if (_carPlayInitialized) {
      _log("CarPlay already initialized, skipping");
      return;
    }

    // Readiness gate only: the lists are built from getSortedStations().
    // Unfiltered, so a phone group filter matching nothing can't keep the
    // car on the loading template.
    final stations = _stationDataService.stations.value;
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

      final stations = _stationDataService.stations.value;
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

      _takeCarPlaySnapshots();
      final sorted = _carSortedStations();
      final bySlug = {for (final s in sorted) s.slug as String: s};
      final layout = _computeHomeLayout(sorted);

      final home = _homeTemplate = CPListTemplate(
        title: _homeTitle,
        sections: _homeSections(layout, bySlug),
        headerImageRow: _pinnedRow(layout, bySlug),
        systemIcon: "house.fill",
        sectionIndexEnabled: false,
      );
      _pinnedSignature = _pinnedSignatureOf(layout);

      final categoryLayout = _computeCategoryLayout();
      _categoriesSignature = categoryLayout.signature;
      final categories = _buildCategoriesTemplate(categoryLayout);

      final tabBar = _carPlayTabBar = CPTabBarTemplate(
        templates: [home, if (categories != null) categories],
      );

      FlutterCarplay.setRootTemplate(
        rootTemplate: tabBar,
        animated: true,
      );
      _flutterCarplay?.forceUpdateRootTemplate();

      // Mark as initialized - this template will NEVER be replaced
      _carPlayInitialized = true;
      _log("CarPlay setup complete - template locked "
          "(pinned=${layout.pinned.length}, "
          "favorites section=${layout.favorites.length}, "
          "categories=${categoryLayout.onGrid.length})");

      // Listen for station metadata changes (song title, artist from 10s polls)
      // and update CarPlay list item detail text accordingly.
      _carPlayStationsSubscription = _stationDataService.stations.stream.listen((updatedStations) {
        _updateCarPlayStationMetadata(updatedStations);
      });

      // Listen for sort order changes (manual refresh, sort option change)
      // and reorder the CarPlay station lists.
      _carPlaySortOrderSubscription = _stationDataService.sortOrderChanged.stream.listen((_) {
        _refreshCarPlayLists();
      });

      // A catalog refresh can add, rename or empty station groups.
      _carPlayGroupsSubscription = _stationDataService.stationGroups.stream
          .skip(1)
          .listen((_) => _refreshCarPlayCategories());
    } catch (e) {
      _log("Error setting up CarPlay: $e");
    }
  }

  /// Pure core for pushing fresh subtitles into car list [items].
  ///
  /// `stations` emits on almost every poll (listener counts change), so
  /// unchanged rows are skipped: each update is a native round trip. Items
  /// whose slug fails [isOnTemplate] are in no native template (a row
  /// kept for a station that left its section), so their text is only
  /// stored; `toJson` carries it with the next section update. A null
  /// detail text counts as empty. Returns whether any on-template item was
  /// updated.
  static bool syncListDetailTexts({
    required Map<String, CPListItem> items,
    required Map<String, Station> stationsBySlug,
    required String Function(Station station) subtitleFor,
    bool Function(String slug)? isOnTemplate,
  }) {
    var changed = false;
    for (final entry in items.entries) {
      final station = stationsBySlug[entry.key];
      if (station == null) continue;
      final item = entry.value;
      final text = subtitleFor(station);
      if ((item.detailText ?? '') == text) continue;
      if (isOnTemplate?.call(entry.key) ?? true) {
        item.setDetailText(text);
        changed = true;
      } else {
        item.detailText = text;
      }
    }
    return changed;
  }

  /// Updates CarPlay list item detail text with current song metadata.
  void _updateCarPlayStationMetadata(List<Station> updatedStations) {
    final stationMap = <String, Station>{
      for (final s in updatedStations) s.slug: s,
    };
    String subtitle(Station s) => _stationListSubtitle(s) ?? '';

    var anyChanged = false;
    for (final rows in _carStationRowSets) {
      final changed = syncListDetailTexts(
        items: rows.items,
        stationsBySlug: stationMap,
        subtitleFor: subtitle,
        isOnTemplate: rows.isShown,
      );
      anyChanged = anyChanged || changed;
    }

    if (anyChanged) {
      _flutterCarplay?.forceUpdateRootTemplate();
    }
  }

  // iOS CarPlay only: listen for connection errors and network state.
  void _listenForConnectionErrors() {
    final network = NetworkService.instance;
    _connectionErrorSubscription = _audioHandler.connectionError.listen((error) {
      if (!isConnected) return;
      // Without internet the network alert covers it, shown or pending;
      // another alert would only replace it.
      if (network.isOffline.value) return;
      // Debounce rapid errors (e.g. user taps multiple stations quickly)
      _connectionErrorDebounceTimer?.cancel();
      _connectionErrorDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (isConnected) {
          _showCarPlayConnectionError(error);
        }
      });
    });

    // The network alert waits while the buffer keeps the audio going and
    // goes when the internet is back (see OfflineAlertGate).
    final gate = _offlineAlertGate = OfflineAlertGate(
      show: () {
        // Already up (a steering-wheel skip while it shows): presenting it
        // again would only flash it.
        if (_shownErrorReason == ConnectionErrorReason.network) return;
        _showCarPlayConnectionError(const ConnectionError(
          stationName: '',
          reason: ConnectionErrorReason.network,
        ));
      },
      dismiss: () {
        if (_isShowingConnectionError) _dismissConnectionErrorAlert();
      },
    );
    _networkRecoverySubscription =
        network.isOffline.stream.listen(gate.onOfflineChanged);
    _carConnectedAlertSubscription =
        isCarConnected.stream.listen(gate.onCarConnectedChanged);
    _audioPlayingAlertSubscription =
        _audioHandler.audioPlayingStream.listen(gate.onAudioPlayingChanged);
    _playRequestAlertSubscription =
        _audioHandler.playRequested.listen((_) => gate.onPlayRequested());
  }

  // iOS CarPlay only: a row whose image failed to download (no internet
  // when the lists were built) shows a question mark until asked to try
  // again.
  void _retryFailedCarPlayImages() {
    _imageRetrySubscription = ImageRetrySignal.stream.listen((_) async {
      try {
        await FlutterCarplay.retryFailedImages();
      } catch (e) {
        _log("Error retrying CarPlay images: $e");
      }
    });
  }

  Future<void> _dismissConnectionErrorAlert() async {
    if (!_isShowingConnectionError) return;
    _shownErrorReason = null;
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
      _shownErrorReason = null;
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
            _shownErrorReason = null;
          },
        ),
      ],
    );

    try {
      await FlutterCarplay.showAlert(template: alertTemplate);
      _shownErrorReason = error.reason;
    } catch (e) {
      _log("Failed to show CarPlay connection error alert: $e");
    }
  }

  // Android Auto only: while the internet is out and nothing plays, the
  // player says why, on the rules of the CarPlay alert (OfflineAlertGate).
  // Android Auto draws its own player from the media session, so the
  // message goes through the session's error state.
  void _showOfflineErrorOnAndroidAuto() {
    final gate = _offlineAlertGate = OfflineAlertGate(
      show: () => _audioHandler.setOfflineError(true),
      dismiss: () => _audioHandler.setOfflineError(false),
    );
    _networkRecoverySubscription = NetworkService.instance.isOffline.stream
        .listen(gate.onOfflineChanged);
    _carConnectedAlertSubscription =
        isCarConnected.stream.listen(gate.onCarConnectedChanged);
    _audioPlayingAlertSubscription =
        _audioHandler.audioPlayingStream.listen(gate.onAudioPlayingChanged);
    _playRequestAlertSubscription =
        _audioHandler.playRequested.listen((_) => gate.onPlayRequested());
  }

  void _initializeAndroidAuto() {
    _log("Initializing Android Auto");
    _flutterAndroidAuto = FlutterAndroidAuto();
    _showOfflineErrorOnAndroidAuto();

    _flutterAndroidAuto!.addListenerOnConnectionChange((status) {
      _log("Android Auto connection status changed: $status");
      final connected = status == ConnectionStatusTypes.connected;
      // Deduplicate: native side already filters, but guard against edge cases
      if (isCarConnected.value == connected) return;
      isCarConnected.add(connected);
      SeekModeManager.changeCarConnected(connected);
      if (!connected && _audioHandler.playbackState.value.playing) {
        _log("Android Auto disconnected while playing, pausing");
        _audioHandler.pause();
      }
      // The car's 5-minute offset applies from the next load, as on
      // CarPlay: reloading a stream that already plays would cut the audio
      // and replay the minutes between the two offsets. ExoPlayer already
      // buffers everything up to the live edge, the offset it plays at.
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
    // Playlist-aware: for a playlist station the "song" line is the current
    // item title/artwork (station now-playing is empty for playlists).
    final fields = _playerFields(station);

    try {
      await FlutterAndroidAuto.pushPlayer(
        stationTitle: station.title,
        songTitle: fields.songTitle,
        songArtist: fields.songArtist,
        imageUrl: fields.imageUrl,
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
    // Playlist-aware fields: item title/artwork in playlist mode, else the
    // station's now-playing song. Advancing a playlist item changes the
    // broadcast mediaItem, which flips the dedup keys below and refreshes.
    final fields = _playerFields(latestStation);
    final songTitle = fields.songTitle;
    final artist = fields.songArtist;

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
        imageUrl: fields.imageUrl,
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

    // Readiness gate only: the lists are built from getSortedStations().
    // Unfiltered, so a phone group filter matching nothing can't keep the
    // car on the loading template.
    final stations = _stationDataService.stations.value;
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

      final stations = _stationDataService.stations.value;
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
        // Playlist item advances change the broadcast mediaItem (not the
        // station), so the player screen must refresh off it too. Only updates
        // the player (dedup-guarded); never triggers a list rebuild.
        _audioHandler.mediaItem.stream.map((_) => 'mediaitem'),
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
    // Full catalog: the phone's group filter can't be changed from the car.
    _sortedAndroidAutoStations =
        _stationDataService.getSortedStations(applyGroupFilter: false);
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
            final subtitle = _stationListSubtitle(station);
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
    _carPlayGroupsSubscription?.cancel();
    _mediaItemSubscription?.cancel();
    _imageRetrySubscription?.cancel();
    _connectionErrorSubscription?.cancel();
    _networkRecoverySubscription?.cancel();
    _carConnectedAlertSubscription?.cancel();
    _audioPlayingAlertSubscription?.cancel();
    _playRequestAlertSubscription?.cancel();
    _offlineAlertGate?.dispose();
    _androidAutoStationSubscription?.cancel();
    _androidAutoRebuildTimer?.cancel();

    if (Platform.isIOS) {
      _flutterCarplay?.removeListenerOnConnectionChange();
    } else if (Platform.isAndroid) {
      _flutterAndroidAuto?.removeListenerOnConnectionChange();
    }
  }
}

/// The CarPlay rows of one station list, by slug.
///
/// Rows are made on first use and kept, so live updates (song line, playing
/// indicator, favorite star) reach the native rows. Only the rows in
/// [shown] are on a native list right now; the others just store updates,
/// which the next section update carries.
class _CarStationRows {
  _CarStationRows(this._create, {this.starsFavorites = false});

  final CPListItem Function(Station station) _create;

  /// Whether rows put a star before the titles of favorites.
  final bool starsFavorites;

  final Map<String, CPListItem> items = {};

  /// Slugs of the rows on a native list, in order.
  List<String> shown = const [];

  /// The rows for [stations], in order; they become the [shown] ones.
  List<CPListItem> rowsFor(List<Station> stations) {
    shown = [for (final s in stations) s.slug as String];
    return [
      for (final s in stations)
        items.putIfAbsent(s.slug as String, () => _create(s)),
    ];
  }

  bool isShown(String slug) => shown.contains(slug);
}

/// A station list pushed over a CarPlay tab, with how to list its stations
/// again when favorites or the sort order change.
class _PushedStationList {
  _PushedStationList(this.rows, this.stations);

  final _CarStationRows rows;
  final List<Station> Function() stations;
}
