import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radio_crestin/services/network_service.dart';

import 'helpers/fake_connectivity.dart';

/// Answers the probe requests: each probe URL answers, fails, or hangs.
class FakeInternet {
  /// Whether the internet answers at all (every probe at once).
  bool reachable = true;

  /// Probe URLs that never answer, to show the others don't wait for them.
  final Set<Uri> hanging = {};

  final List<Uri> requests = [];

  late final http.Client client = MockClient((request) async {
    requests.add(request.url);
    if (hanging.contains(request.url)) {
      await Completer<void>().future;
    }
    if (!reachable) throw const SocketException('Network is unreachable');
    return http.Response('', 204);
  });
}

/// Keeps each request exactly as sent (a [MockClient] only sees a copy),
/// and answers it with a 204.
class RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> sent = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    return http.StreamedResponse(const Stream.empty(), 204);
  }
}

final probeA = InternetProbe(
  Uri.parse('https://a.example/generate_204'),
  (response) => response.statusCode == 204,
);
final probeB = InternetProbe(
  Uri.parse('https://b.example/generate_204'),
  (response) => response.statusCode == 204,
);

/// A service on fake time, initialized: [async] drives its timers, its
/// clock and its probes' timeouts.
NetworkService onFakeTime(
  FakeAsync async, {
  required FakeConnectivity connectivity,
  required http.Client client,
  List<InternetProbe>? probes,
  Duration probeTimeout = const Duration(seconds: 4),
}) {
  final network = NetworkService(
    connectivity: connectivity,
    httpClient: client,
    probes: probes ?? [probeA, probeB],
    probeTimeout: probeTimeout,
    clock: async.getClock(DateTime(2026, 10, 13, 12)).now,
  );
  network.initialize();
  async.flushMicrotasks();
  return network;
}

/// Starts a check; the holder fills in once it is decided.
List<bool> startCheck(FakeAsync async, NetworkService network) {
  final result = <bool>[];
  network.checkInternet().then(result.add);
  async.flushMicrotasks();
  return result;
}

