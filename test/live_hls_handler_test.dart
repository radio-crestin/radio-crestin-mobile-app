import 'dart:async';
import 'dart:io' show HttpDate, InternetAddress, ServerSocket, SocketException;

import 'package:flutter/widgets.dart' show AppLifecycleState;
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
import 'package:radio_crestin/services/hls_hold_proxy_flag.dart';
import 'package:radio_crestin/services/hls_timeline.dart' show SongBoundaryHint;
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/private_stations_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_connectivity.dart';
import 'helpers/fake_just_audio_channels.dart';
import 'helpers/fake_metadata_backend.dart';
import 'helpers/hls_fixtures.dart' show playlistText;

/// No song is liked; the handler only reads like states here.
class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

/// Records every `refreshMetadataNow` call (the boundary, null for the
/// anchored refresh) before running it.
class _RecordingService extends StationDataService {
  _RecordingService({
    required super.graphqlClient,
    super.privateStationsService,
    super.httpClient,
    super.clock,
    super.wait,
  });

  final List<DateTime?> refreshes = [];

  @override
  Future<void> refreshMetadataNow({
    DateTime? boundary,
    SongBoundaryHint? hint,
  }) {
    refreshes.add(boundary);
    return super.refreshMetadataNow(boundary: boundary, hint: hint);
  }
}

/// A client that, like the platform client, refuses requests once closed.
class _ClosableClient extends http.BaseClient {
  _ClosableClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) {
      throw http.ClientException('Client is already closed.', request.url);
    }
    return _inner.send(request);
  }

  @override
  void close() => closed = true;
}

