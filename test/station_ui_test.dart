import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils/station_ui.dart';

import 'helpers/station_factory.dart';

void main() {
  group('computeStationSubtitle', () {
    test('radio with a song shows the song line', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.radio,
          songLine: 'Amazing Grace • John Newton',
          isRomanian: true,
        ),
        'Amazing Grace • John Newton',
      );
    });

    test('idle radio yields null (blank line, as before)', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.radio,
          songLine: '',
          isRomanian: true,
        ),
        isNull,
      );
    });

    test('tv with a song shows the song line', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.tv,
          songLine: 'Predica de pe munte',
          isRomanian: true,
          tvLiveFallback: true,
        ),
        'Predica de pe munte',
      );
    });

    test('idle tv falls back to "Transmisiune live" when enabled', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.tv,
          songLine: '',
          isRomanian: true,
          tvLiveFallback: true,
        ),
        'Transmisiune live',
      );
      expect(
        computeStationSubtitle(
          type: StationMediaType.tv,
          songLine: '',
          isRomanian: false,
          tvLiveFallback: true,
        ),
        'Live broadcast',
      );
    });

    test('idle tv without the fallback stays null (car parity)', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.tv,
          songLine: '',
          isRomanian: true,
        ),
        isNull,
      );
    });

    test('playlist with no current item uses the localized label', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.playlist,
          songLine: '',
          isRomanian: true,
        ),
        'Listă de redare',
      );
      expect(
        computeStationSubtitle(
          type: StationMediaType.playlist,
          songLine: '',
          isRomanian: false,
        ),
        'Playlist',
      );
    });

    test('playlist label appends the item count when > 0', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.playlist,
          songLine: '',
          isRomanian: true,
          playlistItemCount: 12,
        ),
        'Listă de redare · 12 elemente',
      );
      expect(
        computeStationSubtitle(
          type: StationMediaType.playlist,
          songLine: '',
          isRomanian: true,
          playlistItemCount: 1,
        ),
        'Listă de redare · 1 element',
      );
    });

    test('playlist shows the current item title when playing', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.playlist,
          songLine: '',
          isRomanian: true,
          playlistItemTitle: 'Episodul 3',
          playlistItemCount: 12,
        ),
        'Episodul 3',
      );
    });

    test('a blank/whitespace item title falls back to the label', () {
      expect(
        computeStationSubtitle(
          type: StationMediaType.playlist,
          songLine: '',
          isRomanian: true,
          playlistItemTitle: '   ',
        ),
        'Listă de redare',
      );
    });
  });

  group('stationOpensFullPlayerOnTap', () {
    Station station(String type,
        {List<Map<String, String>> items = const []}) {
      return StationFactory.createStation(
        id: 1,
        slug: 's',
        title: 'S',
        stationType: type,
        playlistItems: items.isEmpty
            ? null
            : [
                for (var i = 0; i < items.length; i++)
                  StationFactory.createPlaylistItem(
                    id: i + 1,
                    order: i,
                    type: items[i]['type'],
                    title: items[i]['title'] ?? 'Item',
                  ),
              ],
      );
    }

    test('tv channels open the full player', () {
      expect(stationOpensFullPlayerOnTap(station('tv')), isTrue);
    });

    test('radio stations do not', () {
      expect(stationOpensFullPlayerOnTap(station('radio')), isFalse);
    });

    test('playlist whose first playable item is video opens the full player',
        () {
      expect(
        stationOpensFullPlayerOnTap(station('playlist', items: [
          {'type': 'video'},
          {'type': 'audio'},
        ])),
        isTrue,
      );
    });

    test('playlist whose first playable item is audio does not', () {
      expect(
        stationOpensFullPlayerOnTap(station('playlist', items: [
          {'type': 'audio'},
          {'type': 'video'},
        ])),
        isFalse,
      );
    });

    test('unknown items are skipped when finding the first playable', () {
      expect(
        stationOpensFullPlayerOnTap(station('playlist', items: [
          {'type': 'hologram'}, // unknown, skipped
          {'type': 'video'},
        ])),
        isTrue,
      );
    });

    test('youtube-first playlist does not auto-open', () {
      expect(
        stationOpensFullPlayerOnTap(station('playlist', items: [
          {'type': 'youtube'},
          {'type': 'video'},
        ])),
        isFalse,
      );
    });

    test('empty playlist does not auto-open', () {
      expect(stationOpensFullPlayerOnTap(station('playlist')), isFalse);
    });
  });
}
