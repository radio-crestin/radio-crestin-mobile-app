import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/utils/api_utils.dart';

void main() {
  group('api_utils', () {
    group('getRoundedTimestamp', () {
      test('returns integer', () {
        final result = getRoundedTimestamp();
        expect(result, isA<int>());
      });

      test('is rounded to nearest 10 seconds', () {
        final result = getRoundedTimestamp();
        expect(result % 10, 0);
      });

      test('offset shifts timestamp backwards', () {
        final now = getRoundedTimestamp();
        final offset = getRoundedTimestamp(offset: const Duration(minutes: 2));

        // offset should be ~120 seconds behind
        final diff = now - offset;
        expect(diff, greaterThanOrEqualTo(110)); // allow some rounding
        expect(diff, lessThanOrEqualTo(130));
      });

      test('zero offset returns same as no offset', () {
        final a = getRoundedTimestamp();
        final b = getRoundedTimestamp(offset: Duration.zero);
        // Should be the same (or very close if crossing a 10s boundary)
        expect((a - b).abs(), lessThanOrEqualTo(10));
      });
    });

    group('addTimestampToUrl', () {
      test('adds timestamp query parameter', () {
        final url = addTimestampToUrl('https://api.example.com/data');
        final uri = Uri.parse(url);

        expect(uri.queryParameters.containsKey('timestamp'), true);
        final ts = int.parse(uri.queryParameters['timestamp']!);
        expect(ts % 10, 0);
      });

      test('preserves existing query parameters', () {
        final url = addTimestampToUrl('https://api.example.com/data?foo=bar');
        final uri = Uri.parse(url);

        expect(uri.queryParameters['foo'], 'bar');
        expect(uri.queryParameters.containsKey('timestamp'), true);
      });

      test('applies offset to timestamp', () {
        final urlNow = addTimestampToUrl('https://api.example.com/data');
        final urlOffset = addTimestampToUrl(
          'https://api.example.com/data',
          offset: const Duration(minutes: 5),
        );

        final tsNow = int.parse(Uri.parse(urlNow).queryParameters['timestamp']!);
        final tsOffset = int.parse(Uri.parse(urlOffset).queryParameters['timestamp']!);

        final diff = tsNow - tsOffset;
        expect(diff, greaterThanOrEqualTo(290));
        expect(diff, lessThanOrEqualTo(310));
      });
    });
  });
}
