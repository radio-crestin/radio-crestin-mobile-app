import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// The favorites come in the listener's order, which they arrange on the
/// home page by dragging a row.
void main() {
  late StationDataService service;
  late SharedPreferences prefs;

  final alpha =
      StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha');
  final beta = StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta');
  final gamma =
      StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma');
  final delta =
      StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta');

  List<String> slugsOf(List<Station> stations) =>
      [for (final s in stations) s.slug];

  List<String> stored() =>
      List<String>.from(json.decode(prefs.getString('favoriteStationSlugs')!));

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<SharedPreferences>(prefs)
      ..registerSingleton<PlayCountService>(PlayCountService());
    service = StationDataService(
      graphqlClient: GraphQLClient(
        link: HttpLink('https://example.com/graphql'),
        cache: GraphQLCache(),
      ),
    );
    service.applyPublicStationsForTest([alpha, beta, gamma, delta]);
  });

  tearDown(() async {
    service.dispose();
    await GetIt.instance.reset();
  });

  test('lists the favorites in the listener\'s order', () {
    service.favoriteStationSlugs.add(['gamma', 'gone', 'alpha']);

    expect(slugsOf(service.favoritesIn(service.stations.value)),
        ['gamma', 'alpha'],
        reason: 'not the alphabetical sort; a station no longer listed '
            'is left out');
  });

  test('a moved favorite keeps its new place, saved', () async {
    service.favoriteStationSlugs.add(['alpha', 'beta', 'gamma']);

    await service.setFavoriteOrder(['gamma', 'alpha', 'beta']);

    expect(service.favoriteStationSlugs.value, ['gamma', 'alpha', 'beta']);
    expect(stored(), ['gamma', 'alpha', 'beta']);
  });

  test('favorites the listener doesn\'t see keep their places', () async {
    service.favoriteStationSlugs.add(['alpha', 'gone', 'beta', 'gamma']);

    await service.setFavoriteOrder(['gamma', 'alpha', 'beta']);

    expect(service.favoriteStationSlugs.value,
        ['gamma', 'gone', 'alpha', 'beta']);
  });

  test('an order with stations that aren\'t favorites changes only the '
      'favorites', () async {
    service.favoriteStationSlugs.add(['beta', 'alpha']);

    await service.setFavoriteOrder(['delta', 'alpha', 'beta']);

    expect(service.favoriteStationSlugs.value, ['alpha', 'beta']);
  });

  test('a new favorite comes last', () async {
    service.favoriteStationSlugs.add(['gamma', 'alpha']);

    await service.setStationIsFavorite(beta, true);

    expect(slugsOf(service.favoritesIn(service.stations.value)),
        ['gamma', 'alpha', 'beta']);
  });

  test('a favorite added back at its place goes there', () async {
    service.favoriteStationSlugs.add(['gamma', 'alpha']);

    await service.setStationIsFavorite(beta, true, index: 1);

    expect(service.favoriteStationSlugs.value, ['gamma', 'beta', 'alpha']);
    expect(stored(), ['gamma', 'beta', 'alpha']);
  });

  test('a place past the end, the favorites having shrunk since, is last',
      () async {
    service.favoriteStationSlugs.add(['gamma']);

    await service.setStationIsFavorite(beta, true, index: 3);

    expect(service.favoriteStationSlugs.value, ['gamma', 'beta']);
  });

  group('the order shown before favorites could be arranged', () {
    test('is kept once, from the station list\'s sort', () async {
      // Saved oldest first, shown alphabetically until now.
      service.favoriteStationSlugs.add(['gamma', 'beta', 'alpha']);

      await service.keepShownFavoriteOrderForTest();

      expect(service.favoriteStationSlugs.value, ['alpha', 'beta', 'gamma']);
      expect(stored(), ['alpha', 'beta', 'gamma']);
    });

    test('never again once the listener arranged them', () async {
      service.favoriteStationSlugs.add(['gamma', 'beta', 'alpha']);
      await service.keepShownFavoriteOrderForTest();
      await service.setFavoriteOrder(['gamma', 'alpha', 'beta']);

      await service.keepShownFavoriteOrderForTest();

      expect(service.favoriteStationSlugs.value, ['gamma', 'alpha', 'beta']);
    });
  });
}
