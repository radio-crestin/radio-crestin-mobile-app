import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/private_stations_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Verifies how private (device-allowlisted) stations merge into and order
/// alongside the public catalog:
///   - dedup by id (public wins on conflict)
///   - private pinned FIRST (backend order), frozen public order untouched
///   - a public-only metadata refresh never drops private stations
///   - the full network → parse → merge pipeline (reviews_stats sideload)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Set<int> ids(List<Station> s) => s.map((e) => e.id as int).toSet();
  List<String> slugs(List<Station> s) => s.map((e) => e.slug as String).toList();

  StationDataService newService({PrivateStationsService? private}) =>
      StationDataService(
        graphqlClient: GraphQLClient(
          link: HttpLink('https://example.com/graphql'),
          cache: GraphQLCache(),
        ),
        privateStationsService: private,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    final prefs = await SharedPreferences.getInstance();
    GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    GetIt.instance.registerSingleton<PlayCountService>(PlayCountService());
    reviewsStatsCache.clear();
  });

  tearDown(() => GetIt.instance.reset());

  group('Merge + dedup', () {
    test('private-only stations are added; public wins on id conflict', () {
      final service = newService();

      service.applyPublicStationsForTest([
        StationFactory.createStation(id: 1, slug: 'pub-a', title: 'Pub A'),
        StationFactory.createStation(id: 2, slug: 'pub-b', title: 'Pub B'),
      ]);
      service.applyPrivateStationsForTest([
        // id 2 collides with a public station → public wins, private dropped.
        StationFactory.createStation(id: 2, slug: 'priv-dup', title: 'Priv Dup'),
        StationFactory.createStation(id: 3, slug: 'priv-c', title: 'Priv C'),
      ]);

      final merged = service.stations.value;
      expect(ids(merged), {1, 2, 3});
      expect(merged.where((s) => s.id == 2), hasLength(1),
          reason: 'no duplicate for the conflicting id');
      final two = merged.firstWhere((s) => s.id == 2);
      expect(two.slug, 'pub-b', reason: 'public wins the conflict');

      service.dispose();
    });
  });

  group('Pinned-first ordering', () {
    test('private pinned first in backend order, public sorted after '
        '(non-recommended sort)', () {
      final service = newService();

      // Private slugs deliberately sort LAST alphabetically — proving they are
      // pinned, not sorted into place.
      final priv1 =
          StationFactory.createStation(id: 10, slug: 'zzz-1', title: 'ZZZ 1');
      final priv2 =
          StationFactory.createStation(id: 11, slug: 'zzz-2', title: 'ZZZ 2');
      service.applyPrivateStationsForTest([priv1, priv2]);

      service.filteredStations.add([
        priv1,
        priv2,
        StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'beta', title: 'Beta'),
      ]);
      service.favoriteStationSlugs.add([]);

      expect(
        slugs(service.getSortedStations()),
        ['zzz-1', 'zzz-2', 'alpha', 'beta'],
      );

      service.dispose();
    });

    test('private pinned first while the public recommended order stays '
        'frozen', () async {
      final prefs = GetIt.instance<SharedPreferences>();
      await prefs.setString('station_sort_preference', 'recommended');
      final service = newService();

      final pub = [
        StationFactory.createStation(id: 1, slug: 'p1', title: 'P1', totalListeners: 100),
        StationFactory.createStation(id: 2, slug: 'p2', title: 'P2', totalListeners: 50),
        StationFactory.createStation(id: 3, slug: 'p3', title: 'P3', totalListeners: 200),
      ];
      service.applyPublicStationsForTest(pub);
      service.filteredStations.add(pub);
      service.favoriteStationSlugs.add([]);

      // Freeze the recommended public order.
      final frozenPublic = slugs(service.getSortedStations());

      // Now private stations arrive mid-session.
      final priv =
          StationFactory.createStation(id: 9, slug: 'priv', title: 'Priv');
      service.applyPrivateStationsForTest([priv]);
      service.filteredStations.add([priv, ...pub]);

      final withPrivate = slugs(service.getSortedStations());
      expect(withPrivate.first, 'priv', reason: 'private pinned first');
      expect(withPrivate.sublist(1), frozenPublic,
          reason: 'public order unchanged by the private addition');

      service.dispose();
    });

    test('orderedStations also pins private first', () async {
      final service = newService();
      final priv =
          StationFactory.createStation(id: 9, slug: 'priv', title: 'Priv');
      final pub =
          StationFactory.createStation(id: 1, slug: 'alpha', title: 'Alpha');

      service.applyPublicStationsForTest([pub]);
      service.applyPrivateStationsForTest([priv]);
      // orderedStations updates via a stream listener (microtask).
      await Future<void>.delayed(Duration.zero);

      expect(service.orderedStations.value.first.slug, 'priv');
      service.dispose();
    });
  });

  group('Metadata non-clobbering', () {
    test('a public-only refresh never drops private stations', () {
      final service = newService();
      final priv =
          StationFactory.createStation(id: 9, slug: 'priv', title: 'Priv');

      service.applyPrivateStationsForTest([priv]);
      service.applyPublicStationsForTest([
        StationFactory.createStation(id: 1, slug: 'p1', title: 'P1'),
      ]);
      expect(ids(service.stations.value), {1, 9});

      // Simulate a metadata refresh that replaces the whole public list.
      service.applyPublicStationsForTest([
        StationFactory.createStation(id: 1, slug: 'p1', title: 'P1', totalListeners: 999),
        StationFactory.createStation(id: 2, slug: 'p2', title: 'P2'),
      ]);

      expect(ids(service.stations.value), {1, 2, 9},
          reason: 'private id 9 survives a full public replacement');
      service.dispose();
    });

    test('authoritative empty removes private stations', () {
      final service = newService();
      service.applyPrivateStationsForTest([
        StationFactory.createStation(id: 9, slug: 'priv', title: 'Priv'),
      ]);
      service.applyPublicStationsForTest([
        StationFactory.createStation(id: 1, slug: 'p1', title: 'P1'),
      ]);
      expect(ids(service.stations.value), {1, 9});

      // Empty authoritative response → clear private.
      service.applyPrivateStationsForTest([]);
      expect(ids(service.stations.value), {1});
      service.dispose();
    });
  });

  group('Network → parse → merge pipeline', () {
    test('reviews_stats and now_playing survive the private parse', () async {
      final raw = StationFactory.createRawStationJson(
        id: 77,
        slug: 'private-parsed',
        title: 'Private Parsed',
        averageRating: 4.5,
        numberOfReviews: 12,
        nowPlaying: StationFactory.createNowPlaying(songName: 'Live Song'),
      );
      final client = MockClient(
        (_) async => http.Response(
          json.encode({
            'data': {'stations': [raw]}
          }),
          200,
        ),
      );
      final service = newService(
        private: PrivateStationsService(
          httpClient: client,
          prefs: GetIt.instance<SharedPreferences>(),
          deviceIdProvider: () => 'device-1',
        ),
      );

      await service.refreshPrivateStations();

      final parsed = service.stations.value;
      expect(parsed, hasLength(1));
      final station = parsed.single;
      expect(station.slug, 'private-parsed');
      // reviews_stats sideloaded into the Station via reviewsStatsCache.
      expect(station.averageRating, 4.5);
      expect(station.reviewCount, 12);
      // now_playing carried through the parse.
      expect(station.songTitle, 'Live Song');

      service.dispose();
    });
  });
}
