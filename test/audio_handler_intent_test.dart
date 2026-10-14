import 'dart:async';
import 'dart:convert' show json, utf8;
import 'dart:io' show HttpDate;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart'
    show AudioInterruptionEvent, AudioInterruptionType;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart'
    show CastMediaPlayerState;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/cast_service.dart';
import 'package:radio_crestin/services/hls_health_watchdog_flag.dart';
import 'package:radio_crestin/services/hls_timeline.dart' show SongBoundaryHint;
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/private_stations_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/types/playlist_item.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_just_audio_channels.dart';
import 'helpers/fake_metadata_backend.dart';
import 'helpers/hls_fixtures.dart' show playlistText;

/// No song is liked; the handler only reads like states here.
class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

/// Keeps like states in memory, for the like and dislike actions.
class _InMemoryLikes extends Fake implements SongLikeService {
  final Map<int, int> _statuses = {};

  @override
  int getLikeStatus(int songId) => _statuses[songId] ?? 0;

  @override
  Future<void> setLikeStatus({
    required int stationId,
    required int songId,
    required int likeStatus,
    String? thumbnailUrl,
    String? songTitle,
    String? songArtist,
  }) async =>
      _statuses[songId] = likeStatus;
}

/// A Cast session the tests connect and disconnect by hand.
class _FakeCast extends Fake implements CastService {
  @override
  final BehaviorSubject<bool> isCasting = BehaviorSubject.seeded(false);

  @override
  final BehaviorSubject<CastMediaPlayerState> castPlayerState =
      BehaviorSubject.seeded(CastMediaPlayerState.unknown);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}
}

/// media_kit stand-in: every open autoplays, like the real service, and
/// renders a first frame at once (no fallback watchdog).
class _FakeVideo extends VideoPlaybackService {
  final BehaviorSubject<bool> playing = BehaviorSubject.seeded(false);

  @override
  bool get isInitialized => true;

  @override
  bool get isPlaying => playing.value;

  @override
  Stream<bool> get playingStream => playing.stream;

  @override
  bool get hasRenderedFrame => true;

  @override
  Future<void> open(
    String url, {
    bool live = false,
    bool autoPlay = true,
    Duration? startPosition,
  }) async =>
      playing.add(autoPlay);

  @override
  Future<void> play() async => playing.add(true);

  @override
  Future<void> pause() async => playing.add(false);

  @override
  Future<void> stop() async => playing.add(false);
}

/// Records the hint of every `refreshMetadataNow` call before running it.
class _HintRecordingService extends StationDataService {
  _HintRecordingService({
    required super.graphqlClient,
    super.privateStationsService,
    super.httpClient,
    super.clock,
    super.wait,
  });

  final List<SongBoundaryHint?> hints = [];

  @override
  Future<void> refreshMetadataNow({
    DateTime? boundary,
    SongBoundaryHint? hint,
  }) {
    hints.add(hint);
    return super.refreshMetadataNow(boundary: boundary, hint: hint);
  }
}

