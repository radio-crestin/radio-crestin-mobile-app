import 'package:radio_crestin/services/share_service.dart';

class ShareUtils {
  static String formatShareMessage({
    required ShareLinkData shareLinkData,
    String? stationName,
    String? stationSlug,
    int? songId,
  }) {
    final shareUrl = shareLinkData.generateShareUrl(stationSlug: stationSlug, songId: songId);

    if (stationName != null) {
      return 'Te invit să asculți $stationName:\n$shareUrl';
    }

    return 'Instalează și tu aplicația Radio Creștin și ascultă peste 60 de stații de radio creștin:\n$shareUrl';
  }

  static String combineMessageWithUrl(String message, String url) {
    if (message.contains(url)) {
      return message;
    }
    return '$message\n$url';
  }

  /// Formats the share message with station and now-playing info.
  ///
  /// With song: "Te invit să asculți Radio X: (Song • Artist)\n<url>"
  /// Without song: "Te invit să asculți Radio X:\n<url>"
  /// Without station: falls back to message + url.
  static String formatMessageWithStation(
    String message,
    String url,
    String? stationName, {
    String? songName,
    String? songArtist,
  }) {
    if (stationName == null) {
      return combineMessageWithUrl(message, url);
    }

    final songInfo = _buildSongInfo(songName, songArtist);
    if (songInfo != null) {
      return 'Te invit să asculți $stationName ($songInfo):\n$url';
    }
    return 'Te invit să asculți $stationName:\n$url';
  }

  /// How many friends opened the user's invitation link, in Romanian.
  static String visitCountText(int count) {
    return switch (visitCountParts(count)) {
      (final friends, final rest) => '$friends$rest',
      null => 'Niciun prieten n-a deschis încă invitația ta',
    };
  }

  /// [visitCountText] split into who opened it and the rest, so the first
  /// part can stand out: `('24 de prieteni', ' au deschis invitația ta')`.
  /// Null when nobody did.
  ///
  /// Counts of 20 and up take "de" unless their last two digits are 01–19
  /// ("24 de prieteni", "101 prieteni", "120 de prieteni").
  static (String, String)? visitCountParts(int count) {
    if (count <= 0) return null;
    if (count == 1) return ('Un prieten', ' a deschis invitația ta');
    final lastTwo = count % 100;
    final de = count >= 20 && (lastTwo == 0 || lastTwo >= 20) ? 'de ' : '';
    return ('$count ${de}prieteni', ' au deschis invitația ta');
  }

  /// Builds "SongName • Artist" with graceful fallbacks, or null if nothing.
  static String? _buildSongInfo(String? songName, String? songArtist) {
    final parts = <String>[
      if (songName != null && songName.isNotEmpty) songName,
      if (songArtist != null && songArtist.isNotEmpty) songArtist,
    ];
    if (parts.isEmpty) return null;
    return parts.join(' • ');
  }
}
