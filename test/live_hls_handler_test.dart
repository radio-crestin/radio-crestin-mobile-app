import 'dart:async';
import 'dart:io' show HttpDate;

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
import 'package:radio_crestin/services/hls_timeline.dart' show SongBoundaryHint;
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/private_stations_service.dart';
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
        'the first title of a stream costs one live fetch; a title change '
        'follows the live list until the new row shows up', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(FakeMetadataBackend.mp3UrlOf('s2'), loads: 1);
        await clock.settle();
        final before = backend.metadataRequests.length;

        channels.emitIcyTitle('Artist - Song P');
        await until(() => backend.metadataRequests.length == before + 1);
        await clock.advance(const Duration(seconds: 60));
        expect(backend.metadataRequests, hasLength(before + 1),
            reason: 'no follow-up for the song already playing');

        channels.emitIcyTitle('Artist - Song Q');
        await until(() => backend.metadataRequests.length == before + 2);
        backend.songChange(2, clock.now, const FakeSong(22, 'Song Q'));
        await clock.advance(const Duration(seconds: 10));
        expect(backend.metadataRequests, hasLength(before + 3));
        expect(stationOf(2).songTitle, 'Song Q');
        await clock.advance(const Duration(seconds: 60));
        expect(backend.metadataRequests, hasLength(before + 3),
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
