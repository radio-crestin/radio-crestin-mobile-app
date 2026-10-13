import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Only tapping a row reaches the handler, which these tests never do.
class _FakeAudioHandler extends Fake implements AppAudioHandler {}

Station _radio({
  Query$GetStations$stations$now_playing? nowPlaying,
  bool isUp = true,
}) =>
    StationFactory.createStation(
      id: 1,
      slug: 'rve-sibiu',
      title: 'RVE Sibiu',
      thumbnailUrl: '',
      totalListeners: 26,
      nowPlaying: nowPlaying,
      uptime: Query$GetStations$stations$uptime(
        is_up: isUp,
        timestamp: '2024-01-01T00:00:00Z',
      ),
    );

Future<void> _pumpList(WidgetTester tester, Station station) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(slivers: [
          StationsList(
            stations: [station],
            audioHandler: _FakeAudioHandler(),
            panelController: null,
            favoriteSlugs: const [],
          ),
        ]),
      ),
    ));

Color _textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  group('station row subtitle', () {
    testWidgets(
        'a radio station without a song shows a placeholder, dimmer than '
        'a song line', (tester) async {
      await _pumpList(
        tester,
        _radio(
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Durch die Bibel',
            artistName: 'RVE',
          ),
        ),
      );
      final songAlpha = _textColor(tester, 'Durch die Bibel - RVE').a;

      await _pumpList(tester, _radio());

      expect(find.text('Metadate indisponibile'), findsOneWidget);
      expect(
        _textColor(tester, 'Metadate indisponibile').a,
        lessThan(songAlpha),
      );
    });

    testWidgets('a radio station with a song shows "title - artist"',
        (tester) async {
      await _pumpList(
        tester,
        _radio(
          nowPlaying: StationFactory.createNowPlaying(
            songName: 'Durch die Bibel',
            artistName: 'RVE',
          ),
        ),
      );

      expect(find.text('Durch die Bibel - RVE'), findsOneWidget);
      expect(find.text('Metadate indisponibile'), findsNothing);
    });

    testWidgets('a station that is down still warns on the second line',
        (tester) async {
      await _pumpList(tester, _radio(isUp: false));

      expect(find.text('Stație posibil indisponibilă'), findsOneWidget);
      expect(find.text('Metadate indisponibile'), findsNothing);
    });
  });
}
