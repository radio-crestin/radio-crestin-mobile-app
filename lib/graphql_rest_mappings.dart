import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/queries/getShareLink.graphql.dart';
import 'package:radio_crestin/utils/api_utils.dart';

Map<String, RestApiConfig> createGraphQLToRestMappings() {
  final mappings = <String, RestApiConfig>{};

  // Query mappings - uses live timestamp; HLS offset handled by metadata polling
  mappings['GetStations'] = RestApiConfig(
    restApiUrl: CONSTANTS.STATIONS_URL,
    transformer: _transformStationsData,
    documentNode: documentNodeQueryGetStations,
    urlBuilder: (_) => addTimestampToUrl(CONSTANTS.STATIONS_URL),
  );

  // Mutation mappings
  mappings['GetShareLink'] = RestApiConfig(
    restApiUrl: '${CONSTANTS.SHARE_LINKS_URL}/',
    transformer: _transformShareLinkData,
    documentNode: documentNodeMutationGetShareLink,
    urlBuilder: (variables) {
      final anonymousId = variables['anonymous_id'];
      return addTimestampToUrl('${CONSTANTS.SHARE_LINKS_URL}/$anonymousId/');
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
