/// Widget tests for the Android TV TvBrowse page: header, empty state,
/// "Pentru tine" grid.
library;

import 'package:audio_service/audio_service.dart';
import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/tv/pages/tv_browse.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  @override
  final BehaviorSubject<Station?> currentStation =
      BehaviorSubject.seeded(null);

  void setCurrent(Station? s) => currentStation.add(s);

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FakeStationDataService implements StationDataService {
  final BehaviorSubject<List<Station>> _stations =
      BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<Station>> _ordered =
      BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> _favs =
      BehaviorSubject.seeded(<String>[]);
  final BehaviorSubject<List<Query$GetStations$station_groups>> _groups =
      BehaviorSubject.seeded(<Query$GetStations$station_groups>[]);

  @override
  BehaviorSubject<List<Station>> get stations => _stations;

  /// The browse page reads the frozen order from here. Seed it directly in
  /// tests (mirrors what StationDataService computes once on first load).
  @override
  BehaviorSubject<List<Station>> get orderedStations => _ordered;

  @override
  BehaviorSubject<List<String>> get favoriteStationSlugs => _favs;

  @override
  BehaviorSubject<List<Query$GetStations$station_groups>> get stationGroups =>
      _groups;

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _Fakes {
  final _FakeAudioHandler audio;
  final _FakeStationDataService data;
  _Fakes(this.audio, this.data);
}

Future<_Fakes> _registerFakes() async {
  await GetIt.I.reset();
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  GetIt.I.registerSingleton<SharedPreferences>(prefs);
  final audio = _FakeAudioHandler();
  final data = _FakeStationDataService();
  GetIt.I.registerSingleton<AppAudioHandler>(audio);
  GetIt.I.registerSingleton<StationDataService>(data);
  GetIt.I.registerSingleton<PlayCountService>(PlayCountService());
  return _Fakes(audio, data);
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => await GetIt.I.reset());

  group('TvBrowse — header', () {
    testWidgets('always shows the brand mark and title', (tester) async {
      await _registerFakes();
      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      expect(find.text('Radio Crestin'), findsOneWidget);
      expect(find.byIcon(Icons.radio_rounded), findsOneWidget);
    });
  });

  group('TvBrowse — empty state', () {
    testWidgets('shows a loading spinner (not an empty-state) when no stations',
        (tester) async {
      await _registerFakes();
      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      // No rows yet → a spinner, and definitely no "Pentru tine" row.
      // (The old "Nu sunt posturi" flash is gone — we seed from memory.)
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Pentru tine'), findsNothing);
    });
  });

  group('TvBrowse — populated rows', () {
    testWidgets('renders the "Pentru tine" row header and station titles',
        (tester) async {
      final fakes = await _registerFakes();
      fakes.data.orderedStations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
      ]);

      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      expect(find.text('Pentru tine'), findsOneWidget);
      // Each station's title appears in its row card.
      expect(find.text('A', skipOffstage: false), findsOneWidget);
      expect(find.text('B', skipOffstage: false), findsOneWidget);
      expect(find.text('C', skipOffstage: false), findsOneWidget);
    });

    testWidgets('favorites are listed first in a single "Pentru tine" section '
        '(no separate "Favorite" row)', (tester) async {
      final fakes = await _registerFakes();
      fakes.data.orderedStations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
      ]);
      fakes.data.favoriteStationSlugs.add(['b']);

      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      // Favorites no longer get their own section — one "Pentru tine" list,
      // with favorites floated to the front.
      expect(find.text('Favorite'), findsNothing);
      expect(find.text('Pentru tine'), findsOneWidget);
      // The favorited station still renders within the single list.
      expect(find.text('B', skipOffstage: false), findsOneWidget);
    });
  });

  group('TvBrowse — focus restore on remount', () {
    // Reproduces the bug from the back-from-now-playing flow: the user
    // tapped a station card (focus on TvBrowse), the parent shell swapped
    // in the now-playing screen (focus moved to the play button), then
    // the user pressed BACK, swapping TvBrowse back in. Before the fix,
    // primary focus stayed pointed at the just-disposed play button so
    // the homepage looked focused but D-pad keys went nowhere.
    testWidgets('the first card claims focus after a swap-in remount',
        (tester) async {
      final fakes = await _registerFakes();
      fakes.data.orderedStations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'Beta'),
      ]);

      // The surrogate uses DpadFocusable + DpadNavigator the way the
      // real now-playing play button does, so the dpad package's region
      // manager and history are involved — the same machinery the
      // production bug ran into.
      Widget buildWith({required bool showBrowse}) => MaterialApp(
            home: DpadNavigator(
              enabled: true,
              child: Scaffold(
                body: showBrowse
                    ? TvBrowse(onBack: () {}, onStationSelected: (_) {})
                    : DpadFocusable(
                        autofocus: true,
                        region: 'np-controls',
                        isEntryPoint: true,
                        debugLabel: 'now-playing-play-btn',
                        onSelect: () {},
                        child: const SizedBox.expand(),
                      ),
              ),
            ),
          );

      // Phase 1: surrogate "now-playing" screen has focus.
      await tester.pumpWidget(buildWith(showBrowse: false));
      await tester.pump(); // post-frame autofocus settles
      final initialPrimary = FocusManager.instance.primaryFocus;
      expect(initialPrimary, isNotNull,
          reason: 'precondition: surrogate screen should hold focus');
      expect(initialPrimary!.debugLabel, 'now-playing-play-btn');

      // Phase 2: swap to TvBrowse — mirrors `setState(_browsing = true)`
      // in TvShell. After post-frame settles, focus must move into
      // TvBrowse, not stay stranded on the disposed surrogate.
      await tester.pumpWidget(buildWith(showBrowse: true));
      await tester.pump(); // first frame mounts TvBrowse + cards
      // Long enough for the post-mount focus-recovery delayed callback
      // inside TvBrowse to fire and move focus onto the first card.
      await tester.pump(const Duration(milliseconds: 400));

      final primary = FocusManager.instance.primaryFocus;
      expect(primary, isNotNull,
          reason: 'a focusable inside TvBrowse should now hold focus');

      // Confirm the focused node sits inside TvBrowse — not stranded
      // on the disposed surrogate node or some unrelated surface.
      final browseElement = tester.element(find.byType(TvBrowse));
      bool insideBrowse = false;
      primary!.context!.visitAncestorElements((ancestor) {
        if (ancestor == browseElement) {
          insideBrowse = true;
          return false;
        }
        return true;
      });
      expect(insideBrowse, isTrue,
          reason: 'primary focus should be inside TvBrowse');
    });
  });
}