/// A real [AppAudioHandler] and `AudioPlayer` over the faked just_audio
/// channels, the fake metadata backend and a live playlist: the wiring
/// around the live-HLS watchdog, station switches and stream signals.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 10, 11, 12);
  DateTime t(num seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));

  late SharedPreferences prefs;
  late FakeClock clock;
  late FakeMetadataBackend backend;
  late FakeJustAudioChannels channels;
  late StationDataService service;
  late AppAudioHandler handler;
  late http.Client routing;

  /// Extra playlist header lines (song boundary tags).
  var playlistHeader = <String>[];

  /// The next this many playlist requests answer 503.
  var failingPlaylistRequests = 0;

  /// A live window of 100 six-second segments ending now (real time: the
  /// handler's timeline runs on the device clock).
  String livePlaylist() {
    final now = DateTime.now().toUtc();
    const count = 100;
    final seq = now.millisecondsSinceEpoch ~/ 6000 - count;
    return playlistText(
      mediaSequence: seq,
      count: count,
      firstPdt: DateTime.fromMillisecondsSinceEpoch(seq * 6000, isUtc: true),
      header: playlistHeader,
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
    clock = FakeClock(t0);
    backend = FakeMetadataBackend(clock)
      ..addStation(1, 'rve-suceava', 'RVE Suceava', hls: true);
    for (var id = 2; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    backend.songChange(1, t(-300), const FakeSong(11, 'Song X', artist: 'AX'));
    backend.songChange(1, t(-60), const FakeSong(12, 'Song Y', artist: 'AY'));
    backend.songChange(2, t(-200), const FakeSong(21, 'Song P'));
    channels = FakeJustAudioChannels()..install();
    playlistHeader = [];
    failingPlaylistRequests = 0;
    // Playlists are served live; everything else goes to the backend.
    routing = MockClient((request) async {
      if (request.url.path.endsWith('.m3u8')) {
        if (failingPlaylistRequests > 0) {
          failingPlaylistRequests--;
          return http.Response('unavailable', 503);
        }
        return http.Response(livePlaylist(), 200,
            headers: {'last-modified': HttpDate.format(DateTime.now())});
      }
      return backend.client.get(request.url, headers: request.headers);
    });
  });

  tearDown(() async {
    await http.runWithClient(() => handler.stop(), () => routing);
    AnalyticsService.instance.endListening();
    service.dispose();
    channels.uninstall();
    await GetIt.instance.reset();
  });

  /// Registers [s] (default: the backend's service), builds the handler and
  /// runs the startup sync.
  Future<void> startHandler({StationDataService? s}) async {
    service = s ?? backend.newService(prefs);
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
  }

  Station stationOf(int id) =>
      service.stations.value.firstWhere((s) => s.id == id);

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

  /// Waits until the handler finished a load and is playing [url].
  Future<void> untilPlaying(String url, {required int loads}) => until(() =>
      channels.loads.length == loads &&
      handler.currentStreamInfo.valueOrNull?.url == url &&
      handler.player.playing);

  group('live-HLS liveness watchdog (Darwin)', () {
    final hlsUrl = FakeMetadataBackend.hlsUrlOf('rve-suceava');
    final mp3Url = FakeMetadataBackend.mp3UrlOf('rve-suceava');

    test(
        'a liveness reload while playing re-arms the watchdog, so a second '
        'fire fails the stream over (review R1.3)', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(hlsUrl, loads: 1);
        expect(handler.isLiveHlsWatchdogRunning, isTrue);

        // First fire: reload the same stream, no failure recorded. The
        // player keeps `playing` through the reload (no playing flip).
        final firstFire = DateTime.now();
        handler.debugRecoverFromLiveHlsStall(
            LiveHlsStall.pastLiveEdge, firstFire);
        await untilPlaying(hlsUrl, loads: 2);
        expect(channels.loads.last, contains('/index.m3u8'));
        expect(handler.isLiveHlsWatchdogRunning, isTrue,
            reason: 'armed for the reloaded stream');

        // Second fire within the repeat window: fail over to the MP3.
        handler.debugRecoverFromLiveHlsStall(LiveHlsStall.pastLiveEdge,
            firstFire.add(const Duration(seconds: 60)));
        await untilPlaying(mp3Url, loads: 3);
        expect(handler.loadedStreamType, isNot('HLS'));
        expect(handler.isLiveHlsWatchdogRunning, isFalse,
            reason: 'no watchdog on a direct stream');
      }, () => routing);
    });

    test(
        'turning the remote kill switch off stops a running watchdog at its '
        'next tick', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(hlsUrl, loads: 1);
        expect(handler.isLiveHlsWatchdogRunning, isTrue);

        await prefs.setBool('hls_health_watchdog_enabled', false);
        await HlsHealthWatchdogFlag.instance.loadCache(prefs);

        await until(() => !handler.isLiveHlsWatchdogRunning,
            timeout: ReconnectPolicy.liveHlsWatchdogInterval +
                const Duration(seconds: 2));
        expect(handler.player.playing, isTrue, reason: 'playback untouched');
      }, () => routing);
    });

    test(
        'in instant mode a reload while playing seeks to the live point, '
        'the only thing that restarts a reloaded AVPlayer item', () async {
      SeekModeManager.changeSeekMode(SeekMode.instant);
      addTearDown(() => SeekModeManager.changeSeekMode(SeekMode.twoMinutes));
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(hlsUrl, loads: 1);
        expect(channels.seeks, isEmpty,
            reason: 'a fresh start sends play() itself; no seek needed');

        // The same reload a liveness fire or an offset change makes.
        handler.debugRecoverFromLiveHlsStall(
            LiveHlsStall.pastLiveEdge, DateTime.now());
        await untilPlaying(hlsUrl, loads: 2);
        await until(() => channels.seeks.isNotEmpty);

        expect(channels.seeks, [FakeJustAudioChannels.liveWindow],
            reason: 'the live point: where the item starts anyway');
      }, () => routing);
    });
  });

  group('live HLS after an outage (Darwin)', () {
    final hlsUrl = FakeMetadataBackend.hlsUrlOf('rve-suceava');

    /// Plays station 1 with [buffered] loaded, then loses the internet.
    Future<void> playThenLoseInternet(Duration buffered) async {
      await startHandler();
      unawaited(handler.playStation(stationOf(1)));
      await untilPlaying(hlsUrl, loads: 1);
      channels.emitBufferedPosition(buffered);
      await pumpEventQueue();
      NetworkService.instance.isOffline.add(true);
      await pumpEventQueue();
    }

    /// The internet answers again; the check runs as after [outage].
    Future<void> restoreAfter(Duration outage) async {
      NetworkService.instance.isOffline.add(false);
      await pumpEventQueue();
      final now = DateTime.now();
      handler.debugCheckLoadingAfterOutage(now.subtract(outage), now);
    }

    test(
        'a player that loaded nothing since is reloaded at the listening '
        'offset, before it plays its buffer out and restarts at the live '
        'point', () async {
      await http.runWithClient(() async {
        await playThenLoseInternet(const Duration(minutes: 9));
        await restoreAfter(const Duration(seconds: 60));

        await untilPlaying(hlsUrl, loads: 2);
        expect(channels.loads.last, contains('/index.m3u8'));
        expect(handler.loadedStreamType, 'HLS', reason: 'no failover');
      }, () => routing);
    });

    test('a player that loads again by itself is left alone', () async {
      await http.runWithClient(() async {
        await playThenLoseInternet(const Duration(minutes: 9));
        // AVPlayer loads the segments it missed as soon as it can.
        channels.emitBufferedPosition(const Duration(minutes: 9, seconds: 42));
        await pumpEventQueue();
        await restoreAfter(const Duration(seconds: 60));
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(channels.loads, hasLength(1));
        expect(handler.player.playing, isTrue);
      }, () => routing);
    });

    test(
        'what counts is a load since the network last dropped: one during '
        'a blip before it does not vouch for the player', () async {
      await http.runWithClient(() async {
        await playThenLoseInternet(const Duration(minutes: 9));
        NetworkService.instance.isOffline.add(false);
        channels.emitBufferedPosition(const Duration(minutes: 9, seconds: 42));
        await pumpEventQueue();
        NetworkService.instance.isOffline.add(true);
        await pumpEventQueue();
        await restoreAfter(const Duration(minutes: 3));

        await untilPlaying(hlsUrl, loads: 2);
      }, () => routing);
    });

    test('a stream the listener paused is left alone', () async {
      await http.runWithClient(() async {
        await playThenLoseInternet(const Duration(minutes: 9));
        await handler.pause();
        await restoreAfter(const Duration(seconds: 60));
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(channels.loads, hasLength(1));
        expect(handler.player.playing, isFalse);
      }, () => routing);
    });

    test('the liveness kill switch turns it off too', () async {
      await http.runWithClient(() async {
        await prefs.setBool('hls_health_watchdog_enabled', false);
        await HlsHealthWatchdogFlag.instance.loadCache(prefs);
        addTearDown(() async {
          await prefs.setBool('hls_health_watchdog_enabled', true);
          await HlsHealthWatchdogFlag.instance.loadCache(prefs);
        });
        await playThenLoseInternet(const Duration(minutes: 9));
        await restoreAfter(const Duration(seconds: 60));
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(channels.loads, hasLength(1));
      }, () => routing);
    });
  });

  group('hold proxy (iOS)', () {
    const originUrl = 'https://hls.radiocrestin.ro/hls/rve-origin/index.m3u8';

    setUp(() async {
      AppAudioHandler.holdProxyPlatform = true;
      await HlsHoldProxyFlag.instance.loadCache(prefs);
      backend.addStation(11, 'rve-origin', 'RVE Origin',
          hls: true, hlsUrl: originUrl);
    });

    tearDown(() async {
      AppAudioHandler.holdProxyPlatform = false;
      await handler.debugHoldProxy?.stop();
    });

    test(
        'a live HLS load of the origin plays through the proxy, while the '
        'app keeps the stream\'s own URL', () async {
      final polled = <Uri>[];
      final recording = MockClient((request) async {
        polled.add(request.url);
        return http.Response.fromStream(await routing.send(request));
      });
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 1);

        final proxy = handler.debugHoldProxy!;
        final loaded = Uri.parse(channels.loads.single);
        expect(loaded.origin, 'http://127.0.0.1:${proxy.port}');
        expect(loaded.path,
            '/${proxy.session}/https/hls.radiocrestin.ro/hls/rve-origin/'
            'index-2m.m3u8',
            reason: 'the start variant, through the proxy');
        expect(loaded.queryParameters['ref'], startsWith('radio-crestin-'),
            reason: 'listeners are counted from the tracking parameters');
        expect(loaded.queryParameters, contains('s'));
        expect(proxy.serves(loaded.toString()), isTrue);
        expect(handler.currentStreamInfo.value!.url, originUrl);
        expect(handler.loadedStreamType, 'HLS');
        await until(() => polled.any((u) => u.path.endsWith('.m3u8')));
        expect(
            polled.where((u) => u.path.endsWith('.m3u8')).map((u) => '$u'),
            everyElement(originUrl),
            reason: 'the app polls the stream itself, not the proxy');
      }, () => recording);
    });

    test('every load is a session of its own', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 1);

        handler.debugRecoverFromLiveHlsStall(
            LiveHlsStall.pastLiveEdge, DateTime.now());
        await untilPlaying(originUrl, loads: 2);

        final sessions =
            channels.loads.map((u) => Uri.parse(u).pathSegments.first);
        expect(sessions.toSet(), hasLength(2));
        expect(sessions.last, '${handler.debugHoldProxy!.session}');
      }, () => routing);
    });

    test('with the remote kill switch off the player loads the stream itself',
        () async {
      await prefs.setBool('hls_hold_proxy_enabled', false);
      await HlsHoldProxyFlag.instance.loadCache(prefs);
      addTearDown(() async {
        await prefs.setBool('hls_hold_proxy_enabled', true);
        await HlsHoldProxyFlag.instance.loadCache(prefs);
      });
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 1);

        expect(channels.loads.single,
            startsWith('https://hls.radiocrestin.ro/hls/rve-origin/'
                'index-2m.m3u8?'));
        expect(handler.debugHoldProxy, isNull);
      }, () => routing);
    });

    test('direct streams and HLS of other hosts load directly', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(FakeMetadataBackend.mp3UrlOf('s2'), loads: 1);
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(FakeMetadataBackend.hlsUrlOf('rve-suceava'),
            loads: 2);

        expect(channels.loads[0],
            startsWith('${FakeMetadataBackend.mp3UrlOf('s2')}?'));
        expect(channels.loads[1],
            startsWith('${FakeMetadataBackend.hlsUrlOf('rve-suceava')}?'));
        expect(handler.debugHoldProxy, isNull);
      }, () => routing);
    });

    test(
        'a start variant the origin answers 404 for falls back to the '
        'stream\'s own playlist, through the proxy in a new session',
        () async {
      // AVPlayer's HTTP 404, relayed by the proxy as the origin sent it.
      channels
        ..failingUrlParts.add('index-2m.m3u8')
        ..failureCode = '-1100';
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 2);

        final variant = Uri.parse(channels.loads[0]);
        final fallback = Uri.parse(channels.loads[1]);
        expect(variant.path, endsWith('/rve-origin/index-2m.m3u8'));
        expect(fallback.path,
            '/${handler.debugHoldProxy!.session}/https/hls.radiocrestin.ro/'
            'hls/rve-origin/index.m3u8');
        expect(fallback.pathSegments.first,
            isNot(variant.pathSegments.first));
        expect(variant.host, '127.0.0.1',
            reason: 'a status is the origin answering through the proxy: '
                'never loaded directly for it');
        expect(handler.loadedStreamType, 'HLS', reason: 'no failover');
      }, () => routing);
    });

    test(
        'a load through the proxy that fails before the origin answered '
        'loads directly at once, and the stream skips the proxy from then '
        'on', () async {
      // AVPlayer's connection closed without a response: nothing got
      // through the proxy (a network that requires an HTTP proxy, say).
      channels
        ..failingUrlParts.add('127.0.0.1')
        ..failureCode = '-1005';
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 2);

        expect(Uri.parse(channels.loads[0]).host, '127.0.0.1');
        expect(
            channels.loads[1],
            startsWith('https://hls.radiocrestin.ro/hls/rve-origin/'
                'index-2m.m3u8?'),
            reason: 'the same start variant, directly');
        expect(handler.loadedStreamType, 'HLS', reason: 'no failover');

        handler.debugRecoverFromLiveHlsStall(
            LiveHlsStall.pastLiveEdge, DateTime.now());
        await untilPlaying(originUrl, loads: 3);
        expect(channels.loads[2], startsWith('https://hls.radiocrestin.ro/'),
            reason: 'the stream skips the proxy from then on');

        // On another network the proxy may work again: it is tried again.
        final network = NetworkService.instance;
        addTearDown(() => network.isOnMobileData.add(false));
        network.isOnMobileData.add(true);
        await pumpEventQueue();
        handler.debugRecoverFromLiveHlsStall(LiveHlsStall.pastLiveEdge,
            DateTime.now().add(const Duration(hours: 1)));
        await untilPlaying(originUrl, loads: 5);
        expect(Uri.parse(channels.loads[3]).host, '127.0.0.1');
        expect(channels.loads[4], startsWith('https://hls.radiocrestin.ro/'));
      }, () => routing);
    });

    test(
        'without any network, a load through the proxy that fails is not '
        'loaded directly, nor taken for a missing start variant', () async {
      // NetworkService as main() sets it up, on a network that goes away.
      final connectivity = FakeConnectivity(wifi);
      final network = NetworkService(
        connectivity: connectivity,
        httpClient: MockClient(
            (_) async => throw const SocketException('No route to host')),
        probes: [
          InternetProbe(Uri.parse('https://probe.example/generate_204'),
              (response) => response.statusCode == 204),
        ],
        probeTimeout: const Duration(milliseconds: 200),
      );
      await network.initialize();
      addTearDown(() {
        network.dispose();
        NetworkService(); // the unmonitored default again
      });
      channels
        ..failingUrlParts.add('127.0.0.1')
        ..failureCode = '-1005';
      await http.runWithClient(() async {
        await startHandler();
        connectivity.emit(none);
        await until(() => network.isOffline.value);
        unawaited(handler.playStation(stationOf(11)));
        final mp3Url = FakeMetadataBackend.mp3UrlOf('rve-origin');
        await untilPlaying(mp3Url, loads: 2);

        final failed = Uri.parse(channels.loads[0]);
        expect(failed.host, '127.0.0.1');
        expect(failed.path, endsWith('/rve-origin/index-2m.m3u8'),
            reason: 'a network error is no missing start variant');
        expect(channels.loads[1], startsWith('$mp3Url?'),
            reason: 'the failover goes on to the next stream, as before');
      }, () => routing);
    });

    test('back from the background, a proxy that stopped listening listens '
        'again on its port', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 1);
        final proxy = handler.debugHoldProxy!;
        final port = proxy.port;
        // iOS reclaimed the listening socket while the app was suspended.
        await proxy.debugCloseServer();
        await until(() => !proxy.isRunning);

        handler.onAppLifecycleChanged(AppLifecycleState.resumed);

        await until(() => proxy.isRunning);
        expect(proxy.port, port);
        expect(proxy.serves(channels.loads.single), isTrue,
            reason: 'the loaded item reaches it again');
      }, () => routing);
    });

    test('a resume after a pause plays on from the proxy still serving it',
        () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 1);
        await handler.pause();

        await handler.play();

        expect(handler.player.playing, isTrue);
        expect(channels.loads, hasLength(1), reason: 'a fast resume');
      }, () => routing);
    });

    test(
        'a resume after the proxy moved to another port reloads instead of '
        'resuming an item that reaches nothing', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await untilPlaying(originUrl, loads: 1);
        await handler.pause();
        // iOS reclaimed the listening socket while the app was suspended,
        // and the port is taken by the time the proxy listens again.
        final proxy = handler.debugHoldProxy!;
        final oldPort = proxy.port!;
        await proxy.stop();
        final squatter =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, oldPort);
        addTearDown(squatter.close);

        unawaited(handler.play());
        await untilPlaying(originUrl, loads: 2);

        final reloaded = channels.loads.last;
        expect(Uri.parse(reloaded).port, isNot(oldPort));
        expect(proxy.serves(reloaded), isTrue);
      }, () => routing);
    });
  });

  group('song boundaries at an anchor', () {
    test(
        'an anchor made by a retried poll does not take that poll\'s '
        'already-heard boundary as a change (only the anchored refresh)',
        () async {
      await http.runWithClient(() async {
        final recording = _RecordingService(
          graphqlClient: backend.graphqlClient,
          privateStationsService: PrivateStationsService(
            httpClient: backend.client,
            prefs: prefs,
            deviceIdProvider: () => 'device-1',
          ),
          httpClient: backend.client,
          clock: clock.call,
          wait: clock.wait,
        );
        await startHandler(s: recording);
        // A song change long before the audible instant (the fake player
        // reports the window start, ~600 s behind live).
        final heard = DateTime.now().subtract(const Duration(seconds: 700));
        playlistHeader = [
          '#EXT-X-RC-METADATA-CHANGED:'
              'EPOCH=${heard.millisecondsSinceEpoch ~/ 1000}',
        ];
        // The poll issued with the load fails: the clock anchors on the
        // anchor check's own poll (R3 retry path).
        failingPlaylistRequests = 1;
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(FakeMetadataBackend.hlsUrlOf('rve-suceava'),
            loads: 1);
        await until(() => recording.refreshes.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(recording.refreshes, [null],
            reason: 'one anchored refresh, no change for a heard boundary');
      }, () => routing);
    });
  });

  group('station switch away from an overlaid HLS station', () {
    test(
        'never publishes the old station\'s live (not yet heard) song, and '
        'its late history answer never overwrites the new queue', () async {
      await http.runWithClient(() async {
        await startHandler();
        // The test drives the audible instant (no anchoring here).
        DateTime? audible;
        service.isTimeShiftedHlsActive = () => true;
        service.getAudibleInstant =
            () => handler.currentStation.valueOrNull?.id == 1 ? audible : null;
        final hlsUrl = FakeMetadataBackend.hlsUrlOf('rve-suceava');
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(hlsUrl, loads: 1);
        audible = t(-138);
        await service.refreshMetadataNow();
        await clock.settle();
        expect(handler.mediaItem.value?.extras?['song_title'], 'Song X');

        // Station 1's next queue update (the default window: no
        // `to_timestamp`) is held, so it is still in flight at the switch.
        final queueAnswer = Completer<void>();
        var heldQueueRequests = 0;
        backend.beforeHistoryResponse = (url) async {
          final q = url.queryParameters;
          if (q['station_slug'] == 'rve-suceava' &&
              !q.containsKey('to_timestamp')) {
            heldQueueRequests++;
            await queueAnswer.future;
          }
        };
        audible = t(-50);
        await service.refreshMetadataNow(boundary: t(-60));
        await clock.settle();
        expect(handler.mediaItem.value?.extras?['song_title'], 'Song Y');

        final published = <String>[];
        final sub = handler.mediaItem.listen((m) => published
            .add('${m?.extras?['station_slug']}:${m?.extras?['song_title']}'));
        await pumpEventQueue();
        published.clear();
        backend.songChange(1, t(5), const FakeSong(13, 'Song Z'));
        await clock.advance(const Duration(seconds: 60));
        await service.enqueueSync(SyncReason.periodic); // live: Song Z

        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(FakeMetadataBackend.mp3UrlOf('s2'), loads: 2);
        await until(() =>
            handler.queue.value.isNotEmpty &&
            handler.queue.value.first.title == 'Song P');
        expect(heldQueueRequests, greaterThan(0),
            reason: 'station 1\'s queue answer must still be in flight');
        queueAnswer.complete();
        await pumpEventQueue();
        await sub.cancel();

        expect(published, isNot(contains('rve-suceava:Song Z')),
            reason: 'station 1\'s live song was never heard');
        expect(published.last, 's2:Song P');
        expect(handler.queue.value.map((i) => i.title), ['Song P']);
        expect(stationOf(1).songTitle, 'Song Z',
            reason: 'the list shows station 1 live again');
      }, () => routing);
    });
  });

  group('ICY titles (direct streams)', () {
    test(
        'the first title of a stream costs no fetch after the station '
        'switch asked for the same list; a title change follows the live '
        'list until the new row shows up', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(FakeMetadataBackend.mp3UrlOf('s2'), loads: 1);
        await clock.settle();
        final before = backend.metadataRequests.length;

        channels.emitIcyTitle('Artist - Song P');
        await clock.settle();
        expect(backend.metadataRequests, hasLength(before),
            reason: 'the station switch already asked for this exact list');
        await clock.advance(const Duration(seconds: 60));
        expect(backend.metadataRequests, hasLength(before),
            reason: 'no follow-up for the song already playing');

        channels.emitIcyTitle('Artist - Song Q');
        await clock.settle();
        backend.songChange(2, clock.now, const FakeSong(22, 'Song Q'));
        await until(() => backend.metadataRequests.length == before + 1);
        await clock.advance(const Duration(seconds: 10));
        expect(backend.metadataRequests, hasLength(before + 2));
        expect(stationOf(2).songTitle, 'Song Q');
        await clock.advance(const Duration(seconds: 60));
        expect(backend.metadataRequests, hasLength(before + 2),
            reason: 'the follow-up stops once the row is live');
      }, () => routing);
    });
  });

  group('task removed while the process survives', () {
    test(
        'onTaskRemoved leaves the station data service usable for the '
        'relaunch (audio_service reuses the cached engine)', () async {
      final owned = _ClosableClient(backend.client);
      await http.runWithClient(() async {
        await startHandler(
          s: http.runWithClient(
            () => StationDataService(
              graphqlClient: backend.graphqlClient,
              privateStationsService: PrivateStationsService(
                httpClient: backend.client,
                prefs: prefs,
                deviceIdProvider: () => 'device-1',
              ),
              clock: clock.call,
              wait: clock.wait,
            ),
            () => owned,
          ),
        );

        await handler.onTaskRemoved();
        expect(owned.closed, isFalse);

        backend.songChange(2, t(30), const FakeSong(22, 'Song Q'));
        await clock.advance(const Duration(seconds: 60));
        await service.onAppResumed();
        expect(stationOf(2).songTitle, 'Song Q');
      }, () => routing);
    });
  });
}
