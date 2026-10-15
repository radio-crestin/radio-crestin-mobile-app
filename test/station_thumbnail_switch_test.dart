import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/fake_image_http.dart';
import 'helpers/station_factory.dart';

const _logoA = 'https://cdn.example.com/a.png';
const _logoB = 'https://cdn.example.com/b.png';
const _songA1 = 'https://cdn.example.com/a-song-1.png';
const _songA2 = 'https://cdn.example.com/a-song-2.png';
const _songB = 'https://cdn.example.com/b-song.png';

Station _station(int id, String logo, {String? songArt}) =>
    StationFactory.createStation(
      id: id,
      slug: 'station-$id',
      title: 'Station $id',
      thumbnailUrl: logo,
      nowPlaying: songArt == null
          ? null
          : StationFactory.createNowPlaying(id: id, songThumbnailUrl: songArt),
    );

/// The station's artwork where the mini player shows it: the same slot
/// whatever the station, as when skipping with next.
Widget _miniPlayerArt(Station station) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(width: 60, height: 60, child: station.thumbnail),
      ),
    );

/// Images by width, to tell which one is on screen.
const _widths = {_logoA: 1, _logoB: 2, _songA1: 3, _songA2: 4, _songB: 5};

/// The URL of the picture on screen, or null when none has its picture.
String? _shownUrl(WidgetTester tester) {
  final width = shownImageWidth(tester);
  if (width == null) return null;
  return _widths.entries.firstWhere((entry) => entry.value == width).key;
}

final _logoPlaceholder = find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is AssetImage &&
      (widget.image as AssetImage).assetName ==
          'assets/icons/ic_logo_filled.png',
);

void main() {
  late FakeImageHttpClient http;
  late NetworkService network;

  setUp(() {
    http = FakeImageHttpClient()
      ..widths.addAll(_widths)
      ..answers[_logoA] = FakeImageAnswer.image
      ..answers[_songA1] = FakeImageAnswer.image;
    network = NetworkService();
  });

  tearDown(() => network.dispose());

  testImageWidgets(
      'next to a station whose logo still loads never shows the previous '
      "station's logo", () => http, (tester) async {
    http.answers[_logoB] = FakeImageAnswer.hang;
    await tester.pumpWidget(_miniPlayerArt(_station(1, _logoA)));
    await waitFor(tester, loadedImage);
    expect(_shownUrl(tester), _logoA);

    await tester.pumpWidget(_miniPlayerArt(_station(2, _logoB)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(_shownUrl(tester), isNull);
  });

  testImageWidgets(
      'next to a station whose logo fails shows the app logo, not the '
      "previous station's", () => http, (tester) async {
    await tester.pumpWidget(_miniPlayerArt(_station(1, _logoA)));
    await waitFor(tester, loadedImage);

    await tester.pumpWidget(_miniPlayerArt(_station(2, _logoB)));
    await waitFor(tester, _logoPlaceholder);

    expect(_shownUrl(tester), isNull);
  });

  testImageWidgets(
      'next to a station whose song artwork still loads shows its logo',
      () => http, (tester) async {
    http
      ..answers[_logoB] = FakeImageAnswer.image
      ..answers[_songB] = FakeImageAnswer.hang;
    await tester.pumpWidget(_miniPlayerArt(_station(1, _logoA)));
    await waitFor(tester, loadedImage);

    await tester
        .pumpWidget(_miniPlayerArt(_station(2, _logoB, songArt: _songB)));
    await waitFor(tester, find.byWidgetPredicate((_) => _shownUrl(tester) == _logoB));
  });

  testImageWidgets(
      'a new song on the same station keeps the artwork until the next one '
      'arrives', () => http, (tester) async {
    http.answers[_songA2] = FakeImageAnswer.hang;
    await tester
        .pumpWidget(_miniPlayerArt(_station(1, _logoA, songArt: _songA1)));
    await waitFor(tester, loadedImage);
    expect(_shownUrl(tester), _songA1);

    await tester
        .pumpWidget(_miniPlayerArt(_station(1, _logoA, songArt: _songA2)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(_shownUrl(tester), _songA1);
  });

  testImageWidgets(
      "the logo shows the station's own logo, not its song's artwork",
      () => http, (tester) async {
    final station = _station(1, _logoA, songArt: _songA1);
    await tester.pumpWidget(_miniPlayerArt(station));
    await waitFor(tester, loadedImage);
    expect(_shownUrl(tester), _songA1, reason: 'the artwork is the song');

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: SizedBox.square(dimension: 44, child: station.logo)),
    ));
    await waitFor(
      tester,
      find.byWidgetPredicate((_) => _shownUrl(tester) == _logoA),
    );
  });
}
