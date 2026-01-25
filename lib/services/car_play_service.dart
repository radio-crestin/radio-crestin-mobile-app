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

  // Method channel for Now Playing buttons (iOS CarPlay)
  static const _nowPlayingChannel = MethodChannel('com.radiocrestin.nowplaying_buttons');

  // Subscriptions for current station and favorites changes
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

  void _setupNowPlayingButtonsHandler() {
    // Listen for favorite button presses from native iOS
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

    // Sync favorite button state and list playing indicator when station changes
    _currentStationSubscription = _audioHandler.currentStation.stream.listen((station) {
      if (station != null) {
        _updateNowPlayingFavoriteState(station.isFavorite);
        _updateCarPlayListPlayingState(station.slug);
      }
    });

    _favoritesSubscription = _audioHandler.favoriteStationSlugs.stream.listen((_) {
      final currentStation = _audioHandler.currentStation.value;
      if (currentStation != null) {
        final isFavorite = _audioHandler.favoriteStationSlugs.value.contains(currentStation.slug);
        _updateNowPlayingFavoriteState(isFavorite);
      }
      // Update CarPlay favorites list (reuses existing CPListItem objects)
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
    // Update playing state in both tabs
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
        .map((station) => _favoriteListItems[station.slug]!)
        .toList();

    _log("Updating CarPlay favorites: ${favoriteItems.length} stations");

    _flutterCarplay!.updateListTemplateSections(
      elementId: _favoriteTemplate!.uniqueId,
      sections: [CPListSection(items: favoriteItems)],
    );
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
  }

  void _waitForStations() {
    // Use a simple polling approach instead of stream subscription
    // to avoid the immediate-fire issue with BehaviorSubject
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_carPlayInitialized) {
        timer.cancel();
        return;
      }

      // Use filteredStations which is properly sorted by order (same as app)
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
      final subtitle = station.displaySubtitle.isNotEmpty ? station.displaySubtitle : 'Radio';
      final item = CPListItem(
        text: station.title,
        detailText: subtitle,
        image: station.thumbnailUrl,
        isPlaying: station.slug == currentSlug,
        onPress: (complete, item) {
          _log("CarPlay: Favorite station selected: ${station.title}");
          // Get current favorites for playlist
          final currentFavorites = _sortedStations
              .where((s) => _audioHandler.favoriteStationSlugs.value.contains(s.slug))
              .toList();
          _audioHandler.carPlayPlaylist = List.from(currentFavorites);
          _audioHandler.playStation(station);
          complete();
          FlutterCarplay.showSharedNowPlaying(animated: true);
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
      final subtitle = station.displaySubtitle.isNotEmpty ? station.displaySubtitle : 'Radio';
      final item = CPListItem(
        text: isFavorite ? "★ ${station.title}" : station.title,
        detailText: subtitle,
        image: station.thumbnailUrl,
        isPlaying: station.slug == currentSlug,
        onPress: (complete, item) {
          _log("CarPlay: Station selected: ${station.title}");
          _audioHandler.carPlayPlaylist = List.from(_sortedStations);
          _audioHandler.playStation(station);
          complete();
          FlutterCarplay.showSharedNowPlaying(animated: true);
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

    // Create tab bar with both tabs (All Stations first, then Favorites)
    final tabBarTemplate = CPTabBarTemplate(
      templates: [allStationsTemplate, _favoriteTemplate!],
    );

    FlutterCarplay.setRootTemplate(
      rootTemplate: tabBarTemplate,
      animated: true,
    );

    // Mark as initialized - this template will NEVER be replaced
    _carPlayInitialized = true;
    _log("CarPlay setup complete - template locked");
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

      // Use filteredStations which is properly sorted by order (same as app)
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

    _log("Setting up Android Auto with ${stations.length} stations");

    final favoriteSlugs = _audioHandler.favoriteStationSlugs.value;

    // Sort stations alphabetically by title
    final sortedStations = List<Station>.from(stations);
    sortedStations.sort((a, b) => a.title.toString().compareTo(b.title.toString()));

    final items = sortedStations.map((station) {
      final isFavorite = favoriteSlugs.contains(station.slug);
      return AAListItem(
        title: isFavorite ? "★ ${station.title}" : station.title,
        subtitle: station.displaySubtitle,
        imageUrl: station.thumbnailUrl,
        onPress: (complete, item) {
          _log("Android Auto: Station selected: ${station.title}");
          _audioHandler.playStation(station);
          complete();
        },
      );
    }).toList();

    final listTemplate = AAListTemplate(
      title: "Radio Crestin",
      sections: [
        AAListSection(
          title: "Statii Radio",
          items: items,
        ),
      ],
    );

    FlutterAndroidAuto.setRootTemplate(
      template: listTemplate,
    );

    _androidAutoInitialized = true;
    _log("Android Auto setup complete - template locked");
  }

  void dispose() {
    _log("Disposing CarPlay/Android Auto service");

    _currentStationSubscription?.cancel();
    _favoritesSubscription?.cancel();

    if (Platform.isIOS) {
      _flutterCarplay?.removeListenerOnConnectionChange();
    } else if (Platform.isAndroid) {
      _flutterAndroidAuto?.removeListenerOnConnectionChange();
    }
  }
}
