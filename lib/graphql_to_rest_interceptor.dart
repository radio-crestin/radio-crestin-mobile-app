import 'dart:convert';
import 'package:gql/ast.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;

typedef RestApiTransformer = Map<String, dynamic> Function(dynamic jsonData);

class GraphQLToRestInterceptorLink extends Link {
  final Map<String, RestApiConfig> queryToRestMap;
  
  GraphQLToRestInterceptorLink({required this.queryToRestMap});
  
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
      final urlWithTimestamp = _addTimestampToUrl(config.restApiUrl);
      final response = await _fetchFromRestApi(urlWithTimestamp);
      
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
  
  String _addTimestampToUrl(String url) {
    final timestamp = _getRoundedTimestamp();
    final uri = Uri.parse(url);
    final queryParams = Map<String, String>.from(uri.queryParameters);
    queryParams['_t'] = timestamp.toString();
    
    return uri.replace(queryParameters: queryParams).toString();
  }
  
  int _getRoundedTimestamp() {
    final now = DateTime.now();
    final epochSeconds = now.millisecondsSinceEpoch ~/ 1000;
    // Round to nearest 10 seconds
    return (epochSeconds ~/ 10) * 10;
  }
  
  Future<http.Response> _fetchFromRestApi(String url) async {
    return await http.get(Uri.parse(url));
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
  
  RestApiConfig({
    required this.restApiUrl,
    required this.transformer,
    this.documentNode,
  });
}