import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../appAudioHandler.dart';
import '../seek_mode_manager.dart';
import '../types/Station.dart';
import '../utils.dart';
import 'analytics_service.dart';
import 'image_cache_service.dart';
import 'network_service.dart';
import 'play_count_service.dart';
import 'station_data_service.dart';

/// Keeps the iOS Home Screen widgets in step with the app, and carries out
/// their buttons.
///
/// The widgets show what the lock screen shows: the station playing and
/// the song heard, the listening delay included; else the last station
/// listened to. Also the favorites. Each change goes to
/// `HomeWidgetBridge.swift`, which saves it for the widget extension and
/// reloads the widgets; while audio plays those reloads cost iOS nothing.
class HomeWidgetService {
  HomeWidgetService({
    required AppAudioHandler audioHandler,
    required StationDataService stationDataService,
    required PlayCountService playCountService,
    required SharedPreferences prefs,
  })  : _audioHandler = audioHandler,
        _stationDataService = stationDataService,
        _playCountService = playCountService,
        _prefs = prefs;

  final AppAudioHandler _audioHandler;
  final StationDataService _stationDataService;
  final PlayCountService _playCountService;
  final SharedPreferences _prefs;

  static const _channel = MethodChannel('com.radiocrestin.home_widgets');

  /// How many stations the favorites widget shows.
  static const favoriteSlots = 4;

  /// Gathers the changes of one moment into one save: a station switch
  /// changes the station, the song and the play state.
  static const _saveDelay = Duration(milliseconds: 300);

  /// While playing, how often the app tells the widgets it still plays.
  /// They show it stopped after 12 minutes without word, should the app
  /// quit unseen (`WidgetSnapshot.playingExpiry`).
  static const _heartbeat = Duration(minutes: 5);

  /// How long a button waits for its effect before the widget redraws.
  static const _commandSettle = Duration(seconds: 3);

  /// How long a button that launched the app waits for the stations.
  static const _stationsWait = Duration(seconds: 15);

  /// Song covers asked of the image CDN at this width, sharp on the
  /// medium widget; the API's 250 px would be soft there.
  static const _coverWidth = 400;

  final List<StreamSubscription> _subscriptions = [];
  Timer? _saveTimer;
  Timer? _heartbeatTimer;
  String? _lastSent;
  bool _playbackCommanded = false;

  /// The widget buttons being carried out. Saves wait for their outcome:
  /// a station switch reports playing before it changes the station, and
  /// a save in between showed the previous station playing.
  int _commandsInFlight = 0;

  /// Whether a widget button played, paused or changed the station since
  /// launch. A button can launch the app, and the launch's autoplay of
  /// the last station must then keep out of its way.
  bool get playbackCommanded => _playbackCommanded;

  void start() {
    _channel.setMethodCallHandler(_onCall);
    _subscriptions.addAll([
      _audioHandler.currentStation.stream.listen((_) => _scheduleSave()),
      _audioHandler.mediaItem.listen((_) => _scheduleSave()),
      _audioHandler.playbackState
          .map((state) => state.playing)
          .distinct()
          .listen((playing) {
        _scheduleSave();
        _heartbeatTimer?.cancel();
        _heartbeatTimer = playing
            ? Timer.periodic(_heartbeat, (_) => _invoke('heartbeat'))
            : null;
      }),
      _stationDataService.stations.stream.listen((_) => _scheduleSave()),
      _stationDataService.favoriteStationSlugs.stream
          .listen((_) => _scheduleSave()),
      _stationDataService.hiddenStationSlugs.stream
          .listen((_) => _scheduleSave()),
      // The data-saving modes trade song covers for station logos.
      NetworkService.instance.isOnMobileData.stream
          .distinct()
          .listen((_) => _scheduleSave()),
    ]);
    SeekModeManager.unstableConnection.addListener(_scheduleSave);
    SeekModeManager.carConnected.addListener(_scheduleSave);
    unawaited(_invoke('ready'));
  }

