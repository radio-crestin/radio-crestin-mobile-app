import 'package:flutter/foundation.dart';

/// A selectable video quality for the app's video player.
///
/// This is an app-owned model — it carries no dependency on any playback
/// engine. `Auto` (the [auto] sentinel) opens the HLS MASTER playlist and lets
/// the native player pick renditions adaptively (ABR). A concrete quality
/// carries the VARIANT playlist [url] to pin, plus its advertised [width] /
/// [height] / [bandwidth] parsed from the master.
@immutable
class VideoQuality {
  const VideoQuality({
    required this.id,
    required this.label,
    this.width,
    this.height,
    this.bandwidth,
    this.url,
  });

  /// Stable identity: `'auto'` for the sentinel, otherwise the variant URL.
  /// Drives the picker's checkmark (compared against the selected quality).
  final String id;

  /// Human label, e.g. `Auto` or `1080p`.
  final String label;

  /// Advertised pixel width of the variant (from the master's `RESOLUTION`).
  final int? width;

  /// Advertised pixel height of the variant (from the master's `RESOLUTION`).
  final int? height;

  /// Advertised peak bitrate in bits/second (from the master's `BANDWIDTH`).
  final int? bandwidth;

  /// The variant playlist URL to pin for this quality. Null for [auto], which
  /// keeps the master URL so the native player adapts across renditions.
  final String? url;

  /// True for the adaptive [auto] sentinel.
  bool get isAuto => id == 'auto';

  /// The adaptive sentinel — opens the master playlist (native ABR).
  static const VideoQuality auto = VideoQuality(id: 'auto', label: 'Auto');

  @override
  bool operator ==(Object other) =>
      other is VideoQuality && other.id == id && other.url == url;

  @override
  int get hashCode => Object.hash(id, url);
}

/// The result of parsing an HLS master playlist.
@immutable
class HlsMasterInfo {
  const HlsMasterInfo({
    required this.qualities,
    required this.hasAudioGroups,
    required this.isMaster,
  });

  /// The distinct, pinnable variant qualities (NOT including `Auto`), highest
  /// resolution first, de-duped by height. Empty when the playlist is a media
  /// playlist (not a master) or exposes no usable video renditions.
  final List<VideoQuality> qualities;

  /// True when the master declares separate `EXT-X-MEDIA:TYPE=AUDIO` groups.
  /// When set, a video-variant URL would be VIDEO-ONLY (its audio lives in a
  /// separate rendition the native player muxes at runtime), so pinning a
  /// variant directly would drop the audio. The service disables manual pinning
  /// (Auto only) in that case rather than break audio.
  final bool hasAudioGroups;

  /// True when the content declared at least one `EXT-X-STREAM-INF` (i.e. it is
  /// a master playlist rather than a plain media playlist).
  final bool isMaster;

  static const HlsMasterInfo empty = HlsMasterInfo(
    qualities: [],
    hasAudioGroups: false,
    isMaster: false,
  );
}

/// Parses an HLS MASTER playlist [content] (already fetched as text) into the
/// list of selectable video qualities, resolving each variant URL against
/// [baseUri] (the master's own URL) so relative variant paths become absolute.
///
/// Pure and top-level so the attribute parsing, relative-URL resolution,
/// height de-duplication and audio-group detection are all directly unit
/// testable without any network or player.
///
/// Recognizes:
///   * `#EXT-X-STREAM-INF:...` — a video variant; the following non-comment
///     line is its (possibly relative) URI. `RESOLUTION=WxH` and `BANDWIDTH=n`
///     attributes label and order it.
///   * `#EXT-X-MEDIA:TYPE=AUDIO,...` — a separate audio group (see
///     [HlsMasterInfo.hasAudioGroups]).
///
/// Variants without a parseable `RESOLUTION` are dropped from the picker (Auto
/// still plays them); the remaining variants are de-duped by height (masters
/// often list several bitrates at the same resolution) keeping the first seen,
/// and sorted highest-resolution first.
HlsMasterInfo parseHlsMaster(String content, Uri baseUri) {
  final lines = content.split(RegExp(r'\r?\n'));
  var isMaster = false;
  var hasAudioGroups = false;
  final seenHeights = <int>{};
  final variants = <VideoQuality>[];

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXT-X-MEDIA:') &&
        line.toUpperCase().contains('TYPE=AUDIO')) {
      hasAudioGroups = true;
      continue;
    }

    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    isMaster = true;

    final attrs = line.substring('#EXT-X-STREAM-INF:'.length);
    final resolution = _attr(attrs, 'RESOLUTION');
    final bandwidth = int.tryParse(_attr(attrs, 'BANDWIDTH') ?? '');

    // The URI is the next non-blank, non-comment line.
    String? uri;
    for (var j = i + 1; j < lines.length; j++) {
      final candidate = lines[j].trim();
      if (candidate.isEmpty) continue;
      if (candidate.startsWith('#')) continue;
      uri = candidate;
      break;
    }
    if (uri == null) continue;

    int? width;
    int? height;
    if (resolution != null) {
      final parts = resolution.toLowerCase().split('x');
      if (parts.length == 2) {
        width = int.tryParse(parts[0].trim());
        height = int.tryParse(parts[1].trim());
      }
    }
    if (height == null || height <= 0) continue; // no label → Auto handles it
    if (!seenHeights.add(height)) continue; // de-dupe by resolution height

    final absolute = baseUri.resolve(uri).toString();
    variants.add(VideoQuality(
      id: absolute,
      label: '${height}p',
      width: width,
      height: height,
      bandwidth: bandwidth,
      url: absolute,
    ));
  }

  variants.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
  return HlsMasterInfo(
    qualities: variants,
    hasAudioGroups: hasAudioGroups,
    isMaster: isMaster,
  );
}

/// Extracts an unquoted attribute [name] from an HLS attribute list, e.g.
/// `RESOLUTION=1920x1080` or `BANDWIDTH=4500000`. Anchored on a comma or start
/// so `BANDWIDTH` never matches inside `AVERAGE-BANDWIDTH`. Returns null when
/// absent.
String? _attr(String attrs, String name) {
  final match = RegExp('(?:^|,)$name=([^,]+)', caseSensitive: false)
      .firstMatch(attrs);
  return match?.group(1)?.trim();
}
