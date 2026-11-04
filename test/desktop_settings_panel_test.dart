import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:posthog_flutter/src/posthog_flutter_platform_interface.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/pages/HiddenStationsPage.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/tv/desktop/now_playing_share_menu.dart';
import 'package:radio_crestin/tv/desktop/settings_links.dart';
import 'package:radio_crestin/tv/desktop/settings_panel.dart';
import 'package:radio_crestin/tv/tv_platform.dart';
import 'package:radio_crestin/tv/tv_theme.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'helpers/station_factory.dart';

/// What Settings reads from the handler, and showing a station again.
class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  _FakeAudioHandler(this.data);

  final StationDataService data;

  @override
  final BehaviorSubject<StreamInfo?> currentStreamInfo =
      BehaviorSubject<StreamInfo?>.seeded(null);

  @override
  final BehaviorSubject<List<StreamEvent>> recentStreamEvents =
      BehaviorSubject<List<StreamEvent>>.seeded(const []);

  @override
  bool get isCasting => false;

  @override
  Future<void> unhideStation(Station station, {int? favoriteIndex}) =>
      data.setStationIsHidden(station, false);

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Records the screens PostHog gets; drops the events.
class _ScreenRecorder extends PosthogFlutterPlatformInterface {
  final screens = <String>[];

  @override
  Future<void> screen({
    required String screenName,
    Map<String, Object>? properties,
  }) async =>
      screens.add(screenName);

  @override
  Future<void> capture({
    required String eventName,
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {}
}

void main() {
  group('settings links', () {
    test('the support message names the desktop system', () {
      expect(desktopPlatformLabel('macos'), 'macOS');
      expect(desktopPlatformLabel('windows'), 'Windows');
      expect(desktopPlatformLabel('linux'), 'Linux');
      expect(desktopPlatformLabel('ios'), '');
    });

    test('a review opens the Mac App Store, else the web page', () async {
      final opened = <Uri>[];
      Future<bool> appStore(Uri url,
          {LaunchMode mode = LaunchMode.platformDefault}) async {
        opened.add(url);
        return true;
      }

      await openMacAppStoreReview(launch: appStore);
      expect(opened, [macAppStoreReviewUri]);
      expect(macAppStoreReviewUri.toString(),
          'macappstore://apps.apple.com/app/id6451270471?action=write-review');

      opened.clear();
      Future<bool> noAppStore(Uri url,
          {LaunchMode mode = LaunchMode.platformDefault}) async {
        opened.add(url);
        if (url.scheme == 'macappstore') throw PlatformException(code: 'x');
        return true;
      }

      await openMacAppStoreReview(launch: noAppStore);
      expect(opened, [macAppStoreReviewUri, appStoreReviewWebUri]);
    });
  });

  group('Settings on desktop', () {
    late StationDataService service;
    late _ScreenRecorder recorder;

    final alpha = StationFactory.createStation(
        id: 1, slug: 'alpha', title: 'Alpha', thumbnailUrl: null);

    setUpAll(() => TvPlatform.debugOverride(desktop: true));
    tearDownAll(TvPlatform.debugOverride);

    setUp(() async {
      expect(TvPlatform.isDesktop, isTrue);
      recorder = _ScreenRecorder();
      PosthogFlutterPlatformInterface.instance = recorder;
      SharedPreferences.setMockInitialValues({'device_id': 'test-device'});
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
      GetIt.instance
        ..registerSingleton<StationDataService>(service)
        ..registerSingleton<AppAudioHandler>(_FakeAudioHandler(service));
    });

    tearDown(() async {
      service.dispose();
      await GetIt.instance.reset();
    });

    /// Opens Settings the way the desktop shell does, in a [window].
    Future<void> openSettings(WidgetTester tester,
        {Size window = const Size(1280, 800)}) async {
      await tester.binding.setSurfaceSize(window);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: tvTheme,
        darkTheme: tvTheme,
        themeMode: ThemeMode.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => SettingsPage.show(context),
                child: const Text('Setări'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Setări'));
      await tester.pumpAndSettle();
    }

    Finder inPanel(Finder finder) => find.descendant(
        of: find.byType(DesktopSettingsPanel), matching: finder);

    /// Scrolls the panel's list until [finder] shows.
    Future<void> scrollTo(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 200,
          scrollable: inPanel(find.byType(Scrollable)).first);
      await tester.pumpAndSettle();
    }

    for (final window in const [Size(760, 560), Size(2560, 1440)]) {
      testWidgets(
          'opens in a centered panel in a '
          '${window.width.toInt()} x ${window.height.toInt()} window',
          (tester) async {
        await openSettings(tester, window: window);
        expect(tester.takeException(), isNull);
        final panel = tester.getRect(inPanel(find.byType(ClipRRect)).first);
        expect(panel.width, lessThanOrEqualTo(DesktopSettingsPanel.maxWidth));
        expect(panel.center.dx, closeTo(window.width / 2, 1));
        expect(inPanel(find.text('Setări')), findsOneWidget);
        expect(find.byTooltip('Închide (Esc)'), findsOneWidget);
        expect(find.byTooltip('Înapoi (Esc)'), findsNothing);
      });
    }

    testWidgets('leaves out what only a phone has', (tester) async {
      await openSettings(tester);
      expect(find.text('Interfața temei'), findsNothing,
          reason: 'desktop is dark only');
      expect(find.text('Notificări personalizate'), findsNothing);
      expect(find.text('CarPlay / Android Auto'), findsNothing);
      expect(find.text('Stații ascunse'), findsOneWidget);
      expect(find.text('Nicio stație ascunsă'), findsOneWidget);
      expect(find.text('Pornește automat ultima stație'), findsOneWidget);
      expect(find.text('Conexiune instabilă'), findsOneWidget);
      expect(find.text('Folosește MP3 cu prioritate'),
          Platform.isMacOS ? findsOneWidget : findsNothing,
          reason: 'Windows and Linux always load MP3 streams first');
      await scrollTo(tester, find.text('Distribuie aplicația'));
      expect(find.text('Distribuie aplicația'), findsOneWidget);
      expect(find.text('Lasă-ne o recenzie'),
          Platform.isMacOS ? findsOneWidget : findsNothing);
      expect(find.text('Contactează-ne pe WhatsApp'), findsOneWidget);
      expect(recorder.screens, contains('/settings'));
    });

    testWidgets('Esc and the close button close the panel', (tester) async {
      await openSettings(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsPanel), findsNothing);

      await tester.tap(find.text('Setări'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Închide (Esc)'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsPanel), findsNothing);
    });

    testWidgets('opening Settings again does not stack a second panel',
        (tester) async {
      await openSettings(tester);
      final context = tester.element(find.byType(Scaffold).first);
      SettingsPage.show(context);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsPanel), findsOneWidget);
    });

    testWidgets('the share row opens a menu, which Esc closes alone',
        (tester) async {
      await openSettings(tester);
      await scrollTo(tester, find.text('Distribuie aplicația'));
      await tester.tap(find.text('Distribuie aplicația'));
      await tester.pumpAndSettle();
      expect(find.text(DesktopShareMenu.whatsAppLabel), findsOneWidget);
      expect(find.text(DesktopShareMenu.moreLabel), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text(DesktopShareMenu.whatsAppLabel), findsNothing);
      expect(find.byType(DesktopSettingsPanel), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsPanel), findsNothing,
          reason: 'with the menu gone, Esc closes the panel');
    });

    testWidgets('Esc closes an open dropdown before the panel', (tester) async {
      await openSettings(tester);
      await tester.tap(find.text('2 minute'));
      await tester.pumpAndSettle();
      expect(find.text('5 minute'), findsWidgets, reason: 'the menu is open');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('5 minute'), findsNothing);
      expect(find.byType(DesktopSettingsPanel), findsOneWidget);
    });

    testWidgets(
        'hidden stations open inside the panel; Esc goes back, then '
        'closes', (tester) async {
      await service.setStationIsHidden(alpha, true);
      await openSettings(tester);

      expect(find.text('1 stație ascunsă'), findsOneWidget);
      await tester.tap(find.text('Stații ascunse'));
      await tester.pumpAndSettle();
      expect(inPanel(find.byType(HiddenStationsPage)), findsOneWidget);
      expect(find.byTooltip('Înapoi (Esc)'), findsOneWidget);
      expect(find.byTooltip('Închide setările'), findsOneWidget);
      expect(
        find.text('Stațiile ascunse nu apar în lista de stații, la Favorite '
            'și nici în căutare.'),
        findsOneWidget,
        reason: 'no CarPlay on a computer',
      );
      expect(recorder.screens, contains('/hidden-stations'));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(HiddenStationsPage), findsNothing);
      expect(find.byType(DesktopSettingsPanel), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsPanel), findsNothing);
    });

    testWidgets(
        're-adding the last hidden station shows the desktop '
        'explanation', (tester) async {
      await service.setStationIsHidden(alpha, true);
      await openSettings(tester);
      await tester.tap(find.text('Stații ascunse'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Readaugă'));
      await tester.pumpAndSettle();
      expect(service.hiddenStationSlugs.value, isEmpty);
      expect(find.textContaining('Ține apăsat'), findsNothing,
          reason: 'a computer has no long press');
      expect(
          find.text('Fă clic dreapta pe o stație din listă și alege '
              '„Ascunde stația”. Stațiile ascunse nu apar în lista de '
              'stații, la Favorite și nici în căutare. Le poți readăuga '
              'oricând de aici.'),
          findsOneWidget);

      await tester.tap(find.byTooltip('Închide setările'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsPanel), findsNothing);
    });
  });
}
