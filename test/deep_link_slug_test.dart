import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils.dart';

String slugOf(String link) => Utils.stationSlugFromUri(Uri.parse(link));

void main() {
  group('Utils.stationSlugFromUri — web links', () {
    test('share link drops the share query string', () {
      expect(
        slugOf('https://www.radiocrestin.ro/radio-vocea?s=abc123&song=42'),
        'radio-vocea',
      );
    });

    test('NFC tag link drops the ref query string', () {
      expect(
        slugOf('https://asculta.radiocrestin.ro/radio-emanuel?ref=nfc'),
        'radio-emanuel',
      );
    });

    test('plain station link', () {
      expect(slugOf('https://www.radiocrestin.ro/radio-vocea'), 'radio-vocea');
    });

    test('trailing slash and fragment are ignored', () {
      expect(slugOf('https://www.radiocrestin.ro/radio-vocea/'), 'radio-vocea');
      expect(slugOf('https://www.radiocrestin.ro/radio-vocea#x'), 'radio-vocea');
    });

    test('root link names no station instead of the host', () {
      expect(slugOf('https://www.radiocrestin.ro?s=abc123'), '');
      expect(slugOf('https://www.radiocrestin.ro/'), '');
      expect(slugOf('https://www.radiocrestin.ro'), '');
    });

    test('http links are parsed like https', () {
      expect(slugOf('http://www.radiocrestin.ro/radio-vocea?s=1'), 'radio-vocea');
    });
  });

  group('Utils.stationSlugFromUri — custom scheme', () {
    test('radiocrestin://<slug> reads the slug from the host', () {
      expect(slugOf('radiocrestin://radio-vocea'), 'radio-vocea');
    });

    test('radiocrestin://<slug> ignores a query string', () {
      expect(slugOf('radiocrestin://radio-vocea?ref=nfc'), 'radio-vocea');
    });

    test('radiocrestin:///<slug> falls back to the path', () {
      expect(slugOf('radiocrestin:///radio-vocea'), 'radio-vocea');
    });

    test('radiocrestin:// with nothing after it names no station', () {
      expect(slugOf('radiocrestin://'), '');
    });
  });
}
