// fake_async ships with flutter_test; used here to run the 10s initialize
// timeout in virtual time instead of stalling the suite for ten real seconds.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/services/video_quality.dart';
import 'package:video_player/video_player.dart';

import 'helpers/fake_video_player_platform.dart';

/// Unit tests for [VideoPlaybackService] — the video_player wrapper that owns
/// the app's video mode (TV channels + video playlist items).
///
/// The native player is replaced by [FakeVideoPlayerPlatform] so every
/// interesting race is deterministic: an `open()` superseded mid-initialize, an
/// initialize that fails, the preload-then-swap quality change, and the
/// error de-dupe that keeps a sticky `hasError` from re-firing.
///
/// The master-playlist fetch behind the quality picker is real HTTP, served by
/// a loopback [HttpServer] — no injection seam is needed and the production
/// code path (fetch → parse → gate) runs exactly as it does in the app.

/// Master with three distinct resolutions — a real picker.
const _masterThreeVariants = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
v1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
v720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
v360.m3u8
''';

/// Only one variant — nothing worth a picker.
const _masterSingleVariant = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
v720.m3u8
''';

/// Separate audio renditions — pinning a variant would drop audio.
const _masterWithAudioGroups = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",DEFAULT=YES,URI="a.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO="aac"
v1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,AUDIO="aac"
v720.m3u8
''';

/// Long enough for every scheduled fake event + the loopback fetch to land.
Future<void> _settle([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// The quality parse is fire-and-forget; give the loopback round trip room.
Future<void> _settleQualities() => _settle(400);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late FakeVideoPlayerPlatform platform;
  late VideoPlaybackService service;

  final bodies = <String, String>{
    '/master.m3u8': _masterThreeVariants,
    '/single.m3u8': _masterSingleVariant,
    '/audio-groups.m3u8': _masterWithAudioGroups,
    '/plain.txt': 'this is not a playlist',
  };

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  setUpAll(() async {
    // TestWidgetsFlutterBinding stubs every HttpClient with one that answers
    // 400, which would make the master-playlist fetch untestable. Dropping the
    // override restores real sockets — this suite only ever talks to the
    // loopback server below.
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = bodies[request.uri.path];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.write(body);
      }
      await request.response.close();
    });
  });

  tearDownAll(() async => server.close(force: true));

  setUp(() {
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    service = VideoPlaybackService();
  });

  tearDown(() async {
    await service.dispose();
    await platform.shutdown();
  });

  group('open() supersession', () {
    test('a second open() during the first initialize discards the loser '
        'and emits nothing for it', () async {
      // Arrange: media A hangs in initialize, media B initializes normally.
      final a = url('/a.m3u8');
      final b = url('/b.m3u8');
      platform.script(
          a, const FakeMediaScript(behavior: FakeInitBehavior.manual));
      platform.script(b, const FakeMediaScript());

      final errors = <String>[];
      final errorSub = service.errorStream.listen(errors.add);
      final published = <VideoPlayerController?>[];
      final controllerSub = service.controllerStream.listen(published.add);

      // Act: start A, supersede it with B before A can initialize, then let
      // A's initialize finally resolve.
      final firstOpen = service.open(a, autoPlay: false);
      await _settle();
      final idA = platform.idFor(a);
      await service.open(b, autoPlay: false);
      platform.completeInit(idA);
      await firstOpen;
      await _settle();

      // Assert: the loser was torn down, never bound, never announced.
      expect(platform.isDisposed(idA), isTrue,
          reason: 'the superseded controller must be disposed');
      expect(platform.isDisposed(platform.idFor(b)), isFalse);
      expect(service.controller!.playerId, platform.idFor(b));
      expect(errors, isEmpty,
          reason: 'losing a race is not an error the UI should see');
      expect(published, [null, service.controller],
          reason: 'only the winner is published on controllerStream');

      await errorSub.cancel();
      await controllerSub.cancel();
    });

    test('the winner keeps playing when the loser resolves late', () async {
      // Arrange.
      final a = url('/a.m3u8');
      final b = url('/b.m3u8');
      platform.script(
          a, const FakeMediaScript(behavior: FakeInitBehavior.manual));
      final firstOpen = service.open(a, autoPlay: false);
      await _settle();
      await service.open(b, autoPlay: false);
      final winner = service.controller;

      // Act: A finally initializes, long after it lost.
      platform.completeInit(platform.idFor(a));
      await firstOpen;
      await _settle();

      // Assert.
      expect(service.controller, same(winner));
      expect(service.isInitialized, isTrue);
    });
  });

  group('open() initialize timeout', () {
    test(
        'a host that never answers times out, emits an error and stops the '
        'spinner', () {
      // Arrange: a media whose initialize never completes — the live symptom
      // was an infinite spinner with no error and no fallback trigger.
      fakeAsync((async) {
        final media = url('/black-hole.m3u8');
        platform.script(
            media, const FakeMediaScript(behavior: FakeInitBehavior.manual));

        final errors = <String>[];
        final errorSub = service.errorStream.listen(errors.add);
        final buffering = <bool>[];
        final bufferingSub = service.bufferingStream.listen(buffering.add);

        // Act: open and let the clock run past the initialize timeout.
        var returned = false;
        service.open(media, autoPlay: false).then((_) => returned = true);
        async.elapse(VideoPlaybackService.initializeTimeout -
            const Duration(seconds: 1));
        expect(errors, isEmpty, reason: 'still within the grace window');
        expect(returned, isFalse);

        // Past the timeout (plus room for the bounded teardown that follows).
        async.elapse(const Duration(seconds: 5));

        // Assert: open() returned, the UI got a real error, and the "loading"
        // spinner was turned off instead of spinning next to the error.
        expect(returned, isTrue);
        expect(errors, hasLength(1));
        expect(errors.single, contains('TimeoutException'));
        expect(service.controller, isNull);
        // The hung controller's own dispose() cannot finish while its
        // initialize is still pending (video_player awaits it internally) —
        // that is precisely why the teardown is bounded: open() returns and
        // the error reaches the UI regardless.
        expect(buffering, [false, true, false],
            reason: 'seeded false → true while opening → false on timeout');

        errorSub.cancel();
        bufferingSub.cancel();
        async.flushTimers();
      });
    });

    test('a normal open publishes buffering true then the engine value',
        () async {
      // Arrange.
      final media = url('/live.m3u8');
      final buffering = <bool>[];
      final sub = service.bufferingStream.listen(buffering.add);

      // Act.
      await service.open(media, autoPlay: false);
      await _settle();

      // Assert: the surface can show a spinner from the very first frame,
      // and the engine's own (false) value takes over once bound.
      expect(buffering.first, isFalse); // seeded
      expect(buffering[1], isTrue); // open() announced "working on it"
      expect(buffering.last, isFalse);
      await sub.cancel();
    });
  });

  group('open() initialize failure', () {
    test('emits exactly one error and keeps the previous controller',
        () async {
      // Arrange: a healthy media is playing.
      final good = url('/good.m3u8');
      final bad = url('/bad.m3u8');
      await service.open(good, autoPlay: false);
      final previous = service.controller;
      final previousId = platform.idFor(good);

      final errors = <String>[];
      final errorSub = service.errorStream.listen(errors.add);
      final published = <VideoPlayerController?>[];
      final controllerSub = service.controllerStream.listen(published.add);

      // Act: the next media fails to initialize.
      platform.script(
        bad,
        const FakeMediaScript(
          behavior: FakeInitBehavior.fail,
          errorMessage: 'codec not supported',
        ),
      );
      await service.open(bad, autoPlay: false);
      await _settle();

      // Assert: one error, old controller untouched and still rendered.
      expect(errors, hasLength(1));
      expect(errors.single, contains('codec not supported'));
      expect(service.controller, same(previous));
      expect(platform.isDisposed(previousId), isFalse);
      expect(platform.isDisposed(platform.idFor(bad)), isTrue,
          reason: 'the failed controller must not leak');
      expect(published, [previous],
          reason: 'no new controller is announced for a failed open');

      await errorSub.cancel();
      await controllerSub.cancel();
    });

    test('a failing first open leaves no controller at all', () async {
      // Arrange + Act.
      final bad = url('/bad.m3u8');
      platform.script(
          bad, const FakeMediaScript(behavior: FakeInitBehavior.fail));
      final errors = <String>[];
      final sub = service.errorStream.listen(errors.add);
      await service.open(bad, autoPlay: false);
      await _settle();

      // Assert.
      expect(errors, hasLength(1));
      expect(service.controller, isNull);
      expect(service.isInitialized, isFalse);
      await sub.cancel();
    });
  });

  group('player error de-dupe', () {
    test('a repeated identical hasError is reported once', () async {
      // Arrange: a playing media whose value will go erroneous repeatedly
      // (video_player keeps `hasError` sticky on the value).
      final media = url('/live.m3u8');
      await service.open(media, autoPlay: false);
      final id = platform.idFor(media);
      final errors = <String>[];
      final sub = service.errorStream.listen(errors.add);

      // Act: the same failure surfaces three times.
      platform.failInit(id, message: 'network stalled');
      await _settle();
      platform.failInit(id, message: 'network stalled');
      await _settle();
      platform.failInit(id, message: 'network stalled');
      await _settle();

      // Assert.
      expect(errors, ['network stalled']);
      await sub.cancel();
    });

    test('a genuinely different error is reported again', () async {
      // Arrange.
      final media = url('/live.m3u8');
      await service.open(media, autoPlay: false);
      final id = platform.idFor(media);
      final errors = <String>[];
      final sub = service.errorStream.listen(errors.add);

      // Act.
      platform.failInit(id, message: 'first failure');
      await _settle();
      platform.failInit(id, message: 'first failure');
      await _settle();
      platform.failInit(id, message: 'second failure');
      await _settle();

      // Assert.
      expect(errors, ['first failure', 'second failure']);
      await sub.cancel();
    });

    test('a new open() clears the de-dupe memory', () async {
      // Arrange: the same error string on two consecutive medias must be
      // reported for each — they are different playback sessions.
      final first = url('/one.m3u8');
      final second = url('/two.m3u8');
      await service.open(first, autoPlay: false);
      final errors = <String>[];
      final sub = service.errorStream.listen(errors.add);
      platform.failInit(platform.idFor(first), message: 'same text');
      await _settle();

      // Act.
      await service.open(second, autoPlay: false);
      platform.failInit(platform.idFor(second), message: 'same text');
      await _settle();

      // Assert.
      expect(errors, ['same text', 'same text']);
      await sub.cancel();
    });
  });

  group('open() resets per-media state', () {
    test('qualities, selection, first-frame flag and size all reset',
        () async {
      // Arrange: a fully settled media with a populated picker and a pinned
      // quality.
      final master = url('/master.m3u8');
      await service.open(master, autoPlay: false);
      await _settleQualities();
      expect(service.qualities, hasLength(3));
      expect(service.width, 1280);
      expect(service.hasRenderedFrame, isTrue);

      final pinned = service.qualities.first;
      await service.setVideoQuality(pinned);
      expect(service.selectedQuality.id, pinned.id);

      // Act: open a new media that has not initialized yet.
      final next = url('/next.m3u8');
      platform.script(
          next, const FakeMediaScript(behavior: FakeInitBehavior.manual));
      final pending = service.open(next, autoPlay: false);
      await _settle();

      // Assert: every per-media stream is back to its "nothing known" value.
      expect(service.qualities, isEmpty);
      expect(service.selectedQuality, VideoQuality.auto);
      expect(service.hasRenderedFrame, isFalse);
      expect(service.width, isNull);
      expect(service.height, isNull);

      // Cleanup: let the pending open finish.
      platform.completeInit(platform.idFor(next));
      await pending;
    });
  });

  group('hasFrame', () {
    test('true once initialized with real pixel dimensions', () async {
      // Arrange + Act.
      final media = url('/sized.m3u8');
      platform.script(media, const FakeMediaScript(size: Size(1920, 1080)));
      final frames = <bool>[];
      final sub = service.hasFrameStream.listen(frames.add);
      await service.open(media, autoPlay: false);
      await _settle();

      // Assert.
      expect(service.hasRenderedFrame, isTrue);
      expect(service.width, 1920);
      expect(service.height, 1080);
      // Seeded false → reset to false by open() → true on the first frame.
      expect(frames, [false, false, true]);
      await sub.cancel();
    });

    test('stays false for an initialized player reporting a zero size',
        () async {
      // Arrange: audio-only / undecodable content — initialized, but no
      // picture. The handler's watchdog relies on this staying false.
      final media = url('/nosize.m3u8');
      platform.script(media, const FakeMediaScript(size: Size.zero));

      // Act.
      await service.open(media, autoPlay: false);
      await _settle();

      // Assert.
      expect(service.isInitialized, isTrue,
          reason: 'a controller exists — it just never produced a frame');
      expect(service.hasRenderedFrame, isFalse);
      expect(service.width, isNull);
      expect(service.height, isNull);
    });
  });

  group('play intent vs engine rate', () {
    test(
        'a rebuffer that drops the native rate does NOT report "not playing" '
        '(the transport button stayed on "play" while TV was audible)',
        () async {
      // Arrange: a live channel playing.
      final media = url('/live.m3u8');
      platform.script(media, const FakeMediaScript());
      final playing = <bool>[];
      final sub = service.playingStream.listen(playing.add);
      await service.open(media); // autoPlay
      await _settle();
      expect(service.isPlaying, isTrue);

      // Act: the AVFoundation plugin reports `rate > 0 == false` on every
      // rebuffer / "waiting to play" phase — the exact event that used to flip
      // playbackState.playing to false mid-stream.
      platform.emit(
        platform.idFor(media),
        VideoEvent(eventType: VideoEventType.isPlayingStateUpdate,
            isPlaying: false),
      );
      await _settle();

      // Assert: the intent (what the UI shows) is untouched; only the raw
      // engine flag follows the rate.
      expect(service.isPlaying, isTrue);
      expect(service.engineIsPlaying, isFalse);
      expect(playing, [false, true],
          reason: 'no spurious false on the user-facing stream');
      await sub.cancel();
    });

    test('play / pause / stop drive the intent and emit once per change',
        () async {
      // Arrange.
      final media = url('/vod.m3u8');
      platform.script(media, const FakeMediaScript());
      final playing = <bool>[];
      final sub = service.playingStream.listen(playing.add);
      await service.open(media, autoPlay: false);
      await _settle();

      // Act.
      await service.play();
      await service.play(); // idempotent
      await service.pause();
      await service.play();
      await service.stop();
      await _settle();

      // Assert.
      expect(service.isPlaying, isFalse);
      expect(playing, [false, true, false, true, false]);
      await sub.cancel();
    });

    test('a failed load clears the intent so the button never shows "pause"',
        () async {
      // Arrange: a media whose initialize fails.
      final media = url('/broken.m3u8');
      platform.script(
          media, const FakeMediaScript(behavior: FakeInitBehavior.fail));

      // Act.
      await service.open(media); // autoPlay: true
      await _settle();

      // Assert.
      expect(service.isPlaying, isFalse);
    });

    test('reaching the end of a VOD item clears the intent', () async {
      // Arrange.
      final media = url('/vod.m3u8');
      platform.script(media, const FakeMediaScript());
      await service.open(media);
      await _settle();
      expect(service.isPlaying, isTrue);

      // Act.
      platform.emit(platform.idFor(media),
          VideoEvent(eventType: VideoEventType.completed));
      await _settle();

      // Assert.
      expect(service.isPlaying, isFalse);
    });
  });

  group('setVideoQuality preload-then-swap', () {
    late String master;
    late VideoQuality pinned;

    setUp(() async {
      master = url('/master.m3u8');
      await service.open(master, autoPlay: false);
      await _settleQualities();
      pinned = service.qualities.first; // 1080p variant
    });

    test('the old controller keeps rendering until the new one is ready',
        () async {
      // Arrange: the variant hangs in initialize.
      platform.script(
        pinned.url!,
        const FakeMediaScript(behavior: FakeInitBehavior.manual),
      );
      final oldId = platform.idFor(master);

      // Act: start the swap but leave the preload pending.
      final swap = service.setVideoQuality(pinned);
      await _settle();

      // Assert: nothing swapped yet — no black frame, no early selection.
      expect(service.controller!.playerId, oldId);
      expect(service.selectedQuality, VideoQuality.auto);
      expect(platform.isDisposed(oldId), isFalse);

      // Act: the preload finishes.
      platform.completeInit(platform.idFor(pinned.url!));
      await swap;

      // Assert: atomic hand-over.
      expect(service.controller!.playerId, platform.idFor(pinned.url!));
      expect(service.selectedQuality.id, pinned.id);
      expect(platform.isDisposed(oldId), isTrue);
    });

    test('the preload is muted first and unmuted only after the swap',
        () async {
      // Arrange + Act.
      await service.setVideoQuality(pinned);
      await _settle();

      // Assert: the new player never had audible volume while the old one was
      // still playing (that overlap would be double audio).
      final newId = platform.idFor(pinned.url!);
      final applied = platform.volumesFor(newId);
      expect(applied.first, 0.0);
      expect(applied.last, 1.0);
    });

    test('a VOD swap resumes at the old controller position', () async {
      // Arrange: 30s into the item.
      await service.seek(const Duration(seconds: 30));
      await _settle();

      // Act.
      await service.setVideoQuality(pinned);
      await _settle();

      // Assert.
      final newId = platform.idFor(pinned.url!);
      expect(
        platform.seeks
            .where((e) => e.key == newId)
            .map((e) => e.value)
            .toList(),
        contains(const Duration(seconds: 30)),
      );
    });

    test('a failed preload leaves the old controller and selection untouched',
        () async {
      // Arrange.
      platform.script(
        pinned.url!,
        const FakeMediaScript(behavior: FakeInitBehavior.fail),
      );
      final oldId = platform.idFor(master);
      final oldController = service.controller;
      final errors = <String>[];
      final sub = service.errorStream.listen(errors.add);

      // Act.
      await service.setVideoQuality(pinned);
      await _settle();

      // Assert: the user keeps watching; only the picker request was dropped.
      expect(service.controller, same(oldController));
      expect(platform.isDisposed(oldId), isFalse);
      expect(platform.isDisposed(platform.idFor(pinned.url!)), isTrue);
      expect(service.selectedQuality, VideoQuality.auto);
      expect(errors, isEmpty,
          reason: 'a rejected quality switch is not a playback error');
      await sub.cancel();
    });

    test('re-selecting the already selected quality is a no-op', () async {
      // Arrange + Act.
      final createdBefore = platform.created.length;
      await service.setVideoQuality(VideoQuality.auto);

      // Assert.
      expect(platform.created.length, createdBefore);
      expect(service.selectedQuality, VideoQuality.auto);
    });
  });

  group('quality parsing gates (_loadQualities)', () {
    test('a master with several resolutions populates the picker', () async {
      // Arrange + Act.
      await service.open(url('/master.m3u8'), autoPlay: false);
      await _settleQualities();

      // Assert: highest first, de-duped, Auto excluded.
      expect(service.qualities.map((q) => q.label).toList(),
          ['1080p', '720p', '360p']);
    });

    test('a non-HLS body publishes nothing', () async {
      // Arrange + Act.
      await service.open(url('/plain.txt'), autoPlay: false);
      await _settleQualities();

      // Assert.
      expect(service.qualities, isEmpty);
    });

    test('a master with separate audio groups publishes nothing (Auto only)',
        () async {
      // Arrange + Act: pinning a variant here would drop the audio track.
      await service.open(url('/audio-groups.m3u8'), autoPlay: false);
      await _settleQualities();

      // Assert.
      expect(service.qualities, isEmpty);
    });

    test('a master with fewer than two variants publishes nothing', () async {
      // Arrange + Act.
      await service.open(url('/single.m3u8'), autoPlay: false);
      await _settleQualities();

      // Assert.
      expect(service.qualities, isEmpty);
    });

    test('a non-200 response publishes nothing', () async {
      // Arrange + Act: the loopback server 404s unknown paths.
      await service.open(url('/missing.m3u8'), autoPlay: false);
      await _settleQualities();

      // Assert.
      expect(service.qualities, isEmpty);
    });
  });

  group('dispose', () {
    test('tears down the native controller and closes every stream', () async {
      // Arrange.
      final media = url('/live.m3u8');
      await service.open(media, autoPlay: false);
      final id = platform.idFor(media);

      // Act.
      await service.dispose();

      // Assert: native resources released…
      expect(platform.isDisposed(id), isTrue);
      expect(service.controller, isNull);
      expect(service.isInitialized, isFalse);

      // …and every subject is closed (a leaked subject would keep the UI
      // subscribed to a dead engine).
      await expectLater(service.errorStream, emitsDone);
      await expectLater(service.positionStream, emitsThrough(emitsDone));
      await expectLater(service.durationStream, emitsThrough(emitsDone));
      await expectLater(service.bufferingStream, emitsThrough(emitsDone));
      await expectLater(service.playingStream, emitsThrough(emitsDone));
      await expectLater(service.completedStream, emitsThrough(emitsDone));
      await expectLater(service.controllerStream, emitsThrough(emitsDone));
      await expectLater(service.hasFrameStream, emitsThrough(emitsDone));
      await expectLater(service.widthStream, emitsThrough(emitsDone));
      await expectLater(service.heightStream, emitsThrough(emitsDone));
      await expectLater(service.qualitiesStream, emitsThrough(emitsDone));
      await expectLater(service.selectedQualityStream, emitsThrough(emitsDone));
    });

    test('disposing an untouched service does not throw', () async {
      // Arrange: a service that never opened anything.
      final fresh = VideoPlaybackService();

      // Act + Assert.
      await expectLater(fresh.dispose(), completes);
    });
  });
}
