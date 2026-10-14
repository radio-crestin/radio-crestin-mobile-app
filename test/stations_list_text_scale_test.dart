import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Only tapping a row reaches the handler, which these tests never do.
class _FakeAudioHandler extends Fake implements AppAudioHandler {}

const _song = 'Nu exista prieten ca si Isus - Ionut Craciun';
const _listeners = '1250 ascultatori';

Station _station() => Station(
      rawStationData: StationFactory.createRawStation(
        id: 1,
        slug: 'radio-allelon',
        title: 'Radio Allelon',
        thumbnailUrl: '',
        totalListeners: 1250,
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Nu exista prieten ca si Isus',
          artistName: 'Ionut Craciun',
        ),
      ),
      averageRating: 3.7,
    );

Future<void> _pumpList(WidgetTester tester, double textScale) async {
  tester.view.physicalSize = const Size(402, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final station = _station();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: CustomScrollView(slivers: [
            StationsList(
              stations: [station],
              currentStation: station,
              audioHandler: _FakeAudioHandler(),
              panelController: null,
              favoriteSlugs: const [],
            ),
          ]),
        ),
      ),
    ),
  ));
}

Rect _row(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('station-radio-allelon')));

void main() {
  group('station row text size', () {
    testWidgets('keeps its 105 height at the default text size',
        (tester) async {
      await _pumpList(tester, 1);

      expect(_row(tester).height, 105);
    });

    // 1.35 is iOS's largest standard size; 2.0 and 3.1 are accessibility
    // sizes. An overflow would fail the test on its own.
    for (final scale in [1.35, 2.0, 3.1]) {
      testWidgets('grows to fit its lines at ${scale}x text', (tester) async {
        await _pumpList(tester, scale);

        final row = _row(tester);
        final title = tester.getRect(find.text('Radio Allelon'));
        final song = tester.getRect(find.text(_song));
        final listeners = tester.getRect(find.text(_listeners));
        expect(row.height, greaterThan(105));
        expect(title.top, greaterThanOrEqualTo(row.top));
        expect(song.top, greaterThanOrEqualTo(title.bottom));
        expect(listeners.top, greaterThanOrEqualTo(song.bottom));
        expect(listeners.bottom, lessThanOrEqualTo(row.bottom));
      });
    }
  });
}
