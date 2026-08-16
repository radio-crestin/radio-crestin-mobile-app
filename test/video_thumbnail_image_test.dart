import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/video_thumbnail_image.dart';

/// Tests for [VideoThumbnailImage] and the process-wide first-frame cache
/// behind it.
///
/// Video playlist rows without a `thumbnail_url` each ask the native decoder
/// for a first frame. A long list must not turn that into a stampede, so the
/// cache guarantees three things: one decode per URL no matter how many rows
/// want it, at most three decodes in flight, and a failure remembered so a dead
/// URL is never retried for the rest of the session.
///
/// The native side is faked at the method channel, and each test uses its own
/// URLs because the cache is deliberately process-wide (a real `static`
/// singleton shared by every row in the app).

const _channel =
    MethodChannel('world.nailao.flutter.plugin/video_thumbnail_plus');

/// A valid 1x1 PNG — real bytes so `Image.memory` decodes instead of falling
/// through to its error builder.
final _redPixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A second, visibly different 1x1 PNG.
final _bluePixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwAD'
  'hgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every `video` argument the native side was asked for, in order.
  late List<String> nativeCalls;

  /// url → bytes returned immediately.
  late Map<String, Uint8List> replies;

  /// url → a decode the test completes by hand (for the concurrency gate).
  late Map<String, Completer<Uint8List?>> pending;

  setUp(() {
    nativeCalls = [];
    replies = {};
    pending = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final url = (call.arguments as Map)['video'] as String;
      nativeCalls.add(url);
      final held = pending[url];
      if (held != null) return held.future;
      final reply = replies[url];
      if (reply == null) {
        throw PlatformException(code: 'decode', message: 'no frame');
      }
      return reply;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Widget host(List<Widget> children) => MaterialApp(
        home: Scaffold(body: Column(children: children)),
      );

  Widget thumbnail(String url) => SizedBox(
        width: 70,
        height: 70,
        child: VideoThumbnailImage(
          videoUrl: url,
          placeholder: const ColoredBox(
            color: Colors.grey,
            child: SizedBox.expand(),
          ),
        ),
      );

  Uint8List? shownBytes(WidgetTester tester, {int at = 0}) {
    final images = find.byType(Image);
    if (images.evaluate().isEmpty) return null;
    final image = tester.widgetList<Image>(images).elementAt(at);
    return (image.image as MemoryImage).bytes;
  }

  group('per-URL de-duplication', () {
    testWidgets('two rows sharing a URL trigger a single native decode',
        (tester) async {
      // Arrange: one URL, two rows mounted in the same frame.
      const url = 'https://cdn.test/dedupe.mp4';
      replies[url] = _redPixel;

      // Act.
      await tester.pumpWidget(host([thumbnail(url), thumbnail(url)]));
      await tester.pump(); // post-frame resolve
      await tester.pump(); // channel reply

      // Assert: one decode, both rows upgraded to the frame.
      expect(nativeCalls, [url]);
      expect(find.byType(Image), findsNWidgets(2));
      expect(shownBytes(tester), _redPixel);
      expect(shownBytes(tester, at: 1), _redPixel);
    });

    testWidgets('a later row for a cached URL reuses the memoized bytes',
        (tester) async {
      // Arrange: first row warms the cache.
      const url = 'https://cdn.test/warm.mp4';
      replies[url] = _redPixel;
      await tester.pumpWidget(host([thumbnail(url)]));
      await tester.pump();
      await tester.pump();
      expect(nativeCalls, hasLength(1));

      // Act: a second, independently mounted row asks for the same URL.
      await tester.pumpWidget(host([thumbnail(url), thumbnail(url)]));
      await tester.pump();
      await tester.pump();

      // Assert: still exactly one native decode for this URL.
      expect(nativeCalls, [url]);
      expect(shownBytes(tester), _redPixel);
    });
  });

  group('failures are memoized (no retry this session)', () {
    testWidgets('a failed decode falls back to the placeholder and is never '
        'retried', (tester) async {
      // Arrange: the native side cannot produce a frame for this URL.
      const url = 'https://cdn.test/broken.mp4';

      // Act: mount, let it fail, then mount fresh rows for the same URL.
      await tester.pumpWidget(host([thumbnail(url)]));
      await tester.pump();
      await tester.pump();
      final callsAfterFailure = nativeCalls.length;

      await tester.pumpWidget(host([thumbnail(url), thumbnail(url)]));
      await tester.pump();
      await tester.pump();

      // Assert: the placeholder stays, and the dead URL is asked for exactly
      // once for the whole session.
      expect(callsAfterFailure, 1);
      expect(nativeCalls, [url]);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('URL changes', () {
    testWidgets('didUpdateWidget swaps the bytes for the new URL',
        (tester) async {
      // Arrange: a row showing its first frame.
      const first = 'https://cdn.test/swap-a.mp4';
      const second = 'https://cdn.test/swap-b.mp4';
      replies[first] = _redPixel;
      replies[second] = _bluePixel;
      await tester.pumpWidget(host([thumbnail(first)]));
      await tester.pump();
      await tester.pump();
      expect(shownBytes(tester), _redPixel);

      // Act: the same row is reused for a different item.
      await tester.pumpWidget(host([thumbnail(second)]));
      await tester.pump();
      await tester.pump();

      // Assert: the stale frame is gone, the new one is shown.
      expect(shownBytes(tester), _bluePixel);
      expect(nativeCalls, [first, second]);
    });

    testWidgets('an unchanged URL does not re-decode on rebuild',
        (tester) async {
      // Arrange.
      const url = 'https://cdn.test/stable.mp4';
      replies[url] = _redPixel;
      await tester.pumpWidget(host([thumbnail(url)]));
      await tester.pump();
      await tester.pump();

      // Act: rebuild with identical parameters.
      await tester.pumpWidget(host([thumbnail(url)]));
      await tester.pump();
      await tester.pump();

      // Assert.
      expect(nativeCalls, [url]);
    });
  });

  group('concurrency gate', () {
    testWidgets('at most three native decodes run at once', (tester) async {
      // Arrange: five distinct URLs, every decode held open by the test.
      final urls = List.generate(5, (i) => 'https://cdn.test/gate-$i.mp4');
      for (final url in urls) {
        pending[url] = Completer<Uint8List?>();
      }

      // Act: mount all five rows in one frame.
      await tester.pumpWidget(host(urls.map(thumbnail).toList()));
      await tester.pump();
      await tester.pump();

      // Assert: the queue is throttled to three in flight.
      expect(nativeCalls, hasLength(3));
      expect(nativeCalls.toSet(), urls.take(3).toSet());

      // Act: release one slot.
      pending[urls[0]]!.complete(_redPixel);
      await tester.pump();
      await tester.pump();

      // Assert: exactly one queued decode was admitted.
      expect(nativeCalls, hasLength(4));

      // Cleanup: drain the rest so the shared gate is left empty for other
      // tests (the cache is process-wide by design).
      for (var i = 1; i < urls.length; i++) {
        if (!pending[urls[i]]!.isCompleted) {
          pending[urls[i]]!.complete(_redPixel);
        }
        await tester.pump();
        await tester.pump();
      }
      expect(nativeCalls, hasLength(5));
    });
  });
}
