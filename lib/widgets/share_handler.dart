import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

class ShareHandler {
  static Future<void> shareApp({
    required BuildContext context,
    required String shareUrl,
    required String shareMessage,
    String? stationName,
  }) async {
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