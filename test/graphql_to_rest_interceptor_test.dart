import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/graphql_to_rest_interceptor.dart';

void main() {
  group('RestApiConfig', () {
    test('stores url and transformer', () {
      final config = RestApiConfig(
        restApiUrl: 'https://api.example.com/stations',
        transformer: (data) => {'data': data},
      );

      expect(config.restApiUrl, 'https://api.example.com/stations');
      expect(config.documentNode, isNull);
      expect(config.urlBuilder, isNull);
    });

    test('transformer converts data correctly', () {
      final config = RestApiConfig(
        restApiUrl: 'https://api.example.com',
        transformer: (data) => {
          'stations': (data['items'] as List).map((i) => {'name': i}).toList(),
        },
      );

      final result = config.transformer({
        'items': ['Radio A', 'Radio B'],
      });

      expect(result['stations'], hasLength(2));
      expect(result['stations'][0]['name'], 'Radio A');
    });

    test('urlBuilder overrides restApiUrl', () {
      final config = RestApiConfig(
        restApiUrl: 'https://api.example.com/default',
        transformer: (data) => data as Map<String, dynamic>,
        urlBuilder: (vars) => 'https://api.example.com/custom/${vars['id']}',
      );

      final url = config.urlBuilder!({'id': '123'});
      expect(url, 'https://api.example.com/custom/123');
    });
  });
}
