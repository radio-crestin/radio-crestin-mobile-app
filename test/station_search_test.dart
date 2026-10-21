import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/station_search.dart';

/// The parts of [title] that [query] matches, as text.
List<String>? _matched(String title, String query) => stationTitleMatch(
      title,
      query,
    )?.map((range) => range.textInside(title)).toList();

void main() {
  group('stationTitleMatch', () {
    test('finds a word at its start, wherever it is in the name', () {
      expect(_matched('RVE Cluj', 'cluj'), ['Cluj']);
      expect(_matched('Radio Elim Kids', 'el'), ['El']);
      expect(_matched('RVE Cluj', 'rve'), ['RVE']);
    });

    test('finds three letters or more inside a word', () {
      expect(_matched('Radio Filadelfia', 'delf'), ['delf']);
    });

    test('leaves out two letters inside a word', () {
      // Would otherwise find half the catalog.
      expect(_matched('Radio Filadelfia', 'el'), isNull);
    });

    test('needs every word typed, in any order', () {
      expect(
        _matched('Aripi Spre Cer Popular', 'popular aripi'),
        ['Aripi', 'Popular'],
      );
      expect(_matched('Aripi Spre Cer Popular', 'aripi predici'), isNull);
    });

    test('ignores case and diacritics typed or not', () {
      expect(_matched('Radio Flacăra Rusaliilor', 'flacara'), ['Flacăra']);
      expect(_matched('Radio Vocea Creștinilor', 'CRESTIN'), ['Creștin']);
      expect(_matched('Radio Gosen', 'gosén'), ['Gosen']);
    });

    test('takes cedilla and comma-below letters for the same', () {
      // 'ş' (cedilla, U+015F) against a name spelled with 'ș' (U+0219).
      expect(_matched('Radio Vocea Creștinilor', 'creştin'), ['Creștin']);
    });

    test('ignores punctuation between words', () {
      expect(
        _matched('Radio Vocea Evangheliei - Cluj', 'evangheliei cluj'),
        ['Evangheliei', 'Cluj'],
      );
      expect(_matched('RVE Viena Tineri [DE]', 'de'), ['DE']);
      expect(_matched('RVE Cluj', 'rve-cluj'), ['RVE', 'Cluj']);
    });

    test('shows overlapping matches as one', () {
      expect(_matched('Radio Elim Plus', 'elim el'), ['Elim']);
    });

    test('finds the folded letter in its place in the name', () {
      expect(
        stationTitleMatch('Radio Philadelphia Mansuè', 'mansue'),
        [const TextRange(start: 19, end: 25)],
      );
    });

    test('matches every name with nothing in bold for no text', () {
      expect(stationTitleMatch('Radio Gosen', ''), isEmpty);
      expect(stationTitleMatch('Radio Gosen', '  '), isEmpty);
    });

    test('finds nothing that isn\'t in the name', () {
      expect(_matched('Radio Gosen', 'zzz'), isNull);
    });
  });
}
