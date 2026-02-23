import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/queries/getShareLink.graphql.dart';

String _addTimestampToUrl(String url, {Duration offset = Duration.zero}) {
  final timestamp = _getRoundedTimestamp(offset: offset);
  final uri = Uri.parse(url);
  final queryParams = Map<String, String>.from(uri.queryParameters);
  queryParams['_t'] = timestamp.toString();

  return uri.replace(queryParameters: queryParams).toString();
}

int _getRoundedTimestamp({Duration offset = Duration.zero}) {
  final now = DateTime.now().subtract(offset);
  final epochSeconds = now.millisecondsSinceEpoch ~/ 1000;
  // Round to nearest 10 seconds
  return (epochSeconds ~/ 10) * 10;
}

Map<String, RestApiConfig> createGraphQLToRestMappings() {
  final mappings = <String, RestApiConfig>{};
  
  // Query mappings
  mappings['GetStations'] = RestApiConfig(
    restApiUrl: CONSTANTS.GRAPHQL_ENDPOINT.replaceAll("/v1/graphql", "/api/v1/stations"),
    transformer: _transformStationsData,
    documentNode: documentNodeQueryGetStations,
    urlBuilder: (_) => _addTimestampToUrl(
      CONSTANTS.GRAPHQL_ENDPOINT.replaceAll("/v1/graphql", "/api/v1/stations"),
      offset: SeekModeManager.currentOffset,
    ),
  );
  
  // Mutation mappings
  mappings['GetShareLink'] = RestApiConfig(
    restApiUrl: CONSTANTS.GRAPHQL_ENDPOINT.replaceAll("/v1/graphql", "/api/v1/share-links/"),
    transformer: _transformShareLinkData,
    documentNode: documentNodeMutationGetShareLink,
    urlBuilder: (variables) {
      final anonymousId = variables['anonymous_id'];
      final url = CONSTANTS.GRAPHQL_ENDPOINT.replaceAll("/v1/graphql", '/api/v1/share-links/$anonymousId/');
      return _addTimestampToUrl(url);
    },
  );
  
  return mappings;
}

Map<String, dynamic> _transformStationsData(dynamic jsonData) {
  return jsonData['data'];
}

Map<String, dynamic> _transformShareLinkData(dynamic jsonData) {
  return jsonData['data'];
}