import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/hls_health_watchdog_flag.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_just_audio_channels.dart';
import 'helpers/fake_metadata_backend.dart';

class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

/// What a station switch does to the native player: on Android it keeps
/// it (pause, then the new load replaces the source), elsewhere it stops
/// it. A real AppAudioHandler over faked just_audio channels; real time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final keepsPlayerDefault = AppAudioHandler.switchKeepsNativePlayer;

  late SharedPreferences prefs;
  late FakeMetadataBackend backend;
  late FakeJustAudioChannels channels;
  late StationDataService service;
  late AppAudioHandler handler;
  late http.Client routing;

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
    backend = FakeMetadataBackend(FakeClock(DateTime.utc(2026, 10, 18, 12)));
    for (var id = 1; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    backend.addStation(11, 's11', 'Station 11', hls: true); // two streams
    channels = FakeJustAudioChannels()..install();
    routing = MockClient(
        (request) => backend.client.get(request.url, headers: request.headers));
    // Unmonitored: online, and checkInternet() says yes at once.
    NetworkService();
  });

  tearDown(() async {
    await http.runWithClient(() => handler.stop(), () => routing);
    AppAudioHandler.switchKeepsNativePlayer = keepsPlayerDefault;
    AnalyticsService.instance.endListening();
    service.dispose();
    channels.uninstall();
    NetworkService();
    await GetIt.instance.reset();
  });

  Future<void> startHandler() async {
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
    // The handler takes the replayed online value for a restore and acts
    // on it 500 ms later; let that pass first.
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  Station stationOf(int id) =>
      service.stations.value.firstWhere((s) => s.id == id);

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

  /// Every playback state the session shows from now on.
  List<PlaybackState> collectStates() {
    final states = <PlaybackState>[];
    final subscription = handler.playbackState.skip(1).listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  bool showsPaused(PlaybackState s) =>
      !s.playing && s.processingState == AudioProcessingState.ready;

  test(
      'Android: a switch pauses the old station and loads the new one once, '
      'on the same native player', () async {
    AppAudioHandler.switchKeepsNativePlayer = true;
    await http.runWithClient(() async {
      await startHandler();
      await handler.playStation(stationOf(1));
      expect(channels.isAnyPlayerPlaying, isTrue);
      final players = List.of(channels.createdPlayers);
      final loads = channels.loads.length;
      final pauses = channels.pauses;
      final states = collectStates();

      final gate = channels.loadGate = Completer<void>();
      final switched = handler.playStation(stationOf(3));
      await until(() => channels.loads.length > loads);
      expect(channels.isAnyPlayerPlaying, isFalse,
          reason: 'the old station is silent while the new one loads');
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.loading);
      expect(handler.playbackState.value.playing, isTrue,
          reason: 'the spinner, not the play button');
      gate.complete();
      await switched;

      expect(channels.pauses, pauses + 1);
      expect(channels.disposedPlayers, isEmpty);
      expect(channels.createdPlayers, players,
          reason: 'no new native player');
      expect(channels.loads.skip(loads), [contains('/s3/')]);
      expect(channels.isAnyPlayerPlaying, isTrue);
      expect(handler.currentStation.value?.id, 3);
      expect(states.where(showsPaused), isEmpty,
          reason: 'the play button never shows during the switch');
    }, () => routing);
  });

  test('Android: a retry after a failed load still uses a fresh player',
      () async {
    AppAudioHandler.switchKeepsNativePlayer = true;
    await http.runWithClient(() async {
      await startHandler();
      await handler.playStation(stationOf(1));
      final players = channels.createdPlayers.length;
      // The HLS stream fails, the MP3 one after it loads.
      channels.failingUrlParts.add('/hls/s11/');

      await handler.playStation(stationOf(11));

      expect(channels.disposedPlayers, hasLength(1),
          reason: 'only the retry stops the player');
      expect(channels.createdPlayers, hasLength(players + 1));
      expect(channels.loads.last, contains('/s11/stream.mp3'));
      expect(channels.isAnyPlayerPlaying, isTrue);
    }, () => routing);
  });

  test('iOS: a switch still stops the player, the next load builds a new one',
      () async {
    AppAudioHandler.switchKeepsNativePlayer = false;
    await http.runWithClient(() async {
      await startHandler();
      await handler.playStation(stationOf(1));
      final players = List.of(channels.createdPlayers);
      final pauses = channels.pauses;

      await handler.playStation(stationOf(3));

      expect(channels.disposedPlayers, [players.last]);
      expect(channels.createdPlayers, hasLength(players.length + 1));
      expect(channels.pauses, pauses);
      expect(channels.loads.last, contains('/s3/'));
      expect(channels.isAnyPlayerPlaying, isTrue);
    }, () => routing);
  });
}
