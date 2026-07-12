import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/local_log_store.dart';

void main() {
  group('LocalLogStore.formatLine', () {
    final ts = DateTime.utc(2026, 7, 12, 10, 30, 5);

    test('formats timestamp, level, body and compact JSON attributes', () {
      final line = LocalLogStore.formatLine(
        ts,
        'info',
        'stream loaded',
        {'station_slug': 'rve', 'retry': 2},
      );
      expect(
        line,
        '2026-07-12T10:30:05.000Z [INFO] stream loaded '
        '{"station_slug":"rve","retry":2}',
      );
    });

    test('omits the attributes segment when empty or null', () {
      expect(
        LocalLogStore.formatLine(ts, 'warn', 'careful'),
        '2026-07-12T10:30:05.000Z [WARN] careful',
      );
      expect(
        LocalLogStore.formatLine(ts, 'warn', 'careful', {}),
        '2026-07-12T10:30:05.000Z [WARN] careful',
      );
    });

    test('keeps multi-line bodies (stack traces) on one line', () {
      final line =
          LocalLogStore.formatLine(ts, 'error', 'boom\n#0 main\n#1 run');
      expect(line.contains('\n'), isFalse);
      expect(line, contains(r'boom\n#0 main\n#1 run'));
    });

    test('converts local timestamps to UTC', () {
      final local = DateTime(2026, 7, 12, 12);
      final line = LocalLogStore.formatLine(local, 'info', 'x');
      expect(line, startsWith(local.toUtc().toIso8601String()));
    });

    test('stringifies non-JSON-encodable attribute values', () {
      final line = LocalLogStore.formatLine(
        ts,
        'info',
        'x',
        {'when': Duration(seconds: 3)},
      );
      expect(line, contains('"when":"0:00:03.000000"'));
    });
  });

  group('LocalLogStore.shouldRotate', () {
    test('rotates when the next line would exceed the budget', () {
      expect(LocalLogStore.shouldRotate(500, 24, maxBytes: 512), isTrue);
    });

    test('does not rotate while under the budget', () {
      expect(LocalLogStore.shouldRotate(400, 100, maxBytes: 512), isFalse);
      expect(LocalLogStore.shouldRotate(0, 512, maxBytes: 512), isFalse);
    });

    test('never rotates an empty file, even for an oversized line', () {
      expect(LocalLogStore.shouldRotate(0, 9999, maxBytes: 512), isFalse);
    });
  });

  group('LocalLogStore rotation on disk', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('local_log_store_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('appends one line per record to app.log', () async {
      final store = LocalLogStore(directory: tempDir, maxFileBytes: 4096);
      store.append('info', 'first', {'k': 'v'});
      store.append('warn', 'second');
      await store.dispose();

      final lines = File('${tempDir.path}/app.log').readAsLinesSync();
      expect(lines, hasLength(2));
      expect(lines[0], contains('[INFO] first {"k":"v"}'));
      expect(lines[1], contains('[WARN] second'));
    });

    test('rotates at the byte budget keeping maxFiles files', () async {
      final store =
          LocalLogStore(directory: tempDir, maxFileBytes: 200, maxFiles: 3);
      final filler = 'x' * 80;
      for (var i = 0; i < 12; i++) {
        store.append('info', 'line $i $filler');
      }
      await store.dispose();

      final files = tempDir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
      expect(files, ['app.log', 'app.log.1', 'app.log.2']);
      // The oldest lines were dropped with the deleted oldest file.
      final all = files
          .map((f) => File('${tempDir.path}/$f').readAsStringSync())
          .join();
      expect(all, isNot(contains('line 0 ')));
      expect(all, contains('line 11 '));
    });

    test('collectLogFiles returns existing files after flushing', () async {
      final store = LocalLogStore(directory: tempDir, maxFileBytes: 4096);
      store.append('info', 'hello');

      final files = await store.collectLogFiles();

      expect(files, hasLength(1));
      expect(files.single.readAsStringSync(), contains('hello'));
      await store.dispose();
    });

    test('a broken directory disables the store without throwing', () async {
      final gone = Directory('${tempDir.path}/missing');
      final store = LocalLogStore(directory: gone, maxFileBytes: 4096);
      // Make creation fail by occupying the path with a file.
      File(gone.path).writeAsStringSync('not a dir');

      store.append('info', 'x');
      await store.dispose();

      expect(await store.collectLogFiles(), isEmpty);
    });
  });
}
