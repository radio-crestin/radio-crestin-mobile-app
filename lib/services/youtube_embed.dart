/// What a YouTube link in an announcement's page plays: a video (possibly
/// inside a playlist), a Short, or a playlist.
enum YoutubeEmbedKind { video, short, playlist }

/// A YouTube link that becomes a player in an announcement's page.
///
/// The rules mirror the backend's `services/youtube_embeds.py` (the
/// announcements spec, "YouTube embeds in the announcement page"): the same
/// hosts, paths and ID checks, so the app, the website and the admin preview
/// agree on which links become players. Anything else stays a link.
class YoutubeEmbed {
  const YoutubeEmbed._(this.kind, {this.videoId, this.listId, this.start});

  final YoutubeEmbedKind kind;
  final String? videoId;
  final String? listId;

  /// Where a video starts, in seconds.
  final int? start;

  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _listId = RegExp(r'^[A-Za-z0-9_-]{10,64}$');
  static final _duration = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$');
  static const _hosts = {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtu.be',
    'www.youtu.be',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  };
  static const _pathVideos = {
    'shorts': YoutubeEmbedKind.short,
    'live': YoutubeEmbedKind.video,
    'embed': YoutubeEmbedKind.video,
  };

  /// The canonical link, which the app opens when it can't play inside.
  String get url {
    switch (kind) {
      case YoutubeEmbedKind.playlist:
        return Uri.https('www.youtube.com', '/playlist', {'list': listId})
            .toString();
      case YoutubeEmbedKind.short:
        return 'https://www.youtube.com/shorts/$videoId';
      case YoutubeEmbedKind.video:
        return Uri.https('www.youtube.com', '/watch', {
          'v': videoId,
          if (listId != null) 'list': listId,
          if (start != null) 't': '${start}s',
        }).toString();
    }
  }

  /// The thumbnail, or null for a playlist (no video known).
  String? get thumbnailUrl =>
      videoId == null ? null : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

  /// '90', '90s' or '1h2m3s' in seconds; null when absent or not a time.
  static int? parseStart(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = _duration.firstMatch(value);
    if (match == null) return null;
    int part(int group) => int.tryParse(match.group(group) ?? '') ?? 0;
    final total = part(1) * 3600 + part(2) * 60 + part(3);
    return total == 0 ? null : total;
  }

  /// The embed [url] stands for, or null when it should stay a link.
  static YoutubeEmbed? parse(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        !_hosts.contains(uri.host.toLowerCase())) {
      return null;
    }
    final query = uri.queryParametersAll;
    String? first(String key) => query[key]?.firstOrNull;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final listId = first('list');
    final start = parseStart(first('t') ?? first('start'));

    var kind = YoutubeEmbedKind.video;
    String? videoId;
    if (uri.host.toLowerCase().endsWith('youtu.be')) {
      videoId = segments.length == 1 ? segments.first : null;
    } else if (_is(segments, const ['watch'])) {
      videoId = first('v');
    } else if (_is(segments, const ['playlist']) ||
        _is(segments, const ['embed', 'videoseries'])) {
      kind = YoutubeEmbedKind.playlist;
    } else if (segments.length == 2 && _pathVideos.containsKey(segments[0])) {
      kind = _pathVideos[segments[0]]!;
      videoId = segments[1];
    } else {
      return null; // channels, search pages, anything else
    }

    if (listId != null && !_listId.hasMatch(listId)) return null;
    if (kind == YoutubeEmbedKind.playlist) {
      return listId == null
          ? null
          : YoutubeEmbed._(YoutubeEmbedKind.playlist, listId: listId);
    }
    if (videoId == null || !_videoId.hasMatch(videoId)) return null;
    if (kind == YoutubeEmbedKind.short) {
      return YoutubeEmbed._(YoutubeEmbedKind.short, videoId: videoId);
    }
    return YoutubeEmbed._(YoutubeEmbedKind.video,
        videoId: videoId, listId: listId, start: start);
  }

  static bool _is(List<String> segments, List<String> expected) =>
      segments.length == expected.length &&
      Iterable.generate(expected.length)
          .every((i) => segments[i] == expected[i]);

  /// The link a markdown paragraph holds when it is nothing else: a bare
  /// URL, `<url>`, or `[url](url)` whose text is the URL. Null otherwise.
  static String? paragraphLink(String paragraph) {
    final text = paragraph.trim();
    if (text.contains('\n')) return null;
    final bare = RegExp(r'^<?(https?://\S+?)>?$').firstMatch(text);
    if (bare != null) return bare.group(1);
    final link = RegExp(r'^\[([^\]]+)\]\(\s*<?(https?://[^\s)>]+)>?\s*\)$')
        .firstMatch(text);
    if (link != null && link.group(1)!.trim() == link.group(2)) {
      return link.group(2);
    }
    return null;
  }
}
