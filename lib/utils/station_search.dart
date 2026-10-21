import 'dart:ui' show TextRange;

import '../types/Station.dart';

/// The parts of [title] that match [query] in Home's station search, for
/// the list to show them in bold; null when [title] doesn't match.
///
/// Every word typed must start a word of the title, so "cluj" finds
/// "RVE Cluj" and "aripi popular" finds "Aripi Spre Cer Popular"; a word
/// of three letters or more may also sit inside one, so "delf" finds
/// "Radio Filadelfia". Shorter ones only start words: "el" would
/// otherwise find half the list. Case, diacritics and punctuation don't
/// count. An empty [query] matches every title, with nothing in bold.
List<TextRange>? stationTitleMatch(String title, String query) =>
    _match(title, query, insideWords: true);

/// The parts of [line], a song as a station's row shows it ("Title -
/// Artist"), that match [query] in Home's search; null when it doesn't.
///
/// As [stationTitleMatch], but every word typed must start a word of the
/// line: songs are long and full of common words, so "ist" would find
/// every "Hristos". A query of fewer than [_minSongQueryLetters] letters
/// matches no song: one or two start a word of nearly every one.
List<TextRange>? songLineMatch(String line, String query) =>
    _Folded(query).letters < _minSongQueryLetters
        ? null
        : _match(line, query, insideWords: false);

/// What Home's search finds for [query] among [stations], each in their
/// order: the stations whose names match it, then the ones whose song on
/// the row does.
///
/// Every word typed must match the same one, the name or the song: "cluj"
/// and a singer's name don't find a Cluj station only because the singer
/// is on there.
({List<Station> byName, List<Station> bySong}) searchStations(
  Iterable<Station> stations,
  String query,
) {
  final byName = <Station>[];
  final bySong = <Station>[];
  for (final station in stations) {
    if (stationTitleMatch(station.displayTitle, query) != null) {
      byName.add(station);
    } else if (songLineMatch(_songOnRow(station), query) != null) {
      bySong.add(station);
    }
  }
  return (byName: byName, bySong: bySong);
}

/// The song a station's row shows, which the search looks in: none on a
/// station that may be down, whose row says so instead, nor on a playlist.
String _songOnRow(Station station) =>
    station.isDown || station.isPlaylist ? '' : station.songLine;

/// Home's search results as the songs on the stations change under them,
/// for the rows to come and go one by one.
///
/// While the query stays the same, a station whose song stops matching
/// stays listed, in its place, until its rows have played out
/// ([SearchResultsUpdate.leaving]); one whose new song matches is new
/// ([SearchResultsUpdate.arriving]). A new query lists its results at once.
class LiveSearchResults {
  String _query = '';
  List<Station> _shown = const [];
  final Set<String> _leaving = {};

  /// The stations on their way out of the results.
  Set<String> get leaving => Set.unmodifiable(_leaving);

  /// The results to list for [query], given what the search finds now:
  /// [found], in order, among [listed], the slugs of the stations on show.
  ///
  /// A station that went from the list, hidden or gone from the catalog,
  /// isn't kept: it played its rows out already, or has none to play.
  SearchResultsUpdate update(
    String query,
    List<Station> found,
    Set<String> listed,
  ) {
    if (query != _query) {
      _query = query;
      _leaving.clear();
      _shown = found;
      return SearchResultsUpdate(found);
    }
    final foundSlugs = <String>{for (final station in found) station.slug};
    final shownSlugs = <String>{
      for (final station in _shown) station.slug,
    };
    _leaving.removeWhere((slug) => !listed.contains(slug));
    final newlyLeaving = <String>[];
    for (final station in _shown) {
      final String slug = station.slug;
      if (foundSlugs.contains(slug) || !listed.contains(slug)) continue;
      if (_leaving.add(slug)) newlyLeaving.add(slug);
    }
    final arriving = <String>[
      for (final station in found)
        if (!shownSlugs.contains(station.slug)) station.slug,
    ];
    _shown = _withLeaving(found);
    return SearchResultsUpdate(
      _shown,
      leaving: newlyLeaving,
      arriving: arriving,
    );
  }

  /// [found], with the stations on their way out in the places they had.
  List<Station> _withLeaving(List<Station> found) {
    final foundSlugs = <String>{for (final station in found) station.slug};
    final shown = [...found];
    for (final (index, station) in _shown.indexed) {
      if (_leaving.contains(station.slug) &&
          !foundSlugs.contains(station.slug)) {
        shown.insert(index.clamp(0, shown.length), station);
      }
    }
    return shown;
  }

  /// Forgets the results: the next query lists its own at once, even the
  /// same one again.
  void clear() {
    _query = '';
    _shown = const [];
    _leaving.clear();
  }

  /// The rows of [slug] have played out: it leaves the results. True if it
  /// was on its way out of them.
  bool left(String slug) {
    if (!_leaving.remove(slug)) return false;
    _shown = [
      for (final station in _shown)
        if (station.slug != slug) station,
    ];
    return true;
  }
}

/// What [LiveSearchResults.update] lists, and which stations' rows start
/// to come and go.
class SearchResultsUpdate {
  const SearchResultsUpdate(
    this.shown, {
    this.leaving = const [],
    this.arriving = const [],
  });

  /// The results to list, the ones on their way out among them.
  final List<Station> shown;

  /// The stations whose rows start to play out, no longer matching.
  final List<String> leaving;

  /// The stations new to the results, whose rows grow in.
  final List<String> arriving;
}

/// A typed word this long may match inside a word of a station's name.
const _minLengthInsideWord = 3;

/// A query with fewer letters than this finds stations by name only.
const _minSongQueryLetters = 3;

/// Anything but a letter or a digit, once folded.
final _separators = RegExp(r'[^a-z0-9]+');

final _alphanumeric = RegExp(r'[a-z0-9]');

/// Accents written as marks of their own after the letter ("s" and a
/// cedilla for "ş"), as some songs' tags have them.
final _combiningMark = RegExp('[̀-ͯ]');

/// Letters folded to the plain one people type on a phone keyboard: the
/// Romanian ones, cedilla and comma below alike, and the accents of the
/// few foreign names in the catalog.
const _plainLetters = {
  'ă': 'a', 'â': 'a', 'à': 'a', 'á': 'a', 'ä': 'a',
  'î': 'i', 'ì': 'i', 'í': 'i', 'ï': 'i',
  'ș': 's', 'ş': 's',
  'ț': 't', 'ţ': 't',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ç': 'c', 'ñ': 'n',
};

/// Text as the search compares it: in lowercase, with [_plainLetters]
/// folded and [_combiningMark]s left out, along with where each of its
/// characters comes from, for a match's place in the text.
class _Folded {
  factory _Folded(String text) {
    final folded = StringBuffer();
    final origins = <int>[];
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (_combiningMark.hasMatch(char)) continue;
      final lower = char.toLowerCase();
      folded.write(lower.length == 1 ? _plainLetters[lower] ?? lower : char);
      origins.add(i);
    }
    origins.add(text.length);
    return _Folded._(folded.toString(), origins);
  }

  const _Folded._(this.text, this._origins);

  final String text;

  /// Where each character of [text] is in the text it was folded from,
  /// and that text's length after them.
  final List<int> _origins;

  /// How many letters and digits [text] has.
  int get letters => text.replaceAll(_separators, '').length;

  /// The part of the original text that [start] to [end] of [text] come
  /// from, the marks on its last letter included.
  TextRange originalRange(int start, int end) =>
      TextRange(start: _origins[start], end: _origins[end]);
}

/// The parts of [text] that match [query]; see [stationTitleMatch].
/// [insideWords]: whether a long enough word typed may match inside a
/// word of [text], not only at its start.
List<TextRange>? _match(
  String text,
  String query, {
  required bool insideWords,
}) {
  final folded = _Folded(text);
  final ranges = <TextRange>[];
  for (final word in _Folded(query).text.split(_separators)) {
    if (word.isEmpty) continue;
    final start = _wordStart(folded.text, word) ??
        (insideWords && word.length >= _minLengthInsideWord
            ? _indexOf(folded.text, word)
            : null);
    if (start == null) return null;
    ranges.add(folded.originalRange(start, start + word.length));
  }
  return _merged(ranges);
}

/// Where [word] starts a word of [text], or null.
int? _wordStart(String text, String word) {
  for (var i = text.indexOf(word); i >= 0; i = text.indexOf(word, i + 1)) {
    if (i == 0 || !_alphanumeric.hasMatch(text[i - 1])) return i;
  }
  return null;
}

int? _indexOf(String text, String word) {
  final index = text.indexOf(word);
  return index < 0 ? null : index;
}

/// [ranges] in order, the ones that overlap or touch made one.
List<TextRange> _merged(List<TextRange> ranges) {
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final merged = <TextRange>[];
  for (final range in ranges) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null && range.start <= last.end) {
      merged.last = TextRange(
        start: last.start,
        end: range.end > last.end ? range.end : last.end,
      );
    } else {
      merged.add(range);
    }
  }
  return merged;
}
