import 'package:flutter/foundation.dart';

import '../queries/getStations.graphql.dart';

/// The media kind of a single playlist entry.
///
/// Mirrors the backend `playlist_items[].type` wire value.
enum PlaylistItemType {
  audio,
  video,
  youtube;

  /// Parses a raw wire value case-insensitively, defaulting to [audio].
  ///
  /// Old or partial payloads may omit the field or send an unknown value; in
  /// both cases the item is treated as [audio].
  static PlaylistItemType parse(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'video':
        return PlaylistItemType.video;
      case 'youtube':
        return PlaylistItemType.youtube;
      case 'audio':
      default:
        return PlaylistItemType.audio;
    }
  }
}

/// Immutable view over a single backend playlist entry.
///
/// Wraps the generated GraphQL type so callers work with strongly typed,
/// null-safe fields instead of the raw nullable wire model. Order is preserved
/// exactly as returned by the API (items arrive already sorted by `order`).
@immutable
class PlaylistItem {
  const PlaylistItem({
    required this.id,
    required this.order,
    required this.type,
    required this.url,
    required this.title,
    this.thumbnailUrl,
    this.durationSeconds,
  });

  /// Builds a [PlaylistItem] from the generated GraphQL playlist entry.
  ///
  /// Nullable wire fields are coerced to safe defaults so callers never see a
  /// null `url`, `title` or `order`.
  factory PlaylistItem.fromRaw(
    Query$GetStations$stations$playlist_items raw,
  ) {
    return PlaylistItem(
      id: raw.id,
      order: raw.order ?? 0,
      type: PlaylistItemType.parse(raw.type),
      url: raw.url ?? '',
      title: raw.title ?? '',
      thumbnailUrl: raw.thumbnail_url,
      durationSeconds: raw.duration_seconds,
    );
  }

  /// Builds a [PlaylistItem] from a raw `/station-playlist` REST entry.
  ///
  /// Mirrors [PlaylistItem.fromRaw] but reads the snake_case JSON shape used
  /// by the live playlist endpoint (`thumbnail_url`, `duration_seconds`).
  /// Missing/malformed fields fall back to safe defaults so a partial payload
  /// never yields a null `url`, `title` or `id`.
  factory PlaylistItem.fromJson(Map<String, dynamic> json) {
    return PlaylistItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      order: (json['order'] as num?)?.toInt() ?? 0,
      type: PlaylistItemType.parse(json['type'] as String?),
      url: (json['url'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      thumbnailUrl: json['thumbnail_url'] as String?,
      durationSeconds: (json['duration_seconds'] as num?)?.toInt(),
    );
  }

  /// Stable backend identifier for the entry.
  final int id;

  /// Sort position within the playlist (ascending). Defaults to 0 when absent.
  final int order;

  /// Media kind of the entry (audio, video or youtube).
  final PlaylistItemType type;

  /// Playable/streamable URL for the entry.
  final String url;

  /// Human-readable title shown in the playlist UI.
  final String title;

  /// Optional artwork URL for the entry.
  final String? thumbnailUrl;

  /// Optional total length in seconds, when known.
  final int? durationSeconds;
}
