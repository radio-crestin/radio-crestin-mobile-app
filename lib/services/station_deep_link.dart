import 'dart:async';

import 'package:rxdart/rxdart.dart';

import '../types/Station.dart';
import '../utils.dart';

/// Finds the station a deep link names, the way `HomePage` does on the
/// phone, for the desktop shell.
///
/// Handles `radiocrestin://<slug>` and the web links (share links, NFC
/// tags, radiocrestin.ro pages), which carry the slug as their first path
/// segment, with [Utils.stationSlugFromUri].
class StationDeepLinks {
  /// Creates a resolver over [stations], the full station list.
  StationDeepLinks({
    required ValueStream<List<Station>> stations,
    this.stationsTimeout = const Duration(seconds: 5),
    this.duplicateWindow = const Duration(seconds: 3),
    DateTime Function()? now,
  })  : _stations = stations,
        _now = now ?? DateTime.now;

  final ValueStream<List<Station>> _stations;
  final DateTime Function() _now;

  /// How long a link opened at launch waits for the station list.
  final Duration stationsTimeout;

  /// How close together two deliveries of one link count as one.
  ///
  /// app_links hands the link that launched the app both to
  /// `getInitialLink()` and to the first `uriLinkStream` listener. A later
  /// click on the same link falls outside the window and opens it again.
  final Duration duplicateWindow;

  String? _lastLink;
  DateTime? _lastLinkAt;

  /// The station slug [uri] names, or `''` when it names none (a link to
  /// the site or to the app itself).
  static String slugOf(Uri uri) => Utils.stationSlugFromUri(uri);

  /// Whether [uri] is the link handled moments ago; remembers it if not.
  bool isDuplicate(Uri uri) {
    final link = uri.toString();
    final now = _now();
    final lastAt = _lastLinkAt;
    if (link == _lastLink &&
        lastAt != null &&
        now.difference(lastAt) < duplicateWindow) {
      return true;
    }
    _lastLink = link;
    _lastLinkAt = now;
    return false;
  }

  /// The station list once it has loaded, or the empty list when it does
  /// not load within [stationsTimeout].
  Future<List<Station>> loadedStations() {
    final current = _stations.value;
    if (current.isNotEmpty) return Future.value(current);
    return _stations
        .firstWhere((stations) => stations.isNotEmpty)
        .timeout(stationsTimeout, onTimeout: () => _stations.value);
  }

  /// The station whose slug is [slug], once the list has loaded.
  ///
  /// Null for an empty [slug], a station that does not exist (any more),
  /// or a list that does not load within [stationsTimeout].
  Future<Station?> stationFor(String slug) async {
    if (slug.isEmpty) return null;
    final stations = await loadedStations();
    for (final station in stations) {
      if (station.slug == slug) return station;
    }
    return null;
  }
}
