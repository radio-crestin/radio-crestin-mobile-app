import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Rotating on-device copy of every log record the app emits.
///
/// [AnalyticsService] mirrors each PostHog Logs record here (all severities,
/// including the rich exception records) so a readable log always exists
/// locally at `Documents/logs/app.log` for support/debug use — even when the
/// device is offline or PostHog upload fails.
///
/// Records are one line each: ISO-8601 UTC timestamp, level, body (newlines
/// escaped), compact JSON attributes. The file rotates at [maxFileBytes]
/// keeping [maxFiles] files (`app.log`, `app.log.1`, `app.log.2`); the oldest
/// is dropped on rotation.
///
/// All writes are async and serialized through a single queue so concurrent
/// appends never interleave, buffered via [IOSink] with a periodic flush (no
/// fsync per line), and never throw into callers.
class LocalLogStore {
  static final LocalLogStore _instance = LocalLogStore();

  /// The app-wide singleton, writing under the documents directory.
  static LocalLogStore get instance => _instance;

  /// Creates a store. [directory] overrides the log directory (used by
  /// tests); when null, `<documents>/logs` is resolved lazily on first write.
  LocalLogStore({
    Directory? directory,
    this.maxFileBytes = 512 * 1024,
    this.maxFiles = 3,
  }) : _directoryOverride = directory;

  /// Rotation threshold for the active file, in bytes.
  final int maxFileBytes;

  /// Total number of log files kept (active + rotated).
  final int maxFiles;

  static const _fileName = 'app.log';
  static const _flushEvery = Duration(seconds: 5);

  final Directory? _directoryOverride;
  Directory? _directory;
  IOSink? _sink;
  int _currentBytes = 0;
  bool _dirty = false;
  bool _disabled = false;
  Timer? _flushTimer;

  /// Serialization queue: every file operation chains onto this future, so
  /// writes, rotations, and flushes never overlap.
  Future<void> _queue = Future<void>.value();

  /// Appends one record. Fire-and-forget; never throws into the caller.
  void append(String level, String body, [Map<String, Object>? attributes]) {
    if (_disabled) return;
    final line = formatLine(DateTime.now(), level, body, attributes);
    _enqueue(() => _write(line));
    _flushTimer ??= Timer.periodic(_flushEvery, (_) => _enqueue(_flushSink));
  }

  /// Returns the existing log files, newest first, after flushing buffered
  /// writes — for future support/debug collection (e.g. attach to an email).
  Future<List<File>> collectLogFiles() async {
    _enqueue(_flushSink);
    await _queue;
    final dir = _directory ?? _directoryOverride;
    if (dir == null || !dir.existsSync()) return const [];
    return [
      for (var i = 0; i < maxFiles; i++)
        if (File(_pathFor(dir, i)).existsSync()) File(_pathFor(dir, i)),
    ];
  }

  /// Formats one log line: ISO-8601 UTC timestamp, upper-cased level, body
  /// with newlines escaped (stack traces stay on one line), and compact JSON
  /// attributes. Pure — unit tested directly.
  static String formatLine(
    DateTime timestamp,
    String level,
    String body, [
    Map<String, Object>? attributes,
  ]) {
    final buffer = StringBuffer()
      ..write(timestamp.toUtc().toIso8601String())
      ..write(' [')
      ..write(level.toUpperCase())
      ..write('] ')
      ..write(body.replaceAll('\n', r'\n'));
    if (attributes != null && attributes.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(jsonEncode(
          attributes,
          toEncodable: (Object? value) => value.toString(),
        ));
    }
    return buffer.toString();
  }

  /// Whether writing [nextLineBytes] more bytes should rotate the active
  /// file first. Never rotates an empty file, so a single oversized line
  /// still gets written. Pure — unit tested directly.
  static bool shouldRotate(
    int currentBytes,
    int nextLineBytes, {
    required int maxBytes,
  }) =>
      currentBytes > 0 && currentBytes + nextLineBytes > maxBytes;

  /// Cancels the flush timer and closes the sink. The singleton lives for the
  /// app's lifetime in production; provided for tests and symmetry.
  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _enqueue(() async {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
    });
    await _queue;
  }

  // ── Internals (all run on the serialization queue) ──

  void _enqueue(Future<void> Function() op) {
    _queue = _queue.then((_) => op()).catchError((Object e) {
      // A broken store must never disturb the app; stop retrying so we don't
      // pay the failure cost on every append (e.g. no documents dir).
      _disabled = true;
      _flushTimer?.cancel();
      _flushTimer = null;
      developer.log('LocalLogStore disabled: $e');
    });
  }

  Future<void> _write(String line) async {
    var sink = await _ensureSink();
    final lineBytes = utf8.encode(line).length + 1; // + newline
    if (shouldRotate(_currentBytes, lineBytes, maxBytes: maxFileBytes)) {
      await _rotate();
      sink = _sink!;
    }
    sink.writeln(line);
    _currentBytes += lineBytes;
    _dirty = true;
  }

  Future<void> _flushSink() async {
    if (!_dirty) return;
    _dirty = false;
    await _sink?.flush();
  }

  Future<IOSink> _ensureSink() async {
    final existing = _sink;
    if (existing != null) return existing;
    final dir = _directoryOverride ??
        Directory('${(await getApplicationDocumentsDirectory()).path}/logs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _directory = dir;
    final file = File(_pathFor(dir, 0));
    _currentBytes = file.existsSync() ? file.lengthSync() : 0;
    return _sink = file.openWrite(mode: FileMode.append);
  }

  Future<void> _rotate() async {
    final dir = _directory!;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    // Shift app.log -> app.log.1 -> app.log.2; the rename onto the highest
    // index overwrites it, dropping the oldest file.
    for (var i = maxFiles - 1; i >= 1; i--) {
      final source = File(_pathFor(dir, i - 1));
      if (source.existsSync()) source.renameSync(_pathFor(dir, i));
    }
    _currentBytes = 0;
    _dirty = false;
    _sink = File(_pathFor(dir, 0)).openWrite(mode: FileMode.append);
  }

  String _pathFor(Directory dir, int index) =>
      index == 0 ? '${dir.path}/$_fileName' : '${dir.path}/$_fileName.$index';
}
