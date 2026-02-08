import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/types/Station.dart';

class CarPlayService {
  FlutterCarplay? _flutterCarplay;
  FlutterAndroidAuto? _flutterAndroidAuto;
  final AppAudioHandler _audioHandler = GetIt.instance<AppAudioHandler>();

  // Track initialization state - once true, NEVER rebuild
  bool _carPlayInitialized = false;
  bool _androidAutoInitialized = false;

  // Track CarPlay/Android Auto connection state
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  // Track last known state to avoid redundant native calls
  String? _lastPlayingSlug;

  // Method channel for Now Playing buttons (iOS CarPlay)
  static const _nowPlayingChannel = MethodChannel('com.radiocrestin.nowplaying_buttons');

  // Subscriptions
  StreamSubscription? _currentStationSubscription;
  StreamSubscription? _favoritesSubscription;

  // CarPlay list items by slug - for favorites tab (reused when updating)
  final Map<String, CPListItem> _favoriteListItems = {};

  // CarPlay list items by slug - for "Toate statiile" tab
  final Map<String, CPListItem> _allStationsListItems = {};

  // Store sorted stations for CarPlay playlist and title lookups
  List<Station> _sortedStations = [];

  // Store reference to favorite template for updating
  CPListTemplate? _favoriteTemplate;

  // Android Auto state
  List<Station> _sortedAndroidAutoStations = [];
  StreamSubscription? _androidAutoFavoritesSubscription;
  StreamSubscription? _androidAutoStationSubscription;
  StreamSubscription? _androidAutoStationsListSubscription;

  static void _log(String message) {
    developer.log("CarPlayService: $message");
  }

  Future<void> initialize() async {
    _log("Initializing CarPlay/Android Auto service");

    if (Platform.isIOS) {
      _initializeCarPlay();
      _setupNowPlayingButtonsHandler();
    } else if (Platform.isAndroid) {
      _initializeAndroidAuto();
    }

    _log("CarPlay/Android Auto service initialized");
  }

  /// Returns whether a station slug is currently favorited.
  /// This is the SINGLE source of truth for favorite state.
  bool _isFavorite(String slug) {
    return _audioHandler.favoriteStationSlugs.value.contains(slug);
  }

