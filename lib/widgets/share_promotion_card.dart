import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class SharePromotionCard extends StatefulWidget {
  final GraphQLClient client;
  final String? currentStationSlug;
  final String? currentStationName;
  final VoidCallback? onClose;

  const SharePromotionCard({
    Key? key,
    required this.client,
    this.currentStationSlug,
    this.currentStationName,
    this.onClose,
  }) : super(key: key);

  @override
  State<SharePromotionCard> createState() => SharePromotionCardState();
}

class SharePromotionCardState extends State<SharePromotionCard> {
  // Color constants
  static Color _accentColor(BuildContext context) {
    // Use orange for light theme, keep yellow for dark theme
    return Theme.of(context).brightness == Brightness.light
        ? const Color(0xFFFF6B35) // Orange for light theme
        : const Color(0xFFffc700); // Yellow for dark theme
  }
  static const Color _whatsappColor = Color(0xFF25D366);
  static const Color _facebookColor = Color(0xFF1877F2);
  
  ShareLinkData? _shareLinkData;
  bool _isLoading = true;
  String? _anonymousId;

  @override
  void initState() {
    super.initState();
    _loadShareLink();
  }

  Future<void> refreshShareLink() async {
    setState(() {
      _isLoading = true;
    });
    await _loadShareLink();
  }

  static const String _cacheKey = 'share_link_cache';

