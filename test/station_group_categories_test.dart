import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/station_group_categories.dart';

import 'helpers/station_factory.dart';

Query$GetStations$station_groups _group(
  int id,
  String slug, {
  int order = 0,
  required List<int> stationIds,
}) =>
    StationFactory.createStationGroup(
      id: id,
      name: slug,
      slug: slug,
      order: order,
      stationToStationGroups: [
        for (final s in stationIds)
          StationFactory.createStationToStationGroup(stationId: s),
      ],
    );

void main() {
  final stations = [
    StationFactory.createStation(
        id: 1, slug: 'a', title: 'A', totalListeners: 1000),
    StationFactory.createStation(
        id: 2, slug: 'b', title: 'B', totalListeners: 300),
    StationFactory.createStation(
        id: 3, slug: 'c', title: 'C', totalListeners: 60),
    StationFactory.createStation(
        id: 4, slug: 'd', title: 'D', totalListeners: null),
  ];

  test('counts every station and everyone listening', () {
    final offer = StationGroupCategories.compute(groups: [], stations: stations);

    expect(offer.stationCount, 4);
    expect(offer.listenerCount, 1360);
    expect(offer.categories, isEmpty);
  });

  test('drops the API group that holds every grouped station', () {
    final offer = StationGroupCategories.compute(
      groups: [
        _group(1, 'toate', order: -1, stationIds: [1, 2, 3]),
        _group(2, 'muzica', order: 1, stationIds: [1, 2]),
        _group(3, 'predici', order: 2, stationIds: [3]),
      ],
      stations: stations,
    );

    expect(
      offer.categories.map((c) => c.group.slug),
      ['muzica', 'predici'],
    );
  });

  test('drops groups with none of the stations and counts only known ones',
      () {
    final offer = StationGroupCategories.compute(
      groups: [
        _group(1, 'muzica', stationIds: [1, 2, 99]),
        _group(2, 'gol', stationIds: [98, 99]),
        _group(3, 'copii', stationIds: [3]),
      ],
      stations: stations,
    );

    expect(offer.categories.map((c) => c.group.slug), ['muzica', 'copii']);
    expect(offer.categories.first.stationCount, 2);
  });

  test('follows the order field, keeping the API sequence on ties', () {
    final offer = StationGroupCategories.compute(
      groups: [
        _group(1, 'worship', order: 5, stationIds: [1]),
        _group(2, 'emisiuni', order: 3, stationIds: [2]),
        _group(3, 'popular', order: 3, stationIds: [3]),
      ],
      stations: stations,
    );

    expect(
      offer.categories.map((c) => c.group.slug),
      ['emisiuni', 'popular', 'worship'],
    );
  });

  test('offers only groups that show as a category', () {
    final offer = StationGroupCategories.compute(
      groups: [
        _group(1, 'toate', stationIds: [1, 2, 3]),
        _group(2, 'muzica', stationIds: [1, 2]),
        _group(3, 'predici', stationIds: [3]),
      ],
      stations: stations,
    );

    expect(offer.offers(2), isTrue);
    expect(offer.offers(1), isFalse, reason: 'the hidden "all" group');
    expect(offer.offers(null), isFalse);
  });
}
