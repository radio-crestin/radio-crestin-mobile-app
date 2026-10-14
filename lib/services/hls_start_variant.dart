import 'dart:async' show TimeoutException;
import 'dart:io' show Platform;

import 'package:just_audio/just_audio.dart' show PlayerException;

/// The live playlists the Radio Crestin origin publishes next to each
/// station's `index.m3u8` for the app's seek offsets: `index-2m.m3u8` and
/// `index-5m.m3u8`. Byte for byte `index.m3u8` except their
/// `#EXT-X-START`, 2 and 5 minutes behind live, clamped to the window with
/// the app's own trailing margin (75 s).
///
/// Loading one in place of `index.m3u8` plus the seek behind live starts
/// the player where it is going to play. From `index.m3u8` it first
/// downloads the segments at the near-live start (-18 s), which the seek
/// then throws away: measured with AVPlayer, 6-7 requests (~300-360 KB)
/// where the variant takes 4 (~205 KB), and the 2-minute start took
/// 0.42 s instead of 0.30 s. The segments and their URIs are the same, so
/// caching and bandwidth stay shared.
class HlsStartVariant {
  const HlsStartVariant._();

  /// The origin's hosts, the only ones that publish the variants.
  static const Set<String> hosts = {
    'hls.radiocrestin.ro',
    'live.radiocrestin.ro',
  };

  static const String _livePlaylist = 'index.m3u8';

  /// Whether this platform's player starts a live playlist at its
  /// `#EXT-X-START`: AVPlayer and ExoPlayer do, libmpv (Windows, Linux)
  /// does not by default, so the seek stays there.
  static bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// The variant of [streamUrl] that starts [offset] behind live, keeping
  /// its query parameters. Null for another host, another playlist than
  /// `index.m3u8`, and any offset but exactly 2 or 5 minutes (instant mode
  /// keeps the live start).
  static String? urlFor(String streamUrl, Duration offset) {
    final playlist = _playlistFor(offset);
    if (playlist == null) return null;
    final uri = Uri.tryParse(streamUrl);
    if (uri == null || !hosts.contains(uri.host)) return null;
    if (!uri.path.endsWith('/$_livePlaylist')) return null;
    final directory =
        uri.path.substring(0, uri.path.length - _livePlaylist.length);
    return uri.replace(path: '$directory$playlist').toString();
  }

  static String? _playlistFor(Duration offset) {
    if (offset == const Duration(minutes: 2)) return 'index-2m.m3u8';
    if (offset == const Duration(minutes: 5)) return 'index-5m.m3u8';
    return null;
  }

  /// Whether a variant load that failed with [error] may only mean the
  /// origin does not publish the variant (not deployed yet), so the stream
  /// loads again at once from `index.m3u8` instead of failing.
  ///
  /// AVPlayer answers a missing playlist at once with its HTTP status
  /// ([httpStatus]). ExoPlayer ([android]) does not: it retries a playlist
  /// 404 three times, 0, 1 and 2 s apart, before failing it as a source
  /// error (type 0, like a dropped connection), so the load times out
  /// first. There a failed variant load falls back, unless the internet
  /// is known to be out ([offline]): the network then explains the
  /// failure, and `index.m3u8` would only time out again.
  static bool mayBeMissing(
    Object error, {
    required bool httpStatus,
    required bool android,
    required bool offline,
  }) =>
      // A status is the origin answering, whatever the offline flag says.
      httpStatus ||
      (android &&
          !offline &&
          (error is TimeoutException || error is PlayerException));

  /// What a live load still needs to play at the listening offset
  /// ([currentOffset]), when it loaded the variant starting [variantOffset]
  /// behind live (null: the stream's own playlist).
  ///
  /// [seekRestartsPlayback]: the seek is what restarts playback, as on
  /// Darwin after a reload while already playing, which stays silent until
  /// a seek completes.
  static HlsStartFollowUp followUp({
    required Duration? variantOffset,
    required Duration currentOffset,
    required bool seekRestartsPlayback,
  }) {
    if (variantOffset == null) return HlsStartFollowUp.seek;
    if (variantOffset == currentOffset) {
      return seekRestartsPlayback
          ? HlsStartFollowUp.seek
          : HlsStartFollowUp.none;
    }
    // The offset changed while the variant loaded. The seek reaches any
    // other offset, but the live point is where `index.m3u8` starts: a
    // fresh load is never seeked there.
    return currentOffset == Duration.zero
        ? HlsStartFollowUp.reload
        : HlsStartFollowUp.seek;
  }
}

/// See [HlsStartVariant.followUp].
enum HlsStartFollowUp {
  /// Nothing: the player already starts at the listening offset.
  none,

  /// The seek behind live (or to the live point), as after `index.m3u8`.
  seek,

  /// Reload from `index.m3u8`: instant mode came on while the variant
  /// loaded.
  reload,
}