  Future<void> _loadShareLink() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load cached data first to avoid layout shift
      final cachedJson = prefs.getString(_cacheKey);
      if (cachedJson != null) {
        try {
          final cached = json.decode(cachedJson) as Map<String, dynamic>;
          _shareLinkData = ShareLinkData(
            shareId: cached['shareId'] ?? '',
            url: cached['url'] ?? '',
            shareMessage: cached['shareMessage'] ?? '',
            shareStationMessage: cached['shareStationMessage'] ?? '',
            visitCount: cached['visitCount'] ?? 0,
            createdAt: cached['createdAt'] ?? '',
            isActive: cached['isActive'] ?? true,
            shareSectionMessage: cached['shareSectionMessage'] ?? '',
            shareSectionTitle: cached['shareSectionTitle'] ?? '',
          );
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
          }
        } catch (_) {}
      }

      _anonymousId = prefs.getString('device_id');

      if (_anonymousId == null) {
        // Get device-specific ID
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          _anonymousId = androidInfo.id; // Use Android ID
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          _anonymousId = iosInfo.identifierForVendor; // Use Vendor ID for iOS
        } else {
          // Fallback for other platforms
          _anonymousId = DateTime.now().millisecondsSinceEpoch.toString();
        }

        // Save the device ID for future use
        if (_anonymousId != null) {
          await prefs.setString('device_id', _anonymousId!);
        }
      }

      final shareService = ShareService(widget.client);
      final data = await shareService.getShareLink(_anonymousId!);

      if (data != null) {
        // Cache the fresh data
        await prefs.setString(_cacheKey, json.encode({
          'shareId': data.shareId,
          'url': data.url,
          'shareMessage': data.shareMessage,
          'shareStationMessage': data.shareStationMessage,
          'visitCount': data.visitCount,
          'createdAt': data.createdAt,
          'isActive': data.isActive,
          'shareSectionMessage': data.shareSectionMessage,
          'shareSectionTitle': data.shareSectionTitle,
        }));
      }

      if (mounted) {
        setState(() {
          _shareLinkData = data ?? _shareLinkData;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading share link: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).primaryColor.withOpacity(0.1),
              Theme.of(context).primaryColor.withOpacity(0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Theme.of(context).primaryColor.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_shareLinkData == null) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).primaryColor.withOpacity(0.1),
            Theme.of(context).primaryColor.withOpacity(0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Theme.of(context).primaryColor.withOpacity(0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.people_outline_rounded,
                      color: Theme.of(context).primaryColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _shareLinkData?.shareSectionTitle ?? 'Distribuie aplicația',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _shareLinkData!.shareSectionMessage.isNotEmpty
                    ? _shareLinkData!.shareSectionMessage
                    : 'Ajută la răspândirea Evangheliei prin intermediul radioului creștin. Apasă aici pentru a trimite această aplicație prietenilor tăi.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.85),
                    height: 1.4,
                  ),
                ),
                if (_shareLinkData != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _accentColor(context).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.people_outline_rounded,
                          size: 16,
                          color: _accentColor(context),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _shareLinkData!.visitCount == 0
                                ? 'Niciun prieten nu a accesat link-ul tău'
                                : _shareLinkData!.visitCount == 1
                                    ? '1 prieten a accesat invitația ta'
                                    : '${_shareLinkData!.visitCount} prieteni au accesat invitația ta',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _accentColor(context),
                            ),
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              _buildShareButton(
                context: context,
                icon: FontAwesomeIcons.whatsapp,
                color: _whatsappColor,
                onTap: () => _shareToWhatsApp(),
              ),
              const SizedBox(width: 6),
              _buildShareButton(
                context: context,
                icon: FontAwesomeIcons.facebook,
                color: _facebookColor,
                onTap: () => _shareToFacebook(),
              ),
              const SizedBox(width: 6),
              _buildShareButton(
                context: context,
                icon: Icons.people_outline_rounded,
                label: 'Distribuie',
                color: Theme.of(context).primaryColor,
                onTap: () => _shareGeneric(context),
              ),
                ],
              ),
            ],
          ),
          ),
          // Close X button
          Positioned(
            top: 12,
            right: 12,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _handleClose,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShareButton({
    required BuildContext context,
    IconData? icon,
    IconData? iconData,
    String? label,
    required Color color,
    required VoidCallback onTap,
  }) {
    final iconToUse = icon ?? iconData ?? Icons.people_outline_rounded;
    
    if (label != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: color.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconToUse, size: 20, color: color),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(iconToUse, size: 24, color: color),
        ),
      ),
    );
  }

  String _getShareMessage() {
    return ShareUtils.formatShareMessage(
      shareLinkData: _shareLinkData!,
      stationName: widget.currentStationName,
      stationSlug: widget.currentStationSlug,
    );
  }

  String _getShareUrl() {
    return _shareLinkData!.generateShareUrl(
      stationSlug: widget.currentStationName != null ? widget.currentStationSlug : null,
    );
  }

  void _shareToFacebook() async {
    final shareUrl = _getShareUrl();
    final encodedUrl = Uri.encodeComponent(shareUrl);
    final facebookUrl = 'https://www.facebook.com/sharer/sharer.php?u=$encodedUrl';
    
    if (await canLaunchUrl(Uri.parse(facebookUrl))) {
      await launchUrl(Uri.parse(facebookUrl), mode: LaunchMode.externalApplication);
    } else {
      _shareGeneric(context);
    }
  }

  void _shareToWhatsApp() async {
    final message = _getShareMessage();
    final encodedMessage = Uri.encodeComponent(message);
    
    // Try WhatsApp app first (allows contact selection)
    final whatsappAppUrl = 'whatsapp://send?text=$encodedMessage';
    
    // Fallback to WhatsApp Web
    final whatsappWebUrl = 'https://wa.me/?text=$encodedMessage';
    
    try {
      // First try to open WhatsApp app which allows contact/group selection
      if (await canLaunchUrl(Uri.parse(whatsappAppUrl))) {
        await launchUrl(
          Uri.parse(whatsappAppUrl), 
          mode: LaunchMode.externalApplication,
        );
      } else if (await canLaunchUrl(Uri.parse(whatsappWebUrl))) {
        // Fallback to WhatsApp Web
        await launchUrl(
          Uri.parse(whatsappWebUrl), 
          mode: LaunchMode.externalApplication,
        );
      } else {
        // Final fallback to generic share
        _shareGeneric(context);
      }
    } catch (e) {
      _shareGeneric(context);
    }
  }

  void _shareGeneric(BuildContext context) {
    final shareUrl = _getShareUrl();
    final shareMessage = _getShareMessage();
    
    ShareHandler.shareApp(
      context: context,
      shareUrl: shareUrl,
      shareMessage: shareMessage,
    );
  }

  Future<void> _handleClose() async {
    // Call the onClose callback if provided (this hides the card immediately)
    if (widget.onClose != null) {
      widget.onClose!();
    }
  }
}