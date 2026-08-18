/// Widget tests for the Android TV full-bleed video chrome (TvNowPlaying).
///
/// On a 10-foot screen the back button, title scrim and transport row sit on
/// top of the picture, so they must step aside quickly while something is
/// playing — and come straight back on any remote press. While paused or
/// buffering they stay pinned: nothing is moving, so hiding them would leave
/// the viewer on a still frame with no way to tell what happened.
library;

import 'package:audio_service/audio_service.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';
import 'package:video_player/video_player.dart';

import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/tv/pages/tv_now_playing.dart';
import 'package:radio_crestin/tv/widgets/tv_video_surface.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/fake_video_player_platform.dart';
import 'helpers/station_factory.dart';

/// Minimal AppAudioHandler stand-in: only the streams TvNowPlaying reads.
class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  _FakeAudioHandler(this._videoService);

  final VideoPlaybackService _videoService;

  @override
  final BehaviorSubject<Station?> currentStation = BehaviorSubject.seeded(null);

  @override
  final BehaviorSubject<bool> isVideoMode = BehaviorSubject.seeded(true);

  @override
  VideoPlaybackService get videoService => _videoService;

  /// Pushes a playback state the page's listener understands.
  void emitPlayback({required bool playing, bool buffering = false}) {
    playbackState.add(PlaybackState(
      playing: playing,
      processingState:
          buffering ? AudioProcessingState.buffering : AudioProcessingState.ready,
    ));
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FakeStationDataService implements StationDataService {
  @override
  final BehaviorSubject<List<Station>> stations =
      BehaviorSubject.seeded(<Station>[]);

  @override
  final BehaviorSubject<List<String>> favoriteStationSlugs =
      BehaviorSubject.seeded(<String>[]);

  @override
  noSuchMethod(Invocation invocation) => null;
}

void main() {
  late FakeVideoPlayerPlatform platform;
  late VideoPlaybackService videoService;
  late _FakeAudioHandler audio;
  late PlaylistController playlist;

  final station = StationFactory.createStation(
    id: 1,
    slug: 'tv-test',
    title: 'TV Test',
    stationType: 'tv',
  );

  setUp(() {
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    videoService = VideoPlaybackService();
    audio = _FakeAudioHandler(videoService)..currentStation.add(station);
    playlist = PlaylistController(
      videoService: videoService,
      syncService: PlaylistSyncService(),
    );

    for (final reset in [
      () => GetIt.I.isRegistered<AppAudioHandler>()
          ? GetIt.I.unregister<AppAudioHandler>()
          : null,
      () => GetIt.I.isRegistered<StationDataService>()
          ? GetIt.I.unregister<StationDataService>()
          : null,
      () => GetIt.I.isRegistered<PlaylistController>()
          ? GetIt.I.unregister<PlaylistController>()
          : null,
    ]) {
      reset();
    }
    GetIt.I.registerSingleton<AppAudioHandler>(audio);
    GetIt.I.registerSingleton<StationDataService>(_FakeStationDataService());
    GetIt.I.registerSingleton<PlaylistController>(playlist);
  });

  tearDown(() async {
    await videoService.dispose();
    await platform.shutdown();
  });

  Widget host() => MaterialApp(
        home: DpadNavigator(
          child: Scaffold(
            body: TvNowPlaying(onBrowse: () {}, songHistory: const []),
          ),
        ),
      );

  /// The chrome's own opacity — 1 when it is on screen, 0 once faded out.
  double chromeOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
      .opacity;

  /// Settles the fade without waiting for the (periodic) auto-hide timer.
  Future<void> settleFade(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 300));

  testWidgets('playing video: the chrome steps aside after 5 idle seconds',
      (tester) async {
    // Arrange: a TV station, playing, chrome up.
    await tester.pumpWidget(host());
    audio.emitPlayback(playing: true);
    await tester.pump();
    expect(chromeOpacity(tester), 1.0, reason: 'chrome starts visible');

    // Act: sit still for just under the delay, then cross it.
    await tester.pump(kTvVideoChromeAutoHideDelay - const Duration(seconds: 1));
    expect(chromeOpacity(tester), 1.0, reason: 'still within the idle window');
    await tester.pump(const Duration(seconds: 1));
    await settleFade(tester);

    // Assert: faded out, and its controls are no longer focusable.
    expect(chromeOpacity(tester), 0.0);
    expect(
      tester
          .widgetList<DpadFocusable>(find.byType(DpadFocusable))
          .every((f) => !f.enabled),
      isTrue,
      reason: 'hidden controls must not be reachable by the D-pad',
    );
  });

  testWidgets('a remote press brings the chrome back', (tester) async {
    // Arrange: chrome already auto-hidden.
    await tester.pumpWidget(host());
    audio.emitPlayback(playing: true);
    await tester.pump();
    await tester.pump(kTvVideoChromeAutoHideDelay);
    await settleFade(tester);
    expect(chromeOpacity(tester), 0.0);

    // Act: any D-pad press.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settleFade(tester);

    // Assert: back on screen and focusable again.
    expect(chromeOpacity(tester), 1.0);
    expect(
      tester
          .widgetList<DpadFocusable>(find.byType(DpadFocusable))
          .any((f) => f.enabled),
      isTrue,
    );
  });

  testWidgets('paused video keeps the chrome pinned, however long it sits',
      (tester) async {
    // Arrange: playing, then paused by the user.
    await tester.pumpWidget(host());
    audio.emitPlayback(playing: true);
    await tester.pump();
    audio.emitPlayback(playing: false);
    await tester.pump();

    // Act: wait far past the idle window.
    await tester.pump(kTvVideoChromeAutoHideDelay * 4);
    await settleFade(tester);

    // Assert: still there — a frozen picture always keeps its transport.
    expect(chromeOpacity(tester), 1.0);
  });

  testWidgets('buffering keeps the chrome pinned', (tester) async {
    // Arrange: playing but rebuffering.
    await tester.pumpWidget(host());
    audio.emitPlayback(playing: true, buffering: true);
    await tester.pump();

    // Act.
    await tester.pump(kTvVideoChromeAutoHideDelay * 2);
    await settleFade(tester);

    // Assert.
    expect(chromeOpacity(tester), 1.0);
  });
}
