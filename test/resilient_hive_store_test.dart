import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:hive_ce/hive.dart' as hive;
import 'package:radio_crestin/resilient_hive_store.dart';

void main() {
  late Directory tempDir;
  late hive.Box<dynamic> box;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rh_test_');
    hive.Hive.init(tempDir.path);
    box = await hive.Hive.openBox<dynamic>(
      'graphqlClientStore_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async {
    if (box.isOpen) {
      await box.close();
    }
    // Don't call Hive.close() — it tears down a singleton that other tests
    // depend on. Closing the per-test box is enough for isolation.
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ResilientHiveStore — happy path delegates to Hive', () {
    test('put + get round-trips through Hive', () async {
      final store = ResilientHiveStore(HiveStore(box));
      store.put('Q1', {'__typename': 'Query', 'value': 1});
      // box.put is async — wait one tick for the write to land.
      await Future<void>.delayed(Duration.zero);
      expect(store.get('Q1'), {'__typename': 'Query', 'value': 1});
    });

    test('putAll + toMap returns all stored entries', () async {
      final store = ResilientHiveStore(HiveStore(box));
      store.putAll({
        'A': {'x': 1},
        'B': {'y': 2},
      });
      await Future<void>.delayed(Duration.zero);
      final all = store.toMap();
      expect(all['A'], {'x': 1});
      expect(all['B'], {'y': 2});
    });

    test('delete removes the entry', () async {
      final store = ResilientHiveStore(HiveStore(box));
      store.put('A', {'x': 1});
      await Future<void>.delayed(Duration.zero);
      store.delete('A');
      await Future<void>.delayed(Duration.zero);
      expect(store.get('A'), isNull);
    });

    test('returns null for unknown keys', () {
      final store = ResilientHiveStore(HiveStore(box));
      expect(store.get('missing'), isNull);
    });

    test('get on closed box transparently falls back to InMemoryStore',
        () async {
      // Sync read path is the one that actually exercises the fallback —
      // box.get throws synchronously when the box is closed, so the
      // wrapper's catch fires and swaps in InMemoryStore.
      final store = ResilientHiveStore(HiveStore(box));
      await box.close();
      // Returns null instead of throwing — confirms fallback engaged.
      expect(store.get('anything'), isNull);
    });

    test('toMap on closed box falls back to InMemoryStore', () async {
      final store = ResilientHiveStore(HiveStore(box));
      await box.close();
      expect(store.toMap(), isEmpty);
    });

    test('after fallback engages, subsequent writes hit InMemoryStore',
        () async {
      final store = ResilientHiveStore(HiveStore(box));
      await box.close();
      // Trigger fallback via the sync read.
      store.get('trigger');
      // From now on the delegate is InMemoryStore — synchronous, no async gap.
      store.put('K', {'v': 42});
      expect(store.get('K'), {'v': 42});
    });
  });
}
