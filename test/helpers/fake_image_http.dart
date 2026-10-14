import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transparent PNG [width] pixels wide and 1 high.
///
/// The width tells images apart once decoded: an image decoded to a fixed
/// width (`cacheWidth`) keeps its aspect ratio.
Uint8List _png(int width) {
  final scanline = Uint8List(1 + width * 4); // Filter byte, then RGBA.
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, 1)
    ..setUint8(8, 8) // Bit depth.
    ..setUint8(9, 6); // RGBA.
  return (BytesBuilder()
        ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
        ..add(_chunk('IHDR', header.buffer.asUint8List()))
        ..add(_chunk('IDAT', zlib.encode(scanline)))
        ..add(_chunk('IEND', const [])))
      .toBytes();
}

List<int> _chunk(String type, List<int> data) {
  final typed = [...type.codeUnits, ...data];
  return [
    ...(ByteData(4)..setUint32(0, data.length)).buffer.asUint8List(),
    ...typed,
    ...(ByteData(4)..setUint32(0, _crc32(typed))).buffer.asUint8List(),
  ];
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// How [FakeImageHttpClient] answers a URL.
enum FakeImageAnswer {
  /// Serves a PNG.
  image,

  /// Fails like a dropped network.
  fail,

  /// Never answers, like a request stuck on a weak signal.
  hang,
}

/// The HTTP client network images load through in widget tests.
///
/// Answers each URL as [answers] says, and the others with [fallback]. An
/// image is as many pixels wide as [widths] says (1 by default), so
/// [shownImageWidth] tells which one is on screen.
class FakeImageHttpClient extends Fake implements HttpClient {
  final Map<String, FakeImageAnswer> answers = {};
  final Map<String, int> widths = {};
  FakeImageAnswer fallback = FakeImageAnswer.fail;
  int requests = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requests++;
    final key = url.toString();
    return switch (answers[key] ?? fallback) {
      FakeImageAnswer.image =>
        Future.value(_FakeRequest(_png(widths[key] ?? 1))),
      FakeImageAnswer.fail =>
        Future.error(const SocketException('Network is unreachable')),
      FakeImageAnswer.hang => Completer<HttpClientRequest>().future,
    };
  }
}

class _FakeRequest extends Fake implements HttpClientRequest {
  _FakeRequest(this._body);

  final Uint8List _body;

  @override
  Future<HttpClientResponse> close() async => _ImageResponse(_body);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this._body);

  final Uint8List _body;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _body.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(_body).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// A widget test whose network images load through [client()].
///
/// The client hook is a painting debug variable, which the test framework
/// requires unset before the test body ends.
void testImageWidgets(
  String description,
  FakeImageHttpClient Function() client,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugNetworkImageHttpClientProvider = client;
    try {
      await body(tester);
    } finally {
      debugNetworkImageHttpClientProvider = null;
      PaintingBinding.instance.imageCache.clear();
    }
  });
}

/// An image on screen that has its picture.
final loadedImage = find.byWidgetPredicate(
  (widget) => widget is ExtendedRawImage && widget.image != null,
);

/// The width [FakeImageHttpClient.widths] gave the picture on screen, or
/// null when no image has its picture.
int? shownImageWidth(WidgetTester tester) {
  if (loadedImage.evaluate().isEmpty) return null;
  final image = tester.widget<ExtendedRawImage>(loadedImage.first).image!;
  return (image.width / image.height).round();
}

/// Lets images load until [finder] matches: real time for the I/O and
/// decoding, test time for the loader's retry delays.
Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}
