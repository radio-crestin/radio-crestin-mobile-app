import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/car_song_history.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// The song history behind CarPlay's "Redate recent": loaded ahead per
/// station and song, and followed by the list on screen.
void main() {
  late Station? playing;
  late Map<String, Completer<List<SongHistoryItem>?>> fetches;
  late List<String> fetched;
  late List<String> picturesLoaded;
  late Set<String> onScreen;
  late List<String> shown;
  late CarSongHistory history;

  Station station(String slug, {int songId = 1}) =>
      StationFactory.createStation(
        id: slug.hashCode,
        slug: slug,
        title: slug,
        nowPlaying: StationFactory.createNowPlaying(id: songId),
      );

  List<SongHistoryItem> songsOf(String slug) => [
        SongHistoryItem(
          timestamp: '2026-10-17T15:00:00Z',
          songId: 1,
          songName: '$slug song',
        ),
      ];

  setUp(() {
    playing = null;
    fetches = {};
    fetched = [];
    picturesLoaded = [];
    onScreen = {};
    shown = [];
    history = CarSongHistory(
      playingStation: () => playing,
      fetchSongs: (s) {
        final key = CarSongHistory.keyOf(s);
        fetched.add(key);
        return (fetches[key] = Completer()).future;
      },
      loadPictures: (s, songs) async =>
          picturesLoaded.add(CarSongHistory.keyOf(s)),
      isShown: onScreen.contains,
      showSongs: (templateId, s, songs) async => shown.add(
          '$templateId: ${s.slug} ${songs.map((x) => x.songName).toList()}'),
    );
  });

  /// Answers the request for [s] with its songs, or with a failure.
  Future<void> answer(Station s, {bool fails = false}) async {
    fetches[CarSongHistory.keyOf(s)]!
        .complete(fails ? null : songsOf(s.slug as String));
    await pumpEventQueue();
  }

  group('loading', () {
    test('one request per station and song', () async {
      final rve = station('rve');
      final first = history.load(rve);
      final second = history.load(rve);
      await answer(rve);

      expect(fetched, ['rve|1']);
      expect(await first, same(await second));
    });

    test('a new song loads again', () async {
      history.load(station('rve', songId: 1));
      await answer(station('rve', songId: 1));
      history.load(station('rve', songId: 2));

      expect(fetched, ['rve|1', 'rve|2']);
    });

    test('the songs come once their pictures loaded', () async {
      final rve = station('rve');
      final songs = history.load(rve);
      await answer(rve);

      expect(await songs, isNotNull);
      expect(picturesLoaded, ['rve|1']);
    });

    test('a failed load is tried again on the next call', () async {
      final rve = station('rve');
      final failed = history.load(rve);
      await answer(rve, fails: true);
      expect(await failed, isNull);

      history.load(rve);
      expect(fetched, ['rve|1', 'rve|1']);
    });

    test('pictures load only for the latest station', () async {
      final rve = station('rve');
      final aripi = station('aripi');
      final passed = history.load(rve);
      history.load(aripi);
      await answer(rve);
      await answer(aripi);

      // The station skipped past still gives its songs to whoever waits.
      expect(await passed, isNotNull);
      expect(picturesLoaded, ['aripi|1']);
    });
  });

  group('following the playing station', () {
    test('loads ahead only while a car is connected', () async {
      history.follow(station('rve'), carConnected: false);
      history.follow(station('aripi'), carConnected: true);
      history.follow(station('aripi'), carConnected: true);

      expect(fetched, ['aripi|1']);
    });

    test('the list on screen moves to the next station', () async {
      final rve = station('rve');
      playing = rve;
      history.load(rve);
      await answer(rve);
      onScreen.add('list');
      await history.showing('list', rve);
      expect(shown, isEmpty);

      final aripi = station('aripi');
      playing = aripi;
      history.follow(aripi, carConnected: true);
      await answer(aripi);

      expect(shown, ['list: aripi [aripi song]']);
    });

    test('a new song on the same station joins the list', () async {
      final first = station('rve', songId: 1);
      playing = first;
      history.load(first);
      await answer(first);
      onScreen.add('list');
      await history.showing('list', first);

      final next = station('rve', songId: 2);
      playing = next;
      history.follow(next, carConnected: true);
      await answer(next);

      expect(shown, ['list: rve [rve song]']);
    });

    test('a station skipped past while loading is never shown', () async {
      final rve = station('rve');
      playing = rve;
      history.load(rve);
      await answer(rve);
      onScreen.add('list');
      await history.showing('list', rve);

      final aripi = station('aripi');
      final vocea = station('vocea');
      playing = aripi;
      history.follow(aripi, carConnected: true);
      playing = vocea;
      history.follow(vocea, carConnected: true);
      await answer(vocea);
      await answer(aripi);

      expect(shown, ['list: vocea [vocea song]']);
    });

    test('a failed refresh keeps the songs of the same station', () async {
      final first = station('rve', songId: 1);
      playing = first;
      history.load(first);
      await answer(first);
      onScreen.add('list');
      await history.showing('list', first);

      final next = station('rve', songId: 2);
      playing = next;
      history.follow(next, carConnected: true);
      await answer(next, fails: true);

      expect(shown, isEmpty);
    });

    test('a new station whose history fails shows an empty list', () async {
      final rve = station('rve');
      playing = rve;
      history.load(rve);
      await answer(rve);
      onScreen.add('list');
      await history.showing('list', rve);

      final aripi = station('aripi');
      playing = aripi;
      history.follow(aripi, carConnected: true);
      await answer(aripi, fails: true);

      expect(shown, ['list: aripi []']);
    });

    test('a list closed meanwhile is left alone', () async {
      final rve = station('rve');
      playing = rve;
      history.load(rve);
      await answer(rve);
      onScreen.add('list');
      await history.showing('list', rve);
      onScreen.clear();

      final aripi = station('aripi');
      playing = aripi;
      history.follow(aripi, carConnected: true);
      await answer(aripi);

      expect(shown, isEmpty);
    });

    test('a list opened as the station changed catches up at once', () async {
      final rve = station('rve');
      history.load(rve);
      await answer(rve);

      // Next was pressed while the list was being opened for rve.
      final aripi = station('aripi');
      playing = aripi;
      onScreen.add('list');
      final opened = history.showing('list', rve);
      await answer(aripi);
      await opened;

      expect(shown, ['list: aripi [aripi song]']);
    });

    test('a car going away forgets the list', () async {
      final rve = station('rve');
      playing = rve;
      history.load(rve);
      await answer(rve);
      onScreen.add('list');
      await history.showing('list', rve);
      history.reset();

      final aripi = station('aripi');
      playing = aripi;
      history.follow(aripi, carConnected: true);
      await answer(aripi);

      expect(shown, isEmpty);
    });
  });
}
