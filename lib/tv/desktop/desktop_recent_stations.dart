import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../types/Station.dart';

/// The stations last listened to on the desktop, newest first, kept across
/// launches: the Dock menu offers them under "Ascultate recent", as music
/// apps offer what was played lately.
class DesktopRecentStations {
  DesktopRecentStations(this._prefs)
      : _slugs = List.unmodifiable(_prefs.getStringList(_key) ?? const []);

  static const String _key = 'desktop_recent_stations';

  /// How many stations are remembered.
  static const int capacity = 10;

  /// How many the Dock menu shows.
  static const int shown = 3;

  final SharedPreferences _prefs;
  List<String> _slugs;

  /// The remembered stations' slugs, newest first.
  List<String> get slugs => _slugs;

  /// Puts [slug] first, once; says whether the list changed.
  bool add(String slug) {
    if (_slugs.isNotEmpty && _slugs.first == slug) return false;
    _slugs = List.unmodifiable([
      slug,
      ..._slugs.where((s) => s != slug),
    ].take(capacity));
    unawaited(_prefs.setStringList(_key, _slugs));
    return true;
  }

  /// The stations to offer, newest first: at most [shown], none of them
  /// the one playing ([currentSlug]) and only ones still listed
  /// ([listed]).
  static List<Station> offered(
    List<String> slugs, {
    required Iterable<Station> listed,
    String? currentSlug,
  }) {
    final bySlug = {for (final station in listed) station.slug: station};
    return [
      for (final slug in slugs)
        if (slug != currentSlug)
          if (bySlug[slug] case final Station station) station,
    ].take(shown).toList();
  }
}
