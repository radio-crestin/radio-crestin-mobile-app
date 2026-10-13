import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:radio_crestin/utils/share_utils.dart';

/// Hands a share link to WhatsApp, Facebook or the system share sheet.
///
/// The in-app share sheet with all of these is `ShareSheet`.
class ShareHandler {
  /// Opens the system share sheet, anchored to [context]'s widget on iPad.
  static Future<void> shareApp({
    required BuildContext context,
    required String shareUrl,
    required String shareMessage,
    String? stationName,
    String? songName,
    String? songArtist,
  }) {
    return shareViaSystem(
      shareUrl: shareUrl,
      shareMessage: shareMessage,
      stationName: stationName,
      songName: songName,
      songArtist: songArtist,
      sharePositionOrigin: originOf(context),
    );
  }

  /// Opens the system share sheet.
  ///
  /// [sharePositionOrigin] is where the iPad share popover points to; see
  /// [originOf].
  static Future<void> shareViaSystem({
    required String shareUrl,
    required String shareMessage,
    String? stationName,
    String? songName,
    String? songArtist,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final message = ShareUtils.formatMessageWithStation(shareMessage, shareUrl, stationName, songName: songName, songArtist: songArtist);
      await Share.share(
        message,
        subject: 'Radio Creștin - Stații radio creștine',
        sharePositionOrigin: sharePositionOrigin,
      );
    } catch (e) {
      print('Error sharing: $e');
    }
  }

  /// The global bounds of [context]'s widget, or null once it is gone.
  ///
  /// Read it before closing the route the widget is in.
  static Rect? originOf(BuildContext context) {
    if (!context.mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static Future<void> shareToWhatsApp(String message, String shareUrl, String? stationName, {String? songName, String? songArtist}) async {
    final formattedMessage = ShareUtils.formatMessageWithStation(message, shareUrl, stationName, songName: songName, songArtist: songArtist);
    final encodedMessage = Uri.encodeComponent(formattedMessage);

    // Try native app, fall back to web URL
    try {
      final appUri = Uri.parse('whatsapp://send?text=$encodedMessage');
      if (await launchUrl(appUri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}

    try {
      final webUri = Uri.parse('https://wa.me/?text=$encodedMessage');
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  static Future<void> shareToFacebook(String shareUrl) async {
    final encodedUrl = Uri.encodeComponent(shareUrl);

    // Try native app
    try {
      if (Platform.isIOS) {
        final appUri = Uri.parse('fb://facewebmodal/f?href=${Uri.encodeComponent(shareUrl)}');
        if (await launchUrl(appUri, mode: LaunchMode.externalApplication)) return;
      }
    } catch (_) {}

    // Fall back to web
    try {
      final webUri = Uri.parse('https://www.facebook.com/sharer/sharer.php?u=$encodedUrl');
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}
