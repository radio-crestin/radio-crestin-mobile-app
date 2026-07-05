/// Widget tests for the station-type badges rendered on cards, the mini
/// player and the full player, plus the TV-card variant.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/tv/widgets/tv_station_card.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/widgets/station_type_badge.dart';

import 'helpers/station_factory.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('StationTypeBadge', () {
    testWidgets('TV station renders a "TV" pill', (tester) async {
      await tester.pumpWidget(_wrap(
        const StationTypeBadge(type: StationMediaType.tv),
      ));
      expect(find.text('TV'), findsOneWidget);
      expect(find.byIcon(Icons.live_tv_rounded), findsOneWidget);
    });

    testWidgets('playlist station renders a playlist glyph, no "TV" text',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const StationTypeBadge(type: StationMediaType.playlist),
      ));
      expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
      expect(find.text('TV'), findsNothing);
    });

    testWidgets('radio station renders nothing visible', (tester) async {
      await tester.pumpWidget(_wrap(
        const StationTypeBadge(type: StationMediaType.radio),
      ));
      expect(find.text('TV'), findsNothing);
      expect(find.byIcon(Icons.queue_music_rounded), findsNothing);
      expect(find.byIcon(Icons.live_tv_rounded), findsNothing);
    });
  });

  group('TvStationCard badges', () {
    Widget wrapCard(Station station) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: TvStationCard(
                station: station,
                isPlaying: false,
                isFavorite: false,
                onSelect: () {},
                onFavoriteToggle: () {},
              ),
            ),
          ),
        );

    testWidgets('TV station card shows the TV badge', (tester) async {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'tv-1',
        title: 'Live TV',
        stationType: 'tv',
      );
      await tester.pumpWidget(wrapCard(station));
      expect(find.text('TV'), findsOneWidget);
    });

    testWidgets('playlist station card shows the playlist glyph',
        (tester) async {
      final station = StationFactory.createStation(
        id: 2,
        slug: 'pl-1',
        title: 'Predici',
        stationType: 'playlist',
      );
      await tester.pumpWidget(wrapCard(station));
      expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
    });

    testWidgets('radio station card shows no type badge', (tester) async {
      final station = StationFactory.createStation(
        id: 3,
        slug: 'radio-1',
        title: 'Radio',
      );
      await tester.pumpWidget(wrapCard(station));
      expect(find.text('TV'), findsNothing);
      expect(find.byIcon(Icons.queue_music_rounded), findsNothing);
    });
  });
}
