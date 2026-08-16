import 'dart:convert';
import 'package:gql/ast.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/utils/api_utils.dart';
import 'package:radio_crestin/utils/http_stall_guard.dart';

typedef RestApiTransformer = Map<String, dynamic> Function(dynamic jsonData);

class GraphQLToRestInterceptorLink extends Link {
  final Map<String, RestApiConfig> queryToRestMap;

  /// Factory for the per-request [http.Client]. One client per request
  /// (mirroring `http.get`), closed in a `finally` so a timed-out request
  /// releases its socket instead of leaking a half-open connection.
  /// Injectable so tests can supply a fake/slow client.
  final http.Client Function() _clientFactory;

  GraphQLToRestInterceptorLink({
    required this.queryToRestMap,
    http.Client Function()? httpClientFactory,
  }) : _clientFactory = httpClientFactory ?? (() => http.Client());

  @override
  Stream<Response> request(Request request, [NextLink? forward]) {
    final config = _getConfigForRequest(request);

    if (config != null) {
      // Single-shot by construction: a [Future] completes exactly once, so
      // `Stream.fromFuture` emits exactly one event and then closes. This is
      // the root guard against the "Bad state: Future already completed"
      // race — the REST path can no longer deliver a *second* event after a
      // downstream consumer has already resolved its own completer.
      //
      // Why that race existed: graphql's `QueryManager._resolveQueryOnNetwork`
      // wraps this stream in `.timeout(queryRequestTimeout)` and listens with
      // an *unguarded* `completer.complete` as its onData handler. If the
      // timeout fired first (completing the completer via the guarded error
      // path) and this stream then emitted a late response, that second event
      // hit `completer.complete` on an already-completed completer and threw.
      // Emitting at most once removes our half of the race; the client is also
      // configured with `queryRequestTimeout: null` so the interceptor's own
      // [HttpStallGuard.restApiTimeout] bound is the single timeout authority.
      return Stream.fromFuture(_handleRestApiRequest(request, config));
    }
    if (forward != null) {
      return forward(request);
    }
    return const Stream<Response>.empty();
  }

  /// Resolves the REST call into exactly one [Response]. Never throws:
  /// every failure (timeout, non-200, decode/transform error) is mapped to a
  /// GraphQL error response, preserving the caller's fallback semantics.
  Future<Response> _handleRestApiRequest(
    Request request,
    RestApiConfig config,
  ) async {
    final opName = request.operation.operationName ?? 'unknown';
    try {
      final variables = request.variables;
      final url = config.urlBuilder != null
          ? config.urlBuilder!(variables)
          : addTimestampToUrl(config.restApiUrl);

      PerformanceMonitor.startOperation('rest_api_$opName');
      final http.Response response;
      try {
        response = await _fetchFromRestApi(url);
      } finally {
        // Always close the timing window — even on timeout/error — so a
        // failed poll can't leak a dangling start entry that would inflate
        // the next successful measurement.
        PerformanceMonitor.endOperation('rest_api_$opName');
      }

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body);
        final transformedData = config.transformer(jsonData);
        return _createSuccessResponse(transformedData, request.context);
      }
      return _createErrorResponse(
        'Failed to fetch from REST API (${config.restApiUrl}): '
        '${response.statusCode}',
        request.context,
      );
    } catch (e) {
      return _createErrorResponse(
        'Error fetching from REST API: $e',
        request.context,
      );
    }
  }

  Future<http.Response> _fetchFromRestApi(String url) async {
    // Total-duration bound: this is the station-data poll — an unbounded
    // request here let a silent backend stall the whole refresh pipeline.
    // A timeout surfaces as a GraphQL error response; the poller's next
    // tick retries as usual.
    final client = _clientFactory();
    try {
      return await client
          .get(Uri.parse(url))
          .timeout(HttpStallGuard.restApiTimeout);
    } finally {
      // Close in `finally` so a timed-out (abandoned) request also releases
      // its socket instead of piling up half-open connections.
      client.close();
    }
  }
  
  Response _createSuccessResponse(Map<String, dynamic> data, Context context) {
    return Response(
      response: data,
      data: data,
      context: context,
    );
  }
  
  Response _createErrorResponse(String message, Context context) {
    return Response(
      response: const {},
      errors: [
        GraphQLError(message: message),
      ],
      context: context,
    );
  }
  
  RestApiConfig? _getConfigForRequest(Request request) {
    final operation = request.operation;
    
    // Check by operation name
    if (operation.operationName != null && 
        queryToRestMap.containsKey(operation.operationName!)) {
      return queryToRestMap[operation.operationName!];
    }
    
    // Check by document node
    for (final entry in queryToRestMap.entries) {
      if (entry.value.documentNode != null && 
          operation.document == entry.value.documentNode) {
        return entry.value;
      }
    }
    
    return null;
  }
}

class RestApiConfig {
  final String restApiUrl;
  final RestApiTransformer transformer;
  final DocumentNode? documentNode;
  final String Function(Map<String, dynamic> variables)? urlBuilder;
  
  RestApiConfig({
    required this.restApiUrl,
    required this.transformer,
    this.documentNode,
    this.urlBuilder,
  });
}