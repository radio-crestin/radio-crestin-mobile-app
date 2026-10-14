import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
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

import 'helpers/fake_connectivity.dart';
import 'helpers/fake_just_audio_channels.dart';
import 'helpers/fake_metadata_backend.dart';

class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

/// The play() retry loop against the network: when it waits, when it
/// retries, and when its connection error reaches the user. A real
/// AppAudioHandler over faked just_audio channels; real (short) time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FakeMetadataBackend backend;
  late FakeJustAudioChannels channels;
  late StationDataService service;
  late AppAudioHandler handler;
  late http.Client routing;
  NetworkService? monitored;

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
    backend = FakeMetadataBackend(FakeClock(DateTime.utc(2026, 10, 13, 12)));
    for (var id = 1; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    backend.addStation(11, 's11', 'Station 11', hls: true); // two streams
    channels = FakeJustAudioChannels()..install();
    routing = MockClient(
        (request) => backend.client.get(request.url, headers: request.headers));
    monitored = null;
    // Unmonitored by default: online, and checkInternet() says yes at once.
    NetworkService();
  });

  tearDown(() async {
    await http.runWithClient(() => handler.stop(), () => routing);
    AnalyticsService.instance.endListening();
    service.dispose();
    channels.uninstall();
    monitored?.dispose();
    NetworkService();
    await GetIt.instance.reset();
  });

  /// A monitored NetworkService on a fake network, as main() sets it up,
  /// whose probe [answers] or not, after [probeDelay]. Create it before
  /// [startHandler].
  Future<FakeConnectivity> monitoredNetwork(
    List<ConnectivityResult> initial, {
    bool answers = true,
    Duration probeDelay = Duration.zero,
    Duration probeTimeout = const Duration(milliseconds: 200),
  }) async {
    final connectivity = FakeConnectivity(initial);
    monitored = NetworkService(
      connectivity: connectivity,
      httpClient: MockClient((_) async {
        await Future<void>.delayed(probeDelay);
        if (!answers) throw const SocketException('No route to host');
        return http.Response('', 204);
      }),
      probes: [
        InternetProbe(Uri.parse('https://probe.example/generate_204'),
            (response) => response.statusCode == 204),
      ],
      probeTimeout: probeTimeout,
    );
    await monitored!.initialize();
    return connectivity;
  }

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

  int loadsOf(String part) =>
      channels.loads.where((url) => url.contains(part)).length;

  List<ConnectionError> collectErrors() {
    final errors = <ConnectionError>[];
    final subscription = handler.connectionError.listen(errors.add);
    addTearDown(subscription.cancel);
    return errors;
  }

  /// The loads of [part] made when each error was shown.
  List<int> loadsAtErrors(String part) {
    final loads = <int>[];
    final subscription =
        handler.connectionError.listen((_) => loads.add(loadsOf(part)));
    addTearDown(subscription.cancel);
    return loads;
  }

  /// The network drops and comes back while a load is still out.
  Future<void> outageDuringLoad(FakeConnectivity connectivity) async {
    connectivity.emit(none);
    await until(() => monitored!.isOffline.value);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    connectivity.emit(wifi);
    await until(() => !monitored!.isOffline.value);
  }

  test('a play from the lock screen while a loop retries shows its error',
      () async {
    await http.runWithClient(() async {
      await startHandler();
      channels.failingUrlParts.add('/s2/');
      final errors = collectErrors();
      unawaited(handler.playStation(stationOf(2)));
      await until(() => errors.length == 1);

      // The loop waits out its backoff; the user presses Play (lock
      // screen, headset, car): a new loop takes over.
      final loadsBefore = channels.loads.length;
      unawaited(handler.play());
      await until(() => channels.loads.length > loadsBefore);
      await until(() => errors.length == 2);

      expect(handler.isPlayingOrConnecting, isTrue,
          reason: 'the spinner of the new loop stays');
    }, () => routing);
  });

  test('offline: no error, no retries, then at once when a network is back',
      () async {
    final connectivity = await monitoredNetwork(none);
    await http.runWithClient(() async {
      await startHandler();
      channels
        ..failingUrlParts.add('/s2/')
        ..failureCode = '0'; // how ExoPlayer reports a network failure
      final errors = collectErrors();
      unawaited(handler.playStation(stationOf(2)));
      await until(() => channels.loads.isNotEmpty);
      final firstPass = channels.loads.length;

      // Online, the next attempt would come after 1 s.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(channels.loads, hasLength(firstPass),
          reason: 'no player churn without a network');
      expect(errors, isEmpty, reason: 'the offline banner explains it');

      channels.failingUrlParts.clear();
      final stopwatch = Stopwatch()..start();
      connectivity.emit(wifi);
      await until(() => handler.player.playing);

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'not after the 30 s no-network backoff');
      expect(errors, isEmpty);
    }, () => routing);
  });

  test('a network back without internet ends the no-network wait too',
      () async {
    final connectivity = await monitoredNetwork(none, answers: false);
    await http.runWithClient(() async {
      await startHandler();
      channels
        ..failingUrlParts.add('/s2/')
        ..failureCode = '0';
      final errors = collectErrors();
      unawaited(handler.playStation(stationOf(2)));
      await until(() => channels.loads.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final firstPass = channels.loads.length;

      connectivity.emit(wifi);
      await until(
          () => monitored!.status.value == ConnectionStatus.noInternet);
      // Woken at once, then the usual 1, 2, 5 s pace: the attempts are the
      // check, not the 30 s no-network wait.
      await until(() => channels.loads.length >= firstPass + 2,
          timeout: const Duration(seconds: 6));

      expect(errors, isEmpty, reason: 'still no internet: the banner says so');
    }, () => routing);
  });

  test('a network that drops again at once does not wake the wait',
      () async {
    final connectivity = await monitoredNetwork(none);
    await http.runWithClient(() async {
      await startHandler();
      channels
        ..failingUrlParts.add('/s2/')
        ..failureCode = '0';
      unawaited(handler.playStation(stationOf(2)));
      await until(() => channels.loads.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final firstPass = channels.loads.length;

      connectivity.emit(wifi);
      await until(() => !monitored!.isOffline.value);
      connectivity.emit(none);
      await until(() => monitored!.isOffline.value);
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(channels.loads, hasLength(firstPass),
          reason: 'offline again: the no-network backoff keeps waiting');
    }, () => routing);
  });

  test('after an outage, a station that still fails gets its error',
      () async {
    final connectivity = await monitoredNetwork(none);
    await http.runWithClient(() async {
      await startHandler();
      channels.failingUrlParts.add('/s2/'); // the station is down: HTTP 404
      final errors = collectErrors();
      unawaited(handler.playStation(stationOf(2)));
      await until(() => channels.loads.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(errors, isEmpty, reason: 'offline: not the station, yet');

      connectivity.emit(wifi);
      await until(() => errors.isNotEmpty, timeout: const Duration(seconds: 8));

      expect(errors.single.reason, ConnectionErrorReason.httpError);
    }, () => routing);
  });

  for (final code in ['404', '0']) {
    test('the internet lost and back mid-pass: no error from that pass '
        '(code $code)', () async {
      final connectivity = await monitoredNetwork(wifi);
      await http.runWithClient(() async {
        await startHandler();
        channels
          ..failingUrlParts.add('/s2/')
          ..failureCode = code
          ..loadDelay = const Duration(milliseconds: 1500);
        final errors = collectErrors();
        final loadsAtError = loadsAtErrors('/s2/');
        unawaited(handler.playStation(stationOf(2)));
        await until(() => loadsOf('/s2/') == 1);

        await outageDuringLoad(connectivity);
        await until(() => channels.finishedLoads.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(errors, isEmpty,
            reason: 'that pass overlapped an outage: not the station');

        await until(() => errors.isNotEmpty,
            timeout: const Duration(seconds: 8));
        expect(loadsAtError.single, greaterThanOrEqualTo(2),
            reason: 'from a later pass, the internet up all along');
      }, () => routing);
    });
  }

  test('two streams, the internet lost and back during the first: not '
      'blamed on the station', () async {
    final connectivity = await monitoredNetwork(wifi);
    await http.runWithClient(() async {
      await startHandler();
      channels
        ..failingUrlParts.add('/s11/')
        ..loadDelay = const Duration(milliseconds: 1500);
      final errors = collectErrors();
      final loadsAtError = loadsAtErrors('/s11/');
      unawaited(handler.playStation(stationOf(11)));
      await until(() => loadsOf('/s11/') == 1);

      // The second stream of that pass fails once the network is back.
      await outageDuringLoad(connectivity);
      await until(() => errors.isNotEmpty,
          timeout: const Duration(seconds: 12));

      expect(loadsAtError.single, greaterThanOrEqualTo(3),
          reason: 'shown after a full pass the internet was up for');
    }, () => routing);
  });

  test('an outage longer than the buffer resumes on HLS, not the fallback',
      () async {
    final connectivity = await monitoredNetwork(wifi);
    await http.runWithClient(() async {
      await startHandler();
      unawaited(handler.playStation(stationOf(11)));
      await until(() => handler.player.playing && loadsOf('hls.example') == 1);

      // A tunnel: no network, and the buffer runs dry while it lasts.
      connectivity.emit(none);
      await until(() => monitored!.isOffline.value);
      channels
        ..failingUrlParts.add('/s11/')
        ..failureCode = '0';
      channels.emitProcessingState(2);
      // The stall reattempts after 3 s; both streams fail offline.
      await until(() => loadsOf('stream.example') >= 1,
          timeout: const Duration(seconds: 8));
      expect(handler.player.playing, isFalse,
          reason: 'the loop stops the player between attempts');
      expect(handler.playbackState.value.playing, isTrue,
          reason: 'the session must not say paused while it reconnects: '
              'audio_service would leave the foreground, which Android 12+ '
              'does not let a backgrounded app re-enter');
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.loading);

      channels.failingUrlParts.clear();
      final loadsBefore = channels.loads.length;
      final sessionPlaying = <bool>[];
      final sessionSub = handler.playbackState
          .listen((state) => sessionPlaying.add(state.playing));
      addTearDown(sessionSub.cancel);
      connectivity.emit(wifi);
      await until(() => channels.finishedLoads.length > loadsBefore &&
          handler.player.processingState == ProcessingState.ready);
      await until(() => handler.player.playing);

      expect(channels.loads.last, contains('hls.example'),
          reason: 'the outage is no fault of the HLS stream: the audio comes '
              'back with its forward buffer, not on the direct stream');
      expect(sessionPlaying, isNot(contains(false)),
          reason: 'not even between the load and play(): a session that '
              'says paused takes the backgrounded app out of the foreground');
    }, () => routing);
  });

  test('a slow internet check outlasting the next pass: one error only',
      () async {
    await monitoredNetwork(wifi,
        probeDelay: const Duration(milliseconds: 1500),
        probeTimeout: const Duration(seconds: 3));
    await http.runWithClient(() async {
      await startHandler();
      channels
        ..failingUrlParts.add('/s2/')
        ..failureCode = '0';
      final errors = collectErrors();
      unawaited(handler.playStation(stationOf(2)));
      await until(() => loadsOf('/s2/') >= 4,
          timeout: const Duration(seconds: 12));
      await Future<void>.delayed(const Duration(milliseconds: 1800));

      expect(errors, hasLength(1));
    }, () => routing);
  });

  test('a retry connecting while the error waits on its check: no error',
      () async {
    await monitoredNetwork(wifi,
        probeDelay: const Duration(milliseconds: 2500),
        probeTimeout: const Duration(seconds: 4));
    await http.runWithClient(() async {
      await startHandler();
      channels
        ..failingUrlParts.add('/s2/')
        ..failureCode = '0';
      final errors = collectErrors();
      unawaited(handler.playStation(stationOf(2)));
      await until(() => loadsOf('/s2/') == 1);
      channels.failingUrlParts.clear(); // the next attempt, 1 s on, works

      await until(() => handler.player.playing);
      await Future<void>.delayed(const Duration(milliseconds: 2500));

      expect(errors, isEmpty, reason: 'the audio already came back');
    }, () => routing);
  });

  test('an HTTP error is an answer: the internet is not probed', () async {
    var probes = 0;
    final connectivity = FakeConnectivity(wifi);
    monitored = NetworkService(
      connectivity: connectivity,
      httpClient: MockClient((_) async {
        probes++;
        throw const SocketException('No route to host');
      }),
      probes: [
        InternetProbe(Uri.parse('https://probe.example/generate_204'),
            (response) => response.statusCode == 204),
      ],
      probeTimeout: const Duration(milliseconds: 200),
    );
    await monitored!.initialize();
    await http.runWithClient(() async {
      await startHandler();
      channels
        ..failingUrlParts.add('/s2/')
        // How AVPlayer reports a 404; ExoPlayer reports every source error
        // as code 0, so this rule only helps on iOS.
        ..failureCode = '-1100';
      final errors = collectErrors();
      unawaited(handler.playStation(stationOf(2)));
      await until(() => errors.isNotEmpty);

      expect(monitored!.status.value, ConnectionStatus.online);
      expect(errors.single.reason, ConnectionErrorReason.httpError);
      // Only the check before showing the error, which a failing probe
      // cannot overturn: the 404 itself vouches for the internet.
      expect(probes, lessThanOrEqualTo(1));
    }, () => routing);
  });
}
