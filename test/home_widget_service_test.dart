import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/home_widget_service.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// Switches stations the way the real handler does: it reports playing at
/// once (connecting), and changes the station only once the previous one
/// has stopped.
class _SwitchingAudioHandler extends Fake implements AppAudioHandler {
  _SwitchingAudioHandler(Station current)
      : currentStation = BehaviorSubject.seeded(current);

  static const stopTime = Duration(milliseconds: 500);

  @override
  final BehaviorSubject<Station?> currentStation;

  @override
  final BehaviorSubject<MediaItem?> mediaItem = BehaviorSubject.seeded(null);

  @override
  final BehaviorSubject<PlaybackState> playbackState =
      BehaviorSubject.seeded(PlaybackState());

  @override
  bool get isCarConnected => false;

  @override
  Future<void> playStation(
    Station station, {
    bool? fromFavorites,
    String? fromGroup,
  }) async {
    playbackState.add(playbackState.value.copyWith(playing: true));
    await Future<void>.delayed(stopTime);
    currentStation.add(station);
  }

  @override
  Future<void> pause() async =>
      playbackState.add(playbackState.value.copyWith(playing: false));
}

class _Stations extends Fake implements StationDataService {
  _Stations(List<Station> list) : stations = BehaviorSubject.seeded(list);

  @override
  final BehaviorSubject<List<Station>> stations;

  @override
  final BehaviorSubject<List<String>> favoriteStationSlugs =
      BehaviorSubject.seeded(const []);

  @override
  final BehaviorSubject<List<String>> hiddenStationSlugs =
      BehaviorSubject.seeded(const []);

  @override
  List<Station> get visibleStations => stations.value;

  @override
  List<Station> favoritesIn(Iterable<Station> source) =>
      source.toList(growable: false);

  @override
  List<Station> getSortedStations({bool applyGroupFilter = true}) =>
      stations.value;

  @override
  Station? getNextStation(String currentSlug, {bool wholeCatalog = false}) =>
      null;

  @override
  Station? getPreviousStation(
    String currentSlug, {
    bool wholeCatalog = false,
  }) =>
      null;
}

class _NoPlays extends Fake implements PlayCountService {
  @override
  Map<String, int> get playCounts => const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.radiocrestin.home_widgets');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final moody = StationFactory.createStation(
      id: 1, slug: 'moody', title: 'Radio Moody Chicago');
  final vesteaBuna = StationFactory.createStation(
      id: 2, slug: 'vestea-buna', title: 'Radio Vestea Buna');

  late List<Map<String, dynamic>> saves;
  late HomeWidgetService service;
  late _SwitchingAudioHandler audioHandler;

  /// What the widgets showed playing in each save: the station's slug.
  List<String?> playingIn(List<Map<String, dynamic>> saved) => [
        for (final save in saved)
          if (save['isPlaying'] == true) save['station']?['slug'] as String?,
      ];

  /// Presses a widget button, as `HomeWidgetBridge.swift` sends it, and
  /// returns once the app answers (when iOS redraws the widget).
  Future<void> press(Map<String, Object?> args) async {
    final answered = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('command', args)),
      (_) => answered.complete(),
    );
    await answered.future;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NetworkService();
    saves = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'save') {
        saves.add(jsonDecode(call.arguments as String) as Map<String, dynamic>);
      }
      return null;
    });
    // Paused on Moody, as after its tile was tapped.
    audioHandler = _SwitchingAudioHandler(moody);
    service = HomeWidgetService(
      audioHandler: audioHandler,
      stationDataService: _Stations([moody, vesteaBuna]),
      playCountService: _NoPlays(),
      prefs: await SharedPreferences.getInstance(),
    )..start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
  });

  tearDown(() {
    service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a tile played from pause never shows the paused station playing',
      () async {
    expect(saves.last['isPlaying'], isFalse);
    saves.clear();

    await press({'action': 'play', 'slug': 'vestea-buna', 'fromFavorites': true});

    expect(saves.last['isPlaying'], isTrue);
    expect(saves.last['station']['slug'], 'vestea-buna');
    // The saves the switch's own changes schedule, after the answer.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(playingIn(saves), everyElement('vestea-buna'));
  });

  test('the answer waits for the station tapped to play', () async {
    final pressed = DateTime.now();
    await press({'action': 'play', 'slug': 'vestea-buna', 'fromFavorites': true});

    expect(
      DateTime.now().difference(pressed),
      greaterThanOrEqualTo(_SwitchingAudioHandler.stopTime),
    );
    expect(audioHandler.currentStation.value?.slug, 'vestea-buna');
  });
}
