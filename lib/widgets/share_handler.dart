import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/utils/share_utils.dart';

class ShareHandler {
  /// Shows the share dialog immediately. If [shareLinkData] is provided it
  /// renders right away; otherwise it shows a skeleton while [shareLinkLoader]
  /// fetches the data in the background.
  static Future<void> shareApp({
    required BuildContext context,
    required String shareUrl,
    required String shareMessage,
    String? stationName,
    String? songName,
    String? songArtist,
    int? songId,
    ShareLinkData? shareLinkData,
    Future<ShareLinkData?> Function()? shareLinkLoader,
    bool showDialog = false,
  }) async {
    if (showDialog) {
      await _showShareDialog(
        context,
        shareUrl,
        shareMessage,
        stationName,
        songName,
        songArtist,
        songId,
        shareLinkData,
        shareLinkLoader,
      );
    } else {
      await _performShare(context, shareUrl, shareMessage, stationName, songName: songName, songArtist: songArtist);
    }
  }

  static Future<void> _performShare(
    BuildContext context,
    String shareUrl,
    String shareMessage,
    String? stationName, {
    String? songName,
    String? songArtist,
  }) async {
    try {
      final message = ShareUtils.formatMessageWithStation(shareMessage, shareUrl, stationName, songName: songName, songArtist: songArtist);

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
    String? stationName,
    String? songName,
    String? songArtist,
    int? songId,
    ShareLinkData? initialData,
    Future<ShareLinkData?> Function()? loader,
  ) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.65),
      builder: (BuildContext context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: _ShareDialogContent(
            shareUrl: shareUrl,
            shareMessage: shareMessage,
            stationName: stationName,
            songName: songName,
            songArtist: songArtist,
            songId: songId,
            initialData: initialData,
            loader: loader,
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

/// Stateful dialog content that shows immediately and loads data in background.
class _ShareDialogContent extends StatefulWidget {
  final String shareUrl;
  final String shareMessage;
  final String? stationName;
  final String? songName;
  final String? songArtist;
  final int? songId;
  final ShareLinkData? initialData;
  final Future<ShareLinkData?> Function()? loader;

  const _ShareDialogContent({
    required this.shareUrl,
    required this.shareMessage,
    this.stationName,
    this.songName,
    this.songArtist,
    this.songId,
    this.initialData,
    this.loader,
  });

  @override
  State<_ShareDialogContent> createState() => _ShareDialogContentState();
}

class _ShareDialogContentState extends State<_ShareDialogContent> {
  ShareLinkData? _data;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _data = widget.initialData;
    _isLoading = _data == null;
    if (widget.loader != null) {
      _loadData();
    } else {
      _isLoading = false;
    }
  }

  Future<void> _loadData() async {
    try {
      final result = await widget.loader!();
      if (mounted && result != null) {
        setState(() {
          _data = result;
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String get _shareUrl {
    if (_data != null) {
      return _data!.generateShareUrl(
        stationSlug: widget.stationName != null ? _extractSlug() : null,
        songId: widget.songId,
      );
    }
    return widget.shareUrl;
  }

  String? _extractSlug() {
    // Extract slug from the initial shareUrl if it contains one
    final uri = Uri.tryParse(widget.shareUrl);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    return null;
  }

  String get _shareMessage {
    if (_data != null) {
      return ShareUtils.formatShareMessage(
        shareLinkData: _data!,
        stationName: widget.stationName,
        songId: widget.songId,
      );
    }
    return widget.shareMessage;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = isDark ? const Color(0xFFffc700) : const Color(0xFFFF6B35);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 8,
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF34131E) : const Color(0xFFFAF0F5),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDark
                ? const Color(0xFF220D15)
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
                  // Icon
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
                    _data?.shareSectionTitle.isNotEmpty == true
                        ? _data!.shareSectionTitle
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
                      _data?.shareSectionMessage.isNotEmpty == true
                          ? _data!.shareSectionMessage
                          : 'Ajută la răspândirea Evangheliei prin intermediul radioului creștin.',
                      style: TextStyle(
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.75),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),

                  // Visitor count (skeleton while loading)
                  const SizedBox(height: 20),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _isLoading
                        ? Container(
                            key: const ValueKey('skeleton'),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: accentColor.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Container(
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: accentColor.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Container(
                            key: const ValueKey('data'),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: accentColor.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.people_outline_rounded, size: 16, color: accentColor),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _visitCountText,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: accentColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),

                  const SizedBox(height: 20),

                  // Divider
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

                  // Share buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ShareHandler._buildShareOption(
                        context: context,
                        icon: FontAwesomeIcons.whatsapp,
                        label: 'WhatsApp',
                        color: const Color(0xFF25D366),
                        onTap: () async {
                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'share_whatsapp', 'station_name': widget.stationName, 'song_id': widget.songId});
                          Navigator.pop(context);
                          await ShareHandler.shareToWhatsApp(_shareMessage, _shareUrl, widget.stationName, songName: widget.songName, songArtist: widget.songArtist);
                        },
                      ),
                      const SizedBox(width: 10),
                      ShareHandler._buildShareOption(
                        context: context,
                        icon: FontAwesomeIcons.facebook,
                        label: 'Facebook',
                        color: const Color(0xFF1877F2),
                        onTap: () async {
                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'share_facebook', 'station_name': widget.stationName, 'song_id': widget.songId});
                          Navigator.pop(context);
                          await ShareHandler.shareToFacebook(_shareUrl);
                        },
                      ),
                      const SizedBox(width: 10),
                      ShareHandler._buildShareOption(
                        context: context,
                        icon: Platform.isIOS ? Icons.ios_share : Icons.share,
                        label: 'Share',
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                        onTap: () async {
                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'share_generic', 'station_name': widget.stationName, 'song_id': widget.songId});
                          Navigator.pop(context);
                          await ShareHandler._performShare(context, _shareUrl, _shareMessage, widget.stationName, songName: widget.songName, songArtist: widget.songArtist);
                        },
                      ),
                    ],
                  ),

                  // Share link with copy
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
                            _shareUrl,
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
                            AnalyticsService.instance.capture('button_clicked', {'button_name': 'copy_share_link', 'station_name': widget.stationName});
                            Clipboard.setData(ClipboardData(text: _shareUrl));
                            final overlay = Overlay.of(context);
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
                                      color: isDark ? Colors.white : Colors.black87,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      'Link copiat!',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: isDark ? Colors.black : Colors.white,
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
            // Close button
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
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _visitCountText {
    final count = _data?.visitCount ?? 0;
    if (count == 0) return 'Niciun prieten nu a accesat link-ul tău';
    if (count == 1) return '1 prieten a accesat invitația ta';
    return '$count prieteni au accesat invitația ta';
  }
}
