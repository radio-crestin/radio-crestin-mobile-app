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
        ),
      );

      if (result.hasException) {
        print('Error fetching share link: ${result.exception}');
        return null;
      }

      final data = result.data?['get_share_link'];
      if (data != null && data['share_link'] != null) {
        return ShareLinkData(
          shareId: data['share_link']['share_id'] ?? '',
          url: data['share_link']['url'] ?? '',
          shareMessage: data['share_link']['share_message'] ?? '',
          visitCount: data['share_link']['visit_count'] ?? 0,
          createdAt: data['share_link']['created_at'] ?? '',
          shareSectionMessage: data['share_section_message'] ?? '',
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
  final int visitCount;
  final String createdAt;
  final String shareSectionMessage;

  ShareLinkData({
    required this.shareId,
    required this.url,
    required this.shareMessage,
    required this.visitCount,
    required this.createdAt,
    required this.shareSectionMessage,
  });

  String generateShareUrl({String? stationSlug}) {
    final baseUrl = url;
    final shareParam = '?s=$shareId';
    
    if (stationSlug != null && stationSlug.isNotEmpty) {
      return '$baseUrl/station/$stationSlug$shareParam';
    }
    
    return '$baseUrl$shareParam';
  }
}