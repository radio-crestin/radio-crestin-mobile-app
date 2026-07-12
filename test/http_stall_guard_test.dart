import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:radio_crestin/utils/http_stall_guard.dart';

/// Inner client that accepts the request but never produces headers —
/// models a backend that holds the socket open silently.
class _NeverRespondsClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// Inner client whose response body emits one chunk and then goes silent.
class _StallingBodyClient extends http.BaseClient {
  final _controller = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _controller.add([1, 2, 3]);
    return http.StreamedResponse(_controller.stream, 200);
  }
}

class _HealthyClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.fromIterable([
        [104, 105],
      ]),
      200,
    );
  }
}

void main() {
  final uri = Uri.parse('https://api.example.com/data');

  group('HttpStallGuard.guard', () {
    test('passes data through unchanged on a healthy stream', () async {
      final source = Stream.fromIterable([
        [1, 2],
        [3],
      ]);
      final chunks = await HttpStallGuard.guard(
        source,
        idleTimeout: const Duration(seconds: 1),
      ).toList();
      expect(chunks, [
        [1, 2],
        [3],
      ]);
    });

    test('errors when the stream goes silent mid-transfer', () async {
      final controller = StreamController<List<int>>();
      controller.add([1]); // one chunk, then silence forever
      final guarded = HttpStallGuard.guard(
        controller.stream,
        idleTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        guarded.toList(),
        throwsA(isA<TimeoutException>()),
      );
      await controller.close();
    });

    test('slow-but-flowing stream survives the idle guard', () async {
      // Chunks every 40ms for ~400ms total — far beyond the 100ms idle
      // bound, but never idle longer than it. Must complete fully.
      final source = Stream<List<int>>.periodic(
        const Duration(milliseconds: 40),
        (i) => [i],
      ).take(10);
      final chunks = await HttpStallGuard.guard(
        source,
        idleTimeout: const Duration(milliseconds: 100),
      ).toList();
      expect(chunks.length, 10);
    });
  });

  group('HttpStallGuard.readBytes', () {
    test('collects a healthy stream into bytes', () async {
      final source = Stream.fromIterable([
        [1, 2],
        [3, 4],
      ]);
      final bytes = await HttpStallGuard.readBytes(source);
      expect(bytes, [1, 2, 3, 4]);
    });

    test('total timeout kills an endless trickle', () async {
      // Emits steadily (so the idle guard never fires) but never finishes.
      final trickle = Stream<List<int>>.periodic(
        const Duration(milliseconds: 20),
        (i) => [i],
      );
      await expectLater(
        HttpStallGuard.readBytes(
          trickle,
          idleTimeout: const Duration(milliseconds: 100),
          totalTimeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('idle stall errors before the total timeout', () async {
      final controller = StreamController<List<int>>();
      controller.add([1]);
      final sw = Stopwatch()..start();
      await expectLater(
        HttpStallGuard.readBytes(
          controller.stream,
          idleTimeout: const Duration(milliseconds: 100),
          totalTimeout: const Duration(seconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'the idle guard, not the 5s total, must fire');
      await controller.close();
    });
  });

  group('TimeoutHttpClient', () {
    test('normal response passes through', () async {
      final client = TimeoutHttpClient(_HealthyClient());
      final response = await client.get(uri);
      expect(response.statusCode, 200);
      expect(response.body, 'hi');
    });

    test('backend that never sends headers → TimeoutException', () async {
      final client = TimeoutHttpClient(
        _NeverRespondsClient(),
        headersTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        client.get(uri),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('body that stalls after headers → TimeoutException', () async {
      final client = TimeoutHttpClient(
        _StallingBodyClient(),
        bodyIdleTimeout: const Duration(milliseconds: 100),
      );
      // http.get buffers the whole body, so the stalled body surfaces as
      // an error on the buffered read.
      await expectLater(
        client.get(uri),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
