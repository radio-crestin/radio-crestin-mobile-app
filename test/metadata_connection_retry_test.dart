import 'dart:async';
import 'dart:io' show HttpException, SocketException;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_connectivity.dart';
import 'helpers/fake_metadata_backend.dart';

/// The metadata fetch keeps its connections from one 60 s tick to the
/// next, so a request can go out on one the server has just closed. That
/// request is retried once, at once; only a failure after the retry
/// reaches [NetworkService], within the same 8 s.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 10, 18, 12);
  DateTime t(int seconds) => t0.add(Duration(seconds: seconds));
  const minute = Duration(seconds: 60);
  const p = FakeSong(21, 'Song P');
  const q = FakeSong(22, 'Song Q');

  late SharedPreferences prefs;
  late FakeClock clock;
  late FakeMetadataBackend backend;
  late NetworkService network;
  StationDataService? current;

  /// Internet checks, which a reported request failure starts.
  var probes = 0;

  /// What the next `/stations-metadata` requests throw, in order, each
  /// after [dropAfter].
  final drops = <Object>[];
  var dropAfter = Duration.zero;

  /// Set to make every `/stations-metadata` request hang from then on.
  Completer<void>? hang;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    GetIt.instance.registerSingleton<PlayCountService>(PlayCountService());
    reviewsStatsCache.clear();
    drops.clear();
    dropAfter = Duration.zero;
    hang = null;
    probes = 0;
    clock = FakeClock(t0);
    backend = FakeMetadataBackend(clock)
      ..beforeMetadataResponse = (_) async {
        if (drops.isNotEmpty) {
          final drop = drops.removeAt(0);
          if (dropAfter > Duration.zero) {
            await Future<void>.delayed(dropAfter);
          }
          throw drop;
        }
        await hang?.future;
      };
    for (var id = 1; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    // Monitored, as main() sets it up: a reported failure checks the
    // internet, so [probes] counts the failures that reached it.
    network = NetworkService(
      connectivity: FakeConnectivity(wifi),
      httpClient: MockClient((_) async {
        probes++;
        return http.Response('', 204);
      }),
      probes: [
        InternetProbe(Uri.parse('https://probe.example/generate_204'),
            (response) => response.statusCode == 204),
      ],
    );
    await network.initialize();
    current = null;
  });

  tearDown(() async {
    current?.dispose();
    network.dispose();
    await GetIt.instance.reset();
  });

  StationDataService service() => current!;

  /// Builds the service and runs the startup sync at the current time.
  Future<void> start() async {
    current = backend.newService(prefs);
    await service().enqueueSync(SyncReason.startup);
  }

  /// One 60 s periodic tick, with no time for a wait inside it.
  Future<void> tick() async {
    await clock.advance(minute);
    unawaited(service().enqueueSync(SyncReason.periodic));
    await clock.settle();
  }

  String songOf(int id) =>
      service().stations.value.firstWhere((s) => s.id == id).songTitle;

  /// The metadata requests made since [before] of them were.
  List<Uri> requestsSince(int before) =>
      backend.metadataRequests.sublist(before);

  http.ClientException closedBeforeHeader() => http.ClientException(
      'Connection closed before full header was received');

  group('a connection lost under the request', () {
    final lostConnections = <String, Object Function()>{
      'closed before the response header': closedBeforeHeader,
      'reset (SocketException)': () =>
          const SocketException('Connection reset by peer'),
      'closed (HttpException)': () => const HttpException(
          'Connection closed before response was received'),
    };

    for (final MapEntry(key: name, value: error) in lostConnections.entries) {
      test('$name: retried once, at once, and no failure reported',
          () async {
        backend.songChange(2, t(-300), p);
        await start();
        backend.songChange(2, t(30), q);
        final before = backend.metadataRequests.length;
        drops.add(error());

        await tick();

        final requests = requestsSince(before);
        expect(requests, hasLength(2));
        expect(requests.last, requests.first,
            reason: 'the same request, sent again');
        // tick() lets no fake time pass: a retry after a wait would not
        // have run yet.
        expect(songOf(2), 'Song Q');
        expect(probes, 0, reason: 'NetworkService heard of no failure');
      });
    }

    test('a failure after the retry is reported as before', () async {
      backend.songChange(2, t(-300), p);
      await start();
      backend.songChange(2, t(30), q);
      final before = backend.metadataRequests.length;
      drops.addAll([closedBeforeHeader(), closedBeforeHeader()]);

      await tick();

      expect(requestsSince(before), hasLength(2),
          reason: 'one retry, not two');
      expect(songOf(2), 'Song P');
      expect(probes, 1, reason: 'NetworkService checks the internet');

      // As before a failed diff: the cursor stayed, so the next one
      // covers the gap.
      await tick();
      expect(songOf(2), 'Song Q');
    });
  });

  group('not retried', () {
    for (final status in [404, 500, 503]) {
      test('HTTP $status: an answer, not a failure of the connection',
          () async {
        await start();
        final before = backend.metadataRequests.length;
        backend.failNext('/stations-metadata', status: status);

        await tick();

        expect(requestsSince(before), hasLength(1));
        expect(probes, 0, reason: 'an answer proves the internet works');
      });
    }

    /// Runs the startup sync in fake time, then starts a periodic one
    /// after [prepare]; [body] moves the time on.
    void inFakeTime(void Function() prepare,
        void Function(FakeAsync async, int before) body) {
      fakeAsync((async) {
        current = backend.newService(prefs);
        var started = false;
        service().enqueueSync(SyncReason.startup).then((_) => started = true);
        async.elapse(Duration.zero);
        expect(started, isTrue);
        final before = backend.metadataRequests.length;
        prepare();
        service().enqueueSync(SyncReason.periodic);
        body(async, before);
      });
    }

    test('a timeout: reported after the same 8 s', () {
      inFakeTime(() => hang = Completer<void>(), (async, before) {
        async.elapse(const Duration(milliseconds: 7900));
        expect(requestsSince(before), hasLength(1));
        expect(probes, 0);

        async.elapse(const Duration(milliseconds: 200));
        expect(requestsSince(before), hasLength(1));
        expect(probes, 1);
      });
    });

    test('a retry that times out: reported 8 s after the first request',
        () {
      // The first request is lost late, after 5 s; the retry hangs.
      void prepare() {
        drops.add(closedBeforeHeader());
        dropAfter = const Duration(seconds: 5);
        hang = Completer<void>();
      }

      inFakeTime(prepare, (async, before) {
        async.elapse(const Duration(seconds: 5));
        expect(requestsSince(before), hasLength(2));

        async.elapse(const Duration(milliseconds: 2900));
        expect(probes, 0);

        async.elapse(const Duration(milliseconds: 200));
        expect(requestsSince(before), hasLength(2));
        expect(probes, 1, reason: 'the 8 s cover the retry too');
      });
    });
  });
}
