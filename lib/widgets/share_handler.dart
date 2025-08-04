import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:radio_crestin/services/share_service.dart';

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
      // Check if shareMessage already contains the URL
      final messageContainsUrl = shareMessage.contains(shareUrl);
      
      final message = stationName != null 
        ? messageContainsUrl 
          ? '$shareMessage\n\nAscultă acum: $stationName'
          : '$shareMessage\n\nAscultă acum: $stationName\n$shareUrl'
        : messageContainsUrl
          ? shareMessage
          : '$shareMessage\n$shareUrl';

      await Share.share(
        message,
        subject: 'Radio Creștin - Stații radio creștine',
      );
    } catch (e) {
      _showCopyFallback(context, shareUrl, shareMessage);
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
      builder: (BuildContext dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.share_rounded,
                    color: Theme.of(context).primaryColor,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 16),
                
                // Title
                Text(
                  shareLinkData.shareSectionTitle.isNotEmpty 
                    ? shareLinkData.shareSectionTitle
                    : 'Distribuie aplicația',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                
                // Message
                Text(
                  shareLinkData.shareSectionMessage.isNotEmpty 
                    ? shareLinkData.shareSectionMessage
                    : 'Ajută la răspândirea Evangheliei prin intermediul radioului creștin.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                
                // Visitor count if available
                if (shareLinkData.visitCount > 0) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.people_outline,
                          size: 16,
                          color: Theme.of(context).primaryColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${shareLinkData.visitCount} ${shareLinkData.visitCount == 1 ? 'ascultător' : 'ascultători'} până acum',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                
                const SizedBox(height: 24),
                
                // Share buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildShareOption(
                      context: context,
                      icon: FontAwesomeIcons.whatsapp,
                      label: 'WhatsApp',
                      color: const Color(0xFF25D366),
                      onTap: () async {
                        Navigator.pop(dialogContext);
                        await _shareToWhatsApp(shareMessage, shareUrl);
                      },
                    ),
                    _buildShareOption(
                      context: context,
                      icon: FontAwesomeIcons.facebook,
                      label: 'Facebook',
                      color: const Color(0xFF1877F2),
                      onTap: () async {
                        Navigator.pop(dialogContext);
                        await _shareToFacebook(shareUrl);
                      },
                    ),
                    _buildShareOption(
                      context: context,
                      icon: Icons.more_horiz,
                      label: 'Altele',
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      onTap: () async {
                        Navigator.pop(dialogContext);
                        await _performShare(context, shareUrl, shareMessage, stationName);
                      },
                    ),
                  ],
                ),
                
                const SizedBox(height: 16),
                
                // Close button
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(
                    'Închide',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: color,
                size: 24,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _shareToWhatsApp(String message, String shareUrl) async {
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

  static void _showCopyFallback(
    BuildContext context, 
    String shareUrl, 
    String shareMessage,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Distribuie aplicația',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shareMessage.contains(shareUrl) 
                        ? shareMessage
                        : shareMessage,
                      style: TextStyle(
                        color: Colors.grey[700],
                        fontSize: 14,
                      ),
                    ),
                    if (!shareMessage.contains(shareUrl)) ...[
                      const SizedBox(height: 10),
                      Text(
                        shareUrl,
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final messageContainsUrl = shareMessage.contains(shareUrl);
                        final textToCopy = messageContainsUrl 
                          ? shareMessage 
                          : '$shareMessage\n$shareUrl';
                        Clipboard.setData(ClipboardData(text: textToCopy));
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Link copiat în clipboard!'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copiază link'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        final messageContainsUrl = shareMessage.contains(shareUrl);
                        final textToShare = messageContainsUrl 
                          ? shareMessage 
                          : '$shareMessage\n$shareUrl';
                        Share.share(textToShare);
                      },
                      icon: const Icon(Icons.share),
                      label: const Text('Distribuie'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }
}