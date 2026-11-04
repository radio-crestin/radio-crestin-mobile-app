import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/app_launch_options.dart';
import 'package:radio_crestin/components/MiniAudioPlayer.dart';
import 'package:radio_crestin/main.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
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
  static Future<RadioApp> open(
    WidgetTester tester,
    FakeRadioServer server,
  ) async {
    var app = _current;
    if (app == null) {
      app = _current = RadioApp._(server)..tester = tester;
      await app._launch();
    } else {
      app.tester = tester;
      FlutterError.onError = _appErrorHandler;
      // The test framework emptied the screen after the last test.
      runApp(const RadioCrestinApp(promptsForUpdates: false));
    }
    await app._waitForStationList();
    return app;
  }

  Future<void> _waitForStationList() => waitFor(
        () => find.byKey(_rowKey(Stations.alpha)).evaluate().isNotEmpty,
        reason: 'the station list to show',
        timeout: const Duration(seconds: 30),
      );

  Future<void> _launch() async {
    await _wipeAppData();
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
    await waitFor(
      () => _isPlaying(station),
      reason: '${station.title} to play',
      timeout: within,
    );
    await expectAudioAdvances(listenFor);
    expect(server.mediaBytesSent(station, since: since), greaterThan(0),
        reason: 'the audio of ${station.title} came from its stream');
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

  /// Lets [duration] of real time pass, drawing frames.
  Future<void> pumpFor(Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

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
      await tester.pump(const Duration(milliseconds: 200));
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
  Timeout timeout = const Timeout(Duration(minutes: 3)),
}) {
  testWidgets(description, (tester) async {
    RadioApp.captureBindingErrorHandler();
    final app = await RadioApp.open(tester, server());
    try {
      await body(app);
    } finally {
      await app.reset();
    }
  }, timeout: timeout);
}
