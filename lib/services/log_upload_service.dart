import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_log_store.dart';

/// Outcome of a [LogUploadService.upload] call.
typedef LogUploadResult = ({bool success, int parts, int totalBytes});

/// Ships the local log files to PostHog Logs as a handful of large records.
///
/// Used by Settings → Developer → "Send logs to us" (trigger `manual`) and by
/// the `mobile-remote-debug` flag's `uploadLocalLogs` (trigger `remote`).
///
/// Each file's content is chunked into ~50KB bodies so a full 3x512KB store
/// is at most ~32 records — far under PostHog's 500-records/10s rate cap.
/// Every record carries `{upload_id, file, part, total_parts, trigger}`; a
/// `debug_logs_uploaded` event with the upload_id and total bytes follows,
/// then `Posthog().flush()` pushes everything out immediately.
class LogUploadService {
  static final LogUploadService _instance = LogUploadService();

  /// The app-wide singleton, reading from [LocalLogStore.instance].
  static LogUploadService get instance => _instance;

  /// Creates a service. [store] overrides the log source (used by tests).
  LogUploadService({LocalLogStore? store})
      : _store = store ?? LocalLogStore.instance;

  /// Maximum UTF-8 bytes per uploaded log record body.
  static const maxChunkBytes = 50 * 1024;

  /// Minimum gap between automatic (remote-triggered) uploads.
  static const autoUploadInterval = Duration(hours: 6);

  /// SharedPreferences key holding the last automatic upload timestamp (ms).
  static const lastAutoUploadKey = 'last_log_upload_ms';

  final LocalLogStore _store;
  bool _uploading = false;

  /// Reads the local log files and ships them to PostHog Logs.
  ///
  /// [trigger] is `'manual'` (Settings button) or `'remote'` (flag-driven).
  /// Returns the outcome; never throws. Failures are not retried here — the
  /// manual path surfaces a snackbar, the remote path retries next launch.
  Future<LogUploadResult> upload({required String trigger}) async {
    if (_uploading) return (success: false, parts: 0, totalBytes: 0);
    _uploading = true;
    try {
      final uploadId = DateTime.now().toUtc().toIso8601String();
      var parts = 0;
      var totalBytes = 0;
      for (final file in await _store.collectLogFiles()) {
        final content = await file.readAsString();
        if (content.isEmpty) continue;
        totalBytes += utf8.encode(content).length;
        final chunks = chunkContent(content);
        final name = file.uri.pathSegments.last;
        for (var i = 0; i < chunks.length; i++) {
          await Posthog().captureLog(
            body: chunks[i],
            attributes: {
              'upload_id': uploadId,
              'file': name,
              'part': i + 1,
              'total_parts': chunks.length,
              'trigger': trigger,
            },
          );
          parts++;
        }
      }
      await Posthog().capture(
        eventName: 'debug_logs_uploaded',
        properties: {
          'upload_id': uploadId,
          'total_bytes': totalBytes,
          'total_parts': parts,
          'trigger': trigger,
        },
      );
      await Posthog().flush();
      return (success: true, parts: parts, totalBytes: totalBytes);
    } catch (e) {
      developer.log('Log upload failed ($trigger): $e');
      return (success: false, parts: 0, totalBytes: 0);
    } finally {
      _uploading = false;
    }
  }

  /// Remote-triggered upload, debounced to at most once per
  /// [autoUploadInterval]. The timestamp persists so the debounce survives
  /// restarts; a failed upload does not update it, so the next launch retries.
  Future<void> maybeAutoUpload(SharedPreferences prefs) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!shouldAutoUpload(
      lastUploadMs: prefs.getInt(lastAutoUploadKey),
      nowMs: now,
    )) {
      return;
    }
    final result = await upload(trigger: 'remote');
    if (result.success) await prefs.setInt(lastAutoUploadKey, now);
  }

  /// Whether enough time has passed since the last automatic upload.
  /// Pure — unit tested directly.
  @visibleForTesting
  static bool shouldAutoUpload({
    required int? lastUploadMs,
    required int nowMs,
    Duration interval = autoUploadInterval,
  }) =>
      lastUploadMs == null || nowMs - lastUploadMs >= interval.inMilliseconds;

  /// Splits [content] into chunks of at most [maxBytes] UTF-8 bytes, breaking
  /// at line boundaries. A single line larger than [maxBytes] is hard-split by
  /// characters (logs are ASCII-dominant, so chars ≈ bytes). Pure — unit
  /// tested directly.
  @visibleForTesting
  static List<String> chunkContent(
    String content, {
    int maxBytes = maxChunkBytes,
  }) {
    final chunks = <String>[];
    final buffer = StringBuffer();
    var bufferBytes = 0;

    void flush() {
      if (bufferBytes == 0) return;
      chunks.add(buffer.toString());
      buffer.clear();
      bufferBytes = 0;
    }

    for (var line in const LineSplitter().convert(content)) {
      var lineBytes = utf8.encode(line).length;
      // Hard-split a pathological single line so a chunk stays near the cap.
      // Splits by chars, so a multi-byte remainder may exceed maxBytes in
      // bytes by a bounded factor — acceptable for ASCII-dominant logs.
      while (lineBytes > maxBytes && line.length > maxBytes) {
        flush();
        chunks.add(line.substring(0, maxBytes));
        line = line.substring(maxBytes);
        lineBytes = utf8.encode(line).length;
      }
      final withNewline = lineBytes + 1;
      if (bufferBytes > 0 && bufferBytes + withNewline > maxBytes) flush();
      buffer.writeln(line);
      bufferBytes += withNewline;
    }
    flush();
    return chunks;
  }
}
