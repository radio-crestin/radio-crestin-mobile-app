import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

class _FakeAudioHandler extends Fake implements AppAudioHandler {
  final played = <String>[];

  @override
  Future<void> playStation(
    Station station, {
    bool? fromFavorites,
    String? fromGroup,
  }) async =>
      played.add(station.slug);
}

final _station = StationFactory.createStation(
  id: 1,
  slug: 'rve-cluj',
  title: 'RVE Cluj',
  thumbnailUrl: '',
  nowPlaying: StationFactory.createNowPlaying(
    songName: 'Nu Te Teme',
    artistName: 'Gabriel Gorcea',
  ),
);

Future<void> _pumpList(
  WidgetTester tester, {
  AppAudioHandler? audioHandler,
  String? highlight,
  ValueChanged<Station>? onStationTap,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomScrollView(slivers: [
          StationsList(
            stations: [_station],
            audioHandler: audioHandler ?? _FakeAudioHandler(),
            panelController: null,
            favoriteSlugs: const [],
            highlight: highlight,
            onStationTap: onStationTap,
          ),
        ]),
      ),
    ));

/// The parts of the station's name on its row, and whether each is bold.
List<(String, bool)> _titleParts(WidgetTester tester) =>
    _parts(tester, 'RVE Cluj');

/// The parts of the song on the station's row, and whether each is bold.
List<(String, bool)> _songParts(WidgetTester tester) =>
    _parts(tester, 'Nu Te Teme - Gabriel Gorcea');

/// The parts of the line of the row that reads [text], and whether each is
/// bold.
List<(String, bool)> _parts(WidgetTester tester, String text) {
  final line = tester.widget<Text>(find.text(text));
  final span = line.textSpan;
  if (span == null) return [(line.data!, false)];
  final parts = <(String, bool)>[];
  span.visitChildren((span) {
    final text = (span as TextSpan).text;
    if (text != null && text.isNotEmpty) {
      parts.add((text, span.style?.fontWeight == FontWeight.w700));
    }
    return true;
  });
  return parts;
}

void main() {
  group('station rows while searching', () {
    testWidgets('show the part of the name searched for in bold',
        (tester) async {
      await _pumpList(tester, highlight: 'clu');

      expect(_titleParts(tester), [('RVE ', false), ('Clu', true), ('j', false)]);
    });

    testWidgets('show the name as it is without a search', (tester) async {
      await _pumpList(tester);

      expect(_titleParts(tester), [('RVE Cluj', false)]);
      expect(_songParts(tester), [('Nu Te Teme - Gabriel Gorcea', false)]);
    });

    testWidgets('show the part of the song searched for in bold',
        (tester) async {
      await _pumpList(tester, highlight: 'gabriel teme');

      expect(_songParts(tester), [
        ('Nu Te ', false),
        ('Teme', true),
        (' - ', false),
        ('Gabriel', true),
        (' Gorcea', false),
      ]);
      expect(_titleParts(tester), [('RVE Cluj', false)]);
    });

    testWidgets('tell the page of a tap before the station starts',
        (tester) async {
      final handler = _FakeAudioHandler();
      final events = <String>[];
      await _pumpList(
        tester,
        audioHandler: handler,
        onStationTap: (station) =>
            events.add('tap ${station.slug}, played ${handler.played}'),
      );

      await tester.tap(find.text('RVE Cluj'));
      await tester.pumpAndSettle();

      expect(events, ['tap rve-cluj, played []']);
      expect(handler.played, ['rve-cluj']);
    });
  });
}
