import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/tv/desktop/desktop_recent_stations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('keeps the stations newest first, once each, up to its capacity',
      () {
    final recent = DesktopRecentStations(prefs);
    expect(recent.add('alpha'), isTrue);
    expect(recent.add('bravo'), isTrue);
    expect(recent.add('bravo'), isFalse, reason: 'already first');
    expect(recent.add('alpha'), isTrue);
    expect(recent.slugs, ['alpha', 'bravo']);

    for (var i = 0; i < 20; i++) {
      recent.add('station$i');
    }
    expect(recent.slugs, hasLength(DesktopRecentStations.capacity));
    expect(recent.slugs.first, 'station19');
  });

  test('remembers them across launches', () {
    DesktopRecentStations(prefs)
      ..add('alpha')
      ..add('bravo');
    expect(DesktopRecentStations(prefs).slugs, ['bravo', 'alpha']);
  });

  test('offers the latest few, not the one playing nor gone ones', () {
    final listed = [
      for (final slug in ['a', 'b', 'c', 'd', 'e', 'f', 'g'])
        StationFactory.createStation(
          id: slug.codeUnitAt(0),
          slug: slug,
          title: slug,
        ),
    ];
    final offered = DesktopRecentStations.offered(
      ['b', 'gone', 'a', 'c', 'd', 'e', 'f', 'g'],
      listed: listed,
      currentSlug: 'b',
    );
    expect([for (final s in offered) s.slug], ['a', 'c', 'd']);
  });
}
