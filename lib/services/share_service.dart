import 'dart:convert';

import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/queries/getShareLink.graphql.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      ).timeout(const Duration(seconds: 5));

      // Check for actual errors, not cache write errors
      if (result.hasException && result.data == null) {
        print('Error fetching share link: ${result.exception}');
        return null;
      }

      final shareLink = result.data?['get_share_link']?['share_link'];
      if (shareLink is Map) {
        final data =
            ShareLinkData.fromJson(Map<String, dynamic>.from(shareLink));
        await ShareLinkCache.save(data);
        return data;
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

  /// Reads the API's `share_link` object, the shape [toJson] writes back.
  factory ShareLinkData.fromJson(Map<String, dynamic> json) => ShareLinkData(
        shareId: json['share_id'] as String? ?? '',
        url: json['url'] as String? ?? '',
        shareMessage: json['share_message'] as String? ?? '',
        shareStationMessage: json['share_station_message'] as String? ?? '',
        visitCount: json['visit_count'] as int? ?? 0,
        createdAt: json['created_at'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? true,
        shareSectionMessage: json['share_section_message'] as String? ?? '',
        shareSectionTitle: json['share_section_title'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'share_id': shareId,
        'url': url,
        'share_message': shareMessage,
        'share_station_message': shareStationMessage,
        'visit_count': visitCount,
        'created_at': createdAt,
        'is_active': isActive,
        'share_section_message': shareSectionMessage,
        'share_section_title': shareSectionTitle,
      };

  String generateShareUrl({String? stationSlug, int? songId}) {
    final baseUrl = url;
    final params = <String>['s=$shareId'];
    if (songId != null && songId > 0) {
      params.add('song=$songId');
    }
    final query = '?${params.join('&')}';

    if (stationSlug != null && stationSlug.isNotEmpty) {
      return '$baseUrl/$stationSlug$query';
    }

    return '$baseUrl$query';
  }
}

/// The last share link the API returned, kept on disk.
///
/// The share sheet opens with it, so the visit count and the personal link
/// show at once while a fresh copy loads, instead of a placeholder.
class ShareLinkCache {
  ShareLinkCache._();

  static const String _key = 'share_link_cache';

  /// The cached link, or null when none was saved or it can't be read.
  static ShareLinkData? read() {
    final raw = _prefs?.getString(_key);
    if (raw == null) return null;
    try {
      return ShareLinkData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(ShareLinkData data) async {
    try {
      await _prefs?.setString(_key, jsonEncode(data.toJson()));
    } catch (_) {
      // Best effort: without a cache the sheet just shows a placeholder.
    }
  }

  /// The app's preferences; missing in engines and tests that never
  /// registered them.
  static SharedPreferences? get _prefs {
    final getIt = GetIt.instance;
    return getIt.isRegistered<SharedPreferences>()
        ? getIt<SharedPreferences>()
        : null;
  }
}
