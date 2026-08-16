import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;

import 'package:radio_crestin/graphql_to_rest_interceptor.dart';

/// Fake HTTP client that answers after a fixed [delay]. Lets a test place the
/// REST response *after* a consumer's timeout window to reproduce the race.
class _DelayedClient extends http.BaseClient {
  _DelayedClient({
    required this.delay,
    required this.body,
    this.statusCode = 200,
    this.onClose,
  });

  final Duration delay;
  final String body;
  final int statusCode;
  final void Function()? onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(delay);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      statusCode,
      request: request,
    );
  }

  @override
  void close() {
    onClose?.call();
    super.close();
  }
}

Request _request(String operationName) => Request(
      operation: Operation(
        document: gql('query $operationName { value }'),
        operationName: operationName,
      ),
    );

GraphQLToRestInterceptorLink _link({
  required Duration delay,
  String body = '{"value": 42}',
  int statusCode = 200,
  void Function()? onClose,
}) =>
    GraphQLToRestInterceptorLink(
      queryToRestMap: {
        'GetX': RestApiConfig(
          restApiUrl: 'https://api.example.com/data',
          // `__typename` mirrors what real transformers emit; graphql injects
          // it into the query and its cache normalizer requires it.
          transformer: (d) => {'__typename': 'Query', 'value': d['value']},
        ),
      },
      httpClientFactory: () => _DelayedClient(
        delay: delay,
        body: body,
        statusCode: statusCode,
        onClose: onClose,
      ),
    );

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

  group('GraphQLToRestInterceptorLink single-shot contract', () {
    test('REST path emits exactly one response and then closes', () async {
      final link = _link(delay: const Duration(milliseconds: 30));

      final events = await link.request(_request('GetX')).toList();

      expect(events, hasLength(1));
      expect(events.single.data?['value'], 42);
    });

    test('a non-200 status still yields exactly one (error) response',
        () async {
      final link = _link(
        delay: const Duration(milliseconds: 10),
        statusCode: 503,
      );

      final events = await link.request(_request('GetX')).toList();

      expect(events, hasLength(1));
      expect(events.single.errors, isNotNull);
      expect(events.single.errors, isNotEmpty);
    });

    test('closes the per-request http client (releases the socket)', () async {
      var closed = false;
      final link = _link(
        delay: const Duration(milliseconds: 10),
        onClose: () => closed = true,
      );

      await link.request(_request('GetX')).toList();

      expect(closed, isTrue);
    });
  });

  group('Future-already-completed race (Stream.timeout vs late response)', () {
    // These drive a REAL GraphQLClient exactly as production does, so they
    // exercise QueryManager._resolveQueryOnNetwork — the code that wraps the
    // link stream in `.timeout(queryRequestTimeout)` and completes an
    // unguarded completer from onData.

    QueryOptions<Object?> queryOptions() => QueryOptions(
          document: gql('query GetX { value }'),
          operationName: 'GetX',
          fetchPolicy: FetchPolicy.networkOnly,
        );

    test(
        'reproduces the crash: with a competing per-request timeout, a late '
        'response re-completes the already-completed completer', () async {
      // Response (120ms) lands AFTER the request timeout (20ms) fires.
      final client = GraphQLClient(
        link: _link(delay: const Duration(milliseconds: 120)),
        cache: GraphQLCache(),
        queryRequestTimeout: const Duration(milliseconds: 20),
      );

      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        // Resolves (~20ms) with a timeout exception; the leaked subscription
        // then fires onData at ~120ms → completer.complete() on a completed
        // completer → "Bad state: Future already completed".
        await client.query(queryOptions());
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }, (error, _) {
        zoneErrors.add(error);
      });

      expect(
        zoneErrors.any((e) => e.toString().contains('already completed')),
        isTrue,
        reason: 'the late response should double-complete the completer '
            'when a competing timeout is installed',
      );
    });

    test(
        'fix: with queryRequestTimeout null (production config) a late '
        'response resolves cleanly and never double-completes', () async {
      // Same slow response, but no competing timeout: the interceptor is the
      // single completion authority, so exactly one completion happens.
      final client = GraphQLClient(
        link: _link(delay: const Duration(milliseconds: 120)),
        cache: GraphQLCache(),
        queryRequestTimeout: null,
      );

      final zoneErrors = <Object>[];
      late QueryResult<Object?> result;
      await runZonedGuarded(() async {
        result = await client.query(queryOptions());
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }, (error, _) {
        zoneErrors.add(error);
      });

      expect(zoneErrors, isEmpty);
      expect(result.hasException, isFalse);
      expect(result.data?['value'], 42);
    });
  });
}
