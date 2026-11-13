import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/app_launch_options.dart';
import 'package:radio_crestin/components/MiniAudioPlayer.dart';
import 'package:radio_crestin/main.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:radio_crestin/services/announcements_service.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/playback_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_radio_server.dart';
import 'network_conditions.dart';
import 'station_catalog.dart';

/// The app under test, launched once per run against [server] and driven
/// like a listener would, through its screens.
///
/// Every test of a run shares the one app process, as its services are
/// app-wide singletons; [e2eTest] gives each test the app back on its home
/// screen, silent, on a healthy network.
class RadioApp {
  RadioApp._(this.server);

  static RadioApp? _current;
  static FlutterExceptionHandler? _appErrorHandler;

  /// Where Settings keeps "start the last station on launch".
  static const _autoStartPrefsKey = '_autoStartStation';

  /// Where Settings keeps "Mod dezvoltator".
  static const _developerModePrefsKey = 'developer_mode_enabled';

  final FakeRadioServer server;
  late WidgetTester tester;

  AppAudioHandler get audio => GetIt.instance<AppAudioHandler>();
  NetworkService get network => GetIt.instance<NetworkService>();

  /// Launches the app on a fresh install, or puts the running one back on
  /// its home screen.
  ///
  /// [beforeLaunch] runs on the fresh install, before the app starts: to
  /// leave on the device what an older version would have.
  static Future<RadioApp> open(
    WidgetTester tester,
    FakeRadioServer server, {
    Future<void> Function()? beforeLaunch,
  }) async {
    var app = _current;
    if (app == null) {
      app = _current = RadioApp._(server)..tester = tester;
      await app._launch(beforeLaunch);
    } else {
      app.tester = tester;
      FlutterError.onError = _appErrorHandler;
      // The test framework emptied the screen after the last test.
      runApp(const RadioCrestinApp(promptsForUpdates: false));
    }
    await app._waitForStationList();
    return app;
  }

  /// Builds the app's screens anew, as a launch does: Home loads what the
  /// API serves now. The process, and so its services, stay.
  Future<void> relaunch() async {
    runApp(const SizedBox.shrink());
    await tester.pump();
    _watchFirstHomeFrame();
    runApp(const RadioCrestinApp(promptsForUpdates: false));
    await _waitForStationList();
  }

  /// Whether the first frame with the station list, at the last relaunch,
  /// already had the announcement card, settled: not growing or fading in.
  bool? cardInFirstHomeFrame;

  void _watchFirstHomeFrame() {
    cardInFirstHomeFrame = null;
    void check(Duration _) {
      if (find.byKey(_rowKey(Stations.alpha)).evaluate().isEmpty) {
        SchedulerBinding.instance.addPostFrameCallback(check);
        return;
      }
      cardInFirstHomeFrame = announcementCard.evaluate().isNotEmpty &&
          // The empty slot is still there while the card switches in.
          find.byKey(const ValueKey('no-announcements')).evaluate().isEmpty;
    }

    SchedulerBinding.instance.addPostFrameCallback(check);
  }

  Future<void> _waitForStationList() => waitFor(
        () => find.byKey(_rowKey(Stations.alpha)).evaluate().isNotEmpty,
        reason: 'the station list to show',
        timeout: const Duration(seconds: 30),
      );

  Future<void> _launch(Future<void> Function()? beforeLaunch) async {
    await _wipeAppData();
    await beforeLaunch?.call();
    await runRadioCrestin(AppLaunchOptions(
      apiBaseUrl: server.apiBaseUrl,
      internetProbes: [
        InternetProbe(server.internetProbeUrl, (r) => r.statusCode == 204),
      ],
      // Its HLS takes the production path: start variants, and on iOS the
      // hold proxy.
      liveOriginHosts: {server.host},
      reportsAnalytics: false,
      registersForPush: false,
      promptsForUpdates: false,
    ));
    // The app chains its error handlers onto the test's: an error it
    // filters as benign passes, any other still fails the test.
    _appErrorHandler = FlutterError.onError;
  }

