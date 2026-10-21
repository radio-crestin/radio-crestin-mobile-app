import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../appAudioHandler.dart';
import '../types/Station.dart';
import 'analytics_service.dart';
import 'station_data_service.dart';
import 'station_voice_search.dart';

/// Plays the station a listener asks Siri for on iOS: "Hey Siri, play RVE
/// Constanța on Radio Creștin", also from the car's voice button.
///
/// Siri has no Romanian, so a listener gives the command in Siri's
/// language and the name the Romanian way. Siri learns the station names
/// (`vocabulary`); `SiriMediaHandler.swift` then asks which station a
/// request names (`find`) and to play it (`play`). A request can launch
/// the app in the background, so it waits until this says it is `ready`.
class SiriMediaService {
  SiriMediaService({
    required AppAudioHandler audioHandler,
    required StationDataService stationDataService,
  })  : _audioHandler = audioHandler,
        _stationDataService = stationDataService;

  final AppAudioHandler _audioHandler;
  final StationDataService _stationDataService;

  static const _channel = MethodChannel('com.radiocrestin.siri');

  /// How long a request that launched the app waits for the stations;
  /// Siri gives up on an answer after about 10 seconds.
  static const _stationsWait = Duration(seconds: 7);

  /// Gathers the catalog, favorites and hidden stations changing together
  /// into one update of the names Siri knows.
  static const _vocabularyDelay = Duration(seconds: 2);

  /// Marks a station found for "my favorites": it plays with next and
  /// previous going through the favorites.
  static const _favoritesPrefix = 'favorites/';

  final List<StreamSubscription> _subscriptions = [];
  Timer? _vocabularyTimer;
  List<Map<String, String>> _sentVocabulary = const [];

  void start() {
    _channel.setMethodCallHandler(_onCall);
    _subscriptions.addAll([
      _stationDataService.stations.stream.listen((_) => _scheduleVocabulary()),
      _stationDataService.favoriteStationSlugs.stream
          .listen((_) => _scheduleVocabulary()),
      _stationDataService.hiddenStationSlugs.stream
          .listen((_) => _scheduleVocabulary()),
    ]);
    unawaited(_invoke('ready'));
  }

  void dispose() {
    _vocabularyTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _channel.setMethodCallHandler(null);
  }

  Future<Object?> _onCall(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    switch (call.method) {
      case 'find':
        return _find(
          args['query'] as String? ?? '',
          id: args['id'] as String? ?? '',
        );
      case 'play':
        return _play(args['id'] as String? ?? '');
      default:
        throw MissingPluginException('No ${call.method} for Siri');
    }
  }

  // ---------------------------------------------------------------------------
  // Requests
  // ---------------------------------------------------------------------------

  /// The station a request names, as its id and title: the one Siri
  /// recognized by [id] among the names it learned, else the one [query]
  /// names. "My favorites" is the first favorite; no name at all, the
  /// station playing or paused, else the last one played. Null when no
  /// station comes close.
  Future<Map<String, String>?> _find(String query, {required String id}) async {
    final stations = await _loadedStations();
    final known = stations.where((s) => s.slug == id).firstOrNull;
    final favorites =
        known == null && StationVoiceSearch.asksForFavorites(query);
    final station = known ??
        (favorites
            ? _stationDataService.favoritesIn(stations).firstOrNull
            : query.trim().isEmpty
                ? _audioHandler.currentStation.valueOrNull ??
                    await _audioHandler.getLastPlayedStation()
                : _named(stations, query));
    debugPrint('SiriMediaService: "$query" ($id) -> ${station?.slug}');
    // Without the words said: a request may hold more than a name.
    AnalyticsService.instance.log('siri request', {
      'named': query.trim().isNotEmpty,
      'recognized': known != null,
      'favorites': favorites,
      'found': station != null,
      if (station != null) 'station_slug': station.slug,
    });
    if (station == null) return null;
    return {
      'id': favorites ? '$_favoritesPrefix${station.slug}' : station.slug,
      'title': station.title as String,
    };
  }

  Station? _named(List<Station> stations, String query) {
    final titles = [for (final s in stations) s.title as String];
    final index = StationVoiceSearch.bestMatch(titles, query);
    return index == null ? null : stations[index];
  }

  /// Plays the station [_find] gave as [id]; resumes it when it is the
  /// one paused, keeping where next and previous go. Returns whether it
  /// was found.
  Future<bool> _play(String id) async {
    final favorites = id.startsWith(_favoritesPrefix);
    final slug = favorites ? id.substring(_favoritesPrefix.length) : id;
    final stations = await _loadedStations();
    final station = stations.where((s) => s.slug == slug).firstOrNull;
    if (station == null) return false;
    final current = _audioHandler.currentStation.valueOrNull;
    if (current?.slug == slug) {
      if (!_audioHandler.playbackState.value.playing) {
        unawaited(_audioHandler.play());
      }
    } else {
      // A name was searched in the whole catalog, so next and previous go
      // through all of it; "my favorites" through the favorites.
      unawaited(_audioHandler.playStation(station, fromFavorites: favorites));
    }
    return true;
  }

  /// The stations as CarPlay lists them, once loaded: a request can
  /// launch the app.
  Future<List<Station>> _loadedStations() async {
    final stations = _stationDataService.stations;
    if (stations.value.isEmpty) {
      try {
        await stations.stream
            .firstWhere((list) => list.isNotEmpty)
            .timeout(_stationsWait);
      } on TimeoutException {
        // Answered with what there is: nothing found.
      }
    }
    return _stationDataService.getSortedStations(applyGroupFilter: false);
  }

  // ---------------------------------------------------------------------------
  // Names Siri learns
  // ---------------------------------------------------------------------------

  void _scheduleVocabulary() {
    _vocabularyTimer?.cancel();
    _vocabularyTimer = Timer(_vocabularyDelay, _sendVocabulary);
  }

  /// Teaches Siri the station names when they changed; `stations` emits
  /// on every poll.
  Future<void> _sendVocabulary() async {
    final vocabulary = siriVocabulary(
      _stationDataService.getSortedStations(applyGroupFilter: false),
      favoriteSlugs: _stationDataService.favoriteStationSlugs.value,
    );
    if (vocabulary.isEmpty || _sameVocabulary(vocabulary)) return;
    if (await _invoke('vocabulary', vocabulary)) _sentVocabulary = vocabulary;
  }

  bool _sameVocabulary(List<Map<String, String>> vocabulary) => listEquals(
        [for (final name in _sentVocabulary) '${name['id']}|${name['phrase']}'],
        [for (final name in vocabulary) '${name['id']}|${name['phrase']}'],
      );

  Future<bool> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
      return true;
    } catch (e) {
      debugPrint('SiriMediaService: $method failed: $e');
      return false;
    }
  }
}

/// The station names Siri learns, as each is said ([StationVoiceSearch.
/// spokenForms]) with its station's slug: the favorites first, in the
/// listener's order, since Siri may not keep them all, then the rest of
/// [stations].
@visibleForTesting
List<Map<String, String>> siriVocabulary(
  List<Station> stations, {
  required List<String> favoriteSlugs,
}) {
  final bySlug = {for (final s in stations) s.slug as String: s};
  final ordered = {
    for (final slug in favoriteSlugs)
      if (bySlug[slug] case final station?) station,
    ...stations,
  };
  return [
    for (final station in ordered)
      for (final phrase in StationVoiceSearch.spokenForms(station.title))
        {'id': station.slug as String, 'phrase': phrase},
  ];
}
