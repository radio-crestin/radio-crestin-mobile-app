import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/video_quality.dart';

/// Unit tests for [parseHlsMaster] — the Dart HLS master-playlist parser that
/// feeds the app's quality picker (video_player has no track-selection API, so
/// manual pinning opens a variant playlist directly). Covers variant parsing,
/// relative-URL resolution, height de-duplication + ordering, and the
/// separate-audio-group detection that disables manual pinning.
void main() {
  final base = Uri.parse('https://cdn.example.com/live/master.m3u8');

  group('parseHlsMaster — variants', () {
    test('parses RESOLUTION + BANDWIDTH and resolves relative URLs', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480
480/index.m3u8
''';
      final info = parseHlsMaster(content, base);

      expect(info.isMaster, isTrue);
      expect(info.hasAudioGroups, isFalse);
      // Highest resolution first.
      expect(info.qualities.map((q) => q.label), ['1080p', '720p', '480p']);
      final top = info.qualities.first;
      expect(top.height, 1080);
      expect(top.width, 1920);
      expect(top.bandwidth, 4500000);
      // Relative variant URL resolved against the master's URL.
      expect(top.url, 'https://cdn.example.com/live/1080/index.m3u8');
      expect(top.id, top.url);
      expect(top.isAuto, isFalse);
    });

    test('resolves absolute variant URLs unchanged', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
https://other.cdn.net/720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
https://other.cdn.net/360.m3u8
''';
      final info = parseHlsMaster(content, base);
      expect(info.qualities.map((q) => q.url), [
        'https://other.cdn.net/720.m3u8',
        'https://other.cdn.net/360.m3u8',
      ]);
    });

    test('de-dupes by height (keeps the first seen) and sorts descending', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
720-hi/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
720-lo/index.m3u8
''';
      final info = parseHlsMaster(content, base);
      expect(info.qualities.map((q) => q.label), ['1080p', '720p']);
      // First 720 variant seen is retained.
      expect(info.qualities.firstWhere((q) => q.height == 720).url,
          'https://cdn.example.com/live/720-hi/index.m3u8');
    });

    test('drops variants without a parseable RESOLUTION', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
audio-only/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
720/index.m3u8
''';
      final info = parseHlsMaster(content, base);
      // isMaster is still true (there were EXT-X-STREAM-INF lines), but only the
      // resolution-bearing variant becomes a pickable quality.
      expect(info.isMaster, isTrue);
      expect(info.qualities.map((q) => q.label), ['720p']);
    });

    test('skips comment/blank lines between the tag and its URI', () {
      const content = '''
#EXTM3U

#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720

# a stray comment
720/index.m3u8
''';
      final info = parseHlsMaster(content, base);
      expect(info.qualities.single.url,
          'https://cdn.example.com/live/720/index.m3u8');
    });
  });

  group('parseHlsMaster — audio groups', () {
    test('detects separate EXT-X-MEDIA:TYPE=AUDIO groups', () {
      const content = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/eng.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080,AUDIO="aud"
1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,AUDIO="aud"
720/index.m3u8
''';
      final info = parseHlsMaster(content, base);
      // Variants still parse, but the caller (the service) uses hasAudioGroups
      // to keep "Auto only" so a video-only variant URL never drops the audio.
      expect(info.hasAudioGroups, isTrue);
      expect(info.qualities.map((q) => q.label), ['1080p', '720p']);
    });

    test('no audio groups for a plain muxed master', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
720/index.m3u8
''';
      expect(parseHlsMaster(content, base).hasAudioGroups, isFalse);
    });
  });

  group('parseHlsMaster — non-master input', () {
    test('a media playlist yields no qualities and isMaster=false', () {
      const content = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
segment0.ts
#EXTINF:6.0,
segment1.ts
''';
      final info = parseHlsMaster(content, base);
      expect(info.isMaster, isFalse);
      expect(info.qualities, isEmpty);
      expect(info.hasAudioGroups, isFalse);
    });

    test('handles CRLF line endings', () {
      final content = '#EXTM3U\r\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720\r\n'
          '720/index.m3u8\r\n';
      final info = parseHlsMaster(content, base);
      expect(info.qualities.single.height, 720);
    });
  });

  group('VideoQuality', () {
    test('auto sentinel', () {
      expect(VideoQuality.auto.isAuto, isTrue);
      expect(VideoQuality.auto.id, 'auto');
      expect(VideoQuality.auto.url, isNull);
    });

    test('equality is by id + url', () {
      const a = VideoQuality(id: 'x', label: '720p', url: 'x');
      const b = VideoQuality(id: 'x', label: 'ignored', url: 'x');
      const c = VideoQuality(id: 'y', label: '720p', url: 'y');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });
}
