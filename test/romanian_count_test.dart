import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/utils/romanian_count.dart';

void main() {
  group('romanianCount', () {
    String stations(int n) => romanianCount(n, one: 'stație', many: 'stații');

    test('uses the singular for one', () {
      expect(stations(1), '1 stație');
    });

    test('has no "de" below 20', () {
      expect(stations(0), '0 stații');
      expect(stations(2), '2 stații');
      expect(stations(19), '19 stații');
    });

    test('puts "de" from 20 on', () {
      expect(stations(20), '20 de stații');
      expect(stations(23), '23 de stații');
      expect(stations(64), '64 de stații');
    });

    test('follows the last two digits above 100', () {
      expect(stations(100), '100 de stații');
      expect(stations(101), '101 stații');
      expect(stations(119), '119 stații');
      expect(stations(120), '120 de stații');
    });

    test('groups thousands with a dot', () {
      expect(stations(1360), '1.360 de stații');
      expect(stations(1001), '1.001 stații');
    });
  });

  group('formatThousands', () {
    test('leaves numbers under a thousand alone', () {
      expect(formatThousands(0), '0');
      expect(formatThousands(999), '999');
    });

    test('puts a dot between groups of three digits', () {
      expect(formatThousands(1360), '1.360');
      expect(formatThousands(1000000), '1.000.000');
      expect(formatThousands(-12345), '-12.345');
    });
  });
}
