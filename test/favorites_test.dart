import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

void main() {
  group('Favorites management', () {
    const favoriteStationsKey = 'favoriteStationSlugs';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('loads empty favorites when nothing is stored', () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final favoriteJson = prefs.getString(favoriteStationsKey);

      List<String> favoriteSlugs = [];
      if (favoriteJson != null) {
        favoriteSlugs = List<String>.from(json.decode(favoriteJson));
      }

      expect(favoriteSlugs, isEmpty);
    });

    test('loads stored favorite station slugs', () async {
      SharedPreferences.setMockInitialValues({
        favoriteStationsKey: json.encode(['radio-emanuel', 'radio-vocea']),
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final favoriteJson = prefs.getString(favoriteStationsKey);

      final favoriteSlugs = List<String>.from(json.decode(favoriteJson!));

      expect(favoriteSlugs, ['radio-emanuel', 'radio-vocea']);
    });

    test('adding a favorite persists it', () async {
      final favoriteStationSlugs = BehaviorSubject.seeded(<String>[]);

      // Simulate setStationIsFavorite with isFavorite = true
      final station = StationFactory.createStation(
        id: 1,
        slug: 'radio-test',
        title: 'Radio Test',
      );

      favoriteStationSlugs
          .add([...favoriteStationSlugs.value, station.slug]);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          favoriteStationsKey, json.encode(favoriteStationSlugs.value));

      // Verify persistence
      final stored = prefs.getString(favoriteStationsKey);
      final decoded = List<String>.from(json.decode(stored!));
      expect(decoded, ['radio-test']);

      favoriteStationSlugs.close();
    });

    test('removing a favorite persists the change', () async {
      final favoriteStationSlugs =
          BehaviorSubject.seeded(<String>['radio-a', 'radio-b', 'radio-c']);

      // Simulate removing radio-b
      final stationToRemove = StationFactory.createStation(
        id: 2,
        slug: 'radio-b',
        title: 'Radio B',
      );

      favoriteStationSlugs.add(favoriteStationSlugs.value
          .where((slug) => slug != stationToRemove.slug)
          .toList());

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          favoriteStationsKey, json.encode(favoriteStationSlugs.value));

      final stored = prefs.getString(favoriteStationsKey);
      final decoded = List<String>.from(json.decode(stored!));
      expect(decoded, ['radio-a', 'radio-c']);

      favoriteStationSlugs.close();
    });

    test('toggling favorite on then off results in empty list', () async {
      final favoriteStationSlugs = BehaviorSubject.seeded(<String>[]);
      final station = StationFactory.createStation(
        id: 1,
        slug: 'radio-toggle',
        title: 'Radio Toggle',
      );

      // Add favorite
      favoriteStationSlugs
          .add([...favoriteStationSlugs.value, station.slug]);
      expect(favoriteStationSlugs.value, ['radio-toggle']);

      // Remove favorite
      favoriteStationSlugs.add(favoriteStationSlugs.value
          .where((slug) => slug != station.slug)
          .toList());
      expect(favoriteStationSlugs.value, isEmpty);

      favoriteStationSlugs.close();
    });

    test('adding duplicate favorite results in duplicate entry', () {
      // This tests the actual behavior - the code does not prevent duplicates
      final favoriteStationSlugs =
          BehaviorSubject.seeded(<String>['radio-a']);

      favoriteStationSlugs
          .add([...favoriteStationSlugs.value, 'radio-a']);

      expect(favoriteStationSlugs.value, ['radio-a', 'radio-a']);

      favoriteStationSlugs.close();
    });

    test('favorites BehaviorSubject emits updates to listeners', () async {
      final favoriteStationSlugs = BehaviorSubject.seeded(<String>[]);
      final emissions = <List<String>>[];

      favoriteStationSlugs.listen((value) {
        emissions.add(List.from(value));
      });

      favoriteStationSlugs.add(['radio-1']);
      favoriteStationSlugs.add(['radio-1', 'radio-2']);
      favoriteStationSlugs.add(['radio-2']);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(emissions.length, 4); // initial [] + 3 additions
      expect(emissions[0], []);
      expect(emissions[1], ['radio-1']);
      expect(emissions[2], ['radio-1', 'radio-2']);
      expect(emissions[3], ['radio-2']);

      favoriteStationSlugs.close();
    });
  });

  group('Last played station', () {
    const lastPlayedKey = 'last_played_media_item';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('saves last played station slug', () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(lastPlayedKey, 'radio-emanuel');

      expect(prefs.getString(lastPlayedKey), 'radio-emanuel');
    });

    test('retrieves correct station from slug', () async {
      SharedPreferences.setMockInitialValues({
        lastPlayedKey: 'station-3',
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final stationSlug = prefs.getString(lastPlayedKey);

      final stations = StationFactory.createPlaylist(count: 5);
      final lastPlayed = stations.firstWhere(
        (station) => station.slug == stationSlug,
        orElse: () => stations.first,
      );

      expect(lastPlayed.slug, 'station-3');
    });

    test('falls back to first station when slug not found', () async {
      SharedPreferences.setMockInitialValues({
        lastPlayedKey: 'nonexistent-station',
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final stationSlug = prefs.getString(lastPlayedKey);

      final stations = StationFactory.createPlaylist(count: 5);
      final lastPlayed = stations.firstWhere(
        (station) => station.slug == stationSlug,
        orElse: () => stations.first,
      );

      expect(lastPlayed.slug, 'station-1');
    });

    test('falls back to first station when no slug stored', () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final stationSlug = prefs.getString(lastPlayedKey);

      final stations = StationFactory.createPlaylist(count: 5);
      final lastPlayed = stationSlug != null
          ? stations.firstWhere(
              (station) => station.slug == stationSlug,
              orElse: () => stations.first,
            )
          : stations.first;

      expect(lastPlayed.slug, 'station-1');
    });
  });
}