  void dispose() {
    _saveTimer?.cancel();
    _heartbeatTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    SeekModeManager.unstableConnection.removeListener(_scheduleSave);
    SeekModeManager.carConnected.removeListener(_scheduleSave);
    _channel.setMethodCallHandler(null);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _save);
  }

  Future<void> _saveNow() {
    _saveTimer?.cancel();
    return _save();
  }

  Future<void> _save() async {
    if (_commandsInFlight > 0) return;
    // Before the catalog loads there's no station to show, and saving
    // that would blank widgets that still show the last one.
    if (_stationDataService.stations.value.isEmpty) return;
    final json = jsonEncode(_payload().toJson());
    if (json == _lastSent) return;
    _lastSent = json;
    if (!await _invoke('save', json)) _lastSent = null;
  }

  HomeWidgetPayload _payload() {
    final playing = _audioHandler.playbackState.value.playing;
    final station =
        _audioHandler.currentStation.valueOrNull ?? _lastPlayedStation();
    final visible = _stationDataService.visibleStations;
    final favorites = _stationDataService.favoritesIn(visible);
    final shown = HomeWidgetPayload.stationsShown(
      favorites: favorites,
      others: favorites.length >= favoriteSlots
          ? const []
          : _stationDataService.getSortedStations(applyGroupFilter: false),
      playCounts: _playCountService.playCounts,
      slots: favoriteSlots,
    );
    final wholeCatalog = _audioHandler.isCarConnected;
    return HomeWidgetPayload(
      isPlaying: playing,
      station: station == null ? null : _widgetStation(station),
      song: playing && station != null
          ? HomeWidgetPayload.songOf(station)
          : null,
      cover: playing && station != null ? _cover(station) : null,
      listeners: playing ? null : station?.totalListeners,
      previousSlug: station == null
          ? null
          : _stationDataService
              .getPreviousStation(station.slug, wholeCatalog: wholeCatalog)
              ?.slug,
      nextSlug: station == null
          ? null
          : _stationDataService
              .getNextStation(station.slug, wholeCatalog: wholeCatalog)
              ?.slug,
      favorites: shown.map(_widgetStation).toList(),
      favoriteCount: favorites.length.clamp(0, favoriteSlots),
    );
  }

  /// The station last listened to, unless it was hidden since.
  Station? _lastPlayedStation() {
    final slug = _prefs.getString(AppAudioHandler.LAST_PLAYED_MEDIA_ITEM);
    if (slug == null) return null;
    for (final station in _stationDataService.visibleStations) {
      if (station.slug == slug) return station;
    }
    return null;
  }

  HomeWidgetStation _widgetStation(Station station) => HomeWidgetStation(
        slug: station.slug,
        title: station.displayTitle,
        logo: HomeWidgetImage(
          url: Utils.getStationLogoUrl(station.rawStationData),
          path: station.cachedThumbnailPath,
        ),
      );

  /// The song's artwork, as the app shows it: none in the data-saving
  /// modes, where the station logo stands in.
  HomeWidgetImage? _cover(Station station) {
    final raw = station.rawStationData;
    final art = Utils.getStationThumbnailUrl(raw);
    if (art.isEmpty || art == Utils.getStationLogoUrl(raw)) return null;
    return HomeWidgetImage(
      url: Utils.withCdnWidth(art, _coverWidth),
      path: ImageCacheService.instance.getCachedPath(art),
    );
  }

  Future<bool> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
      return true;
    } catch (e) {
      debugPrint('HomeWidgetService: $method failed: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Buttons
  // ---------------------------------------------------------------------------

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'command') {
      throw MissingPluginException('No ${call.method} on the widgets');
    }
    final args = Map<String, dynamic>.from(call.arguments as Map);
    debugPrint('HomeWidgetService: button $args');
    // A Home Screen button: why playback started, paused or moved on.
    final slug = args['slug'];
    AnalyticsService.instance.log('widget button', {
      'action': args['action'],
      if (slug is String && slug.isNotEmpty) 'station_slug': slug,
    });
    _playbackCommanded = true;
    _commandsInFlight++;
    try {
      switch (args['action']) {
        case 'play':
          await _play(
            args['slug'] as String? ?? '',
            fromFavorites: args['fromFavorites'] == true,
          );
        case 'pause':
          await _audioHandler.pause();
        case 'next':
          await _skip(forward: true);
        case 'previous':
          await _skip(forward: false);
      }
    } catch (e) {
      debugPrint('HomeWidgetService: button failed: $e');
      AnalyticsService.instance.logWarning('widget button failed', {
        'action': args['action'],
        'error': '$e',
      });
    } finally {
      _commandsInFlight--;
    }
    // The widget redraws when this returns: with the button's outcome,
    // once the last button pressed has one.
    if (_commandsInFlight == 0) await _saveNow();
  }

  /// Plays the station of [slug], or the station shown when it's empty.
  Future<void> _play(String slug, {required bool fromFavorites}) async {
    final stations = await _loadedStations();
    final shown =
        _audioHandler.currentStation.valueOrNull ?? _lastPlayedStation();
    final station = slug.isEmpty
        ? shown ?? stations.firstOrNull
        : stations.where((s) => s.slug == slug).firstOrNull;
    if (station == null) {
      AnalyticsService.instance
          .logWarning('widget station not found', {'station_slug': slug});
      return;
    }
    // A favorite tile goes on through the favorites, another tile
    // through the whole list; resuming the station shown keeps where
    // next and previous go.
    final resumes = !fromFavorites && station.slug == shown?.slug;
    unawaited(_audioHandler.playStation(
      station,
      fromFavorites: resumes ? null : fromFavorites,
    ));
    await _settle((current, playing) =>
        playing && current?.slug == station.slug);
  }

  /// Plays the next or the previous station, from the last one listened
  /// to when the app has just started.
  Future<void> _skip({required bool forward}) async {
    final stations = await _loadedStations();
    if (_audioHandler.currentStation.valueOrNull == null) {
      final last = _lastPlayedStation() ?? stations.firstOrNull;
      if (last == null) return;
      await _audioHandler.selectStation(last);
    }
    final before = _audioHandler.currentStation.valueOrNull?.slug;
    unawaited(forward
        ? _audioHandler.skipToNext()
        : _audioHandler.skipToPrevious());
    await _settle((current, playing) =>
        playing && current?.slug != before);
  }

  /// The stations, once loaded: a button can launch the app.
  Future<List<Station>> _loadedStations() async {
    final stations = _stationDataService.stations;
    if (stations.value.isNotEmpty) return stations.value;
    try {
      return await stations.stream
          .firstWhere((list) => list.isNotEmpty)
          .timeout(_stationsWait);
    } on TimeoutException {
      return stations.value;
    }
  }

  /// Waits, briefly, until the station and the play state show a
  /// button's effect: [done] with both, since a switch reports playing
  /// before it changes the station.
  Future<void> _settle(
    bool Function(Station? current, bool playing) done,
  ) async {
    final settled = Rx.combineLatest2(
      _audioHandler.currentStation.stream,
      _audioHandler.playbackState,
      (Station? current, PlaybackState state) => done(current, state.playing),
    );
    try {
      await settled.firstWhere((isDone) => isDone).timeout(_commandSettle);
    } on TimeoutException {
      // Saved as it is: the next change saves again.
    }
  }
}

