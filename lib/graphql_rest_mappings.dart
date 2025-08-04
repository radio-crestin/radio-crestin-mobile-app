import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';

Map<String, RestApiConfig> createGraphQLToRestMappings() {
  return {
    'GetStations': RestApiConfig(
      restApiUrl: 'https://api.radiocrestin.ro/api/v1/stations',
      transformer: _transformStationsData,
      documentNode: documentNodeQueryGetStations,
    ),
    // Add more query mappings here as needed
    // 'OtherQuery': RestApiConfig(
    //   restApiUrl: 'https://api.example.com/endpoint',
    //   transformer: _transformOtherData,
    //   documentNode: documentNodeQueryOtherQuery,
    // ),
  };
}

Map<String, dynamic> _transformStationsData(dynamic jsonData) {
  return {
    'stations': jsonData['stations'] ?? [],
    'station_groups': jsonData['station_groups'] ?? [],
  };
}

// Add more transformer functions here as needed
// Map<String, dynamic> _transformOtherData(dynamic jsonData) {
//   return {
//     'field1': jsonData['field1'] ?? [],
//     'field2': jsonData['field2'] ?? {},
//   };
// }