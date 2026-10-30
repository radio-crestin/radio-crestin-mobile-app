import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/station_deep_link.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

String slugOf(String link) => Utils.stationSlugFromUri(Uri.parse(link));

void main() {
  group('Utils.stationSlugFromUri — web links', () {
    test('share link drops the share query string', () {
      expect(
        slugOf('https://www.radiocrestin.ro/radio-vocea?s=abc123&song=42'),
        'radio-vocea',
      );
    });

    test('NFC tag link drops the ref query string', () {
      expect(
        slugOf('https://asculta.radiocrestin.ro/radio-emanuel?ref=nfc'),
        'radio-emanuel',
      );
    });

    test('plain station link', () {
      expect(slugOf('https://www.radiocrestin.ro/radio-vocea'), 'radio-vocea');
    });

    test('trailing slash and fragment are ignored', () {
      expect(slugOf('https://www.radiocrestin.ro/radio-vocea/'), 'radio-vocea');
      expect(slugOf('https://www.radiocrestin.ro/radio-vocea#x'), 'radio-vocea');
    });

    test('root link names no station instead of the host', () {
      expect(slugOf('https://www.radiocrestin.ro?s=abc123'), '');
      expect(slugOf('https://www.radiocrestin.ro/'), '');
      expect(slugOf('https://www.radiocrestin.ro'), '');
    });

    test('http links are parsed like https', () {
      expect(slugOf('http://www.radiocrestin.ro/radio-vocea?s=1'), 'radio-vocea');
    });
  });

  group('Utils.stationSlugFromUri — custom scheme', () {
    test('radiocrestin://<slug> reads the slug from the host', () {
      expect(slugOf('radiocrestin://radio-vocea'), 'radio-vocea');
    });

    test('radiocrestin://<slug> ignores a query string', () {
      expect(slugOf('radiocrestin://radio-vocea?ref=nfc'), 'radio-vocea');
    });

    test('radiocrestin:///<slug> falls back to the path', () {
      expect(slugOf('radiocrestin:///radio-vocea'), 'radio-vocea');
    });

    test('radiocrestin:// with nothing after it names no station', () {
      expect(slugOf('radiocrestin://'), '');
    });
  });

  // The desktop shell opens links with StationDeepLinks, as HomePage does
  // on the phone.
  group('StationDeepLinks', () {
    final vocea =
        StationFactory.createStation(id: 1, slug: 'radio-vocea', title: 'V');
    final emanuel =
        StationFactory.createStation(id: 2, slug: 'radio-emanuel', title: 'E');

    test('reads every link the Mac app is opened with', () {
      const links = {
        'radiocrestin://radio-vocea': 'radio-vocea',
        'https://share.radiocrestin.ro/radio-vocea?s=abc123': 'radio-vocea',
        'https://asculta.radiocrestin.ro/radio-vocea?ref=nfc': 'radio-vocea',
        'https://www.radiocrestin.ro/radio-vocea/': 'radio-vocea',
        'https://www.radiocrestin.ro?s=abc123': '',
      };
      links.forEach((link, slug) {
        expect(StationDeepLinks.slugOf(Uri.parse(link)), slug, reason: link);
      });
    });

    test('finds the station a link names', () async {
      final links = StationDeepLinks(
        stations: BehaviorSubject.seeded([vocea, emanuel]),
      );
      expect(await links.stationFor('radio-emanuel'), same(emanuel));
    });

    test('a gone station or an empty slug finds none', () async {
      final links = StationDeepLinks(
        stations: BehaviorSubject.seeded([vocea]),
      );
      expect(await links.stationFor('radio-gone'), isNull);
      expect(await links.stationFor(''), isNull);
    });

    // Real time, briefly: rxdart's subjects do not deliver under fakeAsync.
    test('a link that launched the app waits for the station list',
        () async {
      final stations = BehaviorSubject<List<Station>>.seeded(const []);
      final links = StationDeepLinks(stations: stations);
      final found = links.stationFor('radio-vocea');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      stations.add([emanuel, vocea]);

      expect(await found, same(vocea));
    });

    test('gives up when the list does not load in time', () async {
      final links = StationDeepLinks(
        stations: BehaviorSubject<List<Station>>.seeded(const []),
        stationsTimeout: const Duration(milliseconds: 50),
      );

      expect(await links.stationFor('radio-vocea'), isNull);
      expect(await links.loadedStations(), isEmpty);
    });

    test('a link delivered twice at launch counts once', () {
      var now = DateTime(2026, 10, 30, 12);
      final links = StationDeepLinks(
        stations: BehaviorSubject.seeded([vocea]),
        now: () => now,
      );
      final link = Uri.parse('radiocrestin://radio-vocea');

      expect(links.isDuplicate(link), isFalse);
      now = now.add(const Duration(milliseconds: 200));
      expect(links.isDuplicate(link), isTrue);
    });

    test('the same link clicked again later opens again', () {
      var now = DateTime(2026, 10, 30, 12);
      final links = StationDeepLinks(
        stations: BehaviorSubject.seeded([vocea]),
        now: () => now,
      );
      final link = Uri.parse('radiocrestin://radio-vocea');

      expect(links.isDuplicate(link), isFalse);
      now = now.add(const Duration(seconds: 3));
      expect(links.isDuplicate(link), isFalse);
      expect(
        links.isDuplicate(Uri.parse('radiocrestin://radio-emanuel')),
        isFalse,
      );
    });
  });
}