  void _setupNowPlayingButtonsHandler() {
    // Listen for favorite button presses from native iOS CarPlay
    _nowPlayingChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFavoriteButtonPressed') {
        final args = call.arguments as Map<dynamic, dynamic>;
        final isFavorite = args['isFavorite'] as bool;
        final currentStation = _audioHandler.currentStation.value;
        if (currentStation != null) {
          await _audioHandler.setStationIsFavorite(currentStation, isFavorite);
        }
      }
    });

    // Update CarPlay list playing indicator when station changes
    _currentStationSubscription = _audioHandler.currentStation.stream.listen((station) {
      if (station != null && _lastPlayingSlug != station.slug) {
        _lastPlayingSlug = station.slug;
        _updateCarPlayListPlayingState(station.slug);
        // Also sync Now Playing favorite button for the new station
        _updateNowPlayingFavoriteState(_isFavorite(station.slug));
      }
    });

    // Update favorite UI (Now Playing button + CarPlay lists) when favorites change
    _favoritesSubscription = _audioHandler.favoriteStationSlugs.stream.listen((_) {
      // Update Now Playing favorite button
      final currentStation = _audioHandler.currentStation.value;
      if (currentStation != null) {
        _updateNowPlayingFavoriteState(_isFavorite(currentStation.slug));
      }
      // Update CarPlay favorites list and star prefixes
      _updateCarPlayFavorites();
    });
  }

  Future<void> _updateNowPlayingFavoriteState(bool isFavorite) async {
    try {
      await _nowPlayingChannel.invokeMethod('setFavoriteState', {'isFavorite': isFavorite});
    } catch (e) {
      _log("Error updating Now Playing favorite state: $e");
    }
  }

  void _updateCarPlayListPlayingState(String currentSlug) {
    for (final entry in _favoriteListItems.entries) {
      entry.value.setIsPlaying(entry.key == currentSlug);
    }
    for (final entry in _allStationsListItems.entries) {
      entry.value.setIsPlaying(entry.key == currentSlug);
    }
  }

  void _updateCarPlayFavorites() {
    if (_favoriteTemplate == null || _sortedStations.isEmpty || _flutterCarplay == null) return;

    final favoriteSlugs = _audioHandler.favoriteStationSlugs.value;

    // Update star prefix in "Toate statiile" items
    for (final station in _sortedStations) {
      final item = _allStationsListItems[station.slug];
      if (item == null) continue;
      final isFavorite = favoriteSlugs.contains(station.slug);
      item.setText(isFavorite ? "★ ${station.title}" : station.title);
    }

    // Get favorite items (reusing pre-created CPListItem objects)
    final favoriteItems = _sortedStations
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

  void _initializeCarPlay() {
    _log("Initializing iOS CarPlay");
    _flutterCarplay = FlutterCarplay();

    _flutterCarplay!.addListenerOnConnectionChange((status) {
      _log("CarPlay connection status changed: $status");
      _isConnected = status == ConnectionStatusTypes.connected;
      if (!_isConnected) {
        _audioHandler.carPlayPlaylist = [];
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
    final stations = _audioHandler.filteredStations.value;
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
              text: "Se incarca statiile...",
              detailText: "Va rugam asteptati",
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
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_carPlayInitialized) {
        timer.cancel();
        return;
      }

      final stations = _audioHandler.filteredStations.value;
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

    final favoriteSlugs = _audioHandler.favoriteStationSlugs.value;

    // Sort stations alphabetically by title
    _sortedStations = List<Station>.from(stations);
    _sortedStations.sort((a, b) => a.title.toString().compareTo(b.title.toString()));

    final currentSlug = _audioHandler.currentStation.value?.slug;

    _favoriteListItems.clear();
    _allStationsListItems.clear();

    // Pre-create CPListItem objects for ALL stations (for favorites tab)
    for (final station in _sortedStations) {
      final item = CPListItem(
        text: station.title,
        image: station.thumbnailUrl,
        isPlaying: station.slug == currentSlug,
        onPress: (complete, item) async {
          _log("CarPlay: Favorite station selected: ${station.title}");
          // Get current favorites for playlist
          final currentFavorites = _sortedStations
              .where((s) => _isFavorite(s.slug))
              .toList();
          _audioHandler.carPlayPlaylist = List.from(currentFavorites);
          await _audioHandler.selectStation(station);
          complete();
          FlutterCarplay.showSharedNowPlaying(animated: true);
          _audioHandler.play();
        },
      );
      _favoriteListItems[station.slug] = item;
    }

    // Get initial favorite items
    final favoriteItems = _sortedStations
        .where((station) => favoriteSlugs.contains(station.slug))
        .map((station) => _favoriteListItems[station.slug]!)
        .toList();

    _favoriteTemplate = CPListTemplate(
      title: "Favorite",
      sections: [
        CPListSection(items: favoriteItems),
      ],
      emptyViewTitleVariants: ["Nicio statie favorita"],
      emptyViewSubtitleVariants: ["Adauga statii la favorite din aplicatie"],
      systemIcon: "heart.fill",
    );

    // Create "Toate statiile" tab with separate CPListItem objects
    final allStationsItems = _sortedStations.map((station) {
      final isFavorite = favoriteSlugs.contains(station.slug);
      final item = CPListItem(
        text: isFavorite ? "★ ${station.title}" : station.title,
        image: station.thumbnailUrl,
        isPlaying: station.slug == currentSlug,
        onPress: (complete, item) async {
          _log("CarPlay: Station selected: ${station.title}");
          _audioHandler.carPlayPlaylist = List.from(_sortedStations);
          await _audioHandler.selectStation(station);
          complete();
          FlutterCarplay.showSharedNowPlaying(animated: true);
          _audioHandler.play();
        },
      );
      _allStationsListItems[station.slug] = item;
      return item;
    }).toList();

    final allStationsTemplate = CPListTemplate(
      title: "Toate statiile",
      sections: [
        CPListSection(items: allStationsItems),
      ],
      systemIcon: "music.note.list",
    );

    final tabBarTemplate = CPTabBarTemplate(
      templates: [_favoriteTemplate!, allStationsTemplate],
    );

    FlutterCarplay.setRootTemplate(
      rootTemplate: tabBarTemplate,
      animated: true,
    );
    _flutterCarplay?.forceUpdateRootTemplate();

    // Set initial playlist to favorites so next/prev works immediately on cold start
    final favStations = _sortedStations
        .where((s) => favoriteSlugs.contains(s.slug))
        .toList();
    _audioHandler.carPlayPlaylist = favStations.isNotEmpty ? favStations : List.from(_sortedStations);

    // Mark as initialized - this template will NEVER be replaced
    _carPlayInitialized = true;
    _log("CarPlay setup complete - template locked");
    } catch (e) {
      _log("Error setting up CarPlay: $e");
    }
  }

  void _initializeAndroidAuto() {
    _log("Initializing Android Auto");
    _flutterAndroidAuto = FlutterAndroidAuto();

    _flutterAndroidAuto!.addListenerOnConnectionChange((status) {
      _log("Android Auto connection status changed: $status");
      _isConnected = status == ConnectionStatusTypes.connected;
      if (!_isConnected) {
        _audioHandler.carPlayPlaylist = [];
      }
    });

    _trySetupAndroidAutoStations();
  }

  void _trySetupAndroidAutoStations() {
    if (_androidAutoInitialized) {
      _log("Android Auto already initialized, skipping");
      return;
    }

    // Use filteredStations which is properly sorted by order (same as app)
    final stations = _audioHandler.filteredStations.value;
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
          title: "Se incarca...",
          items: [
            AAListItem(
              title: "Se incarca statiile...",
              subtitle: "Va rugam asteptati",
            ),
          ],
        ),
      ],
    );

    FlutterAndroidAuto.setRootTemplate(
      template: listTemplate,
    );
  }

  void _waitForAndroidAutoStations() {
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_androidAutoInitialized) {
        timer.cancel();
        return;
      }

      final stations = _audioHandler.filteredStations.value;
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

      _updateSortedAndroidAutoStations(stations);
      _rebuildAndroidAutoTemplate();

      // Listen for favorites changes to rebuild the template
      _androidAutoFavoritesSubscription = _audioHandler.favoriteStationSlugs.stream.listen((_) {
        _rebuildAndroidAutoTemplate();
      });

      // Listen for current station changes (playing indicator)
      _androidAutoStationSubscription = _audioHandler.currentStation.stream.listen((_) {
        _rebuildAndroidAutoTemplate();
      });

      // Listen for station list/metadata changes (song title, artist, new stations, etc.)
      _androidAutoStationsListSubscription = _audioHandler.stations.stream.listen((updatedStations) {
        _log("Android Auto: stations stream updated (${updatedStations.length} stations)");
        _updateSortedAndroidAutoStations(updatedStations);
        _rebuildAndroidAutoTemplate();
      });

      _androidAutoInitialized = true;
      _log("Android Auto setup complete");
    } catch (e) {
      _log("Error setting up Android Auto: $e");
    }
  }

  void _updateSortedAndroidAutoStations(List<Station> stations) {
    _sortedAndroidAutoStations = List<Station>.from(stations);
    _sortedAndroidAutoStations.sort(
      (a, b) => a.title.toString().compareTo(b.title.toString()),
    );
  }

  void _rebuildAndroidAutoTemplate() {
    final favoriteSlugs = _audioHandler.favoriteStationSlugs.value;
    final currentSlug = _audioHandler.currentStation.value?.slug;

    // Split stations into favorites and non-favorites
    final favoriteStations = _sortedAndroidAutoStations
        .where((s) => favoriteSlugs.contains(s.slug))
        .toList();
    final otherStations = _sortedAndroidAutoStations
        .where((s) => !favoriteSlugs.contains(s.slug))
        .toList();

    AAListItem buildItem(Station station, {required List<Station> playlist}) {
      final isFavorite = favoriteSlugs.contains(station.slug);
      final isPlaying = station.slug == currentSlug;

      // Build subtitle with song metadata
      String? subtitle;
      if (isPlaying && station.songTitle.isNotEmpty) {
        subtitle = station.songArtist.isNotEmpty
            ? "${station.songArtist} - ${station.songTitle}"
            : station.songTitle;
      }

      return AAListItem(
        title: isPlaying ? "▶ ${station.title}" : station.title,
        subtitle: subtitle,
        imageUrl: station.thumbnailUrl,
        onPress: (complete, item) {
          _log("Android Auto: Station selected: ${station.title}");
          _audioHandler.carPlayPlaylist = List.from(playlist);
          _audioHandler.selectStation(station);
          complete();
          _audioHandler.play();
        },
        actions: [
          AAListItemAction(
            title: isFavorite ? "Unfavorite" : "Favorite",
            iconName: isFavorite ? "ic_favorite" : "ic_favorite_border",
            onPress: () {
              _audioHandler.setStationIsFavorite(station, !isFavorite);
            },
          ),
        ],
      );
    }

    final List<AAListSection> sections = [];

    // Add favorites section first (For You)
    if (favoriteStations.isNotEmpty) {
      sections.add(AAListSection(
        title: "Favorite",
        items: favoriteStations
            .map((s) => buildItem(s, playlist: favoriteStations))
            .toList(),
      ));
    }

    // Add remaining (non-favorite) stations — no duplication
    sections.add(AAListSection(
      title: "Toate statiile",
      items: otherStations
          .map((s) => buildItem(s, playlist: _sortedAndroidAutoStations))
          .toList(),
    ));

    final listTemplate = AAListTemplate(
      title: "Radio Crestin",
      sections: sections,
    );

    FlutterAndroidAuto.setRootTemplate(template: listTemplate);
  }

  void dispose() {
    _log("Disposing CarPlay/Android Auto service");

    _currentStationSubscription?.cancel();
    _favoritesSubscription?.cancel();
    _androidAutoFavoritesSubscription?.cancel();
    _androidAutoStationSubscription?.cancel();
    _androidAutoStationsListSubscription?.cancel();

    if (Platform.isIOS) {
      _flutterCarplay?.removeListenerOnConnectionChange();
    } else if (Platform.isAndroid) {
      _flutterAndroidAuto?.removeListenerOnConnectionChange();
    }
  }
}
