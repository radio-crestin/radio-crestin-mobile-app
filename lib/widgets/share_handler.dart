import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/utils/share_utils.dart';

class ShareHandler {
  static Future<void> shareApp({
    required BuildContext context,
    required String shareUrl,
    required String shareMessage,
    String? stationName,
    ShareLinkData? shareLinkData,
    bool showDialog = false,
  }) async {
    // If showDialog is true or shareLinkData is provided, show the share dialog first
    if (showDialog && shareLinkData != null) {
      await _showShareDialog(context, shareUrl, shareMessage, shareLinkData, stationName);
    } else {
      // Direct share without dialog
      await _performShare(context, shareUrl, shareMessage, stationName);
    }
  }

  static Future<void> _performShare(
    BuildContext context,
    String shareUrl,
    String shareMessage,
    String? stationName,
  ) async {
    try {
      final message = ShareUtils.formatMessageWithStation(shareMessage, shareUrl, stationName);

      final box = context.findRenderObject() as RenderBox?;
      final sharePositionOrigin = box != null
          ? box.localToGlobal(Offset.zero) & box.size
          : null;

      await Share.share(
        message,
        subject: 'Radio Creștin - Stații radio creștine',
        sharePositionOrigin: sharePositionOrigin,
      );
    } catch (e) {
      print('Error sharing: $e');
    }
  }

  static Future<void> _showShareDialog(
    BuildContext context,
    String shareUrl,
    String shareMessage,
    ShareLinkData shareLinkData,
    String? stationName,
  ) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          elevation: 8,
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark 
                  ? const Color(0xFF34131E) // Dark background
                  : const Color(0xFFFAF0F5), // Light wine red tinted background
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Theme.of(context).brightness == Brightness.dark 
                    ? const Color(0xFF220D15) // Darker version of #34131E
                    : Theme.of(context).primaryColor.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon with gradient background
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Theme.of(context).primaryColor.withOpacity(0.2),
                              Theme.of(context).primaryColor.withOpacity(0.1),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          Icons.share_rounded,
                          color: Theme.of(context).primaryColor,
                          size: 36,
                        ),
                      ),
                      const SizedBox(height: 20),
                      
                      // Title
                      Text(
                        shareLinkData.shareSectionTitle.isNotEmpty 
                          ? shareLinkData.shareSectionTitle
                          : 'Distribuie aplicația',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      
                      // Message
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          shareLinkData.shareSectionMessage.isNotEmpty 
                            ? shareLinkData.shareSectionMessage
                            : 'Ajută la răspândirea Evangheliei prin intermediul radioului creștin.',
                          style: TextStyle(
                            fontSize: 15,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.75),
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      
                      // Visitor count
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: (Theme.of(context).brightness == Brightness.light
                              ? const Color(0xFFFF6B35) // Orange for light theme
                              : const Color(0xFFffc700)).withOpacity(0.12), // Yellow for dark theme
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: (Theme.of(context).brightness == Brightness.light
                                ? const Color(0xFFFF6B35)
                                : const Color(0xFFffc700)).withOpacity(0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.people_outline_rounded,
                              size: 16,
                              color: Theme.of(context).brightness == Brightness.light
                                  ? const Color(0xFFFF6B35) // Orange for light theme
                                  : const Color(0xFFffc700), // Yellow for dark theme
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                shareLinkData.visitCount == 0
                                    ? 'Niciun prieten nu a accesat link-ul tău'
                                    : shareLinkData.visitCount == 1
                                        ? '1 prieten a accesat invitația ta'
                                        : '${shareLinkData.visitCount} prieteni au accesat invitația ta',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).brightness == Brightness.light
                                      ? const Color(0xFFFF6B35) // Orange for light theme
                                      : const Color(0xFFffc700), // Yellow for dark theme
                                ),
                                textAlign: TextAlign.left,
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // Divider with text
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 1,
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'distribuie',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Container(
                              height: 1,
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1),
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // Share buttons grid
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildShareOption(
                            context: context,
                            icon: FontAwesomeIcons.whatsapp,
                            label: 'WhatsApp',
                            color: const Color(0xFF25D366),
                            onTap: () async {
                              Navigator.pop(context);
                              await _shareToWhatsApp(shareMessage, shareUrl);
                            },
                          ),
                          const SizedBox(width: 10),
                          _buildShareOption(
                            context: context,
                            icon: FontAwesomeIcons.facebook,
                            label: 'Facebook',
                            color: const Color(0xFF1877F2),
                            onTap: () async {
                              Navigator.pop(context);
                              await _shareToFacebook(shareUrl);
                            },
                          ),
                          const SizedBox(width: 10),
                          _buildShareOption(
                            context: context,
                            icon: Platform.isIOS ? Icons.ios_share : Icons.share,
                            label: 'Share',
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                            onTap: () async {
                              Navigator.pop(context);
                              await _performShare(context, shareUrl, shareMessage, stationName);
                            },
                          ),
                        ],
                      ),
                      
                      // Share link with copy button
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                shareUrl,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: shareUrl));
                                // Show custom overlay toast
                                final overlay = Overlay.of(context);
                                final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
                                final overlayEntry = OverlayEntry(
                                  builder: (context) => Positioned(
                                    bottom: MediaQuery.of(context).size.height * 0.1,
                                    left: MediaQuery.of(context).size.width * 0.25,
                                    right: MediaQuery.of(context).size.width * 0.25,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                        decoration: BoxDecoration(
                                          color: isDarkTheme ? Colors.white : Colors.black87,
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Text(
                                          'Link copiat!',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: isDarkTheme ? Colors.black : Colors.white,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                                overlay.insert(overlayEntry);
                                Future.delayed(const Duration(seconds: 2), () {
                                  overlayEntry.remove();
                                });
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).primaryColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.copy,
                                  size: 16,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // X close button in top-right corner
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.05),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close,
                        size: 20,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                    splashRadius: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _buildShareOption({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 75,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: color.withOpacity(0.2),
                    width: 1,
                  ),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: 20,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _shareToWhatsApp(String message, String shareUrl) async {
    // Message already contains the URL from ShareUtils.formatShareMessage
    final encodedMessage = Uri.encodeComponent(message);
    final whatsappAppUrl = 'whatsapp://send?text=$encodedMessage';
    final whatsappWebUrl = 'https://wa.me/?text=$encodedMessage';
    
    try {
      if (await canLaunchUrl(Uri.parse(whatsappAppUrl))) {
        await launchUrl(
          Uri.parse(whatsappAppUrl), 
          mode: LaunchMode.externalApplication,
        );
      } else if (await canLaunchUrl(Uri.parse(whatsappWebUrl))) {
        await launchUrl(
          Uri.parse(whatsappWebUrl), 
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (e) {
      // Silently fail
    }
  }

  static Future<void> _shareToFacebook(String shareUrl) async {
    final encodedUrl = Uri.encodeComponent(shareUrl);
    final facebookUrl = 'https://www.facebook.com/sharer/sharer.php?u=$encodedUrl';
    
    try {
      if (await canLaunchUrl(Uri.parse(facebookUrl))) {
        await launchUrl(Uri.parse(facebookUrl), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      // Silently fail
    }
  }
}