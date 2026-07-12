import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/log_flush_guard.dart';
import 'package:radio_crestin/services/network_service.dart';

/// Pumps the microtask/timer queue so unawaited flush chains settle.
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NetworkService network;
  late int flushCalls;
  late bool flushShouldFail;

  Future<void> fakeFlush() async {
    flushCalls++;
    if (flushShouldFail) throw Exception('network dropped');
  }

  LogFlushGuard newGuard() => LogFlushGuard(flush: fakeFlush);

  setUp(() {
    // A fresh NetworkService replaces the singleton; subjects seed online.
    network = NetworkService();
    flushCalls = 0;
    flushShouldFail = false;
  });

  tearDown(() {
    network.dispose();
  });

  group('requestFlush', () {
    test('flushes immediately when online and leaves no pending flag',
        () async {
      SharedPreferences.setMockInitialValues({});
      final guard = newGuard()..start(await SharedPreferences.getInstance());

      guard.requestFlush();
      await pump();

      expect(flushCalls, 1);
      expect(guard.isPending, isFalse);
      guard.dispose();
    });

    test('defers with a persistent pending flag when offline', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final guard = newGuard()..start(prefs);
      network.isOffline.add(true);

      guard.requestFlush();
      await pump();

      expect(flushCalls, 0);
      expect(guard.isPending, isTrue);
      expect(prefs.getBool(LogFlushGuard.pendingFlushKey), isTrue);
      guard.dispose();
    });

    test('marks pending when the flush itself fails mid-flight', () async {
      SharedPreferences.setMockInitialValues({});
      final guard = newGuard()..start(await SharedPreferences.getInstance());
      flushShouldFail = true;

      guard.requestFlush();
      await pump();

      expect(flushCalls, 1);
      expect(guard.isPending, isTrue);
      guard.dispose();
    });
  });

  group('connectivity recovery', () {
    test('flushes and clears the flag when the network returns', () async {
      SharedPreferences.setMockInitialValues({});
      final guard = newGuard()..start(await SharedPreferences.getInstance());
      network.isOffline.add(true);
      guard.requestFlush();
      await pump();
      expect(flushCalls, 0);

      network.isOffline.add(false);
      await pump();

      expect(flushCalls, 1);
      expect(guard.isPending, isFalse);
      guard.dispose();
    });

    test('does not flush on reconnect when nothing is pending', () async {
      SharedPreferences.setMockInitialValues({});
      final guard = newGuard()..start(await SharedPreferences.getInstance());

      network.isOffline.add(true);
      network.isOffline.add(false);
      await pump();

      expect(flushCalls, 0);
      guard.dispose();
    });
  });

  group('startup (crash-then-restart)', () {
    test('start() settles a flag persisted by a previous launch', () async {
      SharedPreferences.setMockInitialValues({
        LogFlushGuard.pendingFlushKey: true,
      });
      final guard = newGuard();

      // The seeded isOffline=false replays on listen, so start() alone
      // triggers the owed flush.
      guard.start(await SharedPreferences.getInstance());
      await pump();

      expect(flushCalls, 1);
      expect(guard.isPending, isFalse);
      guard.dispose();
    });

    test('start() keeps the flag while offline and flushes later', () async {
      SharedPreferences.setMockInitialValues({
        LogFlushGuard.pendingFlushKey: true,
      });
      network.isOffline.add(true);
      final guard = newGuard();

      guard.start(await SharedPreferences.getInstance());
      await pump();
      expect(flushCalls, 0);
      expect(guard.isPending, isTrue);

      network.isOffline.add(false);
      await pump();
      expect(flushCalls, 1);
      expect(guard.isPending, isFalse);
      guard.dispose();
    });
  });
}
