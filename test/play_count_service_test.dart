import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/play_count_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    if (GetIt.instance.isRegistered<SharedPreferences>()) {
      GetIt.instance.unregister<SharedPreferences>();
    }
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
  });

  tearDown(() async {
    if (GetIt.instance.isRegistered<SharedPreferences>()) {
      GetIt.instance.unregister<SharedPreferences>();
    }
  });

  group('PlayCountService', () {
    test('starts empty when there is no stored value', () {
      final service = PlayCountService();
      expect(service.playCounts, isEmpty);
      expect(service.getPlayCount('any-slug'), 0);
    });

    test('loads existing counts from SharedPreferences on construction', () async {
      SharedPreferences.setMockInitialValues({
        'play_count_store': jsonEncode({'rve': 5, 'aripi': 2}),
      });
      final prefs = await SharedPreferences.getInstance();
      GetIt.instance.unregister<SharedPreferences>();
      GetIt.instance.registerSingleton<SharedPreferences>(prefs);

      final service = PlayCountService();

      expect(service.getPlayCount('rve'), 5);
      expect(service.getPlayCount('aripi'), 2);
      expect(service.getPlayCount('unknown'), 0);
    });

    test('incrementPlayCount increments and persists', () async {
      final service = PlayCountService();
      service.incrementPlayCount('rve');
      service.incrementPlayCount('rve');
      service.incrementPlayCount('aripi');

      expect(service.getPlayCount('rve'), 2);
      expect(service.getPlayCount('aripi'), 1);

      // Persisted: a fresh instance should read the saved value back.
      // Wait one microtask so the async _save completes.
      await Future<void>.delayed(Duration.zero);

      final fresh = PlayCountService();
      expect(fresh.getPlayCount('rve'), 2);
      expect(fresh.getPlayCount('aripi'), 1);
    });

    test('refresh() picks up counts written by another isolate', () async {
      final service = PlayCountService();
      expect(service.getPlayCount('rve'), 0);

      // Simulate the Android Auto isolate writing to SharedPreferences.
      final prefs = GetIt.instance<SharedPreferences>();
      await prefs.setString(
        'play_count_store',
        jsonEncode({'rve': 10}),
      );

      // Without refresh(), the in-memory map is stale.
      expect(service.getPlayCount('rve'), 0);

      service.refresh();
      expect(service.getPlayCount('rve'), 10);
    });

    test('playCounts getter returns an unmodifiable view', () {
      final service = PlayCountService();
      service.incrementPlayCount('s');

      expect(
        () => service.playCounts['s'] = 99,
        throwsUnsupportedError,
      );
    });

    test('survives malformed JSON in storage without throwing', () async {
      SharedPreferences.setMockInitialValues({
        'play_count_store': 'not-json-at-all',
      });
      final prefs = await SharedPreferences.getInstance();
      GetIt.instance.unregister<SharedPreferences>();
      GetIt.instance.registerSingleton<SharedPreferences>(prefs);

      // Constructor catches the decode error and falls back to empty.
      final service = PlayCountService();
      expect(service.playCounts, isEmpty);
    });

    test('coerces numeric values back from doubles in JSON', () async {
      // jsonEncode + parse round-trips through num — explicit doubles end up
      // typed as `num`, and the loader must call .toInt() to keep typing right.
      SharedPreferences.setMockInitialValues({
        'play_count_store': '{"rve":3.0,"x":7}',
      });
      final prefs = await SharedPreferences.getInstance();
      GetIt.instance.unregister<SharedPreferences>();
      GetIt.instance.registerSingleton<SharedPreferences>(prefs);

      final service = PlayCountService();
      expect(service.getPlayCount('rve'), 3);
      expect(service.getPlayCount('x'), 7);
    });
  });

  group('PlayCountTracker', () {
    late List<String> counted;
    late PlayCountTracker tracker;

    setUp(() {
      counted = [];
      tracker = PlayCountTracker(onCounted: counted.add);
    });

    tearDown(() => tracker.dispose());

    test('counts a station once it has played for 30 seconds', () {
      fakeAsync((async) {
        tracker.stationPicked('rve');
        tracker.playingChanged(true);

        async.elapse(const Duration(seconds: 29));
        expect(counted, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(counted, ['rve']);
      });
    });

    test('a station skipped before 30 seconds is not counted', () {
      fakeAsync((async) {
        tracker.stationPicked('a');
        tracker.playingChanged(true);
        async.elapse(const Duration(seconds: 5));
        tracker.stationPicked('b');
        async.elapse(const Duration(seconds: 40));

        expect(counted, isEmpty);
      });
    });

    test('the picked station counts once its own audio starts', () {
      fakeAsync((async) {
        tracker.stationPicked('a');
        tracker.playingChanged(true);
        tracker.stationPicked('b');
        // Switching stations stops the audio, then the new one starts.
        tracker.playingChanged(false);
        tracker.playingChanged(true);
        async.elapse(const Duration(seconds: 30));

        expect(counted, ['b']);
      });
    });

    test('a pause restarts the 30 seconds', () {
      fakeAsync((async) {
        tracker.stationPicked('rve');
        tracker.playingChanged(true);
        async.elapse(const Duration(seconds: 20));
        tracker.playingChanged(false);
        async.elapse(const Duration(minutes: 5));
        expect(counted, isEmpty);

        tracker.playingChanged(true);
        async.elapse(const Duration(seconds: 30));
        expect(counted, ['rve']);
      });
    });

    test('one pick counts once, however long it plays', () {
      fakeAsync((async) {
        tracker.stationPicked('rve');
        tracker.playingChanged(true);
        async.elapse(const Duration(minutes: 10));
        tracker.playingChanged(false);
        tracker.playingChanged(true);
        async.elapse(const Duration(minutes: 10));

        expect(counted, ['rve']);
      });
    });

    test('audio without a picked station counts nothing', () {
      fakeAsync((async) {
        tracker.playingChanged(true);
        async.elapse(const Duration(minutes: 1));

        expect(counted, isEmpty);
      });
    });
  });
}
