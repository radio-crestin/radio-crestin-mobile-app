/// A station the fake radio server publishes, and the streams it has.
class FakeStation {
  const FakeStation({
    required this.id,
    required this.slug,
    required this.title,
    this.hasHls = true,
    this.hasMp3 = true,
  });

  final int id;
  final String slug;
  final String title;

  /// Whether it streams HLS from the origin, tried first.
  final bool hasHls;

  /// Whether it streams MP3 from its own server, the fallback.
  final bool hasMp3;

  String get songTitle => 'Song of $title';
  String get songArtist => 'Artist of $title';
}

/// The stations of every e2e run, in list order. Most real stations have
/// HLS with an MP3 fallback; a few have only MP3.
///
/// The tests play the first four. The rest fill the list to the size the
/// app trusts: it rejects a catalog of fewer than 10 stations as broken.
abstract final class Stations {
  static const alpha = FakeStation(id: 9001, slug: 'e2e-alpha', title: 'E2E Alpha');
  static const beta = FakeStation(id: 9002, slug: 'e2e-beta', title: 'E2E Beta');
  static const gamma = FakeStation(
      id: 9003, slug: 'e2e-gamma', title: 'E2E Gamma', hasHls: false);
  static const delta = FakeStation(id: 9004, slug: 'e2e-delta', title: 'E2E Delta');

  static final all = [
    alpha,
    beta,
    gamma,
    delta,
    for (var n = 5; n <= 12; n++)
      FakeStation(id: 9000 + n, slug: 'e2e-filler-$n', title: 'E2E Filler $n'),
  ];

  static FakeStation bySlug(String slug) =>
      all.firstWhere((station) => station.slug == slug);
}

/// The REST API's JSON for [stations], with stream and image URLs on
/// [baseUrl] (the fake server), shaped as `api.radiocrestin.ro` answers.
class StationCatalog {
  StationCatalog(this.baseUrl, [List<FakeStation>? stations])
      : stations = stations ?? Stations.all;

  final String baseUrl;
  final List<FakeStation> stations;

  String hlsUrl(FakeStation station) =>
      '$baseUrl/hls/${station.slug}/index.m3u8';
  String mp3Url(FakeStation station) => '$baseUrl/mp3/${station.slug}.mp3';
  String imageUrl(String name) => '$baseUrl/images/$name.png';

  /// `GET /api/v1/stations`.
  Map<String, Object?> stationsResponse() => {
        'data': {
          '__typename': 'queryRoot',
          'stations': [
            for (final (index, station) in stations.indexed)
              _station(station, index),
          ],
          'station_groups': [
            {
              '__typename': 'StationGroupType',
              'id': 1,
              'name': 'Toate',
              'order': -1,
              'slug': 'radio',
              'station_to_station_groups': [
                for (final station in stations)
                  {
                    '__typename': 'StationToStationGroupType',
                    'station_id': station.id,
                    'order': 0,
                  },
              ],
            },
          ],
        },
      };

  /// `GET /api/v1/stations-metadata`.
  Map<String, Object?> metadataResponse() => {
        'data': {
          'stations_metadata': [
            for (final station in stations)
              {
                'id': station.id,
                'slug': station.slug,
                'title': station.title,
                'uptime': _uptime(),
                'now_playing': {
                  ..._nowPlaying(station, typed: false),
                  'listeners': 12,
                },
              },
          ],
        },
      };

  /// `GET /api/v1/share-links/<device id>/`.
  Map<String, Object?> shareLinkResponse(String deviceId) => {
        'data': {
          'get_share_link': {
            '__typename': 'GetShareLinkResponse',
            'anonymous_id': deviceId,
            'message': 'Share link retrieved successfully',
            'success': true,
            'share_link': {
              '__typename': 'ShareLinkType',
              'visit_count': 0,
              'url': 'https://example.com/share/e2e',
              'share_id': 'e2e',
              'is_active': true,
              'created_at': DateTime.now().toUtc().toIso8601String(),
              'share_message': 'Listen with me: {url}',
              'share_section_message': 'Share the app with your friends.',
              'share_section_title': 'Share',
            },
          },
        },
      };

  Map<String, Object?> _station(FakeStation station, int order) => {
        '__typename': 'StationType',
        'id': station.id,
        'slug': station.slug,
        'order': order,
        'title': station.title,
        'website': 'https://example.com/${station.slug}',
        'email': '${station.slug}@example.com',
        'stream_url': station.hasMp3 ? mp3Url(station) : hlsUrl(station),
        'proxy_stream_url': null,
        'hls_stream_url': station.hasHls ? hlsUrl(station) : null,
        'hls_dvr_stream_url': null,
        'thumbnail_url': imageUrl(station.slug),
        'total_listeners': 12,
        'radio_crestin_listeners': 0,
        'description': 'The ${station.title} e2e test station.',
        'description_action_title': null,
        'description_link': null,
        'feature_latest_post': false,
        'facebook_page_id': null,
        'station_type': 'radio',
        'station_streams': [
          if (station.hasHls) _stream(0, 'HLS', hlsUrl(station)),
          if (station.hasMp3) _stream(1, 'direct_stream', mp3Url(station)),
        ],
        'playlist_items': <Object>[],
        'posts': <Object>[],
        'uptime': {'__typename': 'StationUptimeType', ..._uptime()},
        'now_playing': _nowPlaying(station),
        'reviews': <Object>[],
        'reviews_stats': {
          '__typename': 'ReviewsStatsType',
          'number_of_reviews': 0,
          'average_rating': 0,
        },
      };

  Map<String, Object?> _stream(int order, String type, String url) => {
        '__typename': 'StationStreamType',
        'order': order,
        'type': type,
        'stream_url': url,
      };

  Map<String, Object?> _uptime() => {
        'is_up': true,
        'latency_ms': 120,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };

  /// The song on air; [typed] as the stations list, which the app parses
  /// as GraphQL, carries it.
  Map<String, Object?> _nowPlaying(FakeStation station, {bool typed = true}) {
    Map<String, Object?> type(String name) =>
        typed ? {'__typename': name} : const {};
    return {
      ...type('StationNowPlayingType'),
      'id': station.id * 10,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'song': {
        ...type('SongType'),
        'id': station.id * 100,
        'name': station.songTitle,
        'thumbnail_url': imageUrl('cover-${station.slug}'),
        'artist': {
          ...type('ArtistType'),
          'id': station.id * 1000,
          'name': station.songArtist,
          'thumbnail_url': null,
        },
      },
    };
  }
}
