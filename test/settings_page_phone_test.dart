import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/android_renderer.dart';
import 'package:radio_crestin/services/default_settings.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/playback_preferences.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/tv/desktop/settings_panel.dart';
import 'package:radio_crestin/tv/tv_platform.dart';
import 'package:radio_crestin/widgets/pinned_title_sliver_header.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// What Settings reads from the handler.
class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  @override
  final BehaviorSubject<StreamInfo?> currentStreamInfo =
      BehaviorSubject<StreamInfo?>.seeded(null);

  @override
  final BehaviorSubject<List<StreamEvent>> recentStreamEvents =
      BehaviorSubject<List<StreamEvent>>.seeded(const []);

  @override
  bool get isCasting => false;

  @override
  Future<void> reapplySeekOffset() async {}

  @override
  void refreshCurrentMetadata() {}

  /// Base's waits for a playback state no player sends here.
  @override
  Future<void> stop() async {}

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// The phone's Settings keep everything the desktop panel leaves out.
void main() {
  late StationDataService service;

  setUp(() async {
    // TvPlatform.initialize() never ran: a phone.
    expect(TvPlatform.isDesktop, isFalse);
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
    service.applyPublicStationsForTest([
      StationFactory.createStation(
          id: 1, slug: 'alpha', title: 'Alpha', thumbnailUrl: null),
    ]);
    GetIt.instance
      ..registerSingleton<StationDataService>(service)
      ..registerSingleton<AppAudioHandler>(_FakeAudioHandler());
  });

  tearDown(() async {
    service.dispose();
    await GetIt.instance.reset();
  });

  testWidgets('Settings opens as a full page with every phone setting',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      darkTheme: darkTheme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => SettingsPage.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopSettingsPanel), findsNothing);
    expect(find.byType(DesktopSettingsFrame), findsNothing);
    expect(find.byType(PinnedTitleSliverHeader), findsOneWidget);
    for (final title in [
      'Interfața temei',
      'Conexiune instabilă',
      'Încărcare în avans',
      'Folosește MP3 cu prioritate',
      'Pornește automat ultima stație',
      'Notificări personalizate',
      'Stații ascunse',
      'Distribuie aplicația',
      'Lasă-ne o recenzie',
      'Contactează-ne pe WhatsApp',
      'CarPlay / Android Auto',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Nicio stație ascunsă'), findsOneWidget);
  });

  testWidgets('the MP3 switch applies and saves the setting',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => PlaybackPreferences.changePreferDirectStreams(false));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('posthog_flutter'),
      (_) async => null,
    );
    await tester.pumpWidget(
        MaterialApp(theme: lightTheme, home: const SettingsPage()));
    await tester.pumpAndSettle();
    final mp3Switch = find.descendant(
      of: find.widgetWithText(ListTile, 'Folosește MP3 cu prioritate'),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(mp3Switch).value, isFalse);

    await tester.tap(mp3Switch);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(mp3Switch).value, isTrue);
    expect(PlaybackPreferences.preferDirectStreams.value, isTrue);
    expect(
      GetIt.instance<SharedPreferences>()
          .getBool(PlaybackPreferences.preferDirectStreamsKey),
      isTrue,
    );
    expect(
      DefaultSettings.isUserSet(GetIt.instance<SharedPreferences>(),
          AppDefaultSettings.preferDirectStreams),
      isTrue,
      reason: "PostHog's default no longer applies to it",
    );
    // Lets the setting-change log's flush timer run out.
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a default PostHog changes shows on the open page',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => PlaybackPreferences.changePreferDirectStreams(false));
    await tester.pumpWidget(
        MaterialApp(theme: lightTheme, home: const SettingsPage()));
    await tester.pumpAndSettle();

    PlaybackPreferences.changePreferDirectStreams(true);
    await tester.pumpAndSettle();

    final mp3Switch = find.descendant(
      of: find.widgetWithText(ListTile, 'Folosește MP3 cu prioritate'),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(mp3Switch).value, isTrue);
  });

  testWidgets('the unstable-connection switch leaves the seek mode as it was',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SeekModeManager.changeSeekMode(SeekMode.instant);
    addTearDown(() {
      SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
      SeekModeManager.changeUnstableConnection(false);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('posthog_flutter'),
      (_) async => null,
    );
    await tester.pumpWidget(
        MaterialApp(theme: lightTheme, home: const SettingsPage()));
    await tester.pumpAndSettle();
    final unstableSwitch = find.descendant(
      of: find.widgetWithText(ListTile, 'Conexiune instabilă'),
      matching: find.byType(Switch),
    );

    await tester.tap(unstableSwitch);
    await tester.pumpAndSettle();
    expect(SeekModeManager.currentOffset, const Duration(minutes: 5));
    await tester.tap(unstableSwitch);
    await tester.pumpAndSettle();

    expect(SeekModeManager.seekMode.value, SeekMode.instant);
    expect(SeekModeManager.currentOffset, Duration.zero);
    final prefs = GetIt.instance<SharedPreferences>();
    expect(DefaultSettings.isUserSet(
        prefs, AppDefaultSettings.unstableConnection), isTrue);
    expect(DefaultSettings.isUserSet(prefs, AppDefaultSettings.seekMode),
        isFalse);
    // Lets the toasts and the log's flush timer run out.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('unlocking developer mode scrolls to its section',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('posthog_flutter'),
      (_) async => null,
    );
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => SettingsPage.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Versiune'), 200);
    await tester.pumpAndSettle();
    expect(find.text('Developer'), findsNothing);

    for (var tap = 0; tap < 7; tap++) {
      await tester.tap(find.text('Versiune'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(find.text('Developer').hitTestable(), findsOneWidget,
        reason: 'the new section was scrolled into view');
    // Lets the taps' reset timer and the toasts run out.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  group('the renderer picker', () {
    Future<void> openDeveloperSettings(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('posthog_flutter'),
        (_) async => null,
      );
      await GetIt.instance<SharedPreferences>()
          .setBool('developer_mode_enabled', true);
      await tester.pumpWidget(
          MaterialApp(theme: lightTheme, home: const SettingsPage()));
      await tester.pumpAndSettle();
      expect(find.text('Developer'), findsOneWidget);
    }

    /// Settings as on Android; returns the app channel's calls.
    Future<List<String>> onAndroid() async {
      final renderer =
          AndroidRenderer(supported: true, readFlag: () async => null);
      await renderer.loadCache(GetIt.instance<SharedPreferences>());
      AndroidRenderer.debugInstance = renderer;
      addTearDown(() => AndroidRenderer.debugInstance = AndroidRenderer());
      const appChannel = MethodChannel('com.radiocrestin.app');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
          appChannel, (call) async => calls.add(call.method));
      addTearDown(() => messenger.setMockMethodCallHandler(appChannel, null));
      return calls;
    }

    Future<void> pick(WidgetTester tester, String label) async {
      await tester.tap(find.text('Automat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('is left out where Impeller is the only renderer',
        (tester) async {
      AndroidRenderer.debugInstance = AndroidRenderer(supported: false);
      addTearDown(() => AndroidRenderer.debugInstance = AndroidRenderer());

      await openDeveloperSettings(tester);

      expect(find.text('Motor grafic'), findsNothing);
    });

    testWidgets('on Android saves the choice for the next launch',
        (tester) async {
      final calls = await onAndroid();
      await openDeveloperSettings(tester);
      expect(find.text('Motor grafic'), findsOneWidget);
      expect(find.textContaining('la următoarea pornire'), findsOneWidget);

      await pick(tester, 'Skia (stabil)');

      expect(
        GetIt.instance<SharedPreferences>()
            .getBool(AndroidRenderer.useSkiaKey),
        isTrue,
      );
      expect(find.text('Repornești aplicația?'), findsOneWidget);
      await tester.tap(find.text('Mai târziu'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty, reason: 'it applies at the next launch');
      expect(find.text('Skia (stabil)'), findsOneWidget);
      // Lets the setting-change log's flush timer run out.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('restarts the app when asked to', (tester) async {
      final calls = await onAndroid();
      await openDeveloperSettings(tester);

      await pick(tester, 'Skia (stabil)');
      await tester.tap(find.text('Repornește'));
      await tester.pumpAndSettle();

      expect(calls, ['restartApp']);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('asks nothing when the next launch renders like this one',
        (tester) async {
      await onAndroid();
      await openDeveloperSettings(tester);

      await pick(tester, 'Impeller');

      expect(find.text('Repornești aplicația?'), findsNothing);
      expect(
        GetIt.instance<SharedPreferences>()
            .getBool(AndroidRenderer.useSkiaKey),
        isFalse,
      );
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('on iOS a tap on the status bar scrolls Settings to the top',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // The Scaffold takes the tap only where the status bar is.
    tester.view.padding = const FakeViewPadding(top: 141);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(MaterialApp(
      // The theme's platform was fixed when it was first built.
      theme: lightTheme.copyWith(platform: TargetPlatform.iOS),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => SettingsPage.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final list = find.byType(CustomScrollView);
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable)).first;
    expect(
      tester.widget<Scrollable>(scrollable).controller,
      same(PrimaryScrollController.maybeOf(tester.element(list))),
      reason: 'the list is the page\'s primary scroll view',
    );

    await tester.drag(list, const Offset(0, -500));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(0));

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.statusBar.name,
      SystemChannels.statusBar.codec
          .encodeMethodCall(const MethodCall('handleScrollToTop')),
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(position.pixels, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
