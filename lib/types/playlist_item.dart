import 'package:flutter/foundation.dart';

import '../queries/getStations.graphql.dart';

/// The media kind of a single playlist entry.
///
/// Mirrors the backend `playlist_items[].type` wire value.
enum PlaylistItemType {
  audio,
  video,
  youtube,

  /// A whole YouTube playlist rendered as a single entry — `url` is a
  /// `.../playlist?list=<ID>` link. Orchestrated exactly like [youtube]
  /// (UI-owned iframe, skipped in car/cast, never video mode).
  youtubePlaylist,

  /// An unrecognized (e.g. future) backend kind. Treated as unplayable so it
  /// is never fed to just_audio — the engine and UI auto-advance past it.
  unknown;

  /// Parses a raw wire value case-insensitively.
  ///
  /// A missing/empty type is treated as [audio] (legacy items predate the
  /// field). A non-empty *unrecognized* value maps to [unknown] rather than
  /// [audio], so a future backend kind is never handed to just_audio (which
  /// would fail) — it is skipped instead.
  static PlaylistItemType parse(String? value) {
    final v = value?.trim().toLowerCase();
    if (v == null || v.isEmpty) return PlaylistItemType.audio;
    switch (v) {
      case 'audio':
        return PlaylistItemType.audio;
      case 'video':
        return PlaylistItemType.video;
      case 'youtube':
        return PlaylistItemType.youtube;
      case 'youtube_playlist':
        return PlaylistItemType.youtubePlaylist;
      default:
        return PlaylistItemType.unknown;
    }
  }

  /// True for any YouTube-backed entry (single video or whole playlist).
  ///
  /// These are rendered by the UI's inline iframe (never an engine-owned
  /// player), skipped when a car/cast route is connected, and paused while the
  /// app is backgrounded.
  bool get isYoutube =>
      this == PlaylistItemType.youtube ||
      this == PlaylistItemType.youtubePlaylist;
}

/// Extracts the playlist id (`list=` query param) from a YouTube playlist URL.
///
/// Handles `youtube.com/playlist?list=<ID>`, a `watch?v=..&list=<ID>` URL, and
/// a bare id. Returns null when no playlist id can be found.
String? youtubePlaylistIdFromUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  final list = uri?.queryParameters['list'];
  if (list != null && list.isNotEmpty) return list;
  // Bare id fallback (no scheme / path / query) — assume it is the list id.
  if (!trimmed.contains('/') && !trimmed.contains('?') &&
      !trimmed.contains('&')) {
    return trimmed;
  }
  return null;
}

/// Romanian month names (1-indexed), for [formatPlaylistDate]. `intl` is not a
/// dependency, so the ro locale is spelled out here.
const List<String> _roMonths = [
  '', // 1-indexed padding
  'ianuarie', 'februarie', 'martie', 'aprilie', 'mai', 'iunie',
  'iulie', 'august', 'septembrie', 'octombrie', 'noiembrie', 'decembrie',
];

/// Formats [date] as a Romanian long date, e.g. `3 august 2024`. Pure so it is
/// trivially unit-testable; used to render a playlist item's publish date.
String formatPlaylistDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day} ${_roMonths[local.month]} ${local.year}';
}

/// User-facing display name for a playlist entry: its title, or the URL's
/// host when the title is empty (never an empty string). Used by failure
/// notifications so the user can tell WHICH element was unavailable.
String playlistItemDisplayName(PlaylistItem item) {
  final title = item.title.trim();
  if (title.isNotEmpty) return title;
  final host = Uri.tryParse(item.url.trim())?.host;
  if (host != null && host.isNotEmpty) return host;
  return 'Element necunoscut';
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
    this.publishedAt,
  });

  /// Parses an optional publish date from a wire value.
  ///
  /// Accepts an ISO-8601 string (`published_at` / `published`) or a unix epoch
  /// (seconds or milliseconds). Returns null for a missing/blank/unparseable
  /// value so a partial payload never throws.
  static DateTime? _parsePublishedAt(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final n = value.toInt();
      // Heuristic: >~ year 2001 in seconds is ~1e9; treat large values as ms.
      final isMillis = n > 100000000000;
      return DateTime.fromMillisecondsSinceEpoch(
          isMillis ? n : n * 1000,
          isUtc: true);
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return DateTime.tryParse(trimmed);
    }
    return null;
  }

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
      // The GraphQL query does not (yet) select a publish date for playlist
      // items, so this is always null on the GraphQL path. The REST live-sync
      // path ([fromJson]) parses one when the backend sends it.
      publishedAt: null,
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
      // Accept either key the backend might adopt; null when absent.
      publishedAt: _parsePublishedAt(
          json['published_at'] ?? json['published']),
    );
  }

  /// Stable backend identifier for the entry.
  final int id;

  /// Sort position within the playlist (ascending). Defaults to 0 when absent.
  final int order;

  /// Media kind of the entry (audio, video, youtube, youtube_playlist or an
  /// [PlaylistItemType.unknown] future kind).
  final PlaylistItemType type;

  /// Playable/streamable URL for the entry.
  final String url;

  /// Human-readable title shown in the playlist UI.
  final String title;

  /// Optional artwork URL for the entry.
  final String? thumbnailUrl;

  /// Optional total length in seconds, when known.
  final int? durationSeconds;

  /// Optional publish date of the entry (e.g. when a live-stream recording was
  /// aired). Populated only from the REST live-sync payload when the backend
  /// sends `published_at`/`published`; null otherwise (including the GraphQL
  /// path, whose query does not select it yet). Rendered when non-null.
  final DateTime? publishedAt;
}
