import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/log_upload_service.dart';

void main() {
  group('LogUploadService.chunkContent', () {
    test('keeps small content as a single chunk', () {
      final chunks = LogUploadService.chunkContent('a\nb\nc\n');
      expect(chunks, hasLength(1));
      expect(chunks.single, 'a\nb\nc\n');
    });

    test('returns no chunks for empty content', () {
      expect(LogUploadService.chunkContent(''), isEmpty);
    });

    test('splits at line boundaries under the byte budget', () {
      // 10 lines of 40 bytes (+newline) with a 100-byte budget → 2 lines fit
      // per chunk (82 bytes), never 3 (123 bytes).
      final line = 'x' * 40;
      final content = List.filled(10, line).join('\n');

      final chunks = LogUploadService.chunkContent(content, maxBytes: 100);

      expect(chunks, hasLength(5));
      for (final chunk in chunks) {
        expect(utf8.encode(chunk).length, lessThanOrEqualTo(100));
        // Chunks contain whole lines only.
        for (final l in const LineSplitter().convert(chunk)) {
          expect(l, line);
        }
      }
    });

    test('reassembled chunks preserve every line in order', () {
      final lines = [for (var i = 0; i < 50; i++) 'line $i ${'y' * 30}'];
      final chunks =
          LogUploadService.chunkContent(lines.join('\n'), maxBytes: 200);

      final reassembled =
          const LineSplitter().convert(chunks.join());
      expect(reassembled, lines);
    });

    test('hard-splits a single oversized line', () {
      final huge = 'z' * 250;
      final chunks = LogUploadService.chunkContent(huge, maxBytes: 100);

      expect(chunks.length, 3);
      expect(chunks[0].length, 100);
      expect(chunks[1].length, 100);
      expect(chunks.join().replaceAll('\n', ''), huge);
    });
  });

  group('LogUploadService.shouldAutoUpload', () {
    const sixHoursMs = 6 * 60 * 60 * 1000;

    test('uploads when never uploaded before', () {
      expect(
        LogUploadService.shouldAutoUpload(lastUploadMs: null, nowMs: 12345),
        isTrue,
      );
    });

    test('skips within the 6h window', () {
      expect(
        LogUploadService.shouldAutoUpload(
          lastUploadMs: 1000,
          nowMs: 1000 + sixHoursMs - 1,
        ),
        isFalse,
      );
    });

    test('uploads once the 6h window has passed', () {
      expect(
        LogUploadService.shouldAutoUpload(
          lastUploadMs: 1000,
          nowMs: 1000 + sixHoursMs,
        ),
        isTrue,
      );
    });
  });
}
