import 'dart:convert';
import 'package:gql/ast.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/utils/api_utils.dart';

typedef RestApiTransformer = Map<String, dynamic> Function(dynamic jsonData);

class GraphQLToRestInterceptorLink extends Link {
  final Map<String, RestApiConfig> queryToRestMap;

  /// Shared across requests so the REST calls reuse connections. Built with
  /// the link (constructed once in main) rather than lazily, so a test's
  /// `http.runWithClient` zone cannot leak into it.
  final http.Client _client;

  /// Stops waiting on a stalled request. GraphQL's own request timeout only
  /// drops the result: this link stays suspended on the download and would
  /// still decode and transform a late response.
  static const _requestTimeout = Duration(seconds: 10);

  /// [httpClient] defaults to a real client; tests inject a fake. main()
  /// passes the API client `StationDataService` uses, whose connections
  /// outlive its 60 s tick, so the station list does not open a new one.
  GraphQLToRestInterceptorLink({
    required this.queryToRestMap,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();
  
  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final config = _getConfigForRequest(request);
    
    if (config != null) {
      yield* _handleRestApiRequest(request, config);
    } else {
      if (forward != null) {
        yield* forward(request);
      }
    }
  }
  
  Stream<Response> _handleRestApiRequest(Request request, RestApiConfig config) async* {
    try {
      final variables = request.variables;
      final url = config.urlBuilder != null
        ? config.urlBuilder!(variables)
        : addTimestampToUrl(config.restApiUrl);
      final opName = request.operation.operationName ?? 'unknown';
      PerformanceMonitor.startOperation('rest_api_$opName');
      final response = await _fetchFromRestApi(url);
      PerformanceMonitor.endOperation('rest_api_$opName');
      
      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body);
        final transformedData = config.transformer(jsonData);
        
        yield _createSuccessResponse(transformedData, request.context);
      } else {
        yield _createErrorResponse(
          'Failed to fetch from REST API (${config.restApiUrl}): ${response.statusCode}',
          request.context,
        );
      }
    } catch (e) {
      yield _createErrorResponse(
        'Error fetching from REST API: $e',
        request.context,
      );
    }
  }
  
  Future<http.Response> _fetchFromRestApi(String url) =>
      _client.get(Uri.parse(url)).timeout(_requestTimeout);
  
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