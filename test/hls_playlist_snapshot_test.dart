import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/hls_timeline.dart';

import 'helpers/hls_fixtures.dart';

/// [HlsPlaylistSnapshot.parse] against production playlists (fetched
/// 2026-10-11 from hls.radiocrestin.ro) and the B14/B7 tag shapes.
void main() {
  final fetchedAt = DateTime.utc(2026, 10, 11, 10, 30, 2);

  HlsPlaylistSnapshot parseFixture(String name) => HlsPlaylistSnapshot.parse(
        readFixture('hls/$name'),
        fetchedAt: fetchedAt,
        lastModifiedHeader: 'Sun, 11 Oct 2026 10:30:02 GMT',
      )!;

  group('production playlists', () {
    test(
        'parses window start, live edge (last PDT + EXTINF) and window '
        'length 660.004', () {
      final s = parseFixture('radio-calea-spre-cer-popular.m3u8');
      expect(s.segments, hasLength(110));
      expect(s.windowStartPdt, closeTo(1791713604.560, 1e-6));
      expect(s.liveEdgePdt, closeTo(1791714264.563189, 1e-6));
      expect(s.windowSeconds, closeTo(660.004, 1e-3));
    });

    test('reads MEDIA-SEQUENCE and TARGETDURATION; seq = sequence + index', () {
      final s = parseFixture('radio-emanuel.m3u8');
      expect(s.mediaSequence, 1791248103);
      expect(s.targetDuration, 6);
      expect(s.firstSeq, 1791248103);
      expect(s.lastSeq, 1791248212);
      expect(s.segments.last.uri, 'radio-emanuel-1791154912-1791248212.ts');
    });

    test(
        'extracts METADATA-CHANGED epoch and every DATERANGE start/end as '
        'boundaries', () {
      final s = parseFixture('radio-calea-spre-cer-popular.m3u8');
      final epoch =
          DateTime.fromMillisecondsSinceEpoch(1791714571000, isUtc: true);
      expect(s.metadataChangedAt, epoch);
      final instants = s.songBoundaries.map((b) => b.at).toList();
      // 5 DATERANGE (start + end each) + 1 METADATA-CHANGED.
      expect(instants, hasLength(11));
      expect(instants, contains(epoch));
      expect(instants, contains(DateTime.utc(2026, 10, 11, 10, 22, 7, 625)));
      expect(instants, contains(DateTime.utc(2026, 10, 11, 10, 29, 31, 389)));
      // Today's backend sends no B14 hint.
      expect(s.songBoundaries.every((b) => b.hint == null), isTrue);
    });

    test('parses Last-Modified HTTP date; missing header → null', () {
      expect(parseFixture('radio-emanuel.m3u8').lastModified,
          DateTime.utc(2026, 10, 11, 10, 30, 2));
      final noHeader = HlsPlaylistSnapshot.parse(
          readFixture('hls/radio-emanuel.m3u8'),
          fetchedAt: fetchedAt)!;
      expect(noHeader.lastModified, isNull);
      final garbage = HlsPlaylistSnapshot.parse(
          readFixture('hls/radio-emanuel.m3u8'),
          fetchedAt: fetchedAt,
          lastModifiedHeader: 'yesterday')!;
      expect(garbage.lastModified, isNull);
    });
  });

  group('B14 hint on METADATA-CHANGED', () {
    HlsPlaylistSnapshot withTag(String tag) =>
        HlsPlaylistSnapshot.parse(playlistText(header: [tag]),
            fetchedAt: fetchedAt)!;

    test('parses optional TITLE/ARTIST/SONG-ID/ARTIST-ID/THUMBNAIL hint', () {
      final s = withTag('#EXT-X-RC-METADATA-CHANGED:'
          'STARTED-AT="2026-10-11T10:06:20.000Z",EPOCH=1791712000,'
          'X-TITLE="Am fost lutul",X-ARTIST="Beni Buble",X-SONG-ID="123",'
          'X-ARTIST-ID="45",X-THUMBNAIL-URL="https://cdn.example/t.webp"');
      final hint = s.songBoundaries.single.hint!;
      expect(hint.title, 'Am fost lutul');
      expect(hint.artist, 'Beni Buble');
      expect(hint.songId, 123);
      expect(hint.artistId, 45);
      expect(hint.thumbnailUrl, 'https://cdn.example/t.webp');
    });

    test('absent attributes → null hint', () {
      final s = withTag('#EXT-X-RC-METADATA-CHANGED:'
          'STARTED-AT="2026-10-11T10:06:20.000Z",EPOCH=1791712000');
      expect(s.songBoundaries.single.hint, isNull);
      expect(s.metadataChangedAt,
          DateTime.fromMillisecondsSinceEpoch(1791712000000, isUtc: true));
    });

    test('a title with commas and "EPOCH=1" does not change the epoch', () {
      final s = withTag('#EXT-X-RC-METADATA-CHANGED:'
          'STARTED-AT="2026-10-11T10:06:20.000Z",EPOCH=1791712000,'
          'X-TITLE="Doar un nume, EPOCH=1, (elvis,robert)",'
          'X-ARTIST="frati, din barbulesti",X-SONG-ID="7"');
      final b = s.songBoundaries.single;
      expect(b.at,
          DateTime.fromMillisecondsSinceEpoch(1791712000000, isUtc: true));
      expect(b.hint!.title, 'Doar un nume, EPOCH=1, (elvis,robert)');
      expect(b.hint!.artist, 'frati, din barbulesti');
      expect(b.hint!.songId, 7);
    });

    test('unquoted ids are accepted; a non-http thumbnail is dropped', () {
      final s = withTag('#EXT-X-RC-METADATA-CHANGED:EPOCH=1791712000,'
          'X-SONG-ID=9,X-THUMBNAIL-URL="javascript:alert(1)"');
      final hint = s.songBoundaries.single.hint!;
      expect(hint.songId, 9);
      expect(hint.thumbnailUrl, isNull);
    });
  });

  group('structure', () {
    test('segment without its own PDT inherits previous PDT + EXTINF', () {
      final s = HlsPlaylistSnapshot.parse(
          playlistText(count: 3, duration: 6.5, pdtOnEverySegment: false),
          fetchedAt: fetchedAt)!;
      final start = secondsOf(DateTime.utc(2026, 10, 11, 10));
      expect(s.segments.map((x) => x.pdt), [start, start + 6.5, start + 13.0]);
    });

    test('segments before the first PDT are back-filled from it', () {
      final body = playlistText(count: 2)
          .replaceFirst(RegExp(r'#EXT-X-PROGRAM-DATE-TIME:[^\n]*\n'), '');
      final s = HlsPlaylistSnapshot.parse(body, fetchedAt: fetchedAt)!;
      expect(s.segments[1].pdt - s.segments[0].pdt, closeTo(6, 1e-6));
    });

    test('locate walks EXTINF (exact at segment edges, clamps)', () {
      final s = parseFixture('radio-emanuel.m3u8');
      expect(s.locate(0), const HlsMediaPosition(1791248103, 0));
      // Exactly on the first edge (6.037189) → next segment, offset 0.
      expect(s.locate(6.037189).seq, 1791248104);
      expect(s.locate(6.037189).offset, closeTo(0, 1e-9));
      final mid = s.locate(12.027933 + 1.5);
      expect(mid.seq, 1791248105);
      expect(mid.offset, closeTo(1.5, 1e-9));
      expect(s.locate(-3), const HlsMediaPosition(1791248103, 0));
      final end = s.locate(10000);
      expect(end.seq, s.lastSeq);
      expect(end.offset, closeTo(s.segments.last.duration, 1e-9));
    });

    test('ignores DISCONTINUITY, DISCONTINUITY-SEQUENCE and unknown tags', () {
      final s = HlsPlaylistSnapshot.parse(
        playlistText(
          count: 3,
          header: [
            '#EXT-X-START:TIME-OFFSET=-18',
            '#EXT-X-INDEPENDENT-SEGMENTS',
            '#EXT-X-DISCONTINUITY-SEQUENCE:4',
            '#EXT-X-SOMETHING-NEW:A=1',
          ],
          beforeSegment: {
            2: ['#EXT-X-DISCONTINUITY', '#EXT-X-UNKNOWN'],
          },
        ),
        fetchedAt: fetchedAt,
      )!;
      expect(s.segments.map((x) => x.seq), [100, 101, 102]);
      expect(s.segments.map((x) => x.uri),
          ['seg-100.ts', 'seg-101.ts', 'seg-102.ts']);
    });

    test('tolerates a UTF-8 byte order mark', () {
      final s = HlsPlaylistSnapshot.parse('\uFEFF${playlistText()}',
          fetchedAt: fetchedAt);
      expect(s?.segments, hasLength(3));
    });

    test('tolerates CRLF', () {
      final s = HlsPlaylistSnapshot.parse(playlistText(lineEnd: '\r\n'),
          fetchedAt: fetchedAt)!;
      expect(s.segments, hasLength(3));
      expect(s.segments.first.uri, 'seg-100.ts');
      expect(s.targetDuration, 6);
    });

    test('returns null without PDT / without segments / for garbage', () {
      final noPdt = playlistText()
          .replaceAll(RegExp(r'#EXT-X-PROGRAM-DATE-TIME:[^\n]*\n'), '');
      expect(HlsPlaylistSnapshot.parse(noPdt, fetchedAt: fetchedAt), isNull);
      expect(HlsPlaylistSnapshot.isMediaPlaylistWithoutPdt(noPdt), isTrue);
      expect(
          HlsPlaylistSnapshot.parse(playlistText(count: 0),
              fetchedAt: fetchedAt),
          isNull);
      expect(
          HlsPlaylistSnapshot.parse('<html>502</html>', fetchedAt: fetchedAt),
          isNull);
      expect(HlsPlaylistSnapshot.isMediaPlaylistWithoutPdt('<html/>'), isFalse);
      expect(HlsPlaylistSnapshot.parse('', fetchedAt: fetchedAt), isNull);
    });
  });

  group('parseHlsAttributeList (RFC 8216 §4.2)', () {
    test('quoted strings keep commas and equals signs', () {
      expect(parseHlsAttributeList('A=1,B="x, y=2",C=ENUM'),
          {'A': '1', 'B': 'x, y=2', 'C': 'ENUM'});
    });

    test('first occurrence wins; unterminated quote stops parsing', () {
      expect(parseHlsAttributeList('A=1,A=2'), {'A': '1'});
      expect(parseHlsAttributeList('A=1,B="open'), {'A': '1'});
    });
  });
}
