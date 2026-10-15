import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// Hidden stations leave every list (home, favorites, search, the car's)
/// but stay in the catalog, so the station playing keeps its song.
void main() {
  late StationDataService service;
  late SharedPreferences prefs;

  final alpha = StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha');
  final beta = StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta');
  final gamma = StationFactory.createStation(id: 3, slug: 'gamma', title: 'Gamma');
  final delta = StationFactory.createStation(id: 4, slug: 'delta', title: 'Delta');

  List<String> slugsOf(List<Station> stations) =>
      [for (final s in stations) s.slug];

  /// What the home list's combiner would publish for the current state.
  void publishHomeList() => service.filteredStations.add(
        StationDataService.filterByGroup(
          null,
          service.stations.value,
          hiddenSlugs: service.hiddenStationSlugs.value.toSet(),
        ),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    GetIt.instance.registerSingleton<PlayCountService>(PlayCountService());
    service = StationDataService(
      graphqlClient: GraphQLClient(
        link: HttpLink('https://example.com/graphql'),
        cache: GraphQLCache(),
      ),
    );
    service.applyPublicStationsForTest([alpha, beta, gamma, delta]);
    publishHomeList();
  });

  tearDown(() async {
    service.dispose();
    await GetIt.instance.reset();
  });

  test('a hidden station leaves the lists but stays in the catalog', () async {
    await service.setStationIsHidden(beta, true);
    publishHomeList();

    expect(slugsOf(service.getSortedStations()),
        ['alpha', 'delta', 'gamma']);
    expect(slugsOf(service.getSortedStations(applyGroupFilter: false)),
        ['alpha', 'delta', 'gamma']);
    expect(slugsOf(service.visibleStations), ['alpha', 'gamma', 'delta']);
    expect(slugsOf(service.stations.value), contains('beta'));
    expect(slugsOf(service.hiddenStations), ['beta']);
  });

  test('the hidden slugs are saved, and saved again once shown', () async {
    await service.setStationIsHidden(beta, true);
    expect(json.decode(prefs.getString('hiddenStationSlugs')!), ['beta']);

    await service.setStationIsHidden(beta, false);
    expect(json.decode(prefs.getString('hiddenStationSlugs')!), isEmpty);
  });

  test('hiding a hidden station, or showing a shown one, changes nothing',
      () async {
    await service.setStationIsHidden(beta, true);
    final emitted = <List<String>>[];
    final sub = service.hiddenStationSlugs.stream.skip(1).listen(emitted.add);

    await service.setStationIsHidden(beta, true);
    await service.setStationIsHidden(gamma, false);
    await pumpEventQueue();

    expect(emitted, isEmpty);
    expect(service.hiddenStationSlugs.value, ['beta']);
    await sub.cancel();
  });

  test('the hidden stations list the last one hidden first, and only the '
      'ones still in the catalog', () async {
    await service.setStationIsHidden(gamma, true);
    await service.setStationIsHidden(
        StationFactory.createStation(id: 99, slug: 'gone', title: 'Gone'),
        true);
    await service.setStationIsHidden(alpha, true);

    expect(slugsOf(service.hiddenStations), ['alpha', 'gamma']);
  });

  test('a station shown again goes back to its place in the order',
      () async {
    expect(slugsOf(service.getSortedStations()),
        ['alpha', 'beta', 'delta', 'gamma']);

    await service.setStationIsHidden(beta, true);
    publishHomeList();
    await service.setStationIsHidden(beta, false);
    publishHomeList();

    expect(slugsOf(service.getSortedStations()),
        ['alpha', 'beta', 'delta', 'gamma']);
    expect(service.hiddenStations, isEmpty);
  });

  test("a group's stations with the hidden ones, each in its place",
      () async {
    final group = StationFactory.createStationGroup(
      id: 7,
      name: 'Worship',
      slug: 'worship',
      stationToStationGroups: [
        for (final s in [alpha, gamma, delta])
          StationFactory.createStationToStationGroup(stationId: s.id),
      ],
    );
    expect(service.getSortedGroupStationsWithHidden(), isEmpty,
        reason: 'no group chosen');

    service.selectedStationGroup.add(group);
    await service.setStationIsHidden(gamma, true);
    await service.setStationIsHidden(alpha, true);

    expect(slugsOf(service.getSortedGroupStationsWithHidden()),
        ['alpha', 'delta', 'gamma']);
  });

  test('the home list combiner leaves hidden stations out',
      () {
    expect(
      slugsOf(StationDataService.filterByGroup(
        null,
        [alpha, beta, gamma],
        hiddenSlugs: {'beta'},
      )),
      ['alpha', 'gamma'],
    );
  });

  group('next/previous from the hidden station playing', () {
    test('continue from its place in the order', () async {
      await service.setStationIsHidden(beta, true);
      publishHomeList();

      // Alphabetical: Alpha, [Beta], Delta, Gamma.
      expect(service.getNextStation('beta')?.slug, 'delta');
      expect(service.getPreviousStation('beta')?.slug, 'alpha');
    });

    test('in the car too', () async {
      await service.setStationIsHidden(beta, true);
      publishHomeList();

      expect(service.getNextStation('beta', wholeCatalog: true)?.slug,
          'delta');
    });

    test('never land on another hidden station', () async {
      await service.setStationIsHidden(beta, true);
      await service.setStationIsHidden(delta, true);
      publishHomeList();

      expect(service.getNextStation('alpha')?.slug, 'gamma');
      expect(service.getNextStation('beta')?.slug, 'gamma');
      expect(service.getPreviousStation('gamma')?.slug, 'alpha');
    });
  });
}
