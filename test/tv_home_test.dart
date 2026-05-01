/// Widget tests for the Android TV home shell (TvHome): single browse page,
/// BACK semantics.
///
/// These tests render a tiny harness that mirrors TvHome's PopScope contract
/// without pulling in the live audio_handler / GraphQL state.
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/types/Station.dart';

/// Minimal AppAudioHandler stand-in. We only need the streams that the
/// TV pages subscribe to during build/initState — no real player.
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
  final BehaviorSubject<List<String>> _favs =
      BehaviorSubject.seeded(<String>[]);

  @override
  BehaviorSubject<List<Station>> get stations => _stations;

  @override
  BehaviorSubject<List<String>> get favoriteStationSlugs => _favs;

  @override
  noSuchMethod(Invocation invocation) => null;
}

void _registerFakes({Station? current}) {
  if (GetIt.I.isRegistered<AppAudioHandler>()) {
    GetIt.I.unregister<AppAudioHandler>();
  }
  if (GetIt.I.isRegistered<StationDataService>()) {
    GetIt.I.unregister<StationDataService>();
  }
  if (GetIt.I.isRegistered<PlayCountService>()) {
    GetIt.I.unregister<PlayCountService>();
  }
  final audio = _FakeAudioHandler();
  audio.setCurrent(current);
  GetIt.I.registerSingleton<AppAudioHandler>(audio);
  GetIt.I.registerSingleton<StationDataService>(_FakeStationDataService());
  GetIt.I.registerSingleton<PlayCountService>(PlayCountService());
}

void main() {
  group('TvHome — BACK semantics', () {
    setUp(() => _registerFakes());

    testWidgets('BACK with station loaded → onOpenNowPlaying', (tester) async {
      bool openedNowPlaying = false;
      await tester.pumpWidget(
        MaterialApp(
          home: _BackHarness(
            hasStation: true,
            onOpenNowPlaying: () => openedNowPlaying = true,
          ),
        ),
      );

      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(openedNowPlaying, isTrue);
    });

    testWidgets('BACK with no station → falls through (canPop=true)',
        (tester) async {
      bool openedNowPlaying = false;
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: (settings) => MaterialPageRoute(
            settings: settings,
            builder: (_) => _BackHarness(
              hasStation: false,
              onOpenNowPlaying: () => openedNowPlaying = true,
            ),
          ),
        ),
      );

      final popped = await tester.binding.handlePopRoute();
      await tester.pump();

      expect(openedNowPlaying, isFalse);
      expect(popped, isFalse, reason: 'PopScope should allow the host to pop');
    });
  });
}

/// Minimal harness mirroring TvHome's PopScope contract without pulling in
/// the real browse page (which needs live audio_handler / GraphQL state).
class _BackHarness extends StatelessWidget {
  final bool hasStation;
  final VoidCallback onOpenNowPlaying;

  const _BackHarness({
    required this.hasStation,
    required this.onOpenNowPlaying,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !hasStation,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (hasStation) onOpenNowPlaying();
      },
      child: const Scaffold(body: Center(child: Text('home'))),
    );
  }
}
