import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show HttpDate;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/hls_health_watchdog_flag.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/station_retry.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_just_audio_channels.dart';
import 'helpers/fake_metadata_backend.dart';
import 'helpers/hls_fixtures.dart' show playlistText;
import 'helpers/station_factory.dart';

/// Records what the retry asks of the handler.
class _RecordingHandler extends Fake implements AppAudioHandler {
  _RecordingHandler(
    this.calls, {
    required Station current,
    this.isPlayingOrConnecting = false,
    this.isPlaylistMode = false,
  }) : currentStation = BehaviorSubject.seeded(current);

  final List<String> calls;

  @override
  final BehaviorSubject<Station?> currentStation;

  @override
  bool isPlayingOrConnecting;

  @override
  bool isPlaylistMode;

  @override
  Future<void> pause() async {
    calls.add('pause');
    isPlayingOrConnecting = false;
  }

  @override
  Future<void> playStation(Station station, {bool? fromFavorites}) async =>
      calls.add('playStation ${station.slug}');
}

/// Records playlist restarts.
class _RecordingPlaylist extends Fake implements PlaylistController {
  _RecordingPlaylist(this.calls, {this.activeStation});

  final List<String> calls;

  @override
  final Station? activeStation;

  @override
  Future<void> startPlaylist(Station station, {int startIndex = 0}) async =>
      calls.add('startPlaylist ${station.slug} @$startIndex');
}

/// No song is liked; the handler only reads like states here.
class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('retryStation routing', () {
    late List<String> calls;

    setUp(() => calls = []);

    final radio =
        StationFactory.createStation(id: 1, slug: 'rve', title: 'RVE');
    final playlist = StationFactory.createStation(
      id: 2,
      slug: 'predici',
      title: 'Predici',
      stationType: 'playlist',
    );

    test('a station stopped after its error: plays it again', () async {
      final handler = _RecordingHandler(calls, current: radio);

      await retryStation(radio,
          handler: handler, playlist: _RecordingPlaylist(calls));

      expect(calls, ['playStation rve']);
    });

    test(
        'a station its retry loop still connects to: ends that loop, then '
        'plays it again', () async {
      final handler =
          _RecordingHandler(calls, current: radio, isPlayingOrConnecting: true);

      await retryStation(radio,
          handler: handler, playlist: _RecordingPlaylist(calls));

      expect(calls, ['pause', 'playStation rve']);
    });

    test('a playlist that failed while active: restarts it from the top',
        () async {
      final handler =
          _RecordingHandler(calls, current: playlist, isPlaylistMode: true);

      await retryStation(
        playlist,
        handler: handler,
        playlist: _RecordingPlaylist(calls, activeStation: playlist),
      );

      expect(calls, ['startPlaylist predici @0']);
    });

    test('a playlist that is no longer active: plays it again', () async {
      final handler = _RecordingHandler(calls, current: playlist);

      await retryStation(playlist,
          handler: handler, playlist: _RecordingPlaylist(calls));

      expect(calls, ['playStation predici']);
    });
  });

  // A real AppAudioHandler over the faked just_audio channels, with a
  // station whose only stream always fails: the case "Reîncearcă" is for.
  group('with the real player', () {
    final t0 = DateTime.utc(2026, 10, 11, 12);
    final failingStream = FakeMetadataBackend.mp3UrlOf('s2');

    late SharedPreferences prefs;
    late FakeMetadataBackend backend;
    late FakeJustAudioChannels channels;
    late StationDataService service;
    late AppAudioHandler handler;
    late http.Client routing;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      await HlsHealthWatchdogFlag.instance.loadCache(prefs);
      await GetIt.instance.reset();
      GetIt.instance
        ..registerSingleton<SharedPreferences>(prefs)
        ..registerSingleton<PlayCountService>(PlayCountService())
        ..registerSingleton<SongLikeService>(_NoLikes())
        ..registerSingleton<VideoPlaybackService>(VideoPlaybackService());
      backend = FakeMetadataBackend(FakeClock(t0));
      // The service only accepts a catalog of at least 10 stations.
      for (var id = 1; id <= 10; id++) {
        backend.addStation(id, 's$id', 'Station $id');
      }
      channels = FakeJustAudioChannels()..install();
      channels.failingUrlParts.add(failingStream);
      routing = MockClient((request) async {
        if (request.url.path.endsWith('.m3u8')) {
          return http.Response.bytes(
            utf8.encode(playlistText(
              mediaSequence: 0,
              count: 10,
              firstPdt: t0,
            )),
            200,
            headers: {'last-modified': HttpDate.format(DateTime.now())},
          );
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
      await GetIt.instance.reset();
    });

    Station failing() => service.stations.value.firstWhere((s) => s.id == 2);

    Future<void> until(bool Function() condition,
        {required Duration within}) async {
      final deadline = DateTime.now().add(within);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('condition not met within $within');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    int loadsOfFailing() =>
        channels.loads.where((url) => url.contains(failingStream)).length;

    /// Plays the failing station until its first pass fails: the moment the
    /// station error shows, with the retry loop still cycling.
    Future<List<ConnectionError>> playUntilError() async {
      final errors = <ConnectionError>[];
      final sub = handler.connectionError.listen(errors.add);
      addTearDown(sub.cancel);
      unawaited(handler.playStation(failing()));
      await until(() => errors.isNotEmpty, within: const Duration(seconds: 5));
      return errors;
    }

    test(
        'the play intent: set by a play, kept through failed passes, '
        'cleared by a pause', () async {
      await http.runWithClient(() async {
        expect(handler.hasPlayIntent, isFalse);

        await playUntilError();
        expect(handler.hasPlayIntent, isTrue,
            reason: 'the loop keeps retrying for the listener');

        await handler.pause();
        expect(handler.hasPlayIntent, isFalse);
      }, () => routing);
    });

    test(
        'after the error, playStation alone does nothing: the loop is '
        'still connecting', () async {
      await http.runWithClient(() async {
        await playUntilError();
        expect(handler.isPlayingOrConnecting, isTrue);
        final loads = loadsOfFailing();

        await handler.playStation(failing());
        await pumpEventQueue();

        expect(loadsOfFailing(), loads);
      }, () => routing);
    });

    test(
        'retry starts a fresh pass at once, keeps the spinner and reports '
        'its own failure', () async {
      await http.runWithClient(() async {
        final errors = await playUntilError();
        final loads = loadsOfFailing();
        final states = <PlaybackState>[];
        final stateSub = handler.playbackState.skip(1).listen(states.add);
        addTearDown(stateSub.cancel);

        unawaited(retryStation(
          failing(),
          handler: handler,
          playlist: _RecordingPlaylist([]),
        ));

        // Before the loop's own 1s backoff would have retried.
        await until(() => loadsOfFailing() > loads,
            within: const Duration(milliseconds: 500));
        expect(handler.isPlayingOrConnecting, isTrue);
        await until(() => errors.length == 2,
            within: const Duration(seconds: 2));
        expect(handler.isPlayingOrConnecting, isTrue,
            reason: 'still retrying by itself');
        expect(
          states.where((s) =>
              !s.playing && s.processingState == AudioProcessingState.ready),
          isEmpty,
          reason: 'the mini player never shows play while retrying',
        );
      }, () => routing);
    });
  });
}