/// The play intent (`_hasBeenPlayed`) and the station-switch supersession
/// through a real [AppAudioHandler] over the faked just_audio channels: a
/// pause must stop automatic restarts, a resume must re-enable them, and
/// a pause during a switch must win over it.
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

  /// A live window of 100 six-second segments ending now.
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
      ..addStation(1, 'rve-suceava', 'RVE Suceava', hls: true)
      ..addStation(11, 'tv-alfa', 'Alfa TV', stationType: 'tv');
    // The service only accepts a catalog of at least 10 stations.
    for (var id = 2; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    backend.songChange(2, t(-200), const FakeSong(21, 'Song P'));
    channels = FakeJustAudioChannels()..install();
    playlistHeader = [];
    // Playlists are served live, as UTF-8 without a charset (like the
    // origin); everything else goes to the backend.
    routing = MockClient((request) async {
      if (request.url.path.endsWith('.m3u8')) {
        return http.Response.bytes(utf8.encode(livePlaylist()), 200,
            headers: {
              'content-type': 'application/vnd.apple.mpegurl',
              'last-modified': HttpDate.format(DateTime.now()),
            });
      }
      return backend.client.get(request.url, headers: request.headers);
    });
  });

  tearDown(() async {
    if (handler.isPlaylistMode) handler.exitPlaylistMode();
    await http.runWithClient(() => handler.stop(), () => routing);
    AnalyticsService.instance.endListening();
    service.dispose();
    channels.uninstall();
    await GetIt.instance.reset();
  });

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

  Future<void> untilPlaying(String url, {required int loads}) => until(() =>
      channels.loads.length == loads &&
      handler.currentStreamInfo.valueOrNull?.url == url &&
      handler.player.playing);

  final mp3Of2 = FakeMetadataBackend.mp3UrlOf('s2');

  group('play intent', () {
    test(
        'a pause stops a network restore from restarting playback; a resume '
        're-enables the recovery', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(mp3Of2, loads: 1);

        await handler.pause();
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await pumpEventQueue();
        expect(channels.loads, hasLength(1));
        expect(handler.player.playing, isFalse, reason: 'the user paused');

        await handler.play(); // fast resume of the loaded stream
        expect(handler.player.playing, isTrue);
        // The player stops by itself (stale source after airplane mode):
        // the restored intent lets the network restore recover it.
        await handler.player.pause();
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await untilPlaying(mp3Of2, loads: 2);
      }, () => routing);
    });

    test(
        'a pause in playlist mode stops a network restore from resuming '
        'the item', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(mp3Of2, loads: 1);
        handler.enterPlaylistMode();

        await handler.pause();
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await pumpEventQueue();

        expect(handler.player.playing, isFalse);
      }, () => routing);
    });
  });

  // The host is not Android, so these follow the iOS rules: every begin is
  // `unknown`, and only an end of type `pause` (shouldResume) resumes.
  group('audio interruption', () {
    final begin = AudioInterruptionEvent(true, AudioInterruptionType.unknown);
    final resumableEnd =
        AudioInterruptionEvent(false, AudioInterruptionType.pause);
    final finalEnd =
        AudioInterruptionEvent(false, AudioInterruptionType.unknown);

    Future<void> playStation2() async {
      await startHandler();
      unawaited(handler.playStation(stationOf(2)));
      await untilPlaying(mp3Of2, loads: 1);
    }

    test(
        'pauses through the handler and resumes through it when the end '
        'allows', () async {
      await http.runWithClient(() async {
        await playStation2();

        handler.debugOnAudioInterruption(begin);
        await until(() => !handler.playbackState.value.playing);
        expect(handler.player.playing, isFalse);
        expect(AnalyticsService.instance.isListening, isFalse,
            reason: 'an interruption ends the listening session');

        handler.debugOnAudioInterruption(resumableEnd);
        await until(() => handler.playbackState.value.playing);
        expect(AnalyticsService.instance.isListening, isTrue);
        expect(channels.loads, hasLength(1),
            reason: 'a short interruption resumes the loaded stream');
      }, () => routing);
    });

    test(
        'an end without a resume leaves playback paused, and a reconnect '
        'does not restart it', () async {
      await http.runWithClient(() async {
        await playStation2();

        handler.debugOnAudioInterruption(begin);
        handler.debugOnAudioInterruption(finalEnd);
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await pumpEventQueue();

        expect(handler.player.playing, isFalse);
        expect(handler.playbackState.value.playing, isFalse);
        expect(channels.loads, hasLength(1));
      }, () => routing);
    });

    test('a pause during the interruption cancels the resume', () async {
      await http.runWithClient(() async {
        await playStation2();

        handler.debugOnAudioInterruption(begin);
        await handler.pause();
        handler.debugOnAudioInterruption(resumableEnd);
        await pumpEventQueue();

        expect(handler.player.playing, isFalse);
      }, () => routing);
    });

    test('an interruption while paused does not start playback', () async {
      await http.runWithClient(() async {
        await playStation2();

        await handler.pause();
        handler.debugOnAudioInterruption(begin);
        handler.debugOnAudioInterruption(resumableEnd);
        await pumpEventQueue();

        expect(handler.player.playing, isFalse);
      }, () => routing);
    });
  });

  group('TV video handoff', () {
    final tvAudio = FakeMetadataBackend.mp3UrlOf('tv-alfa');

    test(
        'a channel paused in the background and reopened as video is handed '
        'back to audio on the next background', () async {
      final video = _FakeVideo();
      GetIt.instance
        ..unregister<VideoPlaybackService>()
        ..registerSingleton<VideoPlaybackService>(video);
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(11)));
        await until(() => video.playing.value);
        expect(handler.isVideoMode.value, isTrue);

        // Backgrounded while watching: the channel goes on as audio.
        handler.onAppLifecycleChanged(AppLifecycleState.paused);
        await untilPlaying(tvAudio, loads: 1);

        // Paused from the lock screen, then the app is reopened: the
        // channel comes back as (autoplaying) video.
        await handler.pause();
        handler.onAppLifecycleChanged(AppLifecycleState.resumed);
        // HomePage's reconnect check right after the resume (a network
        // restore stands in for it, past the 8 s just-loaded debounce)
        // must not load the audio next to the opening video.
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await until(() => video.playing.value && handler.isVideoMode.value);
        expect(channels.loads, hasLength(1));
        expect(AnalyticsService.instance.isListening, isTrue,
            reason: 'the autoplaying video is a listening session');

        // Locked again while the video plays: the handoff keeps it going.
        handler.onAppLifecycleChanged(AppLifecycleState.paused);
        await untilPlaying(tvAudio, loads: 2);
        expect(handler.isVideoMode.value, isFalse);
      }, () => routing);
    });
  });

  group('Cast', () {
    late _FakeCast cast;

    Future<void> castAfterLocalPlay() async {
      await startHandler();
      unawaited(handler.playStation(stationOf(2)));
      await untilPlaying(mp3Of2, loads: 1);
      cast = _FakeCast();
      GetIt.instance.registerSingleton<CastService>(cast);
      handler.watchCastSessions(cast);
      // main.dart on connect: the local player stops, the receiver plays.
      cast.isCasting.add(true);
      await handler.player.stop();
      handler.setCastPlaying(true);
      await pumpEventQueue();
    }

    Future<void> disconnect() async {
      // main.dart on disconnect: the local player stays stopped.
      cast.isCasting.add(false);
      await handler.player.stop();
      handler.setCastPlaying(false);
      await pumpEventQueue();
    }

    test(
        'a disconnect leaves the phone silent: a network restore does not '
        'restart local playback', () async {
      await http.runWithClient(() async {
        await castAfterLocalPlay();

        await disconnect();
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await pumpEventQueue();

        expect(channels.loads, hasLength(1));
        expect(handler.player.playing, isFalse);
      }, () => routing);
    });

    test('pause and resume on the receiver end and resume the listening '
        'session', () async {
      await http.runWithClient(() async {
        await castAfterLocalPlay();
        expect(AnalyticsService.instance.isListening, isTrue);

        await handler.pause();
        expect(AnalyticsService.instance.isListening, isFalse);

        await handler.play();
        expect(AnalyticsService.instance.isListening, isTrue);
        expect(handler.playbackState.value.playing, isTrue);
        await disconnect();
      }, () => routing);
    });
  });

  group('station switch', () {
    test(
        'a pause during the switch wins: the new station never starts and '
        'no loading state lingers', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(mp3Of2, loads: 1);

        // The switch suspends on stopping the previous stream.
        final switching = handler.playStation(stationOf(3));
        await handler.pause();
        await switching;
        await pumpEventQueue();

        expect(channels.loads, hasLength(1),
            reason: 'station 3 must not load after the pause');
        expect(handler.player.playing, isFalse);
        expect(handler.playbackState.value.processingState,
            isNot(AudioProcessingState.loading));
      }, () => routing);
    });
  });

  // A play command (a car's or a headset's play button) while the station
  // is still loading. A play while the loop waits out its backoff starts a
  // new loop: see play_loop_network_test.dart.
  group('play during a load', () {
    test('keeps the load in flight instead of starting it again', () async {
      await http.runWithClient(() async {
        await startHandler();
        final gate = channels.loadGate = Completer<void>();
        unawaited(handler.playStation(stationOf(2)));
        await until(() => channels.loads.length == 1);

        unawaited(handler.play());
        gate.complete();

        // A second load would wait for the stream all over again.
        await untilPlaying(mp3Of2, loads: 1);
        await pumpEventQueue();
        expect(channels.loads, hasLength(1));
      }, () => routing);
    });

    test('after a pause, loads the station again', () async {
      await http.runWithClient(() async {
        await startHandler();
        final gate = channels.loadGate = Completer<void>();
        unawaited(handler.playStation(stationOf(2)));
        await until(() => channels.loads.length == 1);

        // The pause ends that load: the play starts another.
        await handler.pause();
        unawaited(handler.play());
        gate.complete();

        await untilPlaying(mp3Of2, loads: 2);
      }, () => routing);
    });
  });

  // Each user action counts once toward the review dialog thresholds; the
  // handler's own restarts do not.
  group('review actions', () {
    Future<int> actionsMade() async {
      // The handler counts without awaiting.
      await pumpEventQueue();
      final status = json.decode(prefs.getString('_reviewStatus')!);
      return status['actions_made'] as int;
    }

    Future<void> playStation2() async {
      await prefs.setString('_reviewStatus', '{"actions_made":0}');
      await startHandler();
      unawaited(handler.playStation(stationOf(2)));
      await untilPlaying(mp3Of2, loads: 1);
    }

    test('a station start counts once and a reconnect does not', () async {
      await http.runWithClient(() async {
        await playStation2();
        expect(await actionsMade(), 1);

        // The player stops by itself; the network restore reloads it.
        await handler.player.pause();
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await untilPlaying(mp3Of2, loads: 2);

        expect(await actionsMade(), 1);
      }, () => routing);
    });

    test('a resume after a pause counts, the pause does not', () async {
      await http.runWithClient(() async {
        await playStation2();

        await handler.pause();
        expect(await actionsMade(), 1);

        await handler.play();
        expect(await actionsMade(), 2);
      }, () => routing);
    });

    test('the resume after an interruption does not count', () async {
      await http.runWithClient(() async {
        await playStation2();

        handler.debugOnAudioInterruption(
            AudioInterruptionEvent(true, AudioInterruptionType.unknown));
        await until(() => !handler.playbackState.value.playing);
        handler.debugOnAudioInterruption(
            AudioInterruptionEvent(false, AudioInterruptionType.pause));
        await until(() => handler.playbackState.value.playing);

        expect(await actionsMade(), 1);
      }, () => routing);
    });

    test('adding a favorite counts, removing it does not', () async {
      await http.runWithClient(() async {
        await prefs.setString('_reviewStatus', '{"actions_made":0}');
        await startHandler();

        await handler.setStationIsFavorite(stationOf(3), true);
        expect(await actionsMade(), 1);

        await handler.setStationIsFavorite(stationOf(3), false);
        expect(await actionsMade(), 1);
      }, () => routing);
    });

    test('liking a song counts, unliking or disliking it does not', () async {
      GetIt.instance
        ..unregister<SongLikeService>()
        ..registerSingleton<SongLikeService>(_InMemoryLikes());
      await http.runWithClient(() async {
        await playStation2();

        await handler.customAction('likeSong');
        expect(await actionsMade(), 2);

        await handler.customAction('likeSong');
        expect(await actionsMade(), 2, reason: 'the second tap unlikes');

        await handler.customAction('dislikeSong');
        expect(await actionsMade(), 2);
      }, () => routing);
    });
  });

  // A heart flips the favorite as it is at the tap, not as a widget last
  // drew it.
  group('favorite toggle', () {
    test('taps in quick succession each undo the one before', () async {
      await http.runWithClient(() async {
        await startHandler();
        final station = stationOf(3);
        bool isFavorite() =>
            service.favoriteStationSlugs.value.contains(station.slug);

        // No frame between the taps, so no widget could redraw in between.
        expect(handler.toggleStationFavorite(station), isTrue);
        expect(isFavorite(), isTrue);
        expect(handler.toggleStationFavorite(station), isFalse);
        expect(isFavorite(), isFalse);
        expect(handler.toggleStationFavorite(station), isTrue);
        expect(isFavorite(), isTrue);

        await pumpEventQueue();
        expect(json.decode(prefs.getString('favoriteStationSlugs')!),
            [station.slug]);
      }, () => routing);
    });
  });

  // What brings the car's no-internet alert back (OfflineAlertGate).
  group('play requests', () {
    late List<void> requests;
    late StreamSubscription<void> subscription;

    Future<void> playStation2() async {
      await startHandler();
      requests = [];
      subscription = handler.playRequested.listen(requests.add);
      unawaited(handler.playStation(stationOf(2)));
      await untilPlaying(mp3Of2, loads: 1);
    }

    tearDown(() => subscription.cancel());

    test('a station pick requests, even of the station already playing',
        () async {
      await http.runWithClient(() async {
        await playStation2();
        expect(requests, hasLength(1));

        await handler.playStation(stationOf(2));
        await pumpEventQueue();
        expect(requests, hasLength(2));
      }, () => routing);
    });

    test('a resume after a pause requests, a reconnect does not', () async {
      await http.runWithClient(() async {
        await playStation2();

        await handler.pause();
        await handler.play();
        await pumpEventQueue();
        expect(requests, hasLength(2));

        // The player stops by itself; the network restore reloads it.
        await handler.player.pause();
        handler.reconnectIfNeeded(trigger: ReconnectTrigger.networkRestored);
        await untilPlaying(mp3Of2, loads: 2);
        expect(requests, hasLength(2));
      }, () => routing);
    });

    test('the resume after an interruption requests nothing', () async {
      await http.runWithClient(() async {
        await playStation2();

        handler.debugOnAudioInterruption(
            AudioInterruptionEvent(true, AudioInterruptionType.unknown));
        await until(() => !handler.playbackState.value.playing);
        handler.debugOnAudioInterruption(
            AudioInterruptionEvent(false, AudioInterruptionType.pause));
        await until(() => handler.playbackState.value.playing);

        expect(requests, hasLength(1));
      }, () => routing);
    });
  });

  // AVPlayer buffers after every play() before audio comes out, while
  // just_audio keeps reporting the pre-play ready until then.
  group('audio start', () {
    final waitsAfterPlay = AppAudioHandler.playerWaitsAfterPlay;
    setUp(() => AppAudioHandler.playerWaitsAfterPlay = true);
    tearDown(() => AppAudioHandler.playerWaitsAfterPlay = waitsAfterPlay);

    AudioProcessingState reported() =>
        handler.playbackState.value.processingState;

    // Every processing state reported while playing, in order.
    List<AudioProcessingState> recordWhilePlaying() {
      final states = <AudioProcessingState>[];
      handler.playbackState
          .where((s) => s.playing)
          .listen((s) => states.add(s.processingState));
      return states;
    }

    Future<void> playStation2() async {
      unawaited(handler.playStation(stationOf(2)));
      await untilPlaying(mp3Of2, loads: 1);
    }

    test('reports no ready until AVPlayer plays', () async {
      await http.runWithClient(() async {
        channels.waitsAfterPlay = true;
        await startHandler();
        final states = recordWhilePlaying();
        await playStation2();
        await until(() => states.contains(AudioProcessingState.buffering));
        expect(states, isNot(contains(AudioProcessingState.ready)),
            reason: 'the ready before the play is no start');

        channels.emitProcessingState(3); // AVPlayer plays
        await until(() => reported() == AudioProcessingState.ready);
        expect(handler.playbackState.value.playing, isTrue);
      }, () => routing);
    });

    test('a resume waits for AVPlayer too', () async {
      await http.runWithClient(() async {
        channels.waitsAfterPlay = true;
        await startHandler();
        await playStation2();
        channels.emitProcessingState(3);
        await until(() => reported() == AudioProcessingState.ready);
        await handler.pause();
        final states = recordWhilePlaying();

        await handler.play();
        await until(() => states.contains(AudioProcessingState.buffering));
        expect(states, isNot(contains(AudioProcessingState.ready)));
      }, () => routing);
    });

    test('reports ready at once should AVPlayer play without waiting',
        () async {
      await http.runWithClient(() async {
        await startHandler();
        await playStation2();

        // The fake answers the play at once, stamped in whole milliseconds
        // like AVPlayer, usually in the millisecond of the request.
        await until(() => reported() == AudioProcessingState.ready);
      }, () => routing);
    });

    test('an answer from the millisecond of the request answers it', () {
      final requestedAt = DateTime.fromMicrosecondsSinceEpoch(1000700);
      DateTime stamped(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

      expect(AppAudioHandler.mayAnswerPlay(stamped(1000), requestedAt), isTrue);
      expect(AppAudioHandler.mayAnswerPlay(stamped(1001), requestedAt), isTrue);
      expect(AppAudioHandler.mayAnswerPlay(stamped(999), requestedAt), isFalse,
          reason: 'on its way before the play');
    });

    test('a pause before AVPlayer answers shows as a pause', () async {
      await http.runWithClient(() async {
        await startHandler();
        await playStation2();

        await handler.pause();

        expect(handler.playbackState.value.playing, isFalse);
        expect(reported(), AudioProcessingState.ready);
      }, () => routing);
    });

    test('ExoPlayer is ready at once', () async {
      AppAudioHandler.playerWaitsAfterPlay = false;
      await http.runWithClient(() async {
        await startHandler();
        await playStation2();

        expect(reported(), AudioProcessingState.ready);
      }, () => routing);
    });
  });

  // What Android Auto shows while playback waits for the internet.
  group('offline error', () {
    bool showsError() =>
        handler.playbackState.value.processingState ==
        AudioProcessingState.error;

    Future<void> playStation2() async {
      await startHandler();
      unawaited(handler.playStation(stationOf(2)));
      await untilPlaying(mp3Of2, loads: 1);
    }

    test('shows as the error state with a message, and goes', () async {
      await http.runWithClient(() async {
        await playStation2();

        handler.setOfflineError(true);
        final state = handler.playbackState.value;
        expect(state.processingState, AudioProcessingState.error);
        expect(state.errorMessage, isNotEmpty);
        expect(state.playing, isTrue,
            reason: 'audio_service stays in the foreground');

        handler.setOfflineError(false);
        expect(showsError(), isFalse);
        expect(handler.playbackState.value.errorMessage, isNull);
      }, () => routing);
    });

    test('a pause shows as a pause', () async {
      await http.runWithClient(() async {
        await playStation2();
        handler.setOfflineError(true);

        await handler.pause();

        expect(showsError(), isFalse);
        expect(handler.playbackState.value.errorMessage, isNull);
      }, () => routing);
    });

    test('a station pick or a resume clears it at once', () async {
      await http.runWithClient(() async {
        await playStation2();
        handler.setOfflineError(true);

        unawaited(handler.playStation(stationOf(3)));
        expect(showsError(), isFalse, reason: 'the new station loads');

        handler.setOfflineError(true);
        await handler.pause();
        unawaited(handler.play());
        expect(showsError(), isFalse);
      }, () => routing);
    });
  });

  group('session queue', () {
    test('tapping a history row keeps the current station', () async {
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(2)));
        await untilPlaying(mp3Of2, loads: 1);

        await handler.skipToQueueItem(0);
        await pumpEventQueue();

        expect(channels.loads, hasLength(1));
        expect(handler.currentStation.value?.id, 2);
      }, () => routing);
    });
  });

  group('Android Auto browsing', () {
    Future<List<MediaItem>> browse(String folder) async {
      await until(() => handler.stationsMediaItems.value.isNotEmpty);
      return handler.getChildren(folder);
    }

    test(
        'a station picked from the favorites folder keeps next and previous '
        'within the favorites', () async {
      await http.runWithClient(() async {
        await startHandler();
        await service.setStationIsFavorite(stationOf(3), true);
        await service.setStationIsFavorite(stationOf(5), true);

        final favorites = await browse('favoriteStationsRootId');
        expect(favorites.map((i) => i.extras?['station_slug']), ['s3', 's5']);

        unawaited(handler.playFromMediaId(favorites.first.id));
        await until(() => handler.currentStation.valueOrNull?.id == 3);
        expect(service.startedFromFavorites, isTrue);

        unawaited(handler.skipToNext());
        await until(() => handler.currentStation.value?.id == 5);
        unawaited(handler.skipToNext());
        await until(() => handler.currentStation.value?.id == 3);
        unawaited(handler.skipToPrevious());
        await until(() => handler.currentStation.value?.id == 5);
      }, () => routing);
    });

    test('a station picked from all stations navigates the full list',
        () async {
      await http.runWithClient(() async {
        await startHandler();
        service.startedFromFavorites = true;
        await service.setStationIsFavorite(stationOf(3), true);
        await service.setStationIsFavorite(stationOf(5), true);

        final all = await browse('allStationsRootId');
        final s3 = all.firstWhere((i) => i.extras?['station_slug'] == 's3');
        unawaited(handler.playFromMediaId(s3.id));
        await until(() => handler.currentStation.valueOrNull?.id == 3);
        expect(service.startedFromFavorites, isFalse);

        final expected = service.getNextStation('s3')!;
        expect(expected.id, isNot(5), reason: 'the full list, not favorites');
        unawaited(handler.skipToNext());
        await until(() => handler.currentStation.value?.id == expected.id);
      }, () => routing);
    });
  });

  group('car category', () {
    test(
        'a station picked from a car category keeps next and previous '
        'within it; a pick from another list leaves it', () async {
      backend.addGroup(1, 'copii', 'Copii', [3, 5, 7]);
      await http.runWithClient(() async {
        await startHandler();

        unawaited(handler.playStation(
          stationOf(5),
          fromFavorites: false,
          fromGroup: 'copii',
        ));
        await until(() => handler.currentStation.valueOrNull?.id == 5);
        expect(service.startedFromGroup, 'copii');

        unawaited(handler.skipToNext());
        await until(() => handler.currentStation.value?.id == 7);
        unawaited(handler.skipToNext());
        await until(() => handler.currentStation.value?.id == 3);
        unawaited(handler.skipToPrevious());
        await until(() => handler.currentStation.value?.id == 7);
        expect(service.startedFromGroup, 'copii',
            reason: 'next and previous keep the category');

        unawaited(handler.playStation(stationOf(2), fromFavorites: false));
        await until(() => handler.currentStation.value?.id == 2);
        expect(service.startedFromGroup, isNull);
      }, () => routing);
    });
  });

  group('seek offset', () {
    test('reapplySeekOffset reloads only when the offset changed', () async {
      addTearDown(() => SeekModeManager.changeSeekMode(SeekMode.twoMinutes));
      SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
      final hlsUrl = FakeMetadataBackend.hlsUrlOf('rve-suceava');
      await http.runWithClient(() async {
        await startHandler();
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(hlsUrl, loads: 1);

        await handler.reapplySeekOffset();
        expect(channels.loads, hasLength(1), reason: 'offset unchanged');

        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
        await handler.reapplySeekOffset();
        await untilPlaying(hlsUrl, loads: 2);
      }, () => routing);
    });
  });

  group('playlist metadata', () {
    test('refreshCurrentMetadata keeps the playlist item on screen', () async {
      await http.runWithClient(() async {
        await startHandler();
        await handler.selectStation(stationOf(2));
        handler.enterPlaylistMode();
        const item = PlaylistItem(
          id: 7,
          order: 0,
          type: PlaylistItemType.audio,
          url: 'https://cdn.example.com/sermon.mp3',
          title: 'Predica',
          durationSeconds: 1800,
        );
        handler.updatePlaylistMediaItem(item, index: 0, count: 3);

        handler.refreshCurrentMetadata();

        expect(handler.mediaItem.value?.id, item.url);
        expect(handler.mediaItem.value?.isLive, isFalse);
      }, () => routing);
    });
  });

  group('playlist decoding', () {
    test(
        'a song hint with diacritics survives the playlist fetch (UTF-8 '
        'without a charset)', () async {
      await http.runWithClient(() async {
        final recording = _HintRecordingService(
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
        // Song boundaries every 3 s over the first half minute of the
        // window, where the fake player's playhead sits: whichever the
        // anchor lands on, the next one is reached within seconds.
        final windowStart =
            DateTime.now().millisecondsSinceEpoch ~/ 6000 * 6 - 100 * 6;
        playlistHeader = [
          for (var s = 3; s <= 30; s += 3)
            '#EXT-X-RC-METADATA-CHANGED:EPOCH=${windowStart + s},'
                'X-SONG-ID=99,X-TITLE="Cuprins de harul Tău",'
                'X-ARTIST="Corul Ștefan"',
        ];
        unawaited(handler.playStation(stationOf(1)));
        await untilPlaying(FakeMetadataBackend.hlsUrlOf('rve-suceava'),
            loads: 1);
        await until(() => recording.hints.any((h) => h != null),
            timeout: const Duration(seconds: 10));

        final hint = recording.hints.whereType<SongBoundaryHint>().first;
        expect(hint.title, 'Cuprins de harul Tău');
        expect(hint.artist, 'Corul Ștefan');
      }, () => routing);
    });
  });
}
