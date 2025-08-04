import 'package:radio_crestin/services/share_service.dart';

class ShareUtils {
  static String formatShareMessage({
    required ShareLinkData shareLinkData,
    String? stationName,
    String? stationSlug,
  }) {
    final shareUrl = shareLinkData.generateShareUrl(stationSlug: stationSlug);
    
    if (stationName != null && shareLinkData.shareStationMessage.isNotEmpty) {
      return shareLinkData.shareStationMessage
          .replaceAll('{station_name}', stationName)
          .replaceAll('{url}', shareUrl);
    }
    
    if (shareLinkData.shareMessage.isNotEmpty) {
      return shareLinkData.shareMessage
          .replaceAll('{url}', shareUrl);
    }
    
    return 'Ascultă posturile de radio creștine din România și Internațional\n$shareUrl';
  }
  
  static String combineMessageWithUrl(String message, String url) {
    if (message.contains(url)) {
      return message;
    }
    return '$message\n$url';
  }
  
  static String formatMessageWithStation(String message, String url, String? stationName) {
    if (stationName == null) {
      return combineMessageWithUrl(message, url);
    }
    
    if (message.contains(url)) {
      return '$message\n\nAscultă acum: $stationName';
    }
    
    return '$message\n\nAscultă acum: $stationName\n$url';
  }
}