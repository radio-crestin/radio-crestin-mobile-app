import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/services/sleep_timer_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/tv/desktop/desktop_mini_player.dart';
import 'package:radio_crestin/tv/desktop/desktop_now_playing_route.dart';
import 'package:radio_crestin/tv/desktop/now_playing_about.dart';
import 'package:radio_crestin/tv/desktop/now_playing_layout.dart';
import 'package:radio_crestin/tv/desktop/now_playing_share_menu.dart';
import 'package:radio_crestin/tv/desktop/now_playing_sleep_menu.dart';
import 'package:radio_crestin/tv/desktop_now_playing_sheet.dart';
import 'package:radio_crestin/tv/tv_theme.dart';
import 'package:radio_crestin/tv/tv_youtube_auto_advance.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/widgets/song_history_modal.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// Plays, skips and rates the way the panel asks, counting each call.
class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  _FakeAudioHandler(this.data);

  final StationDataService data;
  final calls = <String>[];

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
  Future<void> play() async {
    calls.add('play');
    playbackState.add(playbackState.value.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> skipToNext() async => calls.add('next');

  @override
  Future<void> skipToPrevious() async => calls.add('previous');

  @override
  bool toggleStationFavorite(Station station) {
    final favorite = !data.favoriteStationSlugs.value.contains(station.slug);
    data.setStationIsFavorite(station, favorite);
    return favorite;
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    calls.add(name);
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Tooltips of the panel's icon-only actions.
const _sleepTooltip = 'Somn: oprește radioul după un timp';
const _shareTooltip = 'Trimite stația unui prieten';

void main() {
  group('computeDesktopNowPlayingLayout', () {
    test('a degenerate size does not throw', () {
      final layout = computeDesktopNowPlayingLayout(width: 0, height: 0);
      expect(layout.mediaWidth, DesktopNowPlayingLayout.minArtwork);
      expect(layout.stacked, isTrue);
    });

    test('the smallest window keeps the artwork beside the details, the '
        'recent songs above "Despre stație"', () {
      // A 760 x 560 window: the panel is 736 wide, and below its top bar
      // about 450 tall.
      final layout = computeDesktopNowPlayingLayout(width: 736, height: 450);
      expect(layout.stacked, isFalse);
      expect(layout.mediaWidth, inInclusiveRange(180, 240));
      expect(layout.detailsWidth, greaterThanOrEqualTo(360));
      expect(layout.infoSideBySide, isFalse);
    });

    test('a full screen caps the artwork and puts the recent songs beside '
        '"Despre stație"', () {
      final layout =
          computeDesktopNowPlayingLayout(width: 1100, height: 1340);
      expect(layout.mediaWidth, DesktopNowPlayingLayout.maxArtwork);
      expect(layout.infoSideBySide, isTrue);
    });

    test('a narrow panel stacks the artwork above the details', () {
      final layout = computeDesktopNowPlayingLayout(width: 520, height: 900);
      expect(layout.stacked, isTrue);
      expect(layout.mediaWidth,
          lessThanOrEqualTo(DesktopNowPlayingLayout.maxStackedArtwork));
    });

    test('video is 16:9 and leaves the details room', () {
      final layout = computeDesktopNowPlayingLayout(
          width: 1100, height: 900, isVideo: true);
      expect(layout.mediaHeight, closeTo(layout.mediaWidth * 9 / 16, 0.01));
      expect(layout.detailsWidth, greaterThan(300));
    });
  });

  group('StationAbout', () {
    test('a description loses the API\'s line ends and blank runs', () {
      expect(
        StationAbout.cleanDescription('Unu.\r\n\r\n\r\n\r\nDoi.  \r\nTrei.\r\n'),
        'Unu.\n\nDoi.\nTrei.',
      );
      expect(StationAbout.cleanDescription('  \r\n '), isNull);
      expect(StationAbout.cleanDescription(null), isNull);
    });

    test('a site shows as people write it', () {
      final site = StationAbout.webUri('https://www.rve-timisoara.ro/')!;
      expect(StationAbout.webLabel(site), 'rve-timisoara.ro');
      final page =
          StationAbout.webUri('https://www.predic.ro/livepredicradio.php')!;
      expect(StationAbout.webLabel(page), 'predic.ro/livepredicradio.php');
      expect(StationAbout.webUri('radio.ro'), Uri.parse('https://radio.ro'));
      expect(StationAbout.webUri('mailto:a@b.ro'), isNull);
      expect(StationAbout.webUri(''), isNull);
    });

    test('a Facebook page is its name or its whole address', () {
      expect(StationAbout.facebookUri('Radio.Emanuel.Crestin'),
          Uri.parse('https://www.facebook.com/Radio.Emanuel.Crestin'));
      expect(StationAbout.facebookUri('https://facebook.com/radioelim'),
          Uri.parse('https://facebook.com/radioelim'));
      expect(StationAbout.facebookUri(' '), isNull);
    });

    test('an e-mail opens the mail app, unless it is none', () {
      expect(StationAbout.emailUri('contact@radioelim.ro'),
          Uri.parse('mailto:contact@radioelim.ro'));
      expect(StationAbout.emailUri('nu are'), isNull);
    });

    test('a station\'s links come site, Facebook, e-mail; its action reads '
        'as a link', () {
      final about = StationAbout.of(StationFactory.createStation(
        id: 1,
        slug: 'alpha',
        title: 'Radio Alpha',
        website: 'https://www.radioalpha.ro/',
        facebookPageId: 'RadioAlpha',
        email: 'contact@radioalpha.ro',
        descriptionActionTitle: 'Instalează aplicația pe telefonul mobil.',
        descriptionLink: 'https://radioalpha.ro/app',
      ));
      expect([for (final link in about.links) link.kind], [
        StationLinkKind.website,
        StationLinkKind.facebook,
        StationLinkKind.email,
      ]);
      expect([for (final link in about.links) link.label], [
        'radioalpha.ro',
        'Pagina de Facebook',
        'contact@radioalpha.ro',
      ]);
      expect(about.action?.label, 'Instalează aplicația pe telefonul mobil');
      expect(about.action?.uri, Uri.parse('https://radioalpha.ro/app'));
    });

    test('a station that tells nothing about itself has nothing to show', () {
      final about = StationAbout.of(StationFactory.createStation(
          id: 1, slug: 'alpha', title: 'Radio Alpha', website: '', email: ''));
      expect(about.isEmpty, isTrue);
    });
  });

  group('DesktopNowPlayingRoute', () {
    test('the panel keeps the bar\'s sides and bottom, up to under the '
        'title bar', () {
      const window = Size(1280, 800);
      final bar = DesktopMiniPlayer.rectIn(window);
      final panel = DesktopNowPlayingRoute.panelRectIn(window, top: 52);
      expect(panel, Rect.fromLTRB(bar.left, 52, bar.right, bar.bottom));
      // Without window buttons (full screen), a margin like the bar's.
      expect(DesktopNowPlayingRoute.panelRectIn(window, top: 0).top,
          DesktopMiniPlayer.margin.bottom);
      // Never lower than the bar, however short the window.
      expect(DesktopNowPlayingRoute.panelRectIn(const Size(400, 90), top: 52),
          DesktopMiniPlayer.rectIn(const Size(400, 90)));
    });
  });

  group('DesktopShareContent', () {
    final station = StationFactory.createStation(
      id: 7,
      slug: 'alpha',
      title: 'Radio Alpha',
      nowPlaying: StationFactory.createNowPlaying(
          id: 42, songName: 'Cântec', artistName: 'Grup'),
    );

    test('without a personal link, shares the station page', () {
      final content = DesktopShareContent.of(station: station);
      expect(content.url, 'https://www.radiocrestin.ro/alpha');
      expect(content.invitation,
          'Te invit să asculți Radio Alpha (Cântec • Grup):\n'
          'https://www.radiocrestin.ro/alpha');
    });

    test('without a station, shares the app', () {
      final content = DesktopShareContent.of();
      expect(content.url,
          'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin');
      expect(content.invitation, startsWith('Instalează și tu aplicația'));
      expect(content.invitation, contains(content.url));
    });
  });

  group('DesktopNowPlayingSheet', () {
    late StationDataService service;
    late _FakeAudioHandler handler;
    // The station's history: the song playing, then the ones before it.
    late List<SongHistoryItem>? history;
    final historyRequests = <String>[];
    final openedLinks = <Uri>[];
    final countdown = ValueNotifier<TvYoutubeCountdown?>(null);

    final alpha = StationFactory.createStation(
      id: 1,
      slug: 'alpha',
      title: 'Radio Alpha',
      thumbnailUrl: null,
      totalListeners: 24,
      nowPlaying: StationFactory.createNowPlaying(
          id: 42, songName: 'Cântec nou', artistName: 'Grupul Har'),
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await GetIt.instance.reset();
      GetIt.instance
        ..registerSingleton<SharedPreferences>(prefs)
        ..registerSingleton<PlayCountService>(PlayCountService());
      service = StationDataService(
        graphqlClient: GraphQLClient(
          link: HttpLink('https://example.com/graphql'),
          cache: GraphQLCache(),
        ),
      );
      service.applyPublicStationsForTest([alpha]);
      handler = _FakeAudioHandler(service);
      handler.currentStation.add(alpha);
      GetIt.instance
        ..registerSingleton<StationDataService>(service)
        ..registerSingleton<PlaylistController>(PlaylistController(
          videoService: VideoPlaybackService(),
          syncService: PlaylistSyncService(),
        ))
        ..registerSingleton<AppAudioHandler>(handler);
      historyRequests.clear();
      openedLinks.clear();
      String minutesAgo(int minutes) => DateTime.now()
          .toUtc()
          .subtract(Duration(minutes: minutes))
          .toIso8601String();
      history = [
        SongHistoryItem(
          timestamp: minutesAgo(1),
          songId: 42,
          songName: 'Cântec nou',
          artistName: 'Grupul Har',
        ),
        SongHistoryItem(
          timestamp: minutesAgo(5),
          songId: 41,
          songName: 'Alt cântec',
          artistName: 'Corul',
        ),
      ];
    });

    tearDown(() async {
      handler.sleepTimer.cancel();
      service.dispose();
      await GetIt.instance.reset();
    });

    /// Shows a screen whose "open" button opens the panel the way the
    /// desktop shell does, in a [window].
    Future<void> pumpScreen(WidgetTester tester, Size window) async {
      await tester.binding.setSurfaceSize(window);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: tvTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  DesktopNowPlayingRoute(
                    builder: (_) => DesktopNowPlayingSheet(
                      youtubeCountdown: countdown,
                      loadSongHistory: (slug) async {
                        historyRequests.add(slug);
                        return history;
                      },
                      openLink: (uri) async => openedLinks.add(uri),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
    }

    /// Opens the panel, in a [window].
    Future<void> openPanel(WidgetTester tester, Size window) async {
      await pumpScreen(tester, window);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// Where the panel is: the rect its surface takes.
    Rect panelRect(WidgetTester tester) => tester.getRect(find
        .ancestor(
          of: find.byType(DesktopNowPlayingSheet),
          matching: find.byType(Positioned),
        )
        .first);

    for (final window in const [
      Size(760, 560),
      Size(1280, 800),
      Size(2560, 1440),
    ]) {
      testWidgets('fits a ${window.width.toInt()} x ${window.height.toInt()} '
          'window without overflowing', (tester) async {
        await openPanel(tester, window);
        expect(tester.takeException(), isNull);
        expect(find.text('Cântec nou'), findsOneWidget);
        expect(find.text('Grupul Har'), findsOneWidget);
        // Over the song, and by its logo in "Despre stație".
        expect(find.text('Radio Alpha'), findsNWidgets(2));
        expect(find.text('24 de ascultători'), findsOneWidget);
        expect(find.textContaining('Alt cântec', findRichText: true),
            findsOneWidget);
        // The actions are icons that name themselves in tooltips.
        for (final tooltip in [
          'Adaugă la favorite (F)',
          _sleepTooltip,
          _shareTooltip,
        ]) {
          expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
        }
        expect(find.text('Vezi tot'), findsOneWidget);
        expect(find.text(NowPlayingAbout.title), findsOneWidget);
        expect(find.byTooltip('Închide (Esc)'), findsOneWidget);
        // The player is in view without scrolling; what is about the
        // station may be under it, in a small window.
        expect(
          tester.getRect(find.byTooltip('Redă / Pauză (Spațiu)')).bottom,
          lessThan(window.height),
        );
        // The keyboard shortcuts are named in the tooltips only.
        expect(find.text('redă / pauză'), findsNothing);
      });
    }

    testWidgets('Space plays and pauses, the arrows skip, F favorites',
        (tester) async {
      await openPanel(tester, const Size(1280, 800));

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(handler.calls, ['play']);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(handler.calls.last, 'pause');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(handler.calls.sublist(2), ['next', 'previous']);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(service.favoriteStationSlugs.value, ['alpha']);
      expect(find.byTooltip('Elimină din favorite (F)'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(handler.calls.last, 'likeSong');
    });

    testWidgets('Esc and the close button close the panel', (tester) async {
      await openPanel(tester, const Size(1280, 800));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopNowPlayingSheet), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Închide (Esc)'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    });

    testWidgets('"Melodii recente" lists the station\'s songs before the '
        'one playing, from its history', (tester) async {
      await openPanel(tester, const Size(1280, 800));
      expect(historyRequests, ['alpha']);
      final recent = find.textContaining('Alt cântec', findRichText: true);
      expect(recent, findsOneWidget);
      expect(find.textContaining('Corul', findRichText: true), findsOneWidget);
      // The song playing shows above, not again among the recent ones.
      expect(find.textContaining('Cântec nou', findRichText: true),
          findsOneWidget);
    });

    testWidgets('"Melodii recente" says so when the history has nothing '
        'before the song playing, or fails', (tester) async {
      history = history!.take(1).toList();
      await openPanel(tester, const Size(1280, 800));
      expect(find.text('Nicio altă melodie în ultima oră'), findsOneWidget);
      await tester.tap(find.byTooltip('Închide (Esc)'));
      await tester.pumpAndSettle();

      history = null;
      await openPanel(tester, const Size(1280, 800));
      expect(find.text('Melodiile nu s-au putut încărca'), findsOneWidget);
    });

    testWidgets('"Vezi tot" opens the song history over the panel',
        (tester) async {
      await openPanel(tester, const Size(1280, 800));
      await tester.tap(find.text('Vezi tot'));
      await tester.pumpAndSettle();
      expect(find.byType(SongHistoryModal), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SongHistoryModal), findsNothing);
      expect(find.byType(DesktopNowPlayingSheet), findsOneWidget,
          reason: 'Esc closed the history only');
    });

    testWidgets('the sleep menu arms and cancels the timer, and Esc closes '
        'the menu before the panel', (tester) async {
      await openPanel(tester, const Size(1280, 800));

      await tester.tap(find.byTooltip(_sleepTooltip));
      await tester.pumpAndSettle();
      expect(find.text('Oprește radioul după'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Oprește radioul după'), findsNothing);
      expect(find.byType(DesktopNowPlayingSheet), findsOneWidget,
          reason: 'Esc closed the menu only');

      await tester.tap(find.byTooltip(_sleepTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 min'));
      await tester.pumpAndSettle();
      expect(handler.sleepTimer.state.value?.duration,
          const Duration(minutes: 30));
      expect(find.text('30:00'), findsOneWidget,
          reason: 'the button counts down');

      await tester.tap(find.text('30:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(NowPlayingSleepMenu.cancelLabel));
      await tester.pumpAndSettle();
      expect(handler.sleepTimer.state.value, isNull);
      expect(find.text('30:00'), findsNothing,
          reason: 'the idle button is an icon again');
      expect(find.byTooltip(_sleepTooltip), findsOneWidget);
    });

    testWidgets('the share menu offers WhatsApp, Facebook, copy and more',
        (tester) async {
      await openPanel(tester, const Size(1280, 800));
      await tester.tap(find.byTooltip(_shareTooltip));
      await tester.pumpAndSettle();
      for (final label in [
        DesktopShareMenu.whatsAppLabel,
        DesktopShareMenu.facebookLabel,
        DesktopShareMenu.copyLabel,
        DesktopShareMenu.moreLabel,
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text(DesktopShareMenu.whatsAppLabel), findsNothing);
      expect(find.byType(DesktopNowPlayingSheet), findsOneWidget);

      // The panel has the keyboard back: its shortcuts work again.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(handler.calls, ['play']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    });

    testWidgets('a station that names no songs shows "Live", without the '
        'rating or the recent songs', (tester) async {
      history = [];
      handler.currentStation.add(StationFactory.createStation(
          id: 2, slug: 'beta', title: 'Beta', thumbnailUrl: null));
      await openPanel(tester, const Size(760, 560));
      expect(find.text('Live'), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsNothing);
      expect(find.byIcon(Icons.thumb_down_alt_outlined), findsNothing);
      expect(find.text('Melodii recente'), findsNothing);
      // Alone, "Despre stație" lines up with the artwork.
      expect(
        tester.getTopLeft(find.text(NowPlayingAbout.title)).dx,
        tester.getTopLeft(find.byKey(const ValueKey('np-art-2--1'))).dx,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(handler.calls, isNot(contains('likeSong')));
    });

    testWidgets('"Se redă acum" grows out of the player bar, and shrinks '
        'back into it', (tester) async {
      const window = Size(1280, 800);
      final bar = DesktopMiniPlayer.rectIn(window);
      final open = DesktopNowPlayingRoute.panelRectIn(window, top: 0);
      await pumpScreen(tester, window);

      await tester.tap(find.text('open'));
      await tester.pump();
      expect(panelRect(tester).top, closeTo(bar.top, 1),
          reason: 'it starts as the bar');
      await tester.pump(const Duration(milliseconds: 120));
      final growing = panelRect(tester);
      expect(growing.top, inExclusiveRange(open.top, bar.top));
      expect(
        [growing.left, growing.right, growing.bottom],
        [bar.left, bar.right, bar.bottom],
        reason: 'only its top edge moves',
      );
      await tester.pumpAndSettle();
      expect(panelRect(tester), open);

      await tester.tap(find.byTooltip('Închide (Esc)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(panelRect(tester).top, inExclusiveRange(open.top, bar.top));
      await tester.pump(const Duration(milliseconds: 140));
      expect(panelRect(tester).top, closeTo(bar.top, 4),
          reason: 'it lands on the bar');
      await tester.pumpAndSettle();
      expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    });

    testWidgets('a click on the dimmed window closes the panel',
        (tester) async {
      await openPanel(tester, const Size(1280, 800));
      // Above the panel, which starts under the window's title bar.
      await tester.tapAt(const Offset(640, 4));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    });

    testWidgets('"Despre stație" tells the station\'s description and '
        'rating, and opens its site, Facebook page and e-mail',
        (tester) async {
      handler.currentStation.add(StationFactory.createStation(
        id: 1,
        slug: 'alpha',
        title: 'Radio Alpha',
        thumbnailUrl: null,
        description: 'Radio Alpha vestește Evanghelia.\r\n\r\n\r\nZi și noapte.',
        website: 'https://www.radioalpha.ro/',
        facebookPageId: 'RadioAlpha',
        email: 'contact@radioalpha.ro',
        averageRating: 4.6,
        numberOfReviews: 11,
        nowPlaying: StationFactory.createNowPlaying(
            id: 42, songName: 'Cântec nou', artistName: 'Grupul Har'),
      ));
      await openPanel(tester, const Size(1280, 800));

      expect(find.text('Radio Alpha vestește Evanghelia.\n\nZi și noapte.'),
          findsOneWidget);
      expect(find.text('4.6'), findsOneWidget);
      expect(find.textContaining('11 recenzii'), findsOneWidget);
      for (final (label, uri) in [
        ('radioalpha.ro', 'https://www.radioalpha.ro/'),
        ('Pagina de Facebook', 'https://www.facebook.com/RadioAlpha'),
        ('contact@radioalpha.ro', 'mailto:contact@radioalpha.ro'),
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pump();
        expect(openedLinks.last, Uri.parse(uri), reason: label);
      }
      expect(openedLinks, hasLength(3));
      expect(find.byType(DesktopNowPlayingSheet), findsOneWidget,
          reason: 'a link leaves the panel open');
    });

    testWidgets('a right-click on a link offers to open it or copy it; '
        'a copy confirms itself, and Esc closes the menu only',
        (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      handler.currentStation.add(StationFactory.createStation(
        id: 1,
        slug: 'alpha',
        title: 'Radio Alpha',
        thumbnailUrl: null,
        website: 'https://www.radioalpha.ro/',
        email: 'contact@radioalpha.ro',
      ));
      await openPanel(tester, const Size(1280, 1000));
      Future<void> rightClick(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
      }

      await rightClick('contact@radioalpha.ro');
      expect(find.text('Scrie un e-mail'), findsOneWidget);
      await tester.tap(find.text('Copiază adresa'));
      await tester.pump();
      await tester.pump();
      expect(clipboard, ['contact@radioalpha.ro']);
      expect(find.text(DesktopNowPlayingSheet.addressCopiedLabel),
          findsOneWidget);
      await tester.pumpAndSettle();

      await rightClick('radioalpha.ro');
      await tester.tap(find.text('Copiază linkul'));
      await tester.pump();
      await tester.pump();
      expect(clipboard.last, 'https://www.radioalpha.ro/');
      expect(find.text(DesktopNowPlayingSheet.linkCopiedLabel), findsOneWidget);
      await tester.pumpAndSettle();

      await rightClick('radioalpha.ro');
      await tester.tap(find.text('Deschide în browser'));
      await tester.pumpAndSettle();
      expect(openedLinks, [Uri.parse('https://www.radioalpha.ro/')]);

      await rightClick('radioalpha.ro');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Copiază linkul'), findsNothing);
      expect(find.byType(DesktopNowPlayingSheet), findsOneWidget,
          reason: 'Esc closed the menu only');
      expect(openedLinks, hasLength(1), reason: 'a right-click opens nothing');
    });

    testWidgets('the song underlines under the pointer only on its text, '
        'not in the room kept for a longer title', (tester) async {
      await openPanel(tester, const Size(1280, 800));
      TextDecoration? decoration() => tester
          .widget<Text>(find.text('Cântec nou'))
          .style
          ?.decoration;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      // Under the artist, where a second line of the title would go.
      final artist = tester.getRect(find.text('Grupul Har'));
      await mouse.moveTo(artist.bottomLeft + const Offset(4, 16));
      await tester.pumpAndSettle();
      expect(decoration(), TextDecoration.none);

      await mouse.moveTo(tester.getCenter(find.text('Cântec nou')));
      await tester.pumpAndSettle();
      expect(decoration(), TextDecoration.underline);
    });

    testWidgets('a long description shows four lines, "Mai mult" the rest',
        (tester) async {
      handler.currentStation.add(StationFactory.createStation(
        id: 1,
        slug: 'alpha',
        title: 'Radio Alpha',
        thumbnailUrl: null,
        description: List.filled(80, 'Radio Alpha vestește Evanghelia.')
            .join(' '),
        descriptionActionTitle: 'Instalează aplicația.',
        descriptionLink: 'https://radioalpha.ro/app',
      ));
      await openPanel(tester, const Size(1280, 1000));
      Text description() => tester.widget<Text>(
          find.textContaining('Radio Alpha vestește Evanghelia.'));
      expect(description().maxLines, 4);

      await tester.ensureVisible(find.text('Mai mult'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mai mult'));
      await tester.pumpAndSettle();
      expect(description().maxLines, isNull);
      expect(find.text('Mai puțin'), findsOneWidget);

      await tester.ensureVisible(find.text('Instalează aplicația'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Instalează aplicația'));
      await tester.pump();
      expect(openedLinks, [Uri.parse('https://radioalpha.ro/app')]);

      await tester.ensureVisible(find.text('Mai puțin'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mai puțin'));
      await tester.pumpAndSettle();
      expect(description().maxLines, 4);
    });

    testWidgets('a short description has no "Mai mult"', (tester) async {
      handler.currentStation.add(StationFactory.createStation(
        id: 1,
        slug: 'alpha',
        title: 'Radio Alpha',
        thumbnailUrl: null,
        description: 'Radio Alpha vestește Evanghelia.',
      ));
      await openPanel(tester, const Size(1280, 800));
      expect(find.text('Radio Alpha vestește Evanghelia.'), findsOneWidget);
      expect(find.text('Mai mult'), findsNothing);
    });

    testWidgets('a station playing a song can rate it, and lists its recent '
        'songs', (tester) async {
      await openPanel(tester, const Size(1280, 800));
      expect(find.byTooltip('Îmi place (L)'), findsOneWidget);
      expect(find.byTooltip('Nu-mi place (D)'), findsOneWidget);
      expect(find.text('Melodii recente'), findsOneWidget);
    });
  });
}
