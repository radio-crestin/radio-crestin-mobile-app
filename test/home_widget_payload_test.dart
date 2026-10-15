import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/home_widget_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// What the iOS Home Screen widgets are sent: the favorites they show and
/// the song heard.
void main() {
  Station station(int id, String slug) =>
      StationFactory.createStation(id: id, slug: slug, title: slug);

  final alpha = station(1, 'alpha');
  final beta = station(2, 'beta');
  final gamma = station(3, 'gamma');
  final delta = station(4, 'delta');
  final epsilon = station(5, 'epsilon');

  List<String> slugsOf(List<Station> stations) =>
      [for (final s in stations) s.slug];

  group('stationsShown', () {
    test('shows the first favorites, in the listener\'s order', () {
      final shown = HomeWidgetPayload.stationsShown(
        favorites: [epsilon, gamma, alpha, beta, delta],
        others: const [],
        playCounts: const {},
        slots: 4,
      );

      expect(slugsOf(shown), ['epsilon', 'gamma', 'alpha', 'beta']);
    });

    test('tops the favorites up with the stations played most', () {
      final shown = HomeWidgetPayload.stationsShown(
        favorites: [gamma],
        others: [alpha, beta, gamma, delta, epsilon],
        playCounts: const {'delta': 3, 'beta': 9, 'gamma': 20},
        slots: 4,
      );

      expect(slugsOf(shown), ['gamma', 'beta', 'delta', 'alpha']);
    });

    test('keeps the list\'s order between stations played as often', () {
      final shown = HomeWidgetPayload.stationsShown(
        favorites: const [],
        others: [alpha, beta, gamma, delta, epsilon],
        playCounts: const {'delta': 2, 'beta': 2, 'epsilon': 2},
        slots: 4,
      );

      expect(slugsOf(shown), ['beta', 'delta', 'epsilon', 'alpha']);
    });

    test('shows fewer when the catalog is smaller', () {
      final shown = HomeWidgetPayload.stationsShown(
        favorites: [beta],
        others: [alpha, beta],
        playCounts: const {},
        slots: 4,
      );

      expect(slugsOf(shown), ['beta', 'alpha']);
    });
  });

  group('songOf', () {
    test('names the song and its artist', () {
      final playing = StationFactory.createStation(
        id: 6,
        slug: 'zeta',
        title: 'Zeta',
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Numai la Tine',
          artistName: 'Diana Scridon',
        ),
      );

      final song = HomeWidgetPayload.songOf(playing);

      expect(song?.title, 'Numai la Tine');
      expect(song?.artist, 'Diana Scridon');
    });

    test('has no artist when the song names none', () {
      final playing = StationFactory.createStation(
        id: 6,
        slug: 'zeta',
        title: 'Zeta',
        nowPlaying: StationFactory.createNowPlaying(
          songName: 'Predică',
          artistName: null,
        ),
      );

      final song = HomeWidgetPayload.songOf(playing);

      expect(song?.title, 'Predică');
      expect(song?.artist, isNull);
    });

    test('is null when the station names no song', () {
      expect(HomeWidgetPayload.songOf(alpha), isNull);
    });
  });

  test('sends what HomeWidgetBridge.swift reads', () {
    const logo = HomeWidgetImage(url: 'https://example.com/a.png');
    const payload = HomeWidgetPayload(
      isPlaying: true,
      station: HomeWidgetStation(slug: 'alpha', title: 'Alpha', logo: logo),
      song: (title: 'El Shaddai', artist: 'Michael Card'),
      cover: HomeWidgetImage(
        url: 'https://example.com/c.webp',
        path: '/tmp/c.webp',
      ),
      listeners: null,
      previousSlug: 'delta',
      nextSlug: 'beta',
      favorites: [
        HomeWidgetStation(slug: 'alpha', title: 'Alpha', logo: logo),
      ],
      favoriteCount: 1,
    );

    expect(payload.toJson(), {
      'isPlaying': true,
      'station': {
        'slug': 'alpha',
        'title': 'Alpha',
        'logo': {'url': 'https://example.com/a.png', 'path': null},
      },
      'song': {'title': 'El Shaddai', 'artist': 'Michael Card'},
      'cover': {'url': 'https://example.com/c.webp', 'path': '/tmp/c.webp'},
      'listeners': null,
      'previousSlug': 'delta',
      'nextSlug': 'beta',
      'favorites': [
        {
          'slug': 'alpha',
          'title': 'Alpha',
          'logo': {'url': 'https://example.com/a.png', 'path': null},
        },
      ],
      'favoriteCount': 1,
    });
  });
}
