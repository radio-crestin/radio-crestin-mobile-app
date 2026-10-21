import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/siri_media_service.dart';

import 'helpers/station_factory.dart';

void main() {
  final stations = [
    StationFactory.createStation(id: 1, slug: 'joy', title: 'Radio Joy'),
    StationFactory.createStation(id: 2, slug: 'rve-cluj', title: 'RVE Cluj'),
    StationFactory.createStation(id: 3, slug: 'levi', title: 'Radio Levi'),
  ];

  group('siriVocabulary', () {
    test('lists the favorites first, in the listener\'s order', () {
      final vocabulary =
          siriVocabulary(stations, favoriteSlugs: ['levi', 'joy']);
      expect([for (final name in vocabulary) name['id']],
          ['levi', 'joy', 'rve-cluj', 'rve-cluj']);
    });

    test('teaches both names of an "RVE" station', () {
      final vocabulary = siriVocabulary(stations, favoriteSlugs: const []);
      expect(
        [
          for (final name in vocabulary)
            if (name['id'] == 'rve-cluj') name['phrase'],
        ],
        ['RVE Cluj', 'Radio Vocea Evangheliei Cluj'],
      );
    });

    test('leaves out favorites the list no longer holds', () {
      final vocabulary =
          siriVocabulary(stations, favoriteSlugs: ['gone', 'joy']);
      expect(vocabulary.first, {'id': 'joy', 'phrase': 'Radio Joy'});
      expect(vocabulary, hasLength(4));
    });
  });
}
