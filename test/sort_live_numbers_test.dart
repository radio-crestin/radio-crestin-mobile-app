import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_metadata_backend.dart';

/// The orders the listener picks ("După numărul de ascultători", "După
/// rating") after a launch from the saved station list, which keeps no
/// listener counts: they are made from the live counts once they come, not
/// frozen without them for the whole session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 10, 30, 12);
  const song = FakeSong(11, 'Song X');

  late SharedPreferences prefs;
  late FakeClock clock;
  late FakeMetadataBackend backend;
  late NetworkService network;
  final services = <StationDataService>[];

  /// Launches the app's station service as main() does: the saved list
  /// first, then the startup sync.
  Future<StationDataService> launch() async {
    final service = backend.newService(prefs);
    services.add(service);
    await service.initialize();
    return service;
  }

  List<String> order(StationDataService service) => [
        for (final station in service.getSortedStations(applyGroupFilter: false))
          station.slug as String,
      ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'listeners',
    });
    prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<SharedPreferences>(prefs)
      ..registerSingleton<PlayCountService>(PlayCountService());
    reviewsStatsCache.clear();
    network = NetworkService();
    clock = FakeClock(t0);
    backend = FakeMetadataBackend(clock);
    // Ten, as the service saves a list of at least that many.
    const listeners = {
      1: 5, 2: 300, 3: 40, 4: 120, 5: 7, //
      6: 60, 7: 4, 8: 3, 9: 2, 10: 1,
    };
    for (final MapEntry(key: id, value: count) in listeners.entries) {
      backend
        ..addStation(id, 's$id', 'Station $id')
        ..songChange(id, t0.subtract(const Duration(minutes: 5)), song,
            listeners: count);
    }
  });

  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    network.dispose();
    await GetIt.instance.reset();
  });

  test('"by listeners" after a launch from the saved list follows the live '
      'counts, then stays put', () async {
    // A first launch saves the list for the next one, without its counts.
    await launch();
    await pumpEventQueue();
    expect(prefs.getString('cached_stations_data'), isNotNull);

    // The next launch shows the saved list at once; the car lists order it
    // as it comes, before the network answers.
    final answer = Completer<void>();
    backend.beforeMetadataResponse = (_) => answer.future;
    final service = await launch();
    await pumpEventQueue();
    expect(
      [for (final Station s in service.stations.value) s.totalListeners],
      everyElement(isNull),
      reason: 'the saved list keeps no counts',
    );
    order(service);

    // The startup sync brings them.
    answer.complete();
    await pumpEventQueue();
    expect(order(service), [
      's2', 's4', 's6', 's3', 's5', 's1', 's7', 's8', 's9', 's10'
    ]);

    // Made from them, the order holds as the counts change.
    backend.beforeMetadataResponse = null;
    backend.songChange(1, t0.add(const Duration(seconds: 30)), song,
        listeners: 900);
    await clock.advance(const Duration(minutes: 1));
    await service.enqueueSync(SyncReason.periodic);
    expect(service.stations.value.first.totalListeners, 900);
    expect(order(service), [
      's2', 's4', 's6', 's3', 's5', 's1', 's7', 's8', 's9', 's10'
    ]);
  });
}
