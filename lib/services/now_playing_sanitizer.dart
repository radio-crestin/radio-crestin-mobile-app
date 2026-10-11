/// What to hide of a station's now-playing before it is displayed.
enum NowPlayingVerdict {
  /// Show it as is (almost every station).
  keep,

  /// Hide the song: the UI shows the station only.
  hideSong,

  /// Keep the song title, drop an artist that only repeats the station name.
  dropArtist,
}

/// Hides now-playing values that do not describe what is on air.
///
/// Runs only on the published (display) list, never on the raw rows the
/// metadata pipeline reads, so a hidden song keeps its timing for alignment
/// and can never be fed back into a later merge.
abstract final class NowPlayingSanitizer {
  /// A row older than this is a dead scraper's leftover or a placeholder, not
  /// a song. Measured on all stations: legitimately static titles were 15 h
  /// and 6.5 d old; dead rows and garbage 25-181 d.
  static const staleAfter = Duration(days: 14);

  static final _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static const _diacritics = {
    'ă': 'a',
    'â': 'a',
    'î': 'i',
    'ș': 's',
    'ş': 's',
    'ț': 't',
    'ţ': 't',
  };

  /// Cheap check on typed fields; `keep` for almost every station, so the
  /// caller rebuilds a station only when something must be hidden.
  ///
  /// A stale row, or a song title that only repeats the station name, hides
  /// the song; that wins over an artist that only repeats it.
  static NowPlayingVerdict verdict({
    required String? stationTitle,
    required DateTime? startedAt,
    required String? songName,
    required String? artistName,
    required DateTime now,
  }) {
    if (songName == null) return NowPlayingVerdict.keep;
    if (startedAt != null && now.difference(startedAt) > staleAfter) {
      return NowPlayingVerdict.hideSong;
    }
    final station = normalize(stationTitle ?? '');
    if (station.isEmpty) return NowPlayingVerdict.keep;
    if (normalize(songName) == station) return NowPlayingVerdict.hideSong;
    if (artistName != null && normalize(artistName) == station) {
      return NowPlayingVerdict.dropArtist;
    }
    return NowPlayingVerdict.keep;
  }

  /// [stationJson] (GraphQL station shape) with `now_playing.song` removed
  /// ([NowPlayingVerdict.hideSong]) or `song.artist` removed
  /// ([NowPlayingVerdict.dropArtist]). The `now_playing.timestamp` and the
  /// listener count are kept.
  static Map<String, dynamic> apply(
    Map<String, dynamic> stationJson,
    NowPlayingVerdict verdict,
  ) {
    final nowPlaying = stationJson['now_playing'];
    if (verdict == NowPlayingVerdict.keep ||
        nowPlaying is! Map<String, dynamic>) {
      return stationJson;
    }
    final song = nowPlaying['song'];
    final shown =
        verdict == NowPlayingVerdict.dropArtist && song is Map<String, dynamic>
            ? {...song, 'artist': null}
            : null;
    return {
      ...stationJson,
      'now_playing': {...nowPlaying, 'song': shown},
    };
  }

  /// Lowercase, Romanian diacritics folded, every run of non-alphanumeric
  /// characters collapsed to one space, trimmed. Two values echo each other
  /// only when equal after this; containing the station name is not enough.
  static String normalize(String text) {
    final lower = text.toLowerCase();
    final folded = StringBuffer();
    for (final char in lower.split('')) {
      folded.write(_diacritics[char] ?? char);
    }
    return folded.toString().replaceAll(_separators, ' ').trim();
  }
}
