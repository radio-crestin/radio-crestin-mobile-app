import 'dart:async';
import 'dart:io' show HttpDate, Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/hls_health_watchdog_flag.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_just_audio_channels.dart';
import 'helpers/fake_metadata_backend.dart';
import 'helpers/hls_fixtures.dart' show playlistText;

/// No song is liked; the handler only reads like states here.
class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

/// A real [AppAudioHandler] and `AudioPlayer` over the faked just_audio
/// channels, playing a station of the Radio Crestin origin: which playlist
/// play() loads at each offset, when it still seeks, and how it falls back
/// while the origin does not publish the start variants yet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const stream = 'https://hls.radiocrestin.ro/hls/rve-suceava/index.m3u8';
  const plainPath = '/hls/rve-suceava/index.m3u8';
  const twoMinutePath = '/hls/rve-suceava/index-2m.m3u8';
  const fiveMinutePath = '/hls/rve-suceava/index-5m.m3u8';
  final mp3 = FakeMetadataBackend.mp3UrlOf('rve-suceava');
  const window = FakeJustAudioChannels.liveWindow;

  late SharedPreferences prefs;
  late FakeMetadataBackend backend;
  late FakeJustAudioChannels channels;
  late StationDataService service;
  late AppAudioHandler handler;
  late http.Client routing;

  /// A live window of 100 six-second segments ending now (the handler's
  /// own playlist poll runs on the device clock).
  String livePlaylist() {
    const count = 100;
    final seq = DateTime.now().millisecondsSinceEpoch ~/ 6000 - count;
    return playlistText(
      mediaSequence: seq,
      count: count,
      firstPdt: DateTime.fromMillisecondsSinceEpoch(seq * 6000, isUtc: true),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    prefs = await SharedPreferences.getInstance();
    await HlsHealthWatchdogFlag.instance.loadCache(prefs);
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<SharedPreferences>(prefs)
      ..registerSingleton<PlayCountService>(PlayCountService())
      ..registerSingleton<SongLikeService>(_NoLikes())
      ..registerSingleton<VideoPlaybackService>(VideoPlaybackService());
    reviewsStatsCache.clear();
    SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
    backend = FakeMetadataBackend(FakeClock(DateTime.utc(2026, 10, 14, 12)))
      ..addStation(1, 'rve-suceava', 'RVE Suceava', hls: true, hlsUrl: stream);
    // The service only accepts a catalog of at least 10 stations.
    for (var id = 2; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    channels = FakeJustAudioChannels()..install();
    routing = MockClient((request) async {
      if (request.url.path.endsWith('.m3u8')) {
        return http.Response(livePlaylist(), 200,
            headers: {'last-modified': HttpDate.format(DateTime.now())});
      }
      return backend.client.get(request.url, headers: request.headers);
    });
    await http.runWithClient(() async {
      service = backend.newService(prefs);
      GetIt.instance.registerSingleton<StationDataService>(service);
      handler = AppAudioHandler(
        graphqlClient: backend.graphqlClient,
        player: AudioPlayer(
          handleInterruptions: false,
          androidApplyAudioAttributes: false,
          handleAudioSessionActivation: false,
        ),
      );
      await service.enqueueSync(SyncReason.startup);
    }, () => routing);
  });

  tearDown(() async {
    await http.runWithClient(() => handler.stop(), () => routing);
    AnalyticsService.instance.endListening();
    service.dispose();
    channels.uninstall();
    SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
    await GetIt.instance.reset();
  });

  Station station() => service.stations.value.firstWhere((s) => s.id == 1);

  /// Waits (real time) until [condition] holds.
  Future<void> until(bool Function() condition,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Waits until the handler made [loads] loads and plays [url].
  Future<void> untilPlaying({required int loads, String url = stream}) =>
      until(() =>
          channels.loads.length == loads &&
          handler.currentStreamInfo.valueOrNull?.url == url &&
          handler.player.playing);

  Uri loaded(int index) => Uri.parse(channels.loads[index]);

  List<String> loadedPaths() =>
      [for (final url in channels.loads) Uri.parse(url).path];

  Iterable<StreamEvent> failedAttempts() => handler.recentStreamEvents.value
      .where((e) => e.kind == StreamEventKind.failed);

  // AVPlayer's behavior (macOS host): EXT-X-START honored, an HTTP error
  // status reported as such, and a reload while playing restarted only by
  // a seek. Elsewhere the handler keeps index.m3u8 and its seek.
  group('start variants', skip: Platform.isMacOS ? false : 'needs macOS', () {
    test(
        '2 minutes behind live: loads index-2m.m3u8 with the tracking '
        'parameters, keeps index.m3u8 as the stream, and does not seek',
        () async {
      await http.runWithClient(() async {
        unawaited(handler.playStation(station()));
        await untilPlaying(loads: 1);

        expect(loaded(0).host, 'hls.radiocrestin.ro');
        expect(loaded(0).path, twoMinutePath);
        expect(loaded(0).queryParameters['ref'], startsWith('radio-crestin-'));
        expect(loaded(0).queryParameters, contains('s'));
        expect(handler.currentStreamInfo.value?.url, stream);
        expect(handler.loadedStreamType, 'HLS');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(channels.seeks, isEmpty,
            reason: 'the player already starts 2 minutes behind live');
      }, () => routing);
    });

    test('5 minutes behind live: loads index-5m.m3u8, no seek', () async {
      SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
      await http.runWithClient(() async {
        unawaited(handler.playStation(station()));
        await untilPlaying(loads: 1);

        expect(loaded(0).path, fiveMinutePath);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(channels.seeks, isEmpty);
      }, () => routing);
    });

    test('instant mode loads index.m3u8 as before', () async {
      SeekModeManager.changeSeekMode(SeekMode.instant);
      await http.runWithClient(() async {
        unawaited(handler.playStation(station()));
        await untilPlaying(loads: 1);

        expect(loadedPaths(), [plainPath]);
        expect(loaded(0).queryParameters, contains('ref'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(channels.seeks, isEmpty);
      }, () => routing);
    });

    test(
        'a 404 on the variant: index.m3u8 at once in the same attempt with '
        'the seek, no failure counted, and index.m3u8 for the rest of the '
        'session', () async {
      channels.failingUrlParts.add('/index-2m.m3u8'); // 404 by default
      await http.runWithClient(() async {
        final errors = <ConnectionError>[];
        final sub = handler.connectionError.listen(errors.add);
        addTearDown(sub.cancel);

        unawaited(handler.playStation(station()));
        await untilPlaying(loads: 2);

        expect(loadedPaths(), [twoMinutePath, plainPath]);
        expect(loaded(1).queryParameters, contains('ref'));
        expect(loaded(1).queryParameters, contains('s'));
        expect(handler.currentStreamInfo.value?.attemptIndex, 0,
            reason: 'no failover to the MP3 stream');
        expect(failedAttempts(), isEmpty);
        await until(() => channels.seeks.isNotEmpty);
        expect(channels.seeks, [window - const Duration(minutes: 2)],
            reason: 'index.m3u8 starts near live: the seek behind it');
        expect(errors, isEmpty);

        // The next load of the stream (a liveness reload) goes straight to
        // index.m3u8.
        handler.debugRecoverFromLiveHlsStall(
            LiveHlsStall.evicted, DateTime.now());
        await untilPlaying(loads: 3);
        expect(loaded(2).path, plainPath);
        expect(failedAttempts(), isEmpty);
      }, () => routing);
    });

    test(
        'any other variant error on Darwin fails the stream over, as '
        'before', () async {
      channels
        ..failingUrlParts.add('/index-2m.m3u8')
        ..failureCode = '0';
      await http.runWithClient(() async {
        unawaited(handler.playStation(station()));
        await untilPlaying(loads: 2, url: mp3);

        expect(loadedPaths().first, twoMinutePath);
        expect(channels.loads.last, startsWith(mp3));
        expect(failedAttempts(), hasLength(1));
      }, () => routing);
    });

    test(
        'the station failing as a whole (a pod restarting: index.m3u8 '
        'errs too) keeps the variant: once it is back, the stream loads '
        'index-2m.m3u8 again', () async {
      channels.failingUrlParts.addAll(
          ['/index-2m.m3u8', '/index.m3u8', Uri.parse(mp3).path]);
      await http.runWithClient(() async {
        unawaited(handler.playStation(station()));
        // The whole first pass fails: the variant, then index.m3u8 in the
        // HLS attempt, then the MP3 stream.
        await until(() => channels.finishedLoads.length == 3);
        expect(loadedPaths(),
            [twoMinutePath, plainPath, Uri.parse(mp3).path]);
        expect(failedAttempts(), hasLength(2));

        // Back before the next pass, after its 1 s backoff.
        channels.failingUrlParts.clear();
        await untilPlaying(loads: 4);
        expect(loaded(3).path, twoMinutePath);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(channels.seeks, isEmpty);
      }, () => routing);
    });

    test(
        'an offset change while playing reloads from the new variant and '
        'still seeks: a Darwin reload while playing restarts only then',
        () async {
      await http.runWithClient(() async {
        unawaited(handler.playStation(station()));
        await untilPlaying(loads: 1);
        expect(channels.seeks, isEmpty);

        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
        await handler.reapplySeekOffset();
        await untilPlaying(loads: 2);

        expect(loaded(1).path, fiveMinutePath);
        await until(() => channels.seeks.isNotEmpty);
        expect(channels.seeks, [window - const Duration(minutes: 5)]);
      }, () => routing);
    });

    test(
        'instant mode coming on while the variant loads: reloads '
        'index.m3u8, which starts at the live point', () async {
      await http.runWithClient(() async {
        final gate = channels.loadGate = Completer<void>();
        unawaited(handler.playStation(station()));
        await until(() => channels.loads.length == 1);

        // As the setting does: the reload it asks for skips a load in
        // flight.
        SeekModeManager.changeSeekMode(SeekMode.instant);
        await handler.reapplySeekOffset();
        channels.loadGate = null;
        gate.complete();
        await untilPlaying(loads: 2);

        expect(loadedPaths(), [twoMinutePath, plainPath]);
        await until(() => channels.seeks.isNotEmpty);
        expect(channels.seeks, [window],
            reason: 'the live point, restarting the reloaded AVPlayer item');
        expect(failedAttempts(), isEmpty);
      }, () => routing);
    });
  });
}
