import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/types/playlist_item.dart';

void main() {
  group('youtubePlaylistIdFromUrl', () {
    test('extracts the list id from a canonical playlist URL', () {
      expect(
        youtubePlaylistIdFromUrl(
            'https://www.youtube.com/playlist?list=PLabc123DEF'),
        'PLabc123DEF',
      );
    });

    test('extracts the list id from a watch URL carrying a playlist', () {
      expect(
        youtubePlaylistIdFromUrl(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxyz789'),
        'PLxyz789',
      );
    });

    test('handles youtu.be short links with a list param', () {
      expect(
        youtubePlaylistIdFromUrl('https://youtu.be/dQw4w9WgXcQ?list=PLshort'),
        'PLshort',
      );
    });

    test('accepts a bare playlist id', () {
      expect(youtubePlaylistIdFromUrl('PLbareId123'), 'PLbareId123');
    });

    test('trims surrounding whitespace', () {
      expect(
        youtubePlaylistIdFromUrl('  https://youtube.com/playlist?list=PLws  '),
        'PLws',
      );
    });

    test('returns null when there is no playlist id', () {
      expect(
        youtubePlaylistIdFromUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        isNull,
      );
      expect(youtubePlaylistIdFromUrl(''), isNull);
      expect(youtubePlaylistIdFromUrl('   '), isNull);
    });

    test('returns null for a URL with an empty list param', () {
      expect(
        youtubePlaylistIdFromUrl('https://www.youtube.com/playlist?list='),
        isNull,
      );
    });
  });
}
