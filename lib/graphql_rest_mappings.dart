import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/queries/getShareLink.graphql.dart';

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

Map<String, RestApiConfig> createGraphQLToRestMappings() {
  final mappings = <String, RestApiConfig>{};
  
  // Query mappings
  mappings['GetStations'] = RestApiConfig(
    restApiUrl: 'http://192.168.88.12:8080/api/v1/stations',
    transformer: _transformStationsData,
    documentNode: documentNodeQueryGetStations,
    urlBuilder: (_) => _addTimestampToUrl('http://192.168.88.12:8080/api/v1/stations'),
  );
  
  // Mutation mappings
  mappings['GetShareLink'] = RestApiConfig(
    restApiUrl: 'http://192.168.88.12:8080/api/v1/share-links/',
    transformer: _transformShareLinkData,
    documentNode: documentNodeMutationGetShareLink,
    urlBuilder: (variables) {
      final anonymousId = variables['anonymous_id'];
      final url = 'http://192.168.88.12:8080/api/v1/share-links/$anonymousId/';
      return _addTimestampToUrl(url);
    },
  );
  
  return mappings;
}

Map<String, dynamic> _transformStationsData(dynamic jsonData) {
  return jsonData['data'];
}

Map<String, dynamic> _transformShareLinkData(dynamic jsonData) {
  return {
    'get_share_link': jsonData['data'],
  };
}