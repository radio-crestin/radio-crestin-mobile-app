import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:radio_crestin/services/now_playing_sanitizer.dart';

/// Finds the station a spoken request names, as speech recognition writes
/// it down.
///
/// Siri doesn't speak Romanian, so a name comes back without diacritics,
/// with its letters spelled out ("R V E Constanta") or slightly off
/// ("Constanza"). Pure, so the rules can be unit tested.
abstract final class StationVoiceSearch {
  /// The lowest score that still names a station; below it a request
  /// matches nothing, rather than playing a station nobody asked for.
  /// Measured on the catalog: names said slightly off ("Bethel" for
  /// "Betel Alcala") score 67 and up, most requests for no station
  /// ("news", "Taylor Swift") 60 or less.
  static const minScore = 65;

  /// Words around a name that name no station: "radio" most names start
  /// with, and "station" said around it, in English or Romanian.
  static final _filler =
      RegExp(r'\b(?:radio|station|the|statia|statie|postul)\b');
  static final _rve = RegExp(r'^RVE\s+', caseSensitive: false);
  static final _spelledOut = RegExp(r'\b(?:[a-z] )+[a-z]\b');
  static final _spaces = RegExp(r'\s+');

  /// The index in [titles] of the station [spoken] names best, or null
  /// when none comes close.
  ///
  /// A name scores by how closely it holds the request and by the words
  /// they share, so the city of an "RVE" station counts more than the
  /// "RVE" every one of them shares. Equal scores go to the title closest
  /// to the request as a whole ("Filadelfia" picks "Radio Filadelfia" over
  /// "Radio Filadelfia Special"), then to the first one.
  static int? bestMatch(List<String> titles, String spoken) {
    final request = key(spoken);
    if (request.isEmpty) return null;
    int? best;
    var bestScore = -1;
    var bestCloseness = -1;
    for (var i = 0; i < titles.length; i++) {
      for (final name in spokenForms(titles[i]).map(key)) {
        final score =
            (weightedRatio(name, request) + tokenSetRatio(name, request)) ~/ 2;
        final closeness = ratio(name, request);
        if (score > bestScore ||
            (score == bestScore && closeness > bestCloseness)) {
          best = i;
          bestScore = score;
          bestCloseness = closeness;
        }
      }
    }
    return bestScore >= minScore ? best : null;
  }

  /// Whether [spoken] asks for the favorites rather than a station: "my
  /// favorites", or "favoritele" said the Romanian way.
  static bool asksForFavorites(String spoken) => const {
        'favorite',
        'favorites',
        'favourites',
        'my favorites',
        'my favourites',
        'favoritele',
        'favoritele mele',
      }.contains(key(spoken));

  /// [text] as compared: lowercase, without diacritics or punctuation,
  /// without words that name no station ("radio", "station"), and with
  /// spelled-out letters joined ("r v e" → "rve").
  static String key(String text) => NowPlayingSanitizer.normalize(text)
      .replaceAll(_filler, ' ')
      .replaceAllMapped(_spelledOut, (m) => m[0]!.replaceAll(' ', ''))
      .replaceAll(_spaces, ' ')
      .trim();

  /// The ways a listener may say [title]: as written and, for the
  /// "RVE" stations, with the network's name, Radio Vocea Evangheliei.
  static List<String> spokenForms(String title) => [
        title,
        if (_rve.hasMatch(title))
          title.replaceFirst(_rve, 'Radio Vocea Evangheliei '),
      ];
}
