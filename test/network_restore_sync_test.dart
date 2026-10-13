import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_metadata_backend.dart';

/// How [StationDataService] follows connectivity: it catches the list up
/// when the network returns and rebuilds it on a mobile data/WiFi switch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FakeMetadataBackend backend;
  late NetworkService network;
  StationDataService? started;

  StationDataService service() => started!;

  /// Starts the service as main() does (bootstrap + startup sync).
  Future<void> start() async {
    final s = started = backend.newService(prefs);
    await s.initialize();
    await pumpEventQueue();
  }

  /// The network drops, then comes back.
  Future<void> outage() async {
    network.isOffline.add(true);
    await pumpEventQueue();
    network.isOffline.add(false);
    await pumpEventQueue();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    GetIt.instance.registerSingleton<PlayCountService>(PlayCountService());
    reviewsStatsCache.clear();
    // A fresh instance replaces the singleton; it seeds online, on WiFi.
    network = NetworkService();
    backend = FakeMetadataBackend(FakeClock(DateTime.utc(2026, 10, 13, 12)));
    for (var id = 1; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    started = null;
  });

  tearDown(() async {
    started?.dispose();
    network.dispose();
    await GetIt.instance.reset();
  });

  group('network restore', () {
    setUp(start);

    test('fetches the live list at once, not at the next tick', () async {
      final before = backend.metadataRequests.length;

      network.isOffline.add(true);
      await pumpEventQueue();
      expect(backend.metadataRequests.length, before,
          reason: 'going offline fetches nothing');

      network.isOffline.add(false);
      await pumpEventQueue();
      expect(backend.metadataRequests.length, greaterThan(before));
    });

    test('waits for the resume refresh while polling is paused', () async {
      service().pausePeriodic();
      network.isOffline.add(true);
      await pumpEventQueue();
      final before = backend.metadataRequests.length;

      network.isOffline.add(false);
      await pumpEventQueue();

      expect(backend.metadataRequests.length, before);
    });

    test('with a fresh catalog, only the live list is fetched', () async {
      final before = backend.graphqlRequests.length;

      await outage();

      expect(backend.graphqlRequests, hasLength(before));
    });
  });

  group('catalog after an outage', () {
    test('a first launch offline gets the whole catalog once back',
        () async {
      // Offline at launch: no cache, so the bundled list shows, and the
      // startup refresh fails.
      backend
        ..failNext('/graphql', count: 5)
        ..failNext('/stations-metadata', count: 5);
      await start();
      final before = backend.graphqlRequests.length;

      await outage();

      expect(backend.graphqlRequests.length, greaterThan(before),
          reason: 'not just the live list on top of the bundled one');
    });
  });

  group('catalog past due', () {
    test('a catalog over 10 minutes old is refreshed whole on restore',
        () async {
      await start();
      // Ten minutes on, with the periodic full refresh just failed.
      await backend.clock.advance(const Duration(minutes: 11));
      backend.failNext('/graphql');
      await service().enqueueSync(SyncReason.periodic);
      final before = backend.graphqlRequests.length;

      await outage();

      expect(backend.graphqlRequests.length, greaterThan(before));
    });
  });

  group('mobile data / WiFi switch', () {
    setUp(start);

    test('republishes the list so its artwork follows the network', () async {
      final emissions = <List<Station>>[];
      final subscription = service().stations.stream.skip(1).listen(
            emissions.add,
          );

      network.isOnMobileData.add(true);
      await pumpEventQueue();
      network.isOnMobileData.add(false);
      await pumpEventQueue();

      expect(emissions, hasLength(2));
      await subscription.cancel();
    });
  });
}
