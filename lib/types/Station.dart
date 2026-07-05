
import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:get_it/get_it.dart';

import '../queries/getStations.graphql.dart';
import '../services/image_cache_service.dart';
import '../utils.dart';
import 'playlist_item.dart';

/// The playback kind of a station.
///
/// Mirrors the backend `station_type` wire value. Old cached payloads may omit
/// it entirely, in which case the station is treated as a [radio] stream.
enum StationMediaType {
  radio,
  tv,
  playlist;

  /// Parses a raw wire value case-insensitively, defaulting to [radio].
  ///
  /// Missing, null or unknown values fall back to [radio] so legacy caches and
  /// the bundled fallback asset keep working.
  static StationMediaType parse(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'tv':
        return StationMediaType.tv;
      case 'playlist':
        return StationMediaType.playlist;
      case 'radio':
      default:
        return StationMediaType.radio;
    }
  }
}

class Station {
  Query$GetStations$stations rawStationData;

  /// Aggregated review stats from REST API (reviews_stats field).
  /// These are separate from rawStationData.reviews because the REST endpoint
  /// returns pre-computed stats while the GraphQL reviews array may be empty.
  double _averageRating;
  int _numberOfReviews;

  Station({
    required this.rawStationData,
    double averageRating = 0,
    int numberOfReviews = 0,
  })  : _averageRating = averageRating,
        _numberOfReviews = numberOfReviews;

  get id => rawStationData.id;
  get slug => rawStationData.slug;
  get title => rawStationData.title;
  get order => rawStationData.order;
  get stationStreams => rawStationData.station_streams;
  get totalListeners => rawStationData.total_listeners;
  String? get thumbnailUrl => rawStationData.thumbnail_url;
  String get displayTitle => rawStationData.title;
  String get displaySubtitle => Utils.getCurrentPlayedSongTitle(rawStationData);
  String get artist => Utils.getCurrentPlayedSongTitle(rawStationData);
  bool get isUp => rawStationData.uptime?.is_up ?? false;
  int get songId => rawStationData.now_playing?.song?.id ?? -1;
  String get songTitle => rawStationData.now_playing?.song?.name ?? "";
  String get songArtist => rawStationData.now_playing?.song?.artist?.name ?? "";

  /// Playback kind of the station, defaulting to [StationMediaType.radio] when
  /// the backend omits `station_type` (old caches / fallback asset).
  StationMediaType get stationType =>
      StationMediaType.parse(rawStationData.station_type);

  /// Whether this station is a live TV channel.
  bool get isTv => stationType == StationMediaType.tv;

  /// Whether this station is an on-demand playlist.
  bool get isPlaylist => stationType == StationMediaType.playlist;

  /// Ordered playlist entries for this station.
  ///
  /// Returns an empty list when the station has no playlist (or the field is
  /// absent). Order is preserved exactly as returned by the API.
  List<PlaylistItem> get playlistItems {
    final items = rawStationData.playlist_items;
    if (items == null || items.isEmpty) return const [];
    return items.map(PlaylistItem.fromRaw).toList(growable: false);
  }

  ImageCacheService? get _imageCacheService {
    try {
      return GetIt.instance<ImageCacheService>();
    } catch (_) {
      return null;
    }
  }

  /// Cached path for the station's base thumbnail (stable URL).
  String? get cachedThumbnailPath {
    final url = rawStationData.thumbnail_url;
    if (url == null || url.isEmpty) return null;
    return _imageCacheService?.getCachedPath(url);
  }

  /// Cached path for the display thumbnail (song thumbnail if playing, else station thumbnail).
  String? get cachedArtPath {
    final displayUrl = Utils.getStationThumbnailUrl(rawStationData);
    if (displayUrl.isEmpty) return null;
    return _imageCacheService?.getCachedPath(displayUrl);
  }

  Uri get artUri {
    final cachedPath = cachedArtPath;
    if (cachedPath != null) {
      return Uri.file(cachedPath);
    }
    return Uri.parse(Utils.getStationThumbnailUrl(rawStationData));
  }

  Widget get thumbnail => displayThumbnail();

  Widget displayThumbnail({int? cacheWidth}) {
    final hasSongThumbnail = rawStationData.now_playing?.song?.thumbnail_url != null;
    return Utils.displayImage(
      Utils.getStationThumbnailUrl(rawStationData),
      fallbackImageUrl: rawStationData.thumbnail_url,
      cache: true,
      cachedFilePath: cachedArtPath,
      cacheWidth: cacheWidth,
      // Song thumbnails expire after 10 minutes; station logos cached permanently
      cacheMaxAge: hasSongThumbnail ? const Duration(minutes: 10) : null,
    );
  }

  /// Average star rating from reviews_stats (REST API pre-computed).
  /// Falls back to computing from individual reviews if stats aren't available.
  double get averageRating {
    if (_averageRating > 0) return _averageRating;
    final reviews = rawStationData.reviews;
    if (reviews.isEmpty) return 0;
    final sum = reviews.fold<int>(0, (s, r) => s + r.stars);
    return sum / reviews.length;
  }

  /// Number of reviews from reviews_stats (REST API pre-computed).
  int get reviewCount {
    if (_numberOfReviews > 0) return _numberOfReviews;
    return rawStationData.reviews.length;
  }

  MediaItem get mediaItem {
    return MediaItem(
      id: Utils.getStationStreamUrls(rawStationData).firstOrNull ?? "",
      title: rawStationData.title,
      displayTitle: displayTitle,
      displaySubtitle: displaySubtitle,
      artist: artist,
      duration: null,
      artUri: artUri,
      isLive: true,
      extras: {
        "station_id": rawStationData.id,
        "station_slug": rawStationData.slug,
        "station_title": rawStationData.title,
        "station_type": stationType.name,
        "song_id": songId,
        "song_title": songTitle,
        "song_artist": songArtist,
        "total_listeners": rawStationData.total_listeners,
        "station_is_up": isUp,
        "station_thumbnail_url": rawStationData.thumbnail_url,
        "station_streams": Utils.getStationStreamObjects(rawStationData),
      },
    );
  }

}