void main() {
  group('ConnectivityPolicy', () {
    test('no network: only none, or no results (iOS transition)', () {
      expect(ConnectivityPolicy.hasNoNetwork([]), isTrue);
      expect(ConnectivityPolicy.hasNoNetwork(none), isTrue);
    });

    test('any real interface is a network', () {
      expect(ConnectivityPolicy.hasNoNetwork(wifi), isFalse);
      expect(ConnectivityPolicy.hasNoNetwork(mobile), isFalse);
      expect(ConnectivityPolicy.hasNoNetwork([ConnectivityResult.ethernet]),
          isFalse);
      expect(
          ConnectivityPolicy.hasNoNetwork(
              [ConnectivityResult.none, ConnectivityResult.wifi]),
          isFalse);
    });

    test('mobile data only when WiFi and ethernet are absent', () {
      expect(ConnectivityPolicy.isOnMobileData(mobile), isTrue);
      expect(
          ConnectivityPolicy.isOnMobileData(
              [ConnectivityResult.mobile, ConnectivityResult.wifi]),
          isFalse);
      expect(
          ConnectivityPolicy.isOnMobileData(
              [ConnectivityResult.mobile, ConnectivityResult.ethernet]),
          isFalse);
      expect(ConnectivityPolicy.isOnMobileData(wifi), isFalse);
      expect(ConnectivityPolicy.isOnMobileData([]), isFalse);
    });
  });

  group('InternetProbe answers', () {
    http.Response response(int status, [String body = '']) =>
        http.Response(body, status);

    test('Google and Cloudflare: only their empty 204', () {
      for (final probe in [InternetProbe.google, InternetProbe.cloudflare]) {
        expect(probe.answered(response(204)), isTrue);
        // A captive portal: its login page, or a redirect to it.
        expect(probe.answered(response(200, '<html>Login</html>')), isFalse);
        expect(probe.answered(response(302)), isFalse);
      }
    });

    test('Apple: only its Success page', () {
      final apple = InternetProbe.apple;
      expect(
          apple.answered(response(
              200,
              '<HTML><HEAD><TITLE>Success</TITLE></HEAD>'
              '<BODY>Success</BODY></HTML>')),
          isTrue);
      expect(apple.answered(response(200, '<html>Login</html>')), isFalse);
      expect(apple.answered(response(302)), isFalse);
    });

    test('each platform asks its own check, then Cloudflare: two requests',
        () {
      final probes = InternetProbe.forPlatform();
      expect(probes, hasLength(2));
      expect(
          probes.first,
          same(Platform.isIOS || Platform.isMacOS
              ? InternetProbe.apple
              : InternetProbe.google));
      expect(probes.last, same(InternetProbe.cloudflare));
    });
  });

  group('NetworkService', () {
    late FakeConnectivity connectivity;
    late FakeInternet internet;
    late DateTime now;
    late NetworkService network;

    NetworkService create({List<InternetProbe>? probes}) => NetworkService(
          connectivity: connectivity,
          httpClient: internet.client,
          probes: probes ?? [probeA, probeB],
          probeTimeout: const Duration(milliseconds: 200),
          // Long enough never to fire within a test.
          recheckDelays: const [Duration(minutes: 10)],
          clock: () => now,
        );

    setUp(() {
      connectivity = FakeConnectivity(wifi);
      internet = FakeInternet();
      now = DateTime(2026, 10, 13, 12);
      network = create();
    });

    tearDown(() => network.dispose());

    test('before initialize: online, and no request leaves the app', () async {
      network.reportRequestFailure();
      expect(await network.checkInternet(), isTrue);

      expect(network.status.value, ConnectionStatus.online);
      expect(internet.requests, isEmpty);
    });

    test('starts online without probing on a network', () async {
      await network.initialize();
      await pumpEventQueue();

      expect(network.status.value, ConnectionStatus.online);
      expect(network.isOffline.value, isFalse);
      expect(internet.requests, isEmpty);
    });

    test('losing the network is offline at once, without probing', () async {
      await network.initialize();

      connectivity.emit(none);
      await pumpEventQueue();

      expect(network.status.value, ConnectionStatus.offline);
      expect(network.isOffline.value, isTrue);
      expect(internet.requests, isEmpty);
    });

    test('a network back with internet: online once a probe answers',
        () async {
      connectivity.current = none;
      await network.initialize();
      final statuses = <ConnectionStatus>[];
      network.status.listen(statuses.add);

      connectivity.emit(wifi);
      await pumpEventQueue();

      expect(statuses, [ConnectionStatus.offline, ConnectionStatus.online]);
      expect(network.isOffline.value, isFalse);
    });

    test('a network back without internet: no internet, still offline',
        () async {
      connectivity.current = none;
      await network.initialize();
      internet.reachable = false;
      final offline = <bool>[];
      network.isOffline.listen(offline.add);

      connectivity.emit(wifi);
      await pumpEventQueue();

      expect(network.status.value, ConnectionStatus.noInternet);
      expect(offline, [true],
          reason: 'never a flash of online for listeners to act on');
    });

    test('every probe failing within the timeout means no internet', () async {
      await network.initialize();
      internet.hanging.addAll([probeA.url, probeB.url]);

      expect(await network.checkInternet(), isFalse);
      expect(network.status.value, ConnectionStatus.noInternet);
    });

    test('concurrent checks share one round of probes', () async {
      await network.initialize();

      await Future.wait([network.checkInternet(), network.checkInternet()]);

      expect(internet.requests, hasLength(2));
    });

    test('probes neither follow redirects nor reuse connections', () async {
      final client = RecordingClient();
      network = NetworkService(
          connectivity: connectivity, httpClient: client, probes: [probeA]);
      await network.initialize();

      await network.checkInternet();

      final request = client.sent.single;
      expect(request.followRedirects, isFalse,
          reason: 'a captive portal redirects to its login page');
      expect(request.persistentConnection, isFalse,
          reason: 'a kept-alive socket may belong to the network just left');
      expect(request, isA<http.Abortable>(),
          reason: 'aborted at the timeout, not left holding a socket');
    });

    test('a failed request while online finds a lost internet', () async {
      await network.initialize();
      internet.reachable = false;

      network.reportRequestFailure();
      await pumpEventQueue();

      expect(network.status.value, ConnectionStatus.noInternet);
    });

    test('failed requests check the internet at most every 20 s', () async {
      await network.initialize();
      network.reportRequestFailure();
      await pumpEventQueue();
      expect(internet.requests, hasLength(2));

      now = now.add(const Duration(seconds: 10));
      network.reportRequestFailure();
      await pumpEventQueue();
      expect(internet.requests, hasLength(2),
          reason: 'e.g. a station whose server is down keeps failing');

      now = now.add(const Duration(seconds: 11));
      network.reportRequestFailure();
      await pumpEventQueue();
      expect(internet.requests, hasLength(4));
    });

    test('a request answered while without internet: online at once',
        () async {
      await network.initialize();
      internet.reachable = false;
      await network.checkInternet();
      final requestsBefore = internet.requests.length;

      network.reportRequestSuccess();

      expect(network.status.value, ConnectionStatus.online);
      expect(network.isOffline.value, isFalse);
      expect(internet.requests, hasLength(requestsBefore));
    });

    test('data still arriving keeps it online when the probes time out',
        () async {
      // A weak signal: the stream plays, the tiny probes don't make it.
      await network.initialize();
      internet.reachable = false;
      network.reportRequestSuccess();
      now = now.add(const Duration(seconds: 5));

      expect(await network.checkInternet(), isTrue);
      expect(network.status.value, ConnectionStatus.online);
    });

    test('data that stopped arriving vouches for nothing', () async {
      await network.initialize();
      internet.reachable = false;
      network.reportRequestSuccess();
      now = now.add(const Duration(seconds: 11));

      expect(await network.checkInternet(), isFalse);
      expect(network.status.value, ConnectionStatus.noInternet);
    });

    test('a failure after the last success voids its vouch', () async {
      // Audio from the previous station, then the internet died: tapping
      // another station fails, and the old audio proves nothing.
      await network.initialize();
      internet.reachable = false;
      network.reportRequestSuccess();
      now = now.add(const Duration(seconds: 2));
      network.reportRequestFailure();
      await pumpEventQueue();

      expect(network.status.value, ConnectionStatus.noInternet);
    });

    test('a success after the last failure still vouches', () async {
      // A weak signal: a fetch timed out, but audio keeps arriving.
      await network.initialize();
      internet.reachable = false;
      network.reportRequestFailure();
      await pumpEventQueue();
      network.reportRequestSuccess();
      now = now.add(const Duration(seconds: 21));
      network.reportRequestSuccess();

      expect(await network.checkInternet(), isTrue);
      expect(network.status.value, ConnectionStatus.online);
    });

    test('a network back from offline must answer for itself', () async {
      await network.initialize();
      network.reportRequestSuccess();
      connectivity.emit(none);
      await pumpEventQueue();
      internet.reachable = false;

      connectivity.emit(wifi);
      await pumpEventQueue();

      expect(network.status.value, ConnectionStatus.noInternet,
          reason: 'data from before the outage proves nothing now');
    });

    test('a network lost while probing stays offline', () async {
      await network.initialize();
      internet.hanging.addAll([probeA.url, probeB.url]);
      final check = network.checkInternet();

      connectivity.emit(none);
      await check;

      expect(network.status.value, ConnectionStatus.offline);
    });

    test('mobile data is tracked apart from reachability', () async {
      await network.initialize();

      connectivity.emit(mobile);
      await pumpEventQueue();

      expect(network.isOnMobileData.value, isTrue);
      expect(network.status.value, ConnectionStatus.online);
      expect(internet.requests, isEmpty,
          reason: 'a switch while online is not a reason to probe');
    });

    test('losing the network keeps the mobile data flag', () async {
      // Otherwise a tunnel on mobile data reads as "off mobile data", and
      // the list switches to song art it cannot download.
      connectivity.current = mobile;
      await network.initialize();
      final flags = <bool>[];
      network.isOnMobileData.listen(flags.add);

      connectivity.emit(none);
      await pumpEventQueue();
      connectivity.emit(wifi);
      await pumpEventQueue();

      expect(flags, [true, false]);
    });
  });

  group('NetworkService on fake time', () {
    test('probes run in parallel: one answer decides at once', () {
      fakeAsync((async) {
        final internet = FakeInternet()..hanging.add(probeA.url);
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi), client: internet.client);

        final result = startCheck(async, network);

        expect(result, [true], reason: "A's timeout never ran out");
        expect(internet.requests, containsAll([probeA.url, probeB.url]));
        network.dispose();
      });
    });

    test('every probe silent: no internet exactly at the timeout', () {
      fakeAsync((async) {
        final internet = FakeInternet()
          ..hanging.addAll([probeA.url, probeB.url]);
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi), client: internet.client);

        final result = startCheck(async, network);
        async.elapse(const Duration(milliseconds: 3999));
        expect(result, isEmpty);
        async.elapse(const Duration(milliseconds: 1));

        expect(result, [false]);
        network.dispose();
      });
    });

    test('rechecks back off, up to every 2 minutes', () {
      fakeAsync((async) {
        final internet = FakeInternet()..reachable = false;
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi), client: internet.client);
        startCheck(async, network);
        expect(internet.requests, hasLength(2));

        var expected = 2;
        final delays = [...NetworkService.defaultRecheckDelays];
        delays.add(delays.last);
        for (final delay in delays) {
          async.elapse(delay - const Duration(milliseconds: 1));
          expect(internet.requests, hasLength(expected),
              reason: 'not before $delay');
          async.elapse(const Duration(milliseconds: 1));
          expected += 2;
          expect(internet.requests, hasLength(expected),
              reason: 'a recheck after $delay');
        }
        expect(delays.last, const Duration(minutes: 2));
        network.dispose();
      });
    });

    test('rechecks until the internet answers again', () {
      fakeAsync((async) {
        final internet = FakeInternet()..reachable = false;
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi), client: internet.client);
        startCheck(async, network);
        expect(network.status.value, ConnectionStatus.noInternet);

        internet.reachable = true;
        async.elapse(const Duration(seconds: 2));

        expect(network.status.value, ConnectionStatus.online);
        network.dispose();
      });
    });

    test('no rechecks once the network itself is gone', () {
      fakeAsync((async) {
        final connectivity = FakeConnectivity(wifi);
        final internet = FakeInternet()..reachable = false;
        final network = onFakeTime(async,
            connectivity: connectivity, client: internet.client);
        startCheck(async, network);

        connectivity.emit(none);
        async.flushMicrotasks();
        final requestsBefore = internet.requests.length;
        async.elapse(const Duration(minutes: 10));

        expect(network.status.value, ConnectionStatus.offline);
        expect(internet.requests, hasLength(requestsBefore));
        network.dispose();
      });
    });

    test('in the background with nothing playing, rechecks send no probes',
        () {
      fakeAsync((async) {
        final internet = FakeInternet()..reachable = false;
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi), client: internet.client);
        var wanted = false;
        network.isInternetWanted = () => wanted;
        startCheck(async, network);
        final requestsBefore = internet.requests.length;

        async.elapse(const Duration(minutes: 10));
        expect(internet.requests, hasLength(requestsBefore));

        wanted = true;
        async.elapse(const Duration(minutes: 2));
        expect(internet.requests.length, greaterThan(requestsBefore),
            reason: 'back on screen, the rechecks probe again');
        network.dispose();
      });
    });

    test('one recheck chain, even when the network flaps during a recheck',
        () {
      /// Requests in the 10 minutes after an outage is found at 10 s:
      /// anew, after the network dropped and returned while a recheck's
      /// probes were out, or plainly, by a first check.
      int requestsAfterOutage({required bool flap}) {
        var count = 0;
        fakeAsync((async) {
          final connectivity = FakeConnectivity(wifi);
          final internet = FakeInternet()
            ..hanging.addAll([probeA.url, probeB.url]);
          final network = onFakeTime(async,
              connectivity: connectivity, client: internet.client);
          if (flap) {
            startCheck(async, network);
            async.elapse(const Duration(seconds: 4)); // no internet
            async.elapse(const Duration(seconds: 2)); // a recheck is out
            connectivity.emit(none);
            async.flushMicrotasks();
            connectivity.emit(wifi);
            async.flushMicrotasks();
          } else {
            async.elapse(const Duration(seconds: 6));
            startCheck(async, network);
          }
          async.elapse(const Duration(seconds: 4));
          expect(network.status.value, ConnectionStatus.noInternet);
          final start = internet.requests.length;
          async.elapse(const Duration(minutes: 10));
          count = internet.requests.length - start;
          network.dispose();
        });
        return count;
      }

      // A second, orphaned chain would about double the count.
      expect(requestsAfterOutage(flap: true),
          requestsAfterOutage(flap: false));
    });

    test('a check from the network just left never decides for the new one',
        () {
      fakeAsync((async) {
        // WiFi lost its internet, mobile data works.
        final connectivity = FakeConnectivity(wifi);
        final client = MockClient((request) async {
          if (connectivity.current == wifi) await Completer<void>().future;
          return http.Response('', 204);
        });
        final network = onFakeTime(async,
            connectivity: connectivity, client: client);
        final statuses = <ConnectionStatus>[];
        network.status.listen(statuses.add);
        network.reportRequestFailure(); // starts a check through WiFi
        async.flushMicrotasks();

        connectivity.emit(mobile);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));

        expect(statuses, everyElement(ConnectionStatus.online),
            reason: "WiFi's timed-out probes say nothing about mobile data");
        network.dispose();
      });
    });

    test('without internet, another network is checked at once', () {
      fakeAsync((async) {
        final connectivity = FakeConnectivity(wifi);
        final client = MockClient((request) async {
          if (connectivity.current == wifi) await Completer<void>().future;
          return http.Response('', 204);
        });
        final network = onFakeTime(async,
            connectivity: connectivity, client: client);
        startCheck(async, network);
        async.elapse(const Duration(seconds: 4));
        expect(network.status.value, ConnectionStatus.noInternet);
        async.elapse(const Duration(seconds: 2)); // a recheck is out

        connectivity.emit(mobile);
        async.flushMicrotasks();

        expect(network.status.value, ConnectionStatus.online,
            reason: 'not after the recheck still waiting on WiFi');
        network.dispose();
      });
    });

    test('an answer through a network back from offline wins over its probe',
        () {
      fakeAsync((async) {
        final connectivity = FakeConnectivity(none);
        final internet = FakeInternet()
          ..hanging.addAll([probeA.url, probeB.url]);
        final network = onFakeTime(async,
            connectivity: connectivity, client: internet.client);

        connectivity.emit(mobile);
        async.flushMicrotasks();
        expect(network.status.value, ConnectionStatus.offline,
            reason: 'its probe is still out');

        network.reportRequestSuccess(); // the stream reconnected
        expect(network.status.value, ConnectionStatus.online);
        async.elapse(const Duration(seconds: 5)); // the probe times out

        expect(network.status.value, ConnectionStatus.online);
        network.dispose();
      });
    });

    test('a success through the network just left vouches for nothing', () {
      fakeAsync((async) {
        // Audio arrived over WiFi; then a switch to mobile data without
        // internet, where a request fails.
        final connectivity = FakeConnectivity(wifi);
        final internet = FakeInternet()..reachable = false;
        final network = onFakeTime(async,
            connectivity: connectivity, client: internet.client);
        network.reportRequestSuccess();
        connectivity.emit(mobile);
        async.flushMicrotasks();

        network.reportRequestFailure();
        async.flushMicrotasks();

        expect(network.status.value, ConnectionStatus.noInternet);
        network.dispose();
      });
    });

    test('a flapping network gets one check per second, and a last one', () {
      fakeAsync((async) {
        final connectivity = FakeConnectivity(none);
        final internet = FakeInternet()
          ..hanging.addAll([probeA.url, probeB.url]);
        final network = onFakeTime(async,
            connectivity: connectivity, client: internet.client);

        // 10 switches between WiFi and mobile data within 1 s.
        for (var i = 0; i < 10; i++) {
          connectivity.emit(i.isEven ? wifi : mobile);
          async.elapse(const Duration(milliseconds: 100));
        }
        async.elapse(const Duration(seconds: 1));

        expect(internet.requests, hasLength(4),
            reason: 'one round on the first change, one when it settled');
        network.dispose();
      });
    });

    test('losing the network keeps the mobile data flag, also coming back',
        () {
      fakeAsync((async) {
        final connectivity = FakeConnectivity(mobile);
        final network = onFakeTime(async,
            connectivity: connectivity, client: FakeInternet().client);
        final flags = <bool>[];
        network.isOnMobileData.listen(flags.add);
        async.flushMicrotasks();

        connectivity.emit(none);
        async.flushMicrotasks();
        connectivity.emit(mobile);
        async.flushMicrotasks();

        expect(flags, [true], reason: 'a tunnel is not a switch to WiFi');
        network.dispose();
      });
    });

    test('disposing before initialize finished leaves no listener', () {
      fakeAsync((async) {
        final connectivity = FakeConnectivity(wifi);
        final internet = FakeInternet()..reachable = false;
        final network = NetworkService(
          connectivity: connectivity,
          httpClient: internet.client,
          probes: [probeA, probeB],
        );
        network.initialize();
        network.dispose();
        async.flushMicrotasks();

        expect(connectivity.hasListener, isFalse);
      });
    });

    test('disposing while a recheck is out ends the rechecks', () {
      fakeAsync((async) {
        final internet = FakeInternet()
          ..hanging.addAll([probeA.url, probeB.url]);
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi), client: internet.client);
        startCheck(async, network);
        async.elapse(const Duration(seconds: 4)); // no internet
        async.elapse(const Duration(seconds: 2)); // a recheck is out

        network.dispose();
        final requestsBefore = internet.requests.length;
        async.elapse(const Duration(hours: 1));

        expect(internet.requests, hasLength(requestsBefore));
        expect(async.pendingTimers, isEmpty,
            reason: 'no recheck chain survives, even an idle one');
      });
    });

    test('disposing during a check: no error, no more probes', () {
      fakeAsync((async) {
        final internet = FakeInternet()
          ..hanging.addAll([probeA.url, probeB.url]);
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi), client: internet.client);
        startCheck(async, network);
        final requestsBefore = internet.requests.length;

        network.dispose();
        network.reportRequestSuccess();
        network.reportRequestFailure();
        async.elapse(const Duration(minutes: 10));

        expect(internet.requests, hasLength(requestsBefore));
      });
    });
  });

  group('Apple + Cloudflare: one valid answer is enough', () {
    const timeout = Duration(seconds: 4);

    /// Runs one check on fake time with each host misbehaving as
    /// [trouble] says (absent: answers normally): what it decided, and
    /// after how long.
    (bool, Duration, ConnectionStatus) decide(Map<String, String> trouble) {
      late (bool, Duration, ConnectionStatus) outcome;
      fakeAsync((async) {
        final client = MockClient((request) async {
          switch (trouble[request.url.host]) {
            case 'hang':
              await Completer<void>().future;
            case 'fail':
              throw const SocketException('Connection refused');
            case 'portal':
              return http.Response('<html>Hotel WiFi login</html>', 200);
          }
          return request.url.host == 'captive.apple.com'
              ? http.Response(
                  '<HTML><HEAD><TITLE>Success</TITLE></HEAD>'
                  '<BODY>Success</BODY></HTML>',
                  200)
              : http.Response('', 204);
        });
        final network = onFakeTime(async,
            connectivity: FakeConnectivity(wifi),
            client: client,
            probes: [InternetProbe.apple, InternetProbe.cloudflare],
            probeTimeout: timeout);
        final started = async.elapsed;
        final result = startCheck(async, network);
        while (result.isEmpty) {
          async.elapse(const Duration(milliseconds: 100));
        }
        outcome = (result.single, async.elapsed - started, network.status.value);
        network.dispose();
      });
      return outcome;
    }

    test('Apple fails, Cloudflare answers: internet', () {
      final (reachable, _, status) = decide({'captive.apple.com': 'fail'});

      expect(reachable, isTrue);
      expect(status, ConnectionStatus.online);
    });

    test('Apple hangs, Cloudflare answers: internet, not waiting for Apple',
        () {
      final (reachable, elapsed, _) = decide({'captive.apple.com': 'hang'});

      expect(reachable, isTrue);
      expect(elapsed, Duration.zero,
          reason: "Cloudflare's answer decides; Apple's timeout never runs");
    });

    test('Apple shows a login page, Cloudflare answers: internet', () {
      final (reachable, _, _) = decide({'captive.apple.com': 'portal'});

      expect(reachable, isTrue);
    });

    test('Apple answers, Cloudflare is blocked: internet', () {
      final (reachable, elapsed, _) = decide({'cp.cloudflare.com': 'hang'});

      expect(reachable, isTrue);
      expect(elapsed, Duration.zero);
    });

    test('both silent: no internet, decided once both gave up', () {
      final (reachable, elapsed, status) = decide({
        'captive.apple.com': 'hang',
        'cp.cloudflare.com': 'hang',
      });

      expect(reachable, isFalse);
      expect(elapsed, timeout);
      expect(status, ConnectionStatus.noInternet);
    });

    test('both answering with login pages: no internet', () {
      final (reachable, _, _) = decide({
        'captive.apple.com': 'portal',
        'cp.cloudflare.com': 'portal',
      });

      expect(reachable, isFalse);
    });
  });
}