  /// What a fresh install has: no settings, cache, favorites or history.
  ///
  /// Auto-start is off, so every test starts silent. With it on, a fresh
  /// install would start a station from the app's bundled list, a real one
  /// streamed over the internet, before the fake catalog arrives.
  static Future<void> _wipeAppData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await prefs.setBool(_autoStartPrefsKey, false);
    final directories = [
      await getApplicationDocumentsDirectory(),
      await getApplicationSupportDirectory(),
      await getTemporaryDirectory(),
    ];
    for (final directory in directories) {
      if (!directory.existsSync()) continue;
      for (final entry in directory.listSync()) {
        try {
          entry.deleteSync(recursive: true);
        } on FileSystemException {
          // The OS holds a few of its own files; they carry no app state.
        }
      }
    }
  }

  /// Back to silence, a healthy network and default settings, after a test.
  Future<void> reset() async {
    server.reset();
    await audio.stop();
    PlaybackPreferences.changePreferDirectStreams(false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PlaybackPreferences.preferDirectStreamsKey);
    await prefs.remove(_developerModePrefsKey);
    // Off, as a fresh install has it here: on, every relaunch would start
    // a station.
    await prefs.setBool(_autoStartPrefsKey, false);
    // The test framework checks its handler is back when a test ends.
    FlutterError.onError = _bindingErrorHandler;
  }

  static FlutterExceptionHandler? _bindingErrorHandler;

  /// Remembers the test's own error handler, before the app's takes over.
  static void captureBindingErrorHandler() =>
      _bindingErrorHandler = FlutterError.onError;

  // ── Actions, as the listener does them ─────────────────────────────────

  static Key _rowKey(FakeStation station) =>
      ValueKey('station-${station.slug}');

  static final _anyRow = find.byWidgetPredicate((widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('station-'));

  /// Drags the station list, as a listener does, until [station]'s row can
  /// be tapped: from the top down, as the list sorts by recommendation, so
  /// a row can be anywhere in it.
  ///
  /// Not `ensureVisible`/`scrollUntilVisible`: the home list's viewport
  /// reports an infinite offset to reveal a row (inside its sticky
  /// header's group), so those jump to the end of the list.
  Future<Finder> showStation(FakeStation station) async {
    final row = find.byKey(_rowKey(station)).hitTestable();
    final position = Scrollable.of(_anyRow.evaluate().first).position;
    for (var step = 0; step < 40; step++) {
      if (position.pixels <= position.minScrollExtent) break;
      await _dragList(up: true);
    }
    for (var step = 0; step < 40 && row.evaluate().isEmpty; step++) {
      if (position.pixels >= position.maxScrollExtent) break;
      await _dragList(up: false);
    }
    if (row.evaluate().isEmpty) {
      fail('${station.title} is not in the station list; ${describe()}');
    }
    return row;
  }

  /// Drags the station list by a third of a screen, then lets it settle.
  Future<void> _dragList({required bool up}) async {
    final distance = tester.view.physicalSize.height /
        tester.view.devicePixelRatio /
        3;
    await tester.drag(_anyRow.hitTestable().first,
        Offset(0, up ? distance : -distance));
    await pumpFor(const Duration(milliseconds: 600));
  }

  /// Taps [station] in the station list.
  Future<DateTime> tapStation(FakeStation station) async {
    final row = await showStation(station);
    final at = DateTime.now();
    await tester.tap(row);
    await tester.pump();
    return at;
  }

  Finder get _miniPlayer => find.byType(MiniAudioPlayer);

  /// Taps the mini player's play/pause button.
  Future<void> tapMiniPlayerButton() async {
    final button = find.descendant(
      of: _miniPlayer,
      matching: find.byWidgetPredicate((widget) =>
          widget is Icon &&
          (widget.icon == Icons.pause_rounded ||
              widget.icon == Icons.play_arrow_rounded)),
    );
    await tester.tap(button.first);
    await tester.pump();
  }

  /// Opens the full player from the mini player.
  Future<void> openFullPlayer() async {
    await tester.tap(find.descendant(
      of: _miniPlayer,
      matching: find.text(audio.currentStation.value!.title),
    ));
    await pumpFor(const Duration(seconds: 1));
  }

  /// Taps the button with [tooltip].
  Future<DateTime> tapTooltip(String tooltip) async {
    final at = DateTime.now();
    await tester.tap(find.byTooltip(tooltip).hitTestable());
    await tester.pump();
    return at;
  }

  /// Opens Settings from the home screen's app bar.
  Future<void> openSettings() async {
    await tapTooltip('Setări aplicație');
    await pumpFor(const Duration(seconds: 1));
  }

  /// Scrolls Settings to the switch of the row titled [title] and flips it.
  Future<DateTime> toggleSetting(String title) async {
    final row = find.ancestor(
        of: find.text(title), matching: find.byType(ListTile));
    final scrollable = find
        .descendant(
            of: find.byType(SettingsPage), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(row, 200, scrollable: scrollable);
    final toggle = find
        .descendant(of: row, matching: find.byType(Switch))
        .hitTestable();
    if (toggle.evaluate().isEmpty) {
      fail('The "$title" switch cannot be tapped; ${describe()}');
    }
    final at = DateTime.now();
    await tester.tap(toggle);
    await pumpFor(const Duration(seconds: 1));
    return at;
  }

  /// Presses the system BACK button: the top route pops or, on the home
  /// screen, Android takes the app off the screen.
  Future<DateTime> pressBack() async {
    final at = DateTime.now();
    await tester.binding.handlePopRoute();
    await _waitInRealTime(() => !_onScreen,
        reason: 'the app to leave the screen');
    return at;
  }

  /// Turns on Settings' "start the last station", which on iOS also starts
  /// it on every return to the app.
  Future<void> turnOnAutoStart() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoStartPrefsKey, true);
  }

  /// Switches to another app and back, as the system reports it: through
  /// the background and on the screen again.
  Future<void> leaveAndReturn() async {
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await _waitInRealTime(() => _onScreen,
        reason: 'the app to be on the screen again');
  }

  /// Whether the app is on the screen, waiting in the background (paused)
  /// or closed (detached).
  AppLifecycleState? get lifecycle => WidgetsBinding.instance.lifecycleState;

  /// The app is on the screen and draws frames. Off the screen it draws
  /// none, so waiting must not pump. Not read from [lifecycle], which the
  /// test framework clears after each test.
  bool get _onScreen => SchedulerBinding.instance.framesEnabled;

  /// Waits for [condition] without drawing frames, as a pump would never
  /// return while the app changes between on and off the screen.
  Future<void> _waitInRealTime(
    bool Function() condition, {
    required String reason,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) {
        fail('Timed out after ${timeout.inSeconds}s waiting for $reason; '
            'lifecycle=${lifecycle?.name}');
      }
      await Future<void>.delayed(_tickInterval);
    }
  }

  /// A cold start as far as announcements go: the service starts again
  /// from what it kept on the device and loads as the app's startup does,
  /// and Home is built anew. The rest of the app (audio, stations) runs on.
  Future<void> coldStartAnnouncements() async {
    final getIt = GetIt.instance;
    getIt<AnnouncementsService>().dispose();
    await getIt.unregister<AnnouncementsService>();
    final service = AnnouncementsService(
      prefs: await SharedPreferences.getInstance(),
      pushEnabled: false,
    );
    getIt.registerSingleton<AnnouncementsService>(service);
    await service.loadAtStartup();
    await relaunch();
  }

  /// Pulls the station list down from its top, as a listener refreshes.
  Future<void> pullToRefresh() async {
    final position = Scrollable.of(_anyRow.evaluate().first).position;
    for (var step = 0; step < 40; step++) {
      if (position.pixels <= position.minScrollExtent) break;
      await _dragList(up: true);
    }
    // Far enough to arm the indicator through iOS's bounce friction.
    await tester.timedDrag(_anyRow.hitTestable().first, const Offset(0, 600),
        const Duration(milliseconds: 800));
    await pumpFor(const Duration(seconds: 3));
  }

  /// The announcement card on Home.
  static final announcementCard =
      find.byKey(const ValueKey('announcement-card'));

  /// Swipes the announcement card to the next announcement.
  Future<void> swipeAnnouncement() async {
    await tester.drag(announcementCard.hitTestable(), const Offset(-300, 0));
    await pumpFor(const Duration(seconds: 1));
  }

  /// Taps the on-screen text [text], such as a button's label.
  Future<void> tapText(String text) async {
    await tester.tap(find.text(text).hitTestable());
    await pumpFor(const Duration(seconds: 1));
  }

  /// Taps "Ascunde" on the announcement on screen.
  Future<void> tapDismiss() => tapKey('announcement-dismiss');

  /// Whether a widget keyed [key] is on the screen where it can be tapped.
  bool findsKey(String key) =>
      find.byKey(ValueKey(key)).hitTestable().evaluate().isNotEmpty;

  /// Taps the widget keyed [key].
  Future<void> tapKey(String key) async {
    await tester.tap(find.byKey(ValueKey(key)).hitTestable().first);
    await pumpFor(const Duration(seconds: 1));
  }

  /// Whether [text] is on the screen where a listener could tap it.
  bool showsText(String text) =>
      find.text(text, findRichText: true).hitTestable().evaluate().isNotEmpty;

  // ── What the listener hears and sees ───────────────────────────────────

  /// The station the player has, as the fake server knows it.
  FakeStation get currentStation =>
      Stations.bySlug(audio.currentStation.value!.slug);

  /// Expects [station] to play within [within]: the player renders its
  /// audio (its position moves for [listenFor]), its stream was fetched
  /// from the server, and the mini player shows it playing.
  Future<void> expectPlaying(
    FakeStation station, {
    required DateTime since,
    Duration within = const Duration(seconds: 20),
    Duration listenFor = const Duration(seconds: 5),
  }) async {
    // Its stream fetched since [since] too: the player can still be
    // playing what it buffered before (an outage drains it), and its
    // position starts over once the new load replaces it.
    await waitFor(
      () =>
          _isPlaying(station) &&
          server.mediaBytesSent(station, since: since) > 0,
      reason: '${station.title} to play from its stream',
      timeout: within,
    );
    await expectAudioAdvances(listenFor);
    expect(
      find.descendant(of: _miniPlayer, matching: find.text(station.title)),
      findsWidgets,
      reason: 'the mini player shows ${station.title}',
    );
    expect(
      find.descendant(
          of: _miniPlayer, matching: find.byIcon(Icons.pause_rounded)),
      findsOneWidget,
      reason: 'the mini player offers to pause',
    );
  }

  /// Expects [station] to play from its [origin] stream (HLS or MP3) within
  /// [within] of [since], and its other stream to stop sending.
  ///
  /// The mini player is not checked: Settings may cover it.
  Future<void> expectPlayingFrom(
    FakeStation station,
    Origin origin, {
    required DateTime since,
    Duration within = const Duration(seconds: 20),
  }) async {
    final wantsHls = origin == Origin.hls;
    await waitFor(
      () =>
          _isPlaying(station) && (audio.loadedStreamType == 'HLS') == wantsHls,
      reason: '${station.title} to play its ${origin.name} stream',
      timeout: within,
    );
    await expectAudioAdvances(const Duration(seconds: 5));
    expect(server.mediaBytesSent(station, since: since, origin: origin),
        greaterThan(0),
        reason: 'the audio came from the ${origin.name} stream');

    final other = wantsHls ? Origin.mp3 : Origin.hls;
    int otherBytes() =>
        server.mediaBytesSent(station, since: since, origin: other);
    await pumpFor(const Duration(seconds: 2));
    final settledBytes = otherBytes();
    await pumpFor(const Duration(seconds: 6));
    expect(otherBytes(), settledBytes,
        reason: 'the ${other.name} stream stopped sending');
  }

  bool _isPlaying(FakeStation station) {
    final state = audio.playbackState.value;
    return audio.currentStation.value?.slug == station.slug &&
        state.playing &&
        state.processingState.name == 'ready';
  }

  /// How far the player has played its source: the native player's last
  /// position, moved on by the time since while it plays and is ready, as
  /// just_audio computes it. Unlike `AudioPlayer.position` it is not
  /// clamped to the duration, which iOS gives as zero for an endless MP3
  /// stream; a stall still stops it, as the player then reports buffering.
  Duration get _renderedPosition {
    final player = audio.player;
    final event = player.playbackEvent;
    final ready = player.processingState.name == 'ready';
    if (!player.playing || !ready) return event.updatePosition;
    return event.updatePosition +
        DateTime.now().difference(event.updateTime) * player.speed;
  }

  /// Expects the player's position to move by most of [duration], live,
  /// over [duration]: the audio really plays, without stalls.
  Future<void> expectAudioAdvances(Duration duration) async {
    final from = _renderedPosition;
    await pumpFor(duration);
    final advanced = _renderedPosition - from;
    expect(advanced, greaterThanOrEqualTo(duration * 0.7),
        reason: 'audio played for ${duration.inSeconds}s '
            '(advanced ${advanced.inMilliseconds} ms); ${describe()}');
  }

  /// Expects silence: no audio rendered for [duration].
  Future<void> expectSilent({
    Duration duration = const Duration(seconds: 3),
  }) async {
    final from = _renderedPosition;
    await pumpFor(duration);
    final advanced = _renderedPosition - from;
    expect(advanced, lessThan(const Duration(milliseconds: 500)),
        reason: 'no audio plays; ${describe()}');
    expect(
      find.descendant(
          of: _miniPlayer, matching: find.byIcon(Icons.play_arrow_rounded)),
      findsOneWidget,
      reason: 'the mini player offers to play',
    );
  }

  // ── Time ───────────────────────────────────────────────────────────────

  /// Lets [duration] of real time pass, drawing frames while the app is on
  /// the screen.
  Future<void> pumpFor(Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      await _tick();
    }
  }

  static const _tickInterval = Duration(milliseconds: 200);

  Future<void> _tick() => _onScreen
      ? tester.pump(_tickInterval)
      : Future<void>.delayed(_tickInterval);

  /// Draws frames until [condition] holds, failing after [timeout].
  Future<void> waitFor(
    bool Function() condition, {
    required String reason,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) {
        fail('Timed out after ${timeout.inSeconds}s waiting for $reason; '
            '${describe()}');
      }
      await _tick();
    }
  }

  /// The player's state, for failure messages.
  String describe() {
    final state = audio.playbackState.value;
    final recent = server.requests.reversed
        .take(6)
        .map((r) => '${r.path} (${r.bytesSent} B)')
        .join(', ');
    final rows = find
        .byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('station-'))
        .evaluate()
        .map((e) => (e.widget.key! as ValueKey<String>).value)
        .join(',');
    return 'rows on screen: [$rows] '
        'station=${audio.currentStation.value?.slug} '
        'playing=${state.playing} state=${state.processingState.name} '
        'position=$_renderedPosition '
        'duration=${audio.player.playbackEvent.duration} '
        'player=${audio.player.processingState.name}/'
        '${audio.player.playing ? 'playing' : 'paused'} '
        'buffered=${audio.player.bufferedPosition} '
        'network=${network.status.value.name} recent requests: $recent';
  }
}

/// A test that drives the app: it opens it, runs [body] and leaves it
/// silent on a healthy network for the next test.
void e2eTest(
  String description,
  Future<void> Function(RadioApp app) body, {
  required FakeRadioServer Function() server,
  Future<void> Function()? beforeLaunch,
  Timeout timeout = const Timeout(Duration(minutes: 3)),
  bool skip = false,
}) {
  testWidgets(skip: skip, description, (tester) async {
    RadioApp.captureBindingErrorHandler();
    final app =
        await RadioApp.open(tester, server(), beforeLaunch: beforeLaunch);
    try {
      await body(app);
    } finally {
      await app.reset();
    }
  }, timeout: timeout);
}
