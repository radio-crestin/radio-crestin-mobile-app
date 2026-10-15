/// What to change of a station's now-playing before it is displayed.
enum NowPlayingVerdict {
  /// Show it as is (almost every station).
  keep,

  /// Show it with the song title and artist starting with a capital letter
  /// ([NowPlayingSanitizer.capitalized]).
  capitalize,

  /// Hide the song: the UI shows the station only.
  hideSong,

  /// Keep the song title, drop an artist that only repeats the station name.
  dropArtist,
}

/// Hides now-playing values that do not describe what is on air, and starts
/// the song title and artist it shows with a capital letter.
///
/// Runs only on the published (display) list, never on the raw rows the
/// metadata pipeline reads, so a hidden song keeps its timing for alignment
/// and can never be fed back into a later merge.
abstract final class NowPlayingSanitizer {
  /// A row older than this is a dead scraper's leftover or a placeholder, not
  /// a song. Measured on all stations: legitimately static titles were 15 h
  /// and 6.5 d old; dead rows and garbage 25-181 d.
  static const staleAfter = Duration(days: 14);

  /// A song title that only says the station is on air (normalized). Radio
  /// Micul Samaritean sends "LIVE" as its song all the time; the app labels
  /// a station without a song "Live" itself, with nothing to search for.
  static const _onAirPlaceholder = 'live';

  static final _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static final _alphanumeric = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _letters = RegExp(r'\p{L}+', unicode: true);
  static final _webAddress =
      RegExp(r'^(www\.|https?://)', caseSensitive: false);
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
  /// A stale row, a song title that only says "live", or one that only
  /// repeats the station name, hides the song; that wins over an artist
  /// that only repeats it. A song kept as is but starting with a lowercase
  /// letter is capitalized.
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
    final song = normalize(songName);
    if (song == _onAirPlaceholder) return NowPlayingVerdict.hideSong;
    final station = normalize(stationTitle ?? '');
    if (station.isNotEmpty) {
      if (song == station) return NowPlayingVerdict.hideSong;
      if (artistName != null && normalize(artistName) == station) {
        return NowPlayingVerdict.dropArtist;
      }
    }
    final lowercase = capitalized(songName) != songName ||
        (artistName != null && capitalized(artistName) != artistName);
    return lowercase ? NowPlayingVerdict.capitalize : NowPlayingVerdict.keep;
  }

  /// [stationJson] (GraphQL station shape) with `now_playing.song` removed
  /// ([NowPlayingVerdict.hideSong]) or `song.artist` removed
  /// ([NowPlayingVerdict.dropArtist]), and the song title and artist left
  /// [capitalized]. The `now_playing.timestamp` and the listener count are
  /// kept.
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
    final shown = verdict != NowPlayingVerdict.hideSong &&
            song is Map<String, dynamic>
        ? _shownSong(song,
            dropArtist: verdict == NowPlayingVerdict.dropArtist)
        : null;
    return {
      ...stationJson,
      'now_playing': {...nowPlaying, 'song': shown},
    };
  }

  /// [song] with its title and artist [capitalized], or without the artist.
  static Map<String, dynamic> _shownSong(
    Map<String, dynamic> song, {
    required bool dropArtist,
  }) {
    final name = song['name'];
    final artist = song['artist'];
    return {
      ...song,
      if (name is String) 'name': capitalized(name),
      'artist': switch (artist) {
        _ when dropArtist => null,
        final Map<String, dynamic> shown &&
            {'name': final String artistName} =>
          {...shown, 'name': capitalized(artistName)},
        _ => artist,
      },
    };
  }

  /// [text] with its first letter in uppercase, the way titles and names
  /// are written; the rest is kept as sent.
  ///
  /// The first letter is the first letter or digit, after any punctuation:
  /// "(in Fata Ta)" becomes "(In Fata Ta)", "03. dana" stays. A first word
  /// already in mixed case is a name styled that way ("iBelieve Worship",
  /// "beCLEAN"), and a web address ("www.rvesv.ro") is not a name: both
  /// stay as sent.
  static String capitalized(String text) {
    final start = text.indexOf(_alphanumeric);
    if (start < 0) return text;
    final first = text[start];
    final upper = first.toUpperCase();
    // A digit, an uppercase letter or a letter without case.
    if (upper == first) return text;
    final rest = text.substring(start);
    if (_webAddress.hasMatch(rest)) return text;
    final word = _letters.matchAsPrefix(rest)?.group(0) ?? first;
    if (word.toLowerCase() != word) return text;
    return text.replaceRange(start, start + 1, upper);
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
