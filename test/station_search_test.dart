import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils/station_search.dart';

import 'helpers/station_factory.dart';

/// The parts of [title] that [query] matches, as text.
List<String>? _matched(String title, String query) => stationTitleMatch(
      title,
      query,
    )?.map((range) => range.textInside(title)).toList();

/// The parts of the song [line] that [query] matches, as text.
List<String>? _songMatched(String line, String query) => songLineMatch(
      line,
      query,
    )?.map((range) => range.textInside(line)).toList();

/// A station named [title], playing [song] by [artist].
Station _station(
  String slug, {
  String? title,
  String? song,
  String? artist,
  bool down = false,
  String? type,
}) =>
    StationFactory.createStation(
      id: slug.hashCode,
      slug: slug,
      title: title ?? 'Radio ${slug.toUpperCase()}',
      stationType: type,
      uptime: Query$GetStations$stations$uptime(
        is_up: !down,
        timestamp: '2026-10-21T00:00:00Z',
      ),
      nowPlaying: song == null
          ? null
          : StationFactory.createNowPlaying(
              songName: song,
              artistName: artist,
            ),
    );

List<String> _slugs(Iterable<Station> stations) =>
    [for (final station in stations) station.slug as String];

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

    test('ignores accents written as marks of their own', () {
      // 'a' and a breve (U+0306), as some tags spell 'ă'.
      expect(_matched('Radio Flaca\u0306ra', 'flacara'), ['Flaca\u0306ra']);
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

  group('songLineMatch', () {
    test('finds the words typed in the title or the singer', () {
      expect(
        _songMatched('Nu Te Teme - Gabriel Gorcea', 'gorcea teme'),
        ['Teme', 'Gorcea'],
      );
    });

    test('finds a word only at its start', () {
      // Would otherwise find every "Hristos".
      expect(_songMatched('Lupta nu da - Hristic', 'ist'), isNull);
      expect(_songMatched('Lupta nu da - Hristic', 'hrist'), ['Hrist']);
    });

    test('needs three letters or more', () {
      expect(_songMatched('De ce - Carmen Prodan', 'de'), isNull);
      expect(_songMatched('Vine-o zi - David Preuteasa', 'o zi'), ['o', 'zi']);
    });

    test('ignores case, diacritics and punctuation', () {
      expect(
        _songMatched('Doamne, ce Har - Maria Toll', 'DOAMNE CE'),
        ['Doamne', 'ce'],
      );
      expect(_songMatched('Să nu spui niciodată', 'niciodata'), ['niciodată']);
    });

    test('ignores accents written as marks of their own', () {
      // 's' and a cedilla (U+0327), 'a' and a breve (U+0306), as a
      // station's tags spelled "să ştiu".
      const line = 'sa\u0306 s\u0327tiu sa\u0306 tac';
      expect(_songMatched(line, 'stiu'), ['s\u0327tiu']);
      expect(_songMatched(line, 'ştiu să'), ['sa\u0306', 's\u0327tiu']);
    });
  });

  group('searchStations', () {
    test('finds the stations by name first, then by song', () {
      final found = searchStations([
        _station('a', title: 'Radio Alfa', song: 'Isuse, Tu', artist: 'X'),
        _station('b', title: 'Isus Radio'),
        _station('c', title: 'Radio Gama', song: 'Alt cantec'),
      ], 'isus');

      expect(_slugs(found.byName), ['b']);
      expect(_slugs(found.bySong), ['a']);
    });

    test('keeps the stations in their order', () {
      final found = searchStations([
        _station('c', song: 'Domnul e bun'),
        _station('a', song: 'Domnul meu'),
      ], 'domnul');

      expect(_slugs(found.bySong), ['c', 'a']);
    });

    test('needs every word in the name, or every word in the song', () {
      final found = searchStations([
        _station('cluj', title: 'RVE Cluj', song: 'Har - Elim'),
      ], 'cluj elim');

      expect(found.byName, isEmpty);
      expect(found.bySong, isEmpty);
    });

    test('lists a station found by its name once', () {
      final found = searchStations([
        _station('elim', title: 'Radio Elim', song: 'Har - Elim'),
      ], 'elim');

      expect(_slugs(found.byName), ['elim']);
      expect(found.bySong, isEmpty);
    });

    test('looks in no song a row doesn\'t show', () {
      final found = searchStations([
        _station('down', song: 'Isus e Domn', down: true),
        _station('list', song: 'Isus e Domn', type: 'playlist'),
      ], 'isus');

      expect(found.bySong, isEmpty);
    });
  });

  group('LiveSearchResults', () {
    final a = _station('a');
    final b = _station('b');
    final c = _station('c');
    final all = {'a', 'b', 'c'};

    test('lists a query\'s results at once', () {
      final results = LiveSearchResults();

      final update = results.update('isus', [a, b], all);

      expect(_slugs(update.shown), ['a', 'b']);
      expect(update.leaving, isEmpty);
      expect(update.arriving, isEmpty);
    });

    test('keeps a station whose song stopped matching in its place until '
        'its rows left', () {
      final results = LiveSearchResults()..update('isus', [a, b, c], all);

      final update = results.update('isus', [a, c], all);
      expect(_slugs(update.shown), ['a', 'b', 'c']);
      expect(update.leaving, ['b']);

      final again = results.update('isus', [a, c], all);
      expect(_slugs(again.shown), ['a', 'b', 'c']);
      expect(again.leaving, isEmpty, reason: 'already on its way out');

      expect(results.left('b'), isTrue);
      expect(_slugs(results.update('isus', [a, c], all).shown), ['a', 'c']);
    });

    test('tells of a station whose new song matches', () {
      final results = LiveSearchResults()..update('isus', [a], all);

      final update = results.update('isus', [a, b], all);

      expect(_slugs(update.shown), ['a', 'b']);
      expect(update.arriving, ['b']);
    });

    test('lets a station gone from the list go at once', () {
      final results = LiveSearchResults()..update('isus', [a, b], all);

      final update = results.update('isus', [a], {'a', 'c'});

      expect(_slugs(update.shown), ['a']);
      expect(update.leaving, isEmpty);
    });

    test('a station matching again on its way out comes back once it left',
        () {
      final results = LiveSearchResults()
        ..update('isus', [a, b], all)
        ..update('isus', [a], all);

      final update = results.update('isus', [a, b], all);
      expect(_slugs(update.shown), ['a', 'b']);
      expect(update.arriving, isEmpty);

      results.left('b');
      expect(results.update('isus', [a, b], all).arriving, ['b']);
    });

    test('lists a new query\'s results at once', () {
      final results = LiveSearchResults()
        ..update('isus', [a, b], all)
        ..update('isus', [a], all);

      final update = results.update('isuse', [c], all);

      expect(_slugs(update.shown), ['c']);
      expect(update.leaving, isEmpty);
      expect(results.leaving, isEmpty);
    });

    test('once cleared, lists the same query\'s results at once', () {
      final results = LiveSearchResults()
        ..update('isus', [a, b], all)
        ..update('isus', [a], all)
        ..clear();

      final update = results.update('isus', [c], all);

      expect(_slugs(update.shown), ['c']);
      expect(update.arriving, isEmpty);
      expect(results.left('b'), isFalse);
    });
  });
}
