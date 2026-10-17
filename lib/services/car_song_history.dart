import 'dart:async';

import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/types/Station.dart';

/// The song history behind the car's "Redate recent" list (Up Next on
/// CarPlay's Now Playing).
///
/// While a car is connected, the playing station's history and the
/// pictures of its rows load each time the station or its song changes, so
/// the list opens at once and complete. A list on screen follows the
/// station and its songs, in one update each.
class CarSongHistory {
  CarSongHistory({
    required this.playingStation,
    required this.fetchSongs,
    required this.loadPictures,
    required this.isShown,
    required this.showSongs,
  });

  /// The station playing now, if any.
  final Station? Function() playingStation;

  /// The songs of [Station]'s recent history, or null when the request
  /// failed.
  final Future<List<SongHistoryItem>?> Function(Station station) fetchSongs;

  /// Loads the pictures of the rows for these songs ahead of the list.
  final Future<void> Function(Station station, List<SongHistoryItem> songs)
      loadPictures;

  /// Whether the list with this template id is still on screen.
  final bool Function(String templateId) isShown;

  /// Puts these songs of [Station] on the list with this template id.
  final Future<void> Function(
    String templateId,
    Station station,
    List<SongHistoryItem> songs,
  ) showSongs;

  _SongHistoryLoad? _load;
  String? _followedKey;
  _ShownSongHistory? _shown;

  /// What a history is loaded for: the station and its audible song, since
  /// each new song joins the list.
  static String keyOf(Station station) => '${station.slug}|${station.songId}';

  /// On a new station or song: loads its history ahead while [carConnected],
  /// and moves the list on screen to it.
  void follow(Station station, {required bool carConnected}) {
    final key = keyOf(station);
    if (key == _followedKey) return;
    _followedKey = key;
    if (carConnected) unawaited(load(station));
    unawaited(_syncShown());
  }

  /// Forgets the history and the list, as a car connects or goes away: the
  /// next drive loads afresh.
  void reset() {
    _load = null;
    _followedKey = null;
    _shown = null;
  }

  /// The songs of [station]'s history with the pictures of their rows
  /// loaded, from the load made or under way for this station and song.
  /// Null when they could not be loaded; the next call tries again.
  Future<List<SongHistoryItem>?> load(Station station) {
    final key = keyOf(station);
    final current = _load;
    if (current != null && current.key == key) return current.songs;
    final songs = Completer<List<SongHistoryItem>?>();
    final load = _SongHistoryLoad(key, songs.future);
    _load = load;
    songs.complete(_fetch(station, load));
    return load.songs;
  }

  Future<List<SongHistoryItem>?> _fetch(
    Station station,
    _SongHistoryLoad load,
  ) async {
    List<SongHistoryItem>? songs;
    try {
      songs = await fetchSongs(station);
    } catch (_) {
      songs = null;
    }
    final isLatest = identical(_load, load);
    if (songs == null) {
      if (isLatest) _load = null;
      return null;
    }
    // Pictures only for the station and song still playing: next/previous
    // pressed in a row would load every station's in passing.
    if (isLatest) {
      try {
        await loadPictures(station, songs);
      } catch (_) {
        // The rows load their own pictures then.
      }
    }
    return songs;
  }

  /// The list [templateId] on screen shows [station]'s history; from now on
  /// it follows the playing station and its songs.
  Future<void> showing(String templateId, Station station) {
    _shown = _ShownSongHistory(
      templateId,
      key: keyOf(station),
      slug: station.slug as String,
    );
    // The station or its song may have changed while the list loaded.
    return _syncShown();
  }

  /// Moves the list on screen, if any, to the playing station and its
  /// latest song once their history loaded.
  Future<void> _syncShown() async {
    final station = playingStation();
    final shown = _shown;
    if (station == null || shown == null) return;
    final key = keyOf(station);
    if (shown.key == key) return;

    final songs = await load(station);
    final latest = _shown;
    if (latest == null || latest.key == key) return;
    if (!isShown(latest.templateId)) {
      _shown = null;
      return;
    }
    // A newer station or song took over while this one loaded.
    final playing = playingStation();
    if (playing == null || keyOf(playing) != key) return;
    // A failed refresh keeps the songs of the same station on screen.
    if (songs == null && latest.slug == station.slug) return;

    _shown = _ShownSongHistory(
      latest.templateId,
      key: key,
      slug: station.slug as String,
    );
    await showSongs(latest.templateId, station, songs ?? const []);
  }
}

/// A history load for the station and song in [key]; [songs] completes
/// with null when it failed.
class _SongHistoryLoad {
  _SongHistoryLoad(this.key, this.songs);

  final String key;
  final Future<List<SongHistoryItem>?> songs;
}

/// The list on screen, and the station ([slug]) and song ([key]) it shows.
class _ShownSongHistory {
  _ShownSongHistory(this.templateId, {required this.key, required this.slug});

  final String templateId;
  final String key;
  final String slug;
}
