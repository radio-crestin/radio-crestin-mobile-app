import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/appAudioHandler.dart';

void main() {
  group('StreamInfo', () {
    test('exposes the host of a normal https URL', () {
      final info = StreamInfo(
        url: 'https://hls.radiocrestin.ro/playlist.m3u8',
        type: 'HLS',
        attemptIndex: 0,
        totalStreams: 2,
        stationSlug: 'rve',
        stationTitle: 'RVE',
        loadedAt: DateTime(2026, 1, 1),
      );

      expect(info.host, 'hls.radiocrestin.ro');
    });

    test('exposes host without port', () {
      final info = StreamInfo(
        url: 'https://stream.example.com:8443/live',
        type: 'proxied_stream',
        attemptIndex: 1,
        totalStreams: 3,
        stationSlug: 's',
        stationTitle: 'S',
        loadedAt: DateTime.now(),
      );

      expect(info.host, 'stream.example.com');
    });

    test('returns empty host for an authority-less URL string', () {
      // Uri.parse on a plain string succeeds with an empty host — the host
      // getter just forwards that. The fallback only triggers when parse
      // itself throws (extremely rare).
      final info = StreamInfo(
        url: 'not a url at all',
        type: null,
        attemptIndex: 0,
        totalStreams: 1,
        stationSlug: 's',
        stationTitle: 'S',
        loadedAt: DateTime.now(),
      );

      expect(info.host, '');
    });

    test('stores attempt and total counts as provided', () {
      final info = StreamInfo(
        url: 'https://a.example/x',
        type: 'HLS',
        attemptIndex: 2,
        totalStreams: 4,
        stationSlug: 'slug',
        stationTitle: 'Title',
        loadedAt: DateTime(2026, 5, 1, 12),
      );

      expect(info.attemptIndex, 2);
      expect(info.totalStreams, 4);
      expect(info.stationSlug, 'slug');
      expect(info.stationTitle, 'Title');
      expect(info.loadedAt, DateTime(2026, 5, 1, 12));
    });

    test('accepts null stream type', () {
      final info = StreamInfo(
        url: 'https://x.example/s',
        type: null,
        attemptIndex: 0,
        totalStreams: 1,
        stationSlug: 's',
        stationTitle: 'S',
        loadedAt: DateTime.now(),
      );

      expect(info.type, isNull);
    });
  });

  group('StreamEventKind', () {
    test('exposes every diagnostic kind the recorder uses', () {
      // The diagnostic UI and PostHog `stream_*` events both depend on this
      // enum. If a kind is dropped, downstream filters silently break.
      expect(StreamEventKind.values, containsAll([
        StreamEventKind.attempt,
        StreamEventKind.loaded,
        StreamEventKind.failed,
        StreamEventKind.switched,
        StreamEventKind.hlsCompleted,
        StreamEventKind.nonHlsCompleted,
        StreamEventKind.lostIdle,
        StreamEventKind.bufferingStall,
        StreamEventKind.bufferingDrop,
        StreamEventKind.playerError,
      ]));
    });

    test('has stable name strings (used in PostHog properties)', () {
      // These names are persisted as analytics labels; renaming changes
      // historical event filters in PostHog dashboards.
      expect(StreamEventKind.attempt.name, 'attempt');
      expect(StreamEventKind.loaded.name, 'loaded');
      expect(StreamEventKind.failed.name, 'failed');
      expect(StreamEventKind.switched.name, 'switched');
      expect(StreamEventKind.hlsCompleted.name, 'hlsCompleted');
      expect(StreamEventKind.nonHlsCompleted.name, 'nonHlsCompleted');
      expect(StreamEventKind.lostIdle.name, 'lostIdle');
      expect(StreamEventKind.bufferingStall.name, 'bufferingStall');
      expect(StreamEventKind.bufferingDrop.name, 'bufferingDrop');
      expect(StreamEventKind.playerError.name, 'playerError');
    });
  });

  group('StreamEvent', () {
    test('stores timestamp, kind and message verbatim', () {
      final ts = DateTime(2026, 5, 1, 12, 34, 56);
      const message = 'HLS loaded in 138ms';
      final event = StreamEvent(
        timestamp: ts,
        kind: StreamEventKind.loaded,
        message: message,
      );

      expect(event.timestamp, ts);
      expect(event.kind, StreamEventKind.loaded);
      expect(event.message, message);
    });

    test('keeps message bytes-for-bytes (recorder formats the human string)', () {
      final event = StreamEvent(
        timestamp: DateTime(2026, 5, 1),
        kind: StreamEventKind.bufferingDrop,
        message: 'Rebuffer 312ms — buf 50ms ahead at start, end=ready',
      );

      expect(event.message, 'Rebuffer 312ms — buf 50ms ahead at start, end=ready');
    });
  });
}
