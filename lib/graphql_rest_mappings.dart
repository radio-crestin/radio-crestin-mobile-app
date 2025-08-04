import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/queries/getShareLink.graphql.dart';

Map<String, RestApiConfig> createGraphQLToRestMappings() {
  return {
    'GetStations': RestApiConfig(
      restApiUrl: 'http://192.168.88.12:8080/api/v1/stations',
      transformer: _transformStationsData,
      documentNode: documentNodeQueryGetStations,
    ),
    'GetShareLink': RestApiConfig(
      restApiUrl: 'http://192.168.88.12:8080/api/v1/share-links/',
      transformer: _transformShareLinkData,
      documentNode: documentNodeMutationGetShareLink,
      urlBuilder: (variables) {
        final anonymousId = variables['anonymous_id'];
        return 'http://192.168.88.12:8080/api/v1/share-links/$anonymousId/';
      },
    ),
  };
}

Map<String, dynamic> _transformStationsData(dynamic jsonData) {
  return jsonData['data'];
}

Map<String, dynamic> _transformShareLinkData(dynamic jsonData) {
  return {
    'get_share_link': jsonData['data'],
  };
}