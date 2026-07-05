import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/queries/getShareLink.graphql.dart';
import 'package:radio_crestin/utils/api_utils.dart';

/// Stores reviews_stats extracted from the REST /stations response.
/// Keyed by station ID. Populated during the REST-to-GraphQL transform.
/// StationDataService reads this when creating Station objects.
final Map<int, ({double averageRating, int numberOfReviews})> reviewsStatsCache = {};

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

/// Sideloads each station's `reviews_stats` into [reviewsStatsCache] before
/// GraphQL parsing discards the field. Shared by the GetStations REST transform
/// and the private-stations fetch so both populate the cache identically.
void sideloadReviewsStats(List<dynamic>? stationsList) {
  if (stationsList == null) return;
  for (final station in stationsList) {
    if (station is Map<String, dynamic>) {
      final id = station['id'] as int?;
      final stats = station['reviews_stats'] as Map<String, dynamic>?;
      if (id != null && stats != null) {
        reviewsStatsCache[id] = (
          averageRating: (stats['average_rating'] as num?)?.toDouble() ?? 0,
          numberOfReviews: (stats['number_of_reviews'] as num?)?.toInt() ?? 0,
        );
      }
    }
  }
}

Map<String, dynamic> _transformStationsData(dynamic jsonData) {
  // Extract reviews_stats from REST response before GraphQL parsing discards it
  sideloadReviewsStats(jsonData['data']?['stations'] as List?);
  return jsonData['data'];
}

Map<String, dynamic> _transformShareLinkData(dynamic jsonData) {
  return jsonData['data'];
}
