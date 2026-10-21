import 'dart:ui' show TextRange;

/// The parts of [title] that match [query] in Home's station search, for
/// the list to show them in bold; null when [title] doesn't match.
///
/// Every word typed must start a word of the title, so "cluj" finds
/// "RVE Cluj" and "aripi popular" finds "Aripi Spre Cer Popular"; a word
/// of three letters or more may also sit inside one, so "delf" finds
/// "Radio Filadelfia". Shorter ones only start words: "el" would
/// otherwise find half the list. Case, diacritics and punctuation don't
/// count. An empty [query] matches every title, with nothing in bold.
List<TextRange>? stationTitleMatch(String title, String query) {
  final folded = _fold(title);
  final ranges = <TextRange>[];
  for (final word in _fold(query).split(_separators)) {
    if (word.isEmpty) continue;
    final start = _wordStart(folded, word) ??
        (word.length >= _minLengthInsideWord ? _indexOf(folded, word) : null);
    if (start == null) return null;
    ranges.add(TextRange(start: start, end: start + word.length));
  }
  return _merged(ranges);
}

/// A typed word this long may match inside a word of the title.
const _minLengthInsideWord = 3;

/// Anything but a letter or a digit, once folded.
final _separators = RegExp(r'[^a-z0-9]+');

final _alphanumeric = RegExp(r'[a-z0-9]');

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

/// [text] in lowercase with [_plainLetters] folded, one character for
/// each of [text]'s, so a match's place is its place in [text] too.
String _fold(String text) {
  final folded = StringBuffer();
  for (final char in text.split('')) {
    final lower = char.toLowerCase();
    folded.write(lower.length == 1 ? _plainLetters[lower] ?? lower : char);
  }
  return folded.toString();
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
