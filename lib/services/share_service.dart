import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/queries/getShareLink.graphql.dart';

class ShareService {
  final GraphQLClient client;

  ShareService(this.client);

  Future<ShareLinkData?> getShareLink(String anonymousId) async {
    try {
      final result = await client.mutate(
        MutationOptions(
          document: documentNodeMutationGetShareLink,
          variables: {
            'anonymous_id': anonymousId,
          },
          fetchPolicy: FetchPolicy.noCache,
        ),
      );

      // Check for actual errors, not cache write errors
      if (result.hasException && result.data == null) {
        print('Error fetching share link: ${result.exception}');
        return null;
      }

      final data = result.data?['get_share_link'];
      if (data != null && data['share_link'] != null) {
        return ShareLinkData(
          shareId: data['share_link']['share_id'] ?? '',
          url: data['share_link']['url'] ?? '',
          shareMessage: data['share_link']['share_message'] ?? '',
          shareStationMessage: data['share_link']['share_station_message'] ?? '',
          visitCount: data['share_link']['visit_count'] ?? 0,
          createdAt: data['share_link']['created_at'] ?? '',
          isActive: data['share_link']['is_active'] ?? true,
          shareSectionMessage: data['share_link']['share_section_message'] ?? '',
          shareSectionTitle: data['share_link']['share_section_title'] ?? '',
        );
      }

      return null;
    } catch (e) {
      print('Error in getShareLink: $e');
      return null;
    }
  }
}

class ShareLinkData {
  final String shareId;
  final String url;
  final String shareMessage;
  final String shareStationMessage;
  final int visitCount;
  final String createdAt;
  final bool isActive;
  final String shareSectionMessage;
  final String shareSectionTitle;

  ShareLinkData({
    required this.shareId,
    required this.url,
    required this.shareMessage,
    required this.shareStationMessage,
    required this.visitCount,
    required this.createdAt,
    required this.isActive,
    required this.shareSectionMessage,
    required this.shareSectionTitle,
  });

  String generateShareUrl({String? stationSlug}) {
    final baseUrl = url;
    final shareParam = '?s=$shareId';
    
    if (stationSlug != null && stationSlug.isNotEmpty) {
      return '$baseUrl/$stationSlug$shareParam';
    }
    
    return '$baseUrl$shareParam';
  }
}