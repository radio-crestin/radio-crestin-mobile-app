import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/desktop_menu_service.dart';
import 'package:radio_crestin/services/mac_app_store_updates.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/sleep_timer_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/station_sort_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/tv/desktop/desktop_category_bar.dart';
import 'package:radio_crestin/tv/desktop/desktop_mini_player.dart';
import 'package:radio_crestin/tv/desktop/desktop_search_field.dart';
import 'package:radio_crestin/tv/desktop/desktop_sections.dart';
import 'package:radio_crestin/tv/desktop/desktop_search_results.dart';
import 'package:radio_crestin/tv/desktop/desktop_station_actions.dart';
import 'package:radio_crestin/tv/desktop/desktop_station_card.dart';
import 'package:radio_crestin/tv/desktop/desktop_station_menu.dart';
import 'package:radio_crestin/tv/desktop/desktop_update_dialog.dart';
import 'package:radio_crestin/tv/desktop/desktop_volume_control.dart';
import 'package:radio_crestin/tv/desktop/settings_panel.dart';
import 'package:radio_crestin/tv/desktop_now_playing_sheet.dart';
import 'package:radio_crestin/tv/desktop_shell.dart';
import 'package:radio_crestin/tv/tv_platform.dart';
import 'package:radio_crestin/tv/tv_theme.dart';
import 'package:radio_crestin/tv/tv_youtube_auto_advance.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// Plays, skips, favorites and hides the way the desktop shell asks,
/// recording each call.
class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  _FakeAudioHandler(this.stationDataService);

  @override
  final StationDataService stationDataService;

  final calls = <String>[];

  @override
  final BehaviorSubject<double> listenerVolume =
      BehaviorSubject<double>.seeded(1);

  @override
  Future<void> setListenerVolume(double volume) async {
    calls.add('volume:${volume.toStringAsFixed(2)}');
    listenerVolume.add(volume.clamp(0.0, 1.0).toDouble());
  }

  double _beforeMute = 1;

  @override
  Future<void> toggleListenerMute() async {
    final volume = listenerVolume.value;
    if (volume > 0) _beforeMute = volume;
    listenerVolume.add(volume > 0 ? 0 : _beforeMute);
  }

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

  // What Settings reads.
  @override
  final BehaviorSubject<StreamInfo?> currentStreamInfo =
      BehaviorSubject<StreamInfo?>.seeded(null);

  @override
  final BehaviorSubject<List<StreamEvent>> recentStreamEvents =
      BehaviorSubject<List<StreamEvent>>.seeded(const []);

  @override
  bool get isCasting => false;

  void _setPlaying(bool playing) =>
      playbackState.add(playbackState.value.copyWith(playing: playing));

  @override
  Future<void> play() async {
    calls.add('play');
    _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _setPlaying(false);
  }

  @override
  Future<void> skipToNext() async => calls.add('next');

  @override
  Future<void> skipToPrevious() async => calls.add('previous');

  @override
  Future<void> playStation(
    Station station, {
    bool? fromFavorites,
    String? fromGroup,
  }) async {
    calls.add('playStation:${station.slug}:$fromFavorites');
    currentStation.add(station);
  }

  @override
  bool toggleStationFavorite(Station station) {
    final favorite =
        !stationDataService.favoriteStationSlugs.value.contains(station.slug);
    stationDataService.setStationIsFavorite(station, favorite);
    return favorite;
  }

  @override
  int? hideStation(Station station) {
    calls.add('hide:${station.slug}');
    stationDataService.setStationIsHidden(station, true);
    return null;
  }

  @override
  Future<void> unhideStation(Station station, {int? favoriteIndex}) async {
    calls.add('unhide:${station.slug}');
    await stationDataService.setStationIsHidden(station, false);
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    calls.add(name);
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

Station _station(
  int id,
  String slug,
  String title, {
  String? song,
  String? artist,
  int listeners = 10,
}) =>
    StationFactory.createStation(
      id: id,
      slug: slug,
      title: title,
      thumbnailUrl: null,
      totalListeners: listeners,
      nowPlaying: song == null
          ? null
          : StationFactory.createNowPlaying(
              id: id * 10,
              songName: song,
              artistName: artist,
              timestamp: DateTime.now().toUtc().toIso8601String(),
            ),
    );

Query$GetStations$station_groups _group(
  int id,
  String slug,
  String name, {
  required List<int> stationIds,
  int order = 0,
}) =>
    StationFactory.createStationGroup(
      id: id,
      name: name,
      slug: slug,
      order: order,
      stationToStationGroups: [
        for (final stationId in stationIds)
          StationFactory.createStationToStationGroup(stationId: stationId),
      ],
    );

/// A widget test run as on a Mac, the platform the desktop shell ships on.
void _testMac(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

void main() {
  late StationDataService service;
  late _FakeAudioHandler handler;
  late List<Object?> menuBarStates;
  late List<bool> dragAreaCalls;
  StreamSubscription<List<Station>>? filtering;

  final alpha = _station(1, 'alpha', 'Radio Alpha',
      song: 'Lauda Domnului', artist: 'Grupul Har', listeners: 24);
  final bravo = _station(2, 'bravo', 'Radio Bravo', song: 'Cântec nou');
  final charlie = _station(3, 'charlie', 'Charlie Worship');
  final delta = _station(4, 'delta', 'Delta Gospel');
  final echo = _station(5, 'echo', 'Echo Ascuns');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<SharedPreferences>(prefs)
      ..registerSingleton<PlayCountService>(PlayCountService());

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('posthog_flutter'),
      (_) async => null,
    );
    menuBarStates = [];
    dragAreaCalls = [];
    messenger.setMockMethodCallHandler(
      const MethodChannel(DesktopMenuService.channelName),
      (call) async {
        if (call.method == 'state') menuBarStates.add(call.arguments);
        if (call.method == 'dragArea') {
          dragAreaCalls.add(call.arguments as bool);
        }
        return null;
      },
    );

    service = StationDataService(
      graphqlClient: GraphQLClient(
        link: HttpLink('https://example.com/graphql'),
        cache: GraphQLCache(),
      ),
    );
    service.applyPublicStationsForTest([alpha, bravo, charlie, delta, echo]);
    service.stationGroups.add([
      _group(10, 'muzica', 'Muzica', stationIds: [3, 1]),
      _group(11, 'predici', 'Predici', stationIds: [4], order: 1),
    ]);
    await service.setStationIsFavorite(delta, true);
    await service.setStationIsHidden(echo, true);

    handler = _FakeAudioHandler(service);
    handler.currentStation.add(alpha);
    GetIt.instance
      ..registerSingleton<StationDataService>(service)
      ..registerSingleton<PlaylistController>(PlaylistController(
        videoService: VideoPlaybackService(),
        syncService: PlaylistSyncService(),
      ))
      ..registerSingleton<AppAudioHandler>(handler);
  });

  tearDown(() async {
    await filtering?.cancel();
    filtering = null;
    handler.sleepTimer.cancel();
    service.dispose();
    await GetIt.instance.reset();
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    Size window = const Size(1280, 800),
    MacAppStoreUpdates? updates,
    DateTime Function() now = DateTime.now,
  }) async {
    await tester.binding.setSurfaceSize(window);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // What initialize() wires up, without its network bootstrap; in the
    // test's zone, so its events come with the frames.
    filtering = Rx.combineLatest3(
      service.selectedStationGroup.stream,
      service.stations.stream,
      service.hiddenStationSlugs.stream,
      (group, all, hidden) => StationDataService.filterByGroup(
        group,
        all,
        hiddenSlugs: hidden.toSet(),
      ),
    ).listen(service.filteredStations.add);
    await tester.pumpWidget(MaterialApp(
      theme: tvTheme,
      home: DesktopShell(
        youtubeCountdown: ValueNotifier<TvYoutubeCountdown?>(null),
        updates: updates,
        now: now,
      ),
    ));
    await tester.pumpAndSettle();
  }

  final searchButton = find.byTooltip('Caută (⌘F)');
  final settingsButton = find.byTooltip('Setări (⌘,)');

  /// Unfolds the search field from its button in the top bar.
  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
  }

  Finder card(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byType(DesktopStationCard),
      );

  for (final window in const [
    Size(760, 560),
    Size(1280, 800),
    Size(2560, 1440),
  ]) {
    _testMac('lays out a ${window.width.toInt()} x '
        '${window.height.toInt()} window without overflowing', (tester) async {
      await pumpShell(tester, window: window);
      expect(tester.takeException(), isNull);
      expect(searchButton, findsOneWidget);
      expect(settingsButton, findsOneWidget);
      expect(find.text('Favorite'), findsOneWidget);
      expect(find.text('Pentru tine'), findsOneWidget);
      expect(find.byType(DesktopStationCard), findsWidgets);
      // The sort order sits at the end of its section's header.
      expect(
        tester.getRect(find.text('Pentru tine')).right,
        greaterThan(window.width - 80),
      );
    });
  }

  _testMac('shows the favorites first, then every station; the hidden '
      'one nowhere', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    expect(find.text('Favorite'), findsOneWidget);
    // "Toate stațiile" heads the main section and its chip.
    expect(find.text('Toate stațiile'), findsNWidgets(2));
    // Delta, a favorite, is in both sections, as on the phone.
    expect(card('Delta Gospel'), findsNWidgets(2));
    expect(card('Radio Alpha'), findsOneWidget);
    expect(find.text('Echo Ascuns'), findsNothing);
    // The playing station's song and listeners.
    // On its card and in the mini player.
    expect(find.text('Lauda Domnului - Grupul Har'), findsNWidgets(2));
    expect(find.text('24 de ascultători'), findsOneWidget);
    expect(find.text(DesktopStationCard.pausedLabel), findsOneWidget);
  });

  _testMac('a category narrows the grid and hides the Favorite section',
      (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    await tester.tap(find.text('Muzica'));
    await tester.pumpAndSettle();

    expect(service.selectedStationGroup.value?.slug, 'muzica');
    expect(find.text('Favorite'), findsNothing);
    // The section's title and the chip.
    expect(find.text('Muzica'), findsNWidgets(2));
    expect(card('Charlie Worship'), findsOneWidget);
    expect(card('Radio Alpha'), findsOneWidget);
    expect(card('Radio Bravo'), findsNothing);

    // The chosen chip again shows every station.
    await tester.tap(find.text('Muzica').first);
    await tester.pumpAndSettle();
    expect(service.selectedStationGroup.value, isNull);
  });

  _testMac('a favorite added while scrolled down moves nothing in view',
      (tester) async {
    // Enough stations to scroll, and no favorites yet: the first one makes
    // the whole Favorite section appear above what is in view.
    service.applyPublicStationsForTest([
      alpha,
      bravo,
      charlie,
      delta,
      echo,
      for (var i = 0; i < 16; i++) _station(100 + i, 'extra$i', 'Extra $i'),
    ]);
    await service.setStationIsFavorite(delta, false);
    await pumpShell(tester);
    // Empty, the section takes no room, so it counts as off screen.
    final anchor = find.byType(DesktopScrollAnchor, skipOffstage: false);
    final favorites = tester.renderObject<RenderSliver>(anchor);
    expect(favorites.geometry!.scrollExtent, 0);
    tester
        .state<ScrollableState>(find.ancestor(
          of: anchor,
          matching: find.byType(Scrollable),
        ))
        .position
        .jumpTo(400);
    await tester.pumpAndSettle();
    final inView = tester
        .widget<DesktopStationCard>(find.byType(DesktopStationCard).first)
        .station
        .displayTitle;
    expect(inView, isNot('Radio Bravo'), reason: 'Bravo is above the view');
    final before = tester.getTopLeft(card(inView).last);

    // The Favorite section appears above what is in view.
    await service.setStationIsFavorite(bravo, true);
    await tester.pumpAndSettle();

    expect(favorites.geometry!.scrollExtent, greaterThan(0));
    expect(tester.getTopLeft(card(inView).last), before);
  });

  _testMac('another category\'s title fades in, in the frame its stations '
      'show, in place of the old one, which leaves at once', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));
    Finder title(String text) => find.descendant(
          of: find.byType(DesktopSectionHeader),
          matching: find.text(text),
        );
    double opacity(String text) => tester
        .widget<FadeTransition>(find.ancestor(
          of: title(text),
          matching: find.descendant(
            of: find.byType(DesktopSectionHeader),
            matching: find.byType(FadeTransition),
          ),
        ))
        .opacity
        .value;
    expect(title('Favorite'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(DesktopCategoryBar),
      matching: find.text('Muzica'),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // No frame keeps "Toate stațiile" over the category's stations.
    expect(title('Toate stațiile'), findsNothing);
    expect(title('Favorite'), findsNothing);
    expect(opacity('Muzica'), inExclusiveRange(0, 1));
    expect(card('Charlie Worship'), findsOneWidget);
    expect(card('Radio Bravo'), findsNothing);
    expect(tester.getTopLeft(title('Muzica')).dx, DesktopTokens.gutter);

    await tester.pumpAndSettle();
    expect(opacity('Muzica'), 1);
    expect(tester.getTopLeft(title('Muzica')).dx, DesktopTokens.gutter);
  });

  _testMac('a click on a category whose mouse slips a little still chooses '
      'it; a drag scrolls the row and chooses nothing', (tester) async {
    // Enough categories for the row to scroll; one with every station
    // isn't offered.
    service.stationGroups.add([
      for (var i = 0; i < 12; i++)
        _group(20 + i, 'grupa$i', 'Grupa $i',
            stationIds: [1 + i % 4], order: i),
    ]);
    await pumpShell(tester, window: const Size(760, 560));
    Finder chip(String name) => find.descendant(
          of: find.byType(DesktopCategoryBar),
          matching: find.text(name),
        );
    final row = tester.state<ScrollableState>(find.descendant(
      of: find.byType(DesktopCategoryBar),
      matching: find.byType(Scrollable),
    ));
    expect(row.position.maxScrollExtent, greaterThan(0));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);

    await mouse.down(tester.getCenter(chip('Grupa 1')));
    await mouse.moveBy(const Offset(-5, 1));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(service.selectedStationGroup.value?.name, 'Grupa 1');

    final before = row.position.pixels;
    await mouse.down(tester.getCenter(chip('Grupa 0')));
    for (var i = 0; i < 6; i++) {
      await mouse.moveBy(const Offset(-10, 0));
      await tester.pump();
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expect(row.position.pixels, greaterThan(before));
    expect(service.selectedStationGroup.value?.name, 'Grupa 1');
  });

  _testMac('choosing a category moves no chip in the row', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));
    FontWeight? chipWeight() => DefaultTextStyle.of(tester.element(
          find.descendant(
            of: find.byType(DesktopCategoryBar),
            matching: find.text('Muzica'),
          ),
        )).style.fontWeight;
    Offset predici() => tester.getTopLeft(find.text('Predici'));
    final weight = chipWeight();
    final before = predici();

    await tester.tap(find.text('Muzica'));
    await tester.pumpAndSettle();
    // A bolder label would widen the chosen chip and push the chips after
    // it; the test font's glyphs don't widen with weight, real ones do.
    expect(chipWeight(), weight);
    // Muzica, left of Predici, was in view: the row didn't scroll.
    expect(predici(), before);
  });

  _testMac('the sort menu changes and saves the order', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('Pentru tine'));
    await tester.pumpAndSettle();
    expect(find.text('Sortate alfabetic'), findsOneWidget);

    await tester.tap(find.text('Sortate alfabetic'));
    await tester.pumpAndSettle();

    expect(StationSortService.loadSavedSort(), StationSortOption.alphabetical);
    expect(find.text('Sortate alfabetic'), findsOneWidget);
    expect(find.text('Pentru tine'), findsNothing);
  });

  _testMac('the search finds stations by name and by song, with the '
      'matches in bold; Esc ends it', (tester) async {
    await pumpShell(tester);

    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'lauda');
    await tester.pumpAndSettle();

    expect(find.text('Rezultate'), findsOneWidget);
    expect(find.byType(DesktopSearchResultRow), findsOneWidget);
    expect(find.text('Favorite'), findsNothing);
    final song = tester.widget<RichText>(find.descendant(
      of: find.byType(MatchedText),
      matching: find.byType(RichText),
    ).last);
    final bold = <String>[];
    song.text.visitChildren((span) {
      if (span is TextSpan &&
          span.style?.fontWeight == FontWeight.w800 &&
          span.text != null) {
        bold.add(span.text!);
      }
      return true;
    });
    expect(bold, ['Lauda']);

    await tester.enterText(find.byType(TextField), 'radio');
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSearchResultRow), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), 'nimic');
    await tester.pumpAndSettle();
    expect(find.text('Nicio stație găsită pentru „nimic”.'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Rezultate'), findsNothing);
    expect(find.text('Favorite'), findsOneWidget);
  });

  _testMac('↓ and Enter in the search play the next result',
      (tester) async {
    await pumpShell(tester);

    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'radio');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // Return, as the system's text input reports it.
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(handler.calls.where((c) => c.startsWith('playStation')), [
      'playStation:bravo:false',
    ]);
  });

  _testMac('Space plays and pauses; ⌘→ and ⌘← skip', (tester) async {
    await pumpShell(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.calls, ['play']);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.calls, ['play', 'pause']);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(handler.calls, ['play', 'pause', 'next', 'previous']);
  });

  _testMac('Space types in the search field', (tester) async {
    await pumpShell(tester);

    await openSearch(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(handler.calls, isEmpty);
  });

  _testMac('a click plays a station; one in Favorite steps through the '
      'favorites', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    await tester.tap(card('Radio Bravo'));
    await tester.tap(card('Delta Gospel').first);
    await tester.pump();

    expect(handler.calls, [
      'playStation:bravo:false',
      'playStation:delta:true',
    ]);
  });

  _testMac('a right-click opens the station\'s menu, which favorites '
      'and hides it', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    await tester.tap(card('Radio Bravo'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    for (final label in [
      DesktopStationMenu.playLabel,
      DesktopStationMenu.addFavoriteLabel,
      DesktopStationMenu.shareLabel,
      DesktopStationMenu.copyLinkLabel,
      DesktopStationMenu.hideLabel,
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text(DesktopStationMenu.addFavoriteLabel));
    await tester.pumpAndSettle();
    expect(service.favoriteStationSlugs.value, contains('bravo'));
    expect(find.text(DesktopStationMenu.addFavoriteLabel), findsNothing);
    expect(handler.calls, isEmpty, reason: 'the click only chose the item');

    await tester.tap(card('Radio Alpha'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(DesktopStationMenu.hideLabel));
    await tester.pumpAndSettle();

    expect(handler.calls, ['hide:alpha']);
    expect(card('Radio Alpha'), findsNothing);
    expect(find.text('Stație ascunsă. O poți readuce din Setări.'),
        findsOneWidget);

    await tester.tap(find.text('Anulează'));
    await tester.pumpAndSettle();
    expect(handler.calls.last, 'unhide:alpha');
    expect(card('Radio Alpha'), findsOneWidget);
  });

  _testMac('the player bar\'s "more", after the volume, opens the station\'s '
      'menu without play and pause, which the bar has', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));
    final more = find.byTooltip('Mai multe');
    expect(
      tester.getCenter(more).dx,
      greaterThan(tester.getRect(find.byType(DesktopVolumeControl)).right),
    );

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text(DesktopStationMenu.addFavoriteLabel), findsOneWidget);
    expect(find.text(DesktopStationMenu.playLabel), findsNothing);
    expect(find.text(DesktopStationMenu.pauseLabel), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // A card's menu still plays.
    await tester.tap(card('Radio Bravo'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text(DesktopStationMenu.playLabel), findsOneWidget);
  });

  _testMac('a click outside the menu only closes it', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    await tester.tap(card('Radio Bravo'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    // On the empty top bar, well clear of the menu.
    await tester.tapAt(const Offset(400, 26));
    await tester.pumpAndSettle();
    expect(find.text(DesktopStationMenu.hideLabel), findsNothing);

    // A click on a card while the menu is open doesn't play it.
    await tester.tap(card('Radio Bravo'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(card('Delta Gospel').first);
    await tester.pumpAndSettle();

    expect(find.text(DesktopStationMenu.hideLabel), findsNothing);
    expect(handler.calls, isEmpty);
  });

  _testMac('a right-click on another station moves the open menu to it',
      (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    await tester.tap(card('Charlie Worship'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    // One right-click on Bravo, left of Charlie and clear of its menu,
    // while that menu is open: Bravo's menu.
    await tester.tapAt(
      tester.getTopLeft(card('Radio Bravo').last) + const Offset(16, 16),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(DesktopStationMenu.addFavoriteLabel), findsOneWidget);

    await tester.tap(find.text(DesktopStationMenu.addFavoriteLabel));
    await tester.pumpAndSettle();
    expect(service.favoriteStationSlugs.value, contains('bravo'));
    expect(service.favoriteStationSlugs.value, isNot(contains('charlie')));
  });

  _testMac('a hidden station\'s notice has Ok, and goes by itself after a '
      'few seconds', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));
    Future<void> hide(String title) async {
      await tester.tap(card(title), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(DesktopStationMenu.hideLabel));
      await tester.pumpAndSettle();
    }

    final notice = find.text(DesktopStationActions.hiddenNotice);
    await hide('Radio Bravo');
    expect(notice, findsOneWidget);
    await tester.pump(DesktopStationActions.hiddenNoticeDuration);
    await tester.pumpAndSettle();
    expect(notice, findsNothing);

    await hide('Charlie Worship');
    await tester.tap(find.text(DesktopStationActions.okLabel));
    await tester.pumpAndSettle();
    expect(notice, findsNothing);
    expect(handler.calls, ['hide:bravo', 'hide:charlie'],
        reason: 'Ok undoes nothing');
  });

  _testMac('hiding a favorite asks first', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    await tester.tap(card('Delta Gospel').first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(DesktopStationMenu.hideLabel));
    await tester.pumpAndSettle();

    expect(find.text('Ascunzi „Delta Gospel”?'), findsOneWidget);
    await tester.tap(find.text('Anulează'));
    await tester.pumpAndSettle();
    expect(handler.calls, isEmpty);
    expect(card('Delta Gospel'), findsNWidgets(2));
  });

  _testMac('the menu bar\'s commands act on the shell, and it hears '
      'what plays', (tester) async {
    await pumpShell(tester);
    expect(menuBarStates.last, {
      'hasStation': true,
      'playing': false,
      'isFavorite': false,
      'muted': false,
      'recent': <Object?>[],
    });

    DesktopMenuService.dispatch(DesktopCommand.toggleFavorite);
    await tester.pumpAndSettle();
    expect(service.favoriteStationSlugs.value, contains('alpha'));
    expect(menuBarStates.last, {
      'hasStation': true,
      'playing': false,
      'isFavorite': true,
      'muted': false,
      'recent': <Object?>[],
    });
    // Told once per change.
    for (var i = 1; i < menuBarStates.length; i++) {
      expect(menuBarStates[i], isNot(menuBarStates[i - 1]));
    }

    DesktopMenuService.dispatch(DesktopCommand.search);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasFocus, isTrue);
  });

  _testMac('"Se redă acum" opens once, however often it is asked for',
      (tester) async {
    await pumpShell(tester);

    DesktopMenuService.dispatch(DesktopCommand.nowPlaying);
    await tester.pumpAndSettle();
    DesktopMenuService.dispatch(DesktopCommand.nowPlaying);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopNowPlayingSheet), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopNowPlayingSheet), findsNothing);

    // In the player bar, a click on what plays opens nothing; its arrow
    // opens the panel.
    await tester.tap(find.text('Lauda Domnului - Grupul Har').last);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopNowPlayingSheet), findsOneWidget);
  });

  _testMac('the search field\'s x shows while it has the keyboard and '
      'leaves it', (tester) async {
    await pumpShell(tester);
    final clear = find.byIcon(Icons.close_rounded);
    expect(clear, findsNothing);

    DesktopMenuService.dispatch(DesktopCommand.search);
    await tester.pumpAndSettle();
    expect(clear, findsOneWidget, reason: 'empty, but focused');

    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(clear, findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isFalse,
    );
  });

  _testMac('the player bar\'s volume, ⌘↑ and ⌘↓ set the listener\'s volume',
      (tester) async {
    await pumpShell(tester);
    expect(find.byType(DesktopVolumeControl), findsOneWidget);

    DesktopMenuService.dispatch(DesktopCommand.volumeDown);
    await tester.pumpAndSettle();
    expect(handler.listenerVolume.value, closeTo(0.9, 0.001));

    // The speaker mutes, and unmutes back to where it was.
    await tester.tap(find.byIcon(DesktopVolumeControl.iconFor(0.9)));
    await tester.pumpAndSettle();
    expect(handler.listenerVolume.value, 0);
    await tester.tap(find.byIcon(Icons.volume_off_rounded));
    await tester.pumpAndSettle();
    expect(handler.listenerVolume.value, closeTo(0.9, 0.001));

    DesktopMenuService.dispatch(DesktopCommand.volumeUp);
    DesktopMenuService.dispatch(DesktopCommand.volumeUp);
    await tester.pumpAndSettle();
    expect(handler.listenerVolume.value, 1, reason: 'never past 100%');
  });

  _testMac('M mutes and unmutes; starting to listen while muted says so '
      'over the speaker, and a click there turns the sound on',
      (tester) async {
    await pumpShell(tester);
    final reminder = find.text(DesktopVolumeControl.mutedTitle);
    // The equalizer moves while a station plays: frames for a moment
    // rather than until all settles.
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pumpAndSettle();
    expect(handler.listenerVolume.value, 0);
    expect((menuBarStates.last as Map)['muted'], isTrue);
    expect(reminder, findsNothing, reason: 'nothing started playing');

    await handler.play();
    await settle();
    expect(reminder, findsOneWidget);
    // Right above the speaker, pointing at it.
    final speaker = tester.getRect(find.descendant(
      of: find.byType(DesktopVolumeControl),
      matching: find.byType(IconButton),
    ));
    final bubble = tester.getRect(find
        .ancestor(of: reminder, matching: find.byType(DecoratedBox))
        .first);
    expect(bubble.bottom, closeTo(speaker.top - 2, 0.5));
    expect(bubble.center.dx, closeTo(speaker.center.dx, 0.5));

    await tester.pump(DesktopVolumeControl.reminderDuration);
    await settle();
    expect(reminder, findsNothing, reason: 'gone after a while');

    // Another station, still muted.
    await tester.tap(card('Radio Bravo'));
    await settle();
    expect(reminder, findsOneWidget);
    await tester.tap(reminder);
    await settle();
    expect(handler.listenerVolume.value, 1);
    expect(reminder, findsNothing);
    expect((menuBarStates.last as Map)['muted'], isFalse);

    // With the sound on, starting again says nothing.
    await handler.pause();
    await handler.play();
    await settle();
    expect(reminder, findsNothing);

    // The menu bar's item does what M does.
    DesktopMenuService.dispatch(DesktopCommand.toggleMute);
    await settle();
    expect(handler.listenerVolume.value, 0);
    DesktopMenuService.dispatch(DesktopCommand.toggleMute);
    await settle();
    expect(handler.listenerVolume.value, 1);
  });

  _testMac('F adds the playing station to the favorites and takes it out '
      'again; in the search field it types', (tester) async {
    await pumpShell(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(service.favoriteStationSlugs.value, contains('alpha'));
    expect(find.byTooltip('Elimină din favorite (F)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(service.favoriteStationSlugs.value, isNot(contains('alpha')));

    await openSearch(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(service.favoriteStationSlugs.value, isNot(contains('alpha')));
  });

  _testMac('the muted reminder goes by itself, also after one was clicked '
      'away under the pointer; the player stopping takes it away, and the '
      'same station starting again soon shows nothing', (tester) async {
    await pumpShell(tester);
    final reminder = find.text(DesktopVolumeControl.mutedTitle);
    // The equalizer moves while a station plays: frames for a moment
    // rather than until all settles.
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 400));
    addTearDown(mouse.removePointer);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await handler.play();
    await settle();
    await mouse.moveTo(tester.getCenter(reminder));
    await tester.pump();
    await mouse.down(tester.getCenter(reminder));
    await mouse.up();
    await settle();
    expect(reminder, findsNothing);
    expect(handler.listenerVolume.value, 1);
    // Away from where it was: gone, it never heard the pointer leave.
    await mouse.moveTo(const Offset(10, 400));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    handler.currentStation.add(bravo);
    await settle();
    expect(reminder, findsOneWidget);
    await tester.pump(DesktopVolumeControl.reminderDuration);
    await settle();
    expect(reminder, findsNothing, reason: 'gone by itself');

    handler.currentStation.add(charlie);
    await settle();
    expect(reminder, findsOneWidget);
    await handler.pause();
    await settle();
    expect(reminder, findsNothing, reason: 'the player stopped');

    await handler.play();
    await settle();
    expect(reminder, findsNothing, reason: 'the same station, so soon');
  });

  _testMac('the top bar has search and Settings at its end, level with '
      'the window buttons; the search button unfolds into the field, which '
      'folds back once left with nothing typed', (tester) async {
    addTearDown(
        () => DesktopMenuService.titleBar.value = const DesktopTitleBar());
    DesktopMenuService.titleBar.value =
        const DesktopTitleBar(height: 52, leading: 79);
    await pumpShell(tester);
    final field = find.byType(DesktopSearchField);
    // How much of the field shows: it unfolds from its button.
    double shown() => tester
        .getSize(find.ancestor(of: field, matching: find.byType(ClipRect)).first)
        .width;
    final settings = tester.getRect(settingsButton);
    expect(settings.center.dy, 26, reason: 'level with the buttons');
    expect(settings.right, closeTo(1280 - DesktopTokens.gutter, 6));
    expect(tester.getRect(searchButton).right, lessThan(settings.left));
    expect(shown(), 0, reason: 'folded');
    expect(field.hitTestable(), findsNothing);

    await openSearch(tester);
    expect(shown(), greaterThan(300));
    expect(tester.getRect(field).right, lessThan(settings.left));
    expect(tester.getCenter(field).dy, 26);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );

    // Left with nothing typed: folded again.
    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();
    expect(shown(), 0);

    // ⌘F opens it too; with something typed it stays open once left.
    DesktopMenuService.dispatch(DesktopCommand.search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'radio');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rezultate'));
    await tester.pumpAndSettle();
    expect(shown(), greaterThan(300));
  });

  _testMac('the top bar\'s empty parts move the window; its buttons '
      'don\'t', (tester) async {
    await pumpShell(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(640, 600));
    addTearDown(mouse.removePointer);
    final barMiddle = tester.getCenter(settingsButton).dy;
    Future<bool?> over(Offset point) async {
      await mouse.moveTo(point);
      await tester.pump();
      return dragAreaCalls.isEmpty ? null : dragAreaCalls.last;
    }

    expect(await over(Offset(60, barMiddle)), isTrue);
    expect(await over(Offset(640, barMiddle)), isTrue);
    // Search and Settings take clicks.
    expect(await over(tester.getCenter(searchButton)), isFalse);
    await over(Offset(640, barMiddle));
    expect(await over(tester.getCenter(settingsButton)), isFalse);
    // Down in the grid, the window doesn't move.
    await over(Offset(640, barMiddle));
    expect(await over(const Offset(640, 500)), isFalse);
  });

  _testMac('a skip leaves the list where the listener left it, wherever '
      'the station\'s card is', (tester) async {
    final extras = [
      for (var i = 0; i < 30; i++) _station(100 + i, 'extra$i', 'Extra $i'),
    ];
    service.applyPublicStationsForTest(
        [alpha, bravo, charlie, delta, echo, ...extras]);
    await pumpShell(tester);
    final grid = tester.state<ScrollableState>(find.ancestor(
      of: find.byType(DesktopScrollAnchor, skipOffstage: false),
      matching: find.byType(Scrollable),
    ));
    expect(card('Extra 29'), findsNothing, reason: 'far down, not built');

    // As ⌘→ to the last station would.
    handler.currentStation.add(extras.last);
    await tester.pumpAndSettle();
    expect(grid.position.pixels, 0);

    // Scrolled down, back to a station at the top, above the view.
    grid.position.jumpTo(600);
    await tester.pumpAndSettle();
    handler.currentStation.add(alpha);
    await tester.pumpAndSettle();
    expect(grid.position.pixels, 600);
  });

  _testMac('the arrows bring the station they play into view, its card '
      'not built yet too', (tester) async {
    final extras = [
      for (var i = 0; i < 30; i++) _station(100 + i, 'extra$i', 'Extra $i'),
    ];
    service.applyPublicStationsForTest(
        [alpha, bravo, charlie, delta, echo, ...extras]);
    await pumpShell(tester);
    final grid = tester.state<ScrollableState>(find.ancestor(
      of: find.byType(DesktopScrollAnchor, skipOffstage: false),
      matching: find.byType(Scrollable),
    ));
    final list = tester.getRect(find.byWidget(grid.widget));
    void expectWhollyInView(String title) {
      final rect = tester.getRect(card(title).last);
      expect(rect.top, greaterThanOrEqualTo(list.top), reason: title);
      expect(rect.bottom, lessThanOrEqualTo(list.bottom), reason: title);
    }

    expect(card('Extra 29'), findsNothing, reason: 'far down, not built');
    // As → to the last station, the wrap-around back would.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    handler.currentStation.add(extras.last);
    await tester.pumpAndSettle();
    expectWhollyInView('Extra 29');

    // And ← back to the top.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    handler.currentStation.add(alpha);
    await tester.pumpAndSettle();
    expectWhollyInView('Radio Alpha');
    expect(handler.calls, ['next', 'previous']);
  });

  _testMac('a station picked or skipped to in Favorite plays where it is: '
      'the list doesn\'t scroll down to its card in the grid',
      (tester) async {
    final extras = [
      for (var i = 0; i < 30; i++) _station(100 + i, 'extra$i', 'Extra $i'),
    ];
    service.applyPublicStationsForTest(
        [alpha, bravo, charlie, delta, echo, ...extras]);
    await service.setStationIsFavorite(extras[29], true);
    await service.setStationIsFavorite(extras[28], true);
    await pumpShell(tester);
    final grid = tester.state<ScrollableState>(find.ancestor(
      of: find.byType(DesktopScrollAnchor, skipOffstage: false),
      matching: find.byType(Scrollable),
    ));
    for (final title in ['Extra 29', 'Extra 28']) {
      expect(card(title), findsOneWidget,
          reason: '$title shows in Favorite; its grid card is far down');
    }

    // A click on its card.
    await tester.tap(card('Extra 29'));
    await tester.pumpAndSettle();
    expect(handler.calls, ['playStation:extra29:true']);
    expect(grid.position.pixels, 0);

    // "Redă" in its card's menu.
    await tester.tap(card('Extra 28'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(DesktopStationMenu.playLabel));
    await tester.pumpAndSettle();
    expect(handler.calls.last, 'playStation:extra28:true');
    expect(grid.position.pixels, 0);

    // As ⌘→ through the favorites would land on it.
    handler.currentStation.add(extras[29]);
    await tester.pumpAndSettle();
    expect(grid.position.pixels, 0);
  });

  _testMac('the station listened to last, back at launch, leaves the list '
      'at the top', (tester) async {
    final extras = [
      for (var i = 0; i < 30; i++) _station(100 + i, 'extra$i', 'Extra $i'),
    ];
    service.applyPublicStationsForTest(
        [alpha, bravo, charlie, delta, echo, ...extras]);
    handler.currentStation.add(null);
    await pumpShell(tester);
    final grid = tester.state<ScrollableState>(find.ancestor(
      of: find.byType(DesktopScrollAnchor, skipOffstage: false),
      matching: find.byType(Scrollable),
    ));

    // Restored once the screen is up, far down the grid.
    handler.currentStation.add(extras.last);
    await tester.pumpAndSettle();
    expect(grid.position.pixels, 0);
    expect(find.text('Favorite'), findsOneWidget);
  });

  _testMac('the Dock menu hears of the stations listened to lately',
      (tester) async {
    await pumpShell(tester);

    // Bravo comes on after Alpha: Alpha is offered again, Bravo plays.
    handler.currentStation.add(bravo);
    await tester.pumpAndSettle();
    expect((menuBarStates.last as Map)['recent'], [
      {'slug': 'alpha', 'title': 'Radio Alpha'},
    ]);
  });

  _testMac('back and forward (⌘[ and ⌘]) close and reopen panels, as in a '
      'browser', (tester) async {
    await pumpShell(tester);
    Future<void> step(DesktopCommand command) async {
      DesktopMenuService.dispatch(command);
      await tester.pumpAndSettle();
    }

    await step(DesktopCommand.nowPlaying);
    await step(DesktopCommand.back);
    expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    await step(DesktopCommand.forward);
    expect(find.byType(DesktopNowPlayingSheet), findsOneWidget);

    // Back again, then leaves the category; forward chooses it again.
    await step(DesktopCommand.back);
    await tester.tap(find.text('Muzica'));
    await tester.pumpAndSettle();
    await step(DesktopCommand.back);
    expect(service.selectedStationGroup.value, isNull);
    await step(DesktopCommand.forward);
    expect(service.selectedStationGroup.value?.slug, 'muzica');

    // Something new forgets what forward would bring back.
    await step(DesktopCommand.back);
    await tester.tap(find.text('Predici'));
    await tester.pumpAndSettle();
    await step(DesktopCommand.forward);
    expect(service.selectedStationGroup.value?.slug, 'predici');
  });

  _testMac('the mouse\'s back and forward buttons go through the stations '
      'played; over Settings, through its pages', (tester) async {
    TvPlatform.debugOverride(desktop: true);
    addTearDown(TvPlatform.debugOverride);
    await pumpShell(tester, window: const Size(1600, 1000));
    Future<void> press(int button) async {
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: button,
      );
      await mouse.down(const Offset(400, 26));
      await mouse.up();
      await tester.pumpAndSettle();
    }

    // Alpha plays; Bravo, then Charlie, are picked.
    await tester.tap(card('Radio Bravo'));
    await tester.tap(card('Charlie Worship'));
    await tester.pumpAndSettle();
    handler.calls.clear();

    await press(kBackMouseButton);
    await press(kBackMouseButton);
    expect(handler.currentStation.value?.slug, 'alpha');
    await press(kForwardMouseButton);
    // Next and previous keep stepping through what they did.
    expect(handler.calls, [
      'playStation:bravo:null',
      'playStation:alpha:null',
      'playStation:bravo:null',
    ]);

    // Also under "Se redă acum", which stays open.
    DesktopMenuService.dispatch(DesktopCommand.nowPlaying);
    await tester.pumpAndSettle();
    await press(kBackMouseButton);
    expect(handler.currentStation.value?.slug, 'alpha');
    expect(find.byType(DesktopNowPlayingSheet), findsOneWidget);

    // A station picked otherwise forgets what forward would play.
    await tester.tap(find.byTooltip('Închide (Esc)'));
    await tester.pumpAndSettle();
    await tester.tap(card('Radio Bravo'));
    await tester.pumpAndSettle();
    handler.calls.clear();
    await press(kForwardMouseButton);
    expect(handler.calls, isEmpty);

    // Over Settings they close it, and leave the station be.
    DesktopMenuService.dispatch(DesktopCommand.settings);
    await tester.pumpAndSettle();
    await press(kBackMouseButton);
    expect(find.byType(DesktopSettingsPanel), findsNothing);
    expect(handler.calls, isEmpty);
  });

  _testMac('with nothing on the keyboard, the arrows go through the grid: '
      '← and → play the station before and after, ↑ and ↓ the one above and '
      'below', (tester) async {
    final extras = [
      for (var i = 0; i < 30; i++) _station(100 + i, 'extra$i', 'Extra $i'),
    ];
    service.applyPublicStationsForTest(
        [alpha, bravo, charlie, delta, echo, ...extras]);
    await pumpShell(tester, window: const Size(1600, 1000));
    Future<void> arrow(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    await arrow(LogicalKeyboardKey.arrowRight);
    await arrow(LogicalKeyboardKey.arrowLeft);
    expect(handler.calls, ['next', 'previous']);
    handler.calls.clear();

    // The card right under Alpha's, in the grid below Favorite.
    final alphaCard = tester.getRect(card('Radio Alpha'));
    final below = tester
        .widgetList<DesktopStationCard>(find.byType(DesktopStationCard))
        .where((c) {
      final rect = tester.getRect(find.byWidget(c));
      return rect.left == alphaCard.left && rect.top > alphaCard.top;
    }).first;
    final String belowSlug = below.station.slug;

    await arrow(LogicalKeyboardKey.arrowDown);
    expect(handler.currentStation.value?.slug, belowSlug);
    await arrow(LogicalKeyboardKey.arrowUp);
    expect(handler.currentStation.value?.slug, 'alpha');
    // Next and previous keep stepping through what they did.
    expect(handler.calls,
        ['playStation:$belowSlug:null', 'playStation:alpha:null']);
    expect(FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<DesktopStationCard>(), isNull);
  });

  _testMac('a card Tab moved the keyboard to keeps the arrows, which move '
      'it; a click takes it off', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));
    String? focusedCard() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<DesktopStationCard>()
        ?.station
        .slug;

    final bravo = find.descendant(
      of: card('Radio Bravo'),
      matching: find.byType(GestureDetector),
    );
    Focus.of(tester.element(bravo.first)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedCard(), isNot(anyOf(isNull, 'bravo')));
    expect(handler.calls, isEmpty);

    // A click elsewhere takes it off, ring and all; the arrows play again.
    await tester.tapAt(const Offset(400, 26), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(focusedCard(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(handler.calls, ['next']);
  });

  _testMac('back goes back in Settings, then closes it; forward reopens it',
      (tester) async {
    TvPlatform.debugOverride(desktop: true);
    addTearDown(TvPlatform.debugOverride);
    await pumpShell(tester);
    DesktopMenuService.dispatch(DesktopCommand.settings);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsPanel), findsOneWidget);

    DesktopMenuService.dispatch(DesktopCommand.back);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsPanel), findsNothing);
    DesktopMenuService.dispatch(DesktopCommand.forward);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsPanel), findsOneWidget);
  });

  _testMac('"Se redă acum" grows with the window', (tester) async {
    // The window's size as MediaQuery reports it too, not only the
    // surface's.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(760, 560);
    addTearDown(tester.view.reset);
    await pumpShell(tester, window: const Size(760, 560));
    DesktopMenuService.dispatch(DesktopCommand.nowPlaying);
    await tester.pumpAndSettle();
    // As wide as the player bar it grew out of.
    expect(tester.getSize(find.byType(DesktopNowPlayingSheet)).width,
        DesktopMiniPlayer.rectIn(const Size(760, 560)).width);

    // Enlarged, or full screen.
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(DesktopNowPlayingSheet)).width,
        DesktopMiniPlayer.rectIn(const Size(1600, 1000)).width);
    expect(tester.takeException(), isNull);
  });

  _testMac('Settings takes "Se redă acum" off the screen with the dialog '
      'opened from it', (tester) async {
    TvPlatform.debugOverride(desktop: true);
    addTearDown(TvPlatform.debugOverride);
    await pumpShell(tester);
    DesktopMenuService.dispatch(DesktopCommand.nowPlaying);
    await tester.pumpAndSettle();
    // As its song history opens.
    unawaited(showDialog<void>(
      context: tester.element(find.byType(DesktopNowPlayingSheet)),
      builder: (_) => const Dialog(child: Text('Istoric')),
    ));
    await tester.pumpAndSettle();

    // "Setări…" from the menu bar, which works whatever has the keyboard.
    DesktopMenuService.dispatch(DesktopCommand.settings);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsPanel), findsOneWidget);
    expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    expect(find.text('Istoric'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSettingsPanel), findsNothing);
    expect(find.text('Istoric'), findsNothing);
    expect(find.byType(Dialog), findsNothing);
  });

  _testMac('the results follow the songs: a station whose song stops '
      'matching leaves, one whose new song matches comes', (tester) async {
    await pumpShell(tester);
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'lauda');
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSearchResultRow), findsOneWidget);

    final alphaNext = _station(1, 'alpha', 'Radio Alpha',
        song: 'Alt cântec', artist: 'Corul', listeners: 24);
    final bravoNext = _station(2, 'bravo', 'Radio Bravo',
        song: 'Lauda serii', artist: 'Ana');
    service.applyPublicStationsForTest(
        [alphaNext, bravoNext, charlie, delta, echo]);
    // The new catalog, then the screen's frame with it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // Alpha plays its row out, in its place, while Bravo's grows in.
    expect(find.byType(DesktopSearchResultRow), findsNWidgets(2));
    await tester.pumpAndSettle();
    final rows = tester
        .widgetList<DesktopSearchResultRow>(
            find.byType(DesktopSearchResultRow))
        .map((row) => row.station.slug)
        .toList();
    expect(rows, ['bravo']);
  });

  _testMac('a category whose stations are all hidden lists them dimmed, '
      'with a way to add each back', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));
    await tester.tap(find.text('Predici'));
    await tester.pumpAndSettle();

    await tester.tap(card('Delta Gospel'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(DesktopStationMenu.hideLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ascunde'));
    await tester.pumpAndSettle();

    expect(handler.calls, ['hide:delta']);
    expect(find.text('Singura stație din Predici e ascunsă.'), findsOneWidget);
    expect(find.text(DesktopStationCard.unhideLabel), findsOneWidget);
    // Its chip stays, the way back to every station.
    expect(find.text('Predici'), findsNWidgets(2));

    await tester.tap(find.text(DesktopStationCard.unhideLabel));
    await tester.pumpAndSettle();
    expect(handler.calls.last, 'unhide:delta');
    expect(find.text(DesktopStationCard.unhideLabel), findsNothing);
  });

  _testMac('a click outside the search field gives Space back to the '
      'player', (tester) async {
    await pumpShell(tester);

    await openSearch(tester);
    await tester.tap(find.text('Favorite'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(handler.calls, ['play']);
  });

  _testMac('a card the keyboard moved to plays on Return; Space still '
      'plays and pauses', (tester) async {
    await pumpShell(tester, window: const Size(1600, 1000));

    final bravo = find.descendant(
      of: card('Radio Bravo'),
      matching: find.byType(GestureDetector),
    );
    Focus.of(tester.element(bravo.first)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(handler.calls, ['playStation:bravo:false', 'play']);
  });

  _testMac('an update found under "Se redă acum" is offered once the panel '
      'closes, with the App Store asked once however long it stays open',
      (tester) async {
    var lookups = 0;
    final prefs = GetIt.instance<SharedPreferences>();
    final updates = MacAppStoreUpdates(
      prefs: prefs,
      currentVersion: '1.5.1',
      client: MockClient((_) async {
        lookups++;
        return http.Response(
          json.encode({
            'resultCount': 1,
            'results': [
              {'kind': 'mac-software', 'version': '1.6.0'},
            ],
          }),
          200,
        );
      }),
    );
    await pumpShell(tester, updates: updates);
    final offer = find.text(DesktopUpdateDialog.title);
    DesktopMenuService.dispatch(DesktopCommand.nowPlaying);
    await tester.pumpAndSettle();

    // The check a few seconds after launch finds it under the panel.
    await tester.pump(const Duration(seconds: 4));
    expect(lookups, 1);
    expect(offer, findsNothing);

    // An hour of listening with the panel open.
    for (var minute = 0; minute < 60; minute++) {
      await tester.pump(const Duration(minutes: 1));
    }
    expect(lookups, 1);
    expect(offer, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // Once the panel has shrunk back into the player bar.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopNowPlayingSheet), findsNothing);
    expect(offer, findsOneWidget);
    expect(lookups, 1);

    await tester.tap(find.text(DesktopUpdateDialog.laterLabel));
    await tester.pumpAndSettle();
    expect(offer, findsNothing);
    expect(prefs.getString('mac_update_postponed_version'), '1.6.0');

    // The regular check, later, asks again; the version put off isn't
    // offered.
    await tester.pump(const Duration(hours: 12));
    await tester.pumpAndSettle();
    expect(lookups, 2);
    expect(offer, findsNothing);
  });

  _testMac('a press in the window before the fresh numbers come puts the '
      'new order off to the window\'s next return', (tester) async {
    await StationSortService.saveSortOption(StationSortOption.listeners);
    var now = DateTime(2026, 10, 30, 9);
    await pumpShell(tester, window: const Size(1600, 1000), now: () => now);
    String first() => tester
        .widget<DesktopStationGrid>(find.byWidgetPredicate(
          (widget) => widget is DesktopStationGrid && widget.keyPrefix == 'all',
        ))
        .stations
        .first
        .slug as String;
    Future<void> lifecycle(List<AppLifecycleState> states) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
    }

    const leave = [AppLifecycleState.inactive, AppLifecycleState.hidden];
    await lifecycle(const [AppLifecycleState.resumed]);
    expect(first(), 'alpha');
    final more = [
      alpha,
      bravo,
      _station(3, 'charlie', 'Charlie Worship', listeners: 90),
      delta,
      echo,
    ];

    await lifecycle(leave);
    now = now.add(const Duration(hours: 1));
    await lifecycle(const [AppLifecycleState.inactive]);
    // A click lands before the sync's numbers.
    await tester.tap(find.descendant(
      of: find.byType(DesktopSectionHeader),
      matching: find.text('Toate stațiile'),
    ));
    service.applyPublicStationsForTest(more);
    await tester.pumpAndSettle();
    expect(first(), 'alpha', reason: 'the window is in use');
    await lifecycle(const [AppLifecycleState.resumed]);

    // Away for a moment only, the radio playing: made at this return.
    await lifecycle(leave);
    now = now.add(const Duration(minutes: 1));
    service.applyPublicStationsForTest(more);
    await tester.pumpAndSettle();
    await lifecycle(const [AppLifecycleState.inactive]);
    expect(first(), 'charlie');
  });

  _testMac('back in sight after half an hour away, the order by listeners '
      'is made again from fresh numbers; never while the window is used, '
      'and "Pentru tine" stays', (tester) async {
    await StationSortService.saveSortOption(StationSortOption.listeners);
    var now = DateTime(2026, 10, 30, 9);
    await pumpShell(tester, window: const Size(1600, 1000), now: () => now);
    List<String> grid() => tester
        .widget<DesktopStationGrid>(find.byWidgetPredicate(
          (widget) => widget is DesktopStationGrid && widget.keyPrefix == 'all',
        ))
        .stations
        .map((station) => station.slug as String)
        .toList();
    Future<void> lifecycle(List<AppLifecycleState> states) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
    }

    const leave = [AppLifecycleState.inactive, AppLifecycleState.hidden];
    const comeBack = [AppLifecycleState.inactive, AppLifecycleState.resumed];
    await lifecycle(const [AppLifecycleState.resumed]);
    expect(grid().first, 'alpha', reason: '24 listeners, the most');

    // Charlie's listeners grow while the window is used for hours.
    service.applyPublicStationsForTest([
      alpha,
      bravo,
      _station(3, 'charlie', 'Charlie Worship', listeners: 90),
      delta,
      echo,
    ]);
    now = now.add(const Duration(hours: 2));
    await tester.pumpAndSettle();
    expect(grid().first, 'alpha');

    // Left in sight while another app is used, then clicked back into.
    await lifecycle(const [AppLifecycleState.inactive]);
    now = now.add(const Duration(minutes: 45));
    await lifecycle(const [AppLifecycleState.resumed]);
    expect(grid().first, 'alpha', reason: 'the click lands on a card');

    // Out of sight, but not for long.
    await lifecycle(leave);
    now = now.add(const Duration(minutes: 29));
    await lifecycle(comeBack);
    expect(grid().first, 'alpha');

    // Out of sight for over half an hour with nothing playing: no sync
    // ran meanwhile, so the order waits for the numbers the return brings.
    await lifecycle(leave);
    now = now.add(const Duration(minutes: 31));
    await lifecycle(const [AppLifecycleState.inactive]);
    expect(grid().first, 'alpha', reason: 'the numbers are from before');
    service.applyPublicStationsForTest([
      alpha,
      bravo,
      _station(3, 'charlie', 'Charlie Worship', listeners: 90),
      delta,
      echo,
    ]);
    await tester.pumpAndSettle();
    expect(grid().first, 'charlie');
    await lifecycle(const [AppLifecycleState.resumed]);

    // Away again while the radio plays: the sync goes on, the numbers are
    // fresh as the window shows, and the order is made at once.
    await lifecycle(leave);
    now = now.add(const Duration(minutes: 40));
    service.applyPublicStationsForTest([
      alpha,
      _station(2, 'bravo', 'Radio Bravo', listeners: 300),
      _station(3, 'charlie', 'Charlie Worship', listeners: 90),
      delta,
      echo,
    ]);
    await tester.pumpAndSettle();
    expect(grid().first, 'charlie', reason: 'out of sight, nothing moves');
    await lifecycle(const [AppLifecycleState.inactive]);
    expect(grid().first, 'bravo');
    await lifecycle(const [AppLifecycleState.resumed]);

    // "Pentru tine" keeps the order it was made in.
    await tester.tap(find.text('După numărul de ascultători'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pentru tine').last);
    await tester.pumpAndSettle();
    final recommended = grid();
    service.applyPublicStationsForTest([
      alpha,
      _station(2, 'bravo', 'Radio Bravo', song: 'Cântec nou', listeners: 500),
      charlie,
      delta,
      echo,
    ]);
    await lifecycle(leave);
    now = now.add(const Duration(hours: 3));
    await lifecycle(comeBack);
    expect(grid(), recommended);
  });
}
