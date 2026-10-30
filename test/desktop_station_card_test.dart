import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/tv/desktop/desktop_station_card.dart';
import 'package:radio_crestin/tv/tv_theme.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

final _station = StationFactory.createStation(
  id: 1,
  slug: 'alpha',
  title: 'Radio Alpha',
  thumbnailUrl: null,
  totalListeners: 24,
  nowPlaying: StationFactory.createNowPlaying(
    id: 10,
    songName: 'Cântec',
    artistName: 'Grup',
    timestamp: DateTime.now().toUtc().toIso8601String(),
  ),
);

final _down = StationFactory.createStation(
  id: 2,
  slug: 'down',
  title: 'Radio Down',
  thumbnailUrl: null,
  uptime: Query$GetStations$stations$uptime(
    is_up: false,
    timestamp: '2024-01-01T00:00:00Z',
  ),
);

/// Records what the card asks for.
class _Calls {
  final list = <String>[];
}

Widget _card(
  Station station,
  _Calls calls, {
  bool isCurrent = false,
  bool isPlaying = false,
  bool isFavorite = false,
  bool hidden = false,
}) {
  return MaterialApp(
    theme: tvTheme,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 200 + DesktopStationCard.extraHeight(TextScaler.noScaling),
          child: DesktopStationCard(
            station: station,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            isFavorite: isFavorite,
            hidden: hidden,
            onPlay: () => calls.list.add('play'),
            onTogglePlayback: () => calls.list.add('toggle'),
            onToggleFavorite: () => calls.list.add('favorite'),
            onContextMenu: (_) => calls.list.add('menu'),
            onUnhide: hidden ? () => calls.list.add('unhide') : null,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the name, the song and the listeners', (tester) async {
    await tester.pumpWidget(_card(_station, _Calls()));

    expect(find.text('Radio Alpha'), findsOneWidget);
    expect(find.text('Cântec - Grup'), findsOneWidget);
    expect(find.text('24 de ascultători'), findsOneWidget);
    expect(find.text(DesktopStationCard.playingLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('marks the playing station in words, not color alone',
      (tester) async {
    await tester.pumpWidget(
        _card(_station, _Calls(), isCurrent: true, isPlaying: true));
    expect(find.text(DesktopStationCard.playingLabel), findsOneWidget);

    await tester.pumpWidget(
        _card(_station, _Calls(), isCurrent: true, isPlaying: false));
    expect(find.text(DesktopStationCard.pausedLabel), findsOneWidget);
  });

  testWidgets('says a station may be down', (tester) async {
    await tester.pumpWidget(_card(_down, _Calls()));

    expect(find.text(DesktopStationCard.downLabel), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
  });

  testWidgets('a click plays it, a right-click opens its menu',
      (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_card(_station, calls));

    await tester.tap(find.text('Radio Alpha'));
    await tester.tap(find.text('Radio Alpha'), buttons: kSecondaryButton);
    await tester.pump();

    expect(calls.list, ['play', 'menu']);
  });

  testWidgets('under the pointer, its play button and heart show and work',
      (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
        _card(_station, calls, isCurrent: true, isPlaying: true));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(DesktopStationCard)));
    await tester.pump(const Duration(milliseconds: 300));

    // The playing station's button pauses it.
    await tester.tap(
      find.byIcon(Icons.pause_rounded),
      kind: PointerDeviceKind.mouse,
    );
    await tester.tap(
      find.byIcon(Icons.favorite_border_rounded),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls.list, ['toggle', 'favorite']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('its play button grows a little under the pointer',
      (tester) async {
    await tester.pumpWidget(_card(_station, _Calls()));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(DesktopStationCard)));
    await tester.pump(const Duration(milliseconds: 300));
    final play = find.byIcon(Icons.play_arrow_rounded);
    double scale() => tester
        .widget<AnimatedScale>(find
            .ancestor(of: play, matching: find.byType(AnimatedScale))
            .first)
        .scale;
    expect(scale(), 1);

    await mouse.moveTo(tester.getCenter(play));
    await tester.pump(const Duration(milliseconds: 300));
    expect(scale(), greaterThan(1));

    await mouse.moveTo(tester.getCenter(find.text('Radio Alpha')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(scale(), 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a hidden station is dimmed, plays nothing, and can be added '
      'back', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_card(_station, calls, hidden: true));

    expect(find.text(DesktopStationCard.hiddenLabel), findsOneWidget);
    await tester.tap(find.text('Radio Alpha'));
    await tester.tap(find.text('Radio Alpha'), buttons: kSecondaryButton);
    await tester.tap(find.text(DesktopStationCard.unhideLabel));
    await tester.pump();

    expect(calls.list, ['unhide']);
  });
}
