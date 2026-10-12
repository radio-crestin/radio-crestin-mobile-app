import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';

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

  group('GraphQLToRestInterceptorLink', () {
    const url = 'https://api.example.com/stations';
    final getStations = Request(
      operation: Operation(
        document: documentNodeQueryGetStations,
        operationName: 'GetStations',
      ),
    );

    GraphQLToRestInterceptorLink linkWith(MockClient client) =>
        GraphQLToRestInterceptorLink(
          queryToRestMap: {
            'GetStations': RestApiConfig(
              restApiUrl: url,
              transformer: (data) => data['data'] as Map<String, dynamic>,
              urlBuilder: (_) => url,
            ),
          },
          httpClient: client,
        );

    test('serves a mapped query through the injected client', () async {
      final requested = <Uri>[];
      final link = linkWith(MockClient((request) async {
        requested.add(request.url);
        return http.Response(
            json.encode({
              'data': {'stations': <Object>[]},
            }),
            200);
      }));

      final response = await link.request(getStations).first;

      expect(requested, [Uri.parse(url)]);
      expect(response.errors, isNull);
      expect(response.data, {'stations': <Object>[]});
    });

    test('maps a non-200 status to a GraphQL error', () async {
      final link =
          linkWith(MockClient((_) async => http.Response('down', 503)));

      final response = await link.request(getStations).first;

      expect(response.data, isNull);
      expect(response.errors?.single.message, contains('503'));
    });

    test('maps a transport failure to a GraphQL error', () async {
      final link = linkWith(MockClient(
          (request) async => throw http.ClientException('reset', request.url)));

      final response = await link.request(getStations).first;

      expect(response.errors?.single.message, contains('reset'));
    });
  });
}
