import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/desktop_menu_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/sleep_timer_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/tv/tv_platform.dart';
import 'package:radio_crestin/tv/tv_shell.dart';
import 'package:radio_crestin/tv/tv_theme.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// Plays the way the desktop launch asks, recording each call.
class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  _FakeAudioHandler(this.stationDataService, {required this.lastPlayed});

  @override
  final StationDataService stationDataService;

  /// The station played last, as the launch finds it.
  final Station lastPlayed;

  /// When set, looking up [lastPlayed] lasts until this completes.
  Completer<void>? lastPlayedLookup;

  final calls = <String>[];

  @override
  final BehaviorSubject<double> listenerVolume =
      BehaviorSubject<double>.seeded(1);

  @override
  final GraphQLClient graphqlClient = GraphQLClient(
    link: HttpLink('https://example.com/graphql'),
    cache: GraphQLCache(),
  );

  @override
  final BehaviorSubject<Station?> currentStation =
      BehaviorSubject<Station?>.seeded(null);

  @override
  final BehaviorSubject<bool> isVideoMode = BehaviorSubject.seeded(false);

  @override
  final BehaviorSubject<bool> audioOnlyFallback =
      BehaviorSubject.seeded(false);

  @override
  late final SleepTimerService sleepTimer = SleepTimerService(
    stopPlayback: () async {},
    setVolume: (_) async {},
  );

  @override
  final BehaviorSubject<StreamInfo?> currentStreamInfo =
      BehaviorSubject<StreamInfo?>.seeded(null);

  @override
  final BehaviorSubject<List<StreamEvent>> recentStreamEvents =
      BehaviorSubject<List<StreamEvent>>.seeded(const []);

  @override
  bool get isCasting => false;

  @override
  Future<Station?> getLastPlayedStation() async {
    await lastPlayedLookup?.future;
    return lastPlayed;
  }

  @override
  Future<void> playStation(
    Station station, {
    bool? fromFavorites,
    String? fromGroup,
  }) async {
    calls.add('playStation:${station.slug}');
    currentStation.add(station);
  }

  @override
  Future<void> selectStation(Station station) async {
    calls.add('selectStation:${station.slug}');
    currentStation.add(station);
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

Station _station(int id, String slug, String title) =>
    StationFactory.createStation(
      id: id,
      slug: slug,
      title: title,
      thumbnailUrl: null,
    );

/// The channels app_links talks to the native side over.
const _linkMethods = MethodChannel('com.llfbandit.app_links/messages');
const _linkEvents = EventChannel('com.llfbandit.app_links/events');

void main() {
  late StationDataService service;
  late _FakeAudioHandler handler;
  late String? initialLink;
  late MockStreamHandlerEventSink? linkSink;

  final alpha = _station(1, 'alpha', 'Radio Alpha');
  final bravo = _station(2, 'bravo', 'Radio Bravo');
  final charlie = _station(3, 'charlie', 'Charlie Worship');

  setUp(() async {
    TvPlatform.debugOverride(desktop: true);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<SharedPreferences>(prefs)
      ..registerSingleton<PlayCountService>(PlayCountService());

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in const [
      MethodChannel('posthog_flutter'),
      MethodChannel(DesktopMenuService.channelName),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    initialLink = null;
    linkSink = null;
    messenger.setMockMethodCallHandler(_linkMethods, (call) async {
      if (call.method == 'getInitialLink') return initialLink;
      return null;
    });
    messenger.setMockStreamHandler(
      _linkEvents,
      MockStreamHandler.inline(
        onListen: (_, events) {
          linkSink = events;
        },
        onCancel: (_) {
          linkSink = null;
        },
      ),
    );

    // The station list has not loaded yet, as at launch.
    service = StationDataService(
      graphqlClient: GraphQLClient(
        link: HttpLink('https://example.com/graphql'),
        cache: GraphQLCache(),
      ),
    );
    handler = _FakeAudioHandler(service, lastPlayed: alpha);
    GetIt.instance
      ..registerSingleton<StationDataService>(service)
      ..registerSingleton<PlaylistController>(PlaylistController(
        videoService: VideoPlaybackService(),
        syncService: PlaylistSyncService(),
      ))
      ..registerSingleton<AppAudioHandler>(handler);
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_linkMethods, null);
    messenger.setMockStreamHandler(_linkEvents, null);
    TvPlatform.debugOverride();
    handler.sleepTimer.cancel();
    service.dispose();
    await GetIt.instance.reset();
  });

  /// Lets the launch and the links run their course.
  ///
  /// Waiting for the station list ends with cancelling an rxdart
  /// subscription, which completes outside the test's fake async: hence
  /// the real turns between the frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pump();
  }

  /// Launches the desktop app and lets `getInitialLink()` answer.
  Future<void> launch(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(theme: tvTheme, home: const TvShell()));
    await settle(tester);
  }

  /// Opens [link] the way a click on it does while the app runs.
  Future<void> openLink(WidgetTester tester, String link) async {
    linkSink!.success(link);
    await tester.pump();
  }

  /// The station list arrives from the network.
  Future<void> loadStations(WidgetTester tester) async {
    service.applyPublicStationsForTest([alpha, bravo, charlie]);
    await settle(tester);
  }

  /// Closes the app, so its link subscription ends with the test.
  Future<void> quit(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }

  testWidgets('a link that comes while the launch waits for the stations '
      'plays its station, and the last station never starts', (tester) async {
    await launch(tester);
    // macOS hands the link that opened the app to the stream, after
    // getInitialLink() has found none.
    await openLink(tester, 'radiocrestin://bravo');

    await loadStations(tester);

    expect(handler.calls, ['playStation:bravo']);
    expect(handler.currentStation.value?.slug, 'bravo');
    await quit(tester);
  });

  testWidgets('a link that comes while the last station is looked up wins',
      (tester) async {
    handler.lastPlayedLookup = Completer<void>();
    await launch(tester);
    await loadStations(tester);

    await openLink(tester, 'radiocrestin://charlie');
    await settle(tester);
    handler.lastPlayedLookup!.complete();
    await settle(tester);

    expect(handler.calls, ['playStation:charlie']);
    await quit(tester);
  });

  testWidgets('a link that names no station during the launch starts the '
      'last station, once', (tester) async {
    await launch(tester);
    await openLink(tester, 'radiocrestin://gone');

    await loadStations(tester);

    expect(handler.calls, ['playStation:alpha']);
    await quit(tester);
  });

  testWidgets('without a link, the launch starts the last station',
      (tester) async {
    await launch(tester);
    await loadStations(tester);

    expect(handler.calls, ['playStation:alpha']);
    await quit(tester);
  });

  testWidgets('with "Pornește automat" off, the launch only shows the last '
      'station', (tester) async {
    await GetIt.instance<SharedPreferences>()
        .setBool('_autoStartStation', false);
    await launch(tester);
    await loadStations(tester);

    expect(handler.calls, ['selectStation:alpha']);
    await quit(tester);
  });

  testWidgets('the link that opened the app plays its station, once',
      (tester) async {
    initialLink = 'radiocrestin://bravo';
    await launch(tester);
    // app_links hands the launch link to the stream too.
    await openLink(tester, 'radiocrestin://bravo');

    await loadStations(tester);

    expect(handler.calls, ['playStation:bravo']);
    await quit(tester);
  });

  testWidgets('a link while the app runs plays its station; one that names '
      'none leaves the radio as it is', (tester) async {
    await launch(tester);
    await loadStations(tester);
    expect(handler.calls, ['playStation:alpha']);

    await openLink(tester, 'radiocrestin://charlie');
    await settle(tester);
    await openLink(tester, 'radiocrestin://gone');
    await settle(tester);

    expect(handler.calls, ['playStation:alpha', 'playStation:charlie']);
    await quit(tester);
  });
}