/// An image a widget shows: its URL, and the app's cached copy if any.
@immutable
class HomeWidgetImage {
  const HomeWidgetImage({required this.url, this.path});

  final String url;
  final String? path;

  Map<String, dynamic> toJson() => {'url': url, 'path': path};
}

@immutable
class HomeWidgetStation {
  const HomeWidgetStation({
    required this.slug,
    required this.title,
    required this.logo,
  });

  final String slug;
  final String title;
  final HomeWidgetImage logo;

  Map<String, dynamic> toJson() =>
      {'slug': slug, 'title': title, 'logo': logo.toJson()};
}

/// What the widgets show, as sent to `HomeWidgetBridge.swift`.
@immutable
class HomeWidgetPayload {
  const HomeWidgetPayload({
    required this.isPlaying,
    required this.station,
    required this.song,
    required this.cover,
    required this.listeners,
    required this.previousSlug,
    required this.nextSlug,
    required this.favorites,
    required this.favoriteCount,
  });

  /// Whether the listener wants audio playing, also while it connects.
  final bool isPlaying;

  /// The station playing, or else the last one listened to.
  final HomeWidgetStation? station;

  /// The song heard, while playing.
  final ({String title, String? artist})? song;
  final HomeWidgetImage? cover;

  /// How many listen to [station]; only sent while it isn't playing,
  /// where the widgets show it, so a new count doesn't reload them.
  final int? listeners;

  /// What previous and next play, for the links that stand in for the
  /// buttons before iOS 17.
  final String? previousSlug;
  final String? nextSlug;
  final List<HomeWidgetStation> favorites;

  /// How many of [favorites] are the listener's.
  final int favoriteCount;

  Map<String, dynamic> toJson() => {
        'isPlaying': isPlaying,
        'station': station?.toJson(),
        'song': switch (song) {
          final song? => {'title': song.title, 'artist': song.artist},
          null => null,
        },
        'cover': cover?.toJson(),
        'listeners': listeners,
        'previousSlug': previousSlug,
        'nextSlug': nextSlug,
        'favorites': [for (final station in favorites) station.toJson()],
        'favoriteCount': favoriteCount,
      };

  /// The song [station] plays, or null when it names none.
  static ({String title, String? artist})? songOf(Station station) {
    final title = station.songTitle.trim();
    if (title.isEmpty) return null;
    final artist = station.songArtist.trim();
    return (title: title, artist: artist.isEmpty ? null : artist);
  }

  /// The stations the favorites widget shows: the favorites in the
  /// listener's order, topped up to [slots] with the stations they play
  /// most, then with [others] in their order.
  static List<Station> stationsShown({
    required List<Station> favorites,
    required List<Station> others,
    required Map<String, int> playCounts,
    required int slots,
  }) {
    final shown = favorites.take(slots).toList();
    final taken = {for (final station in shown) station.slug};
    int playsOf(Station station) => playCounts[station.slug] ?? 0;
    final order = {
      for (final (index, station) in others.indexed) station.slug: index,
    };
    final mostPlayed = others
        .where((station) => playsOf(station) > 0)
        .toList()
      // Ties keep the list's order.
      ..sort((a, b) {
        final byPlays = playsOf(b).compareTo(playsOf(a));
        return byPlays != 0 ? byPlays : order[a.slug]!.compareTo(order[b.slug]!);
      });
    for (final station in [...mostPlayed, ...others]) {
      if (shown.length >= slots) break;
      if (taken.add(station.slug)) shown.add(station);
    }
    return shown;
  }
}
