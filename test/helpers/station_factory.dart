import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/types/Station.dart';

/// Factory helper to create test Station instances from simple parameters.
class StationFactory {
  static Query$GetStations$stations createRawStation({
    required int id,
    required String slug,
    required String title,
    int order = 0,
    String website = 'https://example.com',
    String email = 'test@example.com',
    String? thumbnailUrl = 'https://example.com/thumb.png',
    int? totalListeners = 10,
    bool featureLatestPost = false,
    List<Query$GetStations$stations$station_streams>? stationStreams,
    Query$GetStations$stations$uptime? uptime,
    Query$GetStations$stations$now_playing? nowPlaying,
    String? stationType,
    String? hlsDvrStreamUrl,
    List<Query$GetStations$stations$playlist_items>? playlistItems,
  }) {
    return Query$GetStations$stations(
      id: id,
      slug: slug,
      title: title,
      order: order,
      website: website,
      email: email,
      thumbnail_url: thumbnailUrl,
      total_listeners: totalListeners,
      feature_latest_post: featureLatestPost,
      station_type: stationType,
      hls_dvr_stream_url: hlsDvrStreamUrl,
      playlist_items: playlistItems,
      station_streams: stationStreams ??
          [
            Query$GetStations$stations$station_streams(
              order: 0,
              type: 'mp3',
              stream_url: 'https://stream.example.com/$slug/stream.mp3',
            ),
          ],
      posts: [],
      uptime: uptime ??
          Query$GetStations$stations$uptime(
            is_up: true,
            timestamp: '2024-01-01T00:00:00Z',
          ),
      now_playing: nowPlaying,
      reviews: [],
    );
  }

  static Station createStation({
    required int id,
    required String slug,
    required String title,
    int order = 0,
    String? thumbnailUrl = 'https://example.com/thumb.png',
    int? totalListeners = 10,
    List<Query$GetStations$stations$station_streams>? stationStreams,
    Query$GetStations$stations$uptime? uptime,
    Query$GetStations$stations$now_playing? nowPlaying,
    String? stationType,
    String? hlsDvrStreamUrl,
    List<Query$GetStations$stations$playlist_items>? playlistItems,
  }) {
    return Station(
      rawStationData: createRawStation(
        id: id,
        slug: slug,
        title: title,
        order: order,
        thumbnailUrl: thumbnailUrl,
        totalListeners: totalListeners,
        stationStreams: stationStreams,
        uptime: uptime,
        nowPlaying: nowPlaying,
        stationType: stationType,
        hlsDvrStreamUrl: hlsDvrStreamUrl,
        playlistItems: playlistItems,
      ),
    );
  }

  /// Creates a raw playlist entry for playlist-station tests.
  static Query$GetStations$stations$playlist_items createPlaylistItem({
    required int id,
    int? order = 0,
    String? type = 'audio',
    String? url = 'https://example.com/track.mp3',
    String? title = 'Track',
    String? thumbnailUrl,
    int? durationSeconds,
  }) {
    return Query$GetStations$stations$playlist_items(
      id: id,
      order: order,
      type: type,
      url: url,
      title: title,
      thumbnail_url: thumbnailUrl,
      duration_seconds: durationSeconds,
    );
  }

  static Query$GetStations$stations$now_playing createNowPlaying({
    int id = 1,
    String songName = 'Test Song',
    String? songThumbnailUrl,
    String? artistName = 'Test Artist',
    String? artistThumbnailUrl,
  }) {
    return Query$GetStations$stations$now_playing(
      id: id,
      timestamp: '2024-01-01T00:00:00Z',
      song: Query$GetStations$stations$now_playing$song(
        id: id,
        name: songName,
        thumbnail_url: songThumbnailUrl,
        artist: artistName != null
            ? Query$GetStations$stations$now_playing$song$artist(
                id: 1,
                name: artistName,
                thumbnail_url: artistThumbnailUrl,
              )
            : null,
      ),
    );
  }

  static Query$GetStations$station_groups createStationGroup({
    required int id,
    required String name,
    required String slug,
    int order = 0,
    List<Query$GetStations$station_groups$station_to_station_groups>?
        stationToStationGroups,
  }) {
    return Query$GetStations$station_groups(
      id: id,
      name: name,
      slug: slug,
      order: order,
      station_to_station_groups: stationToStationGroups ?? [],
    );
  }

  static Query$GetStations$station_groups$station_to_station_groups
      createStationToStationGroup({
    required int stationId,
    int order = 0,
  }) {
    return Query$GetStations$station_groups$station_to_station_groups(
      station_id: stationId,
      order: order,
    );
  }

  /// Builds a raw station JSON map matching the REST `/stations` (and
  /// `/private-stations`) wire shape: no `__typename` keys, plus an optional
  /// `reviews_stats` block. Handy for exercising the private-stations parse
  /// pipeline (typename injection + reviews-stats sideload).
  static Map<String, dynamic> createRawStationJson({
    required int id,
    required String slug,
    required String title,
    int order = 0,
    int? totalListeners = 10,
    Query$GetStations$stations$now_playing? nowPlaying,
    Query$GetStations$stations$uptime? uptime,
    List<Query$GetStations$stations$station_streams>? stationStreams,
    String? stationType,
    double? averageRating,
    int? numberOfReviews,
  }) {
    final raw = createRawStation(
      id: id,
      slug: slug,
      title: title,
      order: order,
      totalListeners: totalListeners,
      nowPlaying: nowPlaying,
      uptime: uptime,
      stationStreams: stationStreams,
      stationType: stationType,
    );
    final map = _stripTypenames(raw.toJson()) as Map<String, dynamic>;
    if (averageRating != null || numberOfReviews != null) {
      map['reviews_stats'] = <String, dynamic>{
        'average_rating': averageRating ?? 0,
        'number_of_reviews': numberOfReviews ?? 0,
      };
    }
    return map;
  }

  /// Recursively removes `__typename` keys, mirroring a raw REST payload.
  static dynamic _stripTypenames(dynamic node) {
    if (node is Map) {
      final out = <String, dynamic>{};
      node.forEach((key, value) {
        if (key == '__typename') return;
        out[key as String] = _stripTypenames(value);
      });
      return out;
    }
    if (node is List) return node.map(_stripTypenames).toList();
    return node;
  }

  /// Creates a list of test stations for playlist/navigation testing.
  static List<Station> createPlaylist({int count = 5}) {
    return List.generate(
      count,
      (i) => createStation(
        id: i + 1,
        slug: 'station-${i + 1}',
        title: 'Station ${i + 1}',
        order: i,
      ),
    );
  }
}
