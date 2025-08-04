import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
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
  State<SharePromotionCard> createState() => _SharePromotionCardState();
}

class _SharePromotionCardState extends State<SharePromotionCard> {
  ShareLinkData? _shareLinkData;
  bool _isLoading = true;
  String? _anonymousId;

  @override
  void initState() {
    super.initState();
    _loadShareLink();
  }

  Future<void> _loadShareLink() async {
    try {
      final prefs = await SharedPreferences.getInstance();
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
      
      if (mounted) {
        setState(() {
          _shareLinkData = data;
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
              children: [
                Row(
                  children: [
                    Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.share_rounded,
                  color: Theme.of(context).primaryColor,
                  size: 24,
                ),
              ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _shareLinkData?.shareSectionTitle ?? 'Distribuie aplicația',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
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
                  if (_shareLinkData != null && _shareLinkData!.visitCount > 0) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 14,
                            color: Theme.of(context).primaryColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${_shareLinkData!.visitCount} ${_shareLinkData!.visitCount == 1 ? 'ascultător' : 'ascultători'}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _buildShareButton(
                context: context,
                icon: FontAwesomeIcons.whatsapp,
                color: const Color(0xFF25D366),
                onTap: () => _shareToWhatsApp(),
              ),
              const SizedBox(width: 6),
              _buildShareButton(
                context: context,
                icon: FontAwesomeIcons.facebook,
                color: const Color(0xFF1877F2),
                onTap: () => _shareToFacebook(),
              ),
              const SizedBox(width: 6),
              _buildShareButton(
                context: context,
                icon: Icons.share_rounded,
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
            top: 8,
            right: 8,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _handleClose,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(6),
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
    final iconToUse = icon ?? iconData ?? Icons.share;
    
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
    final shareUrl = _shareLinkData!.generateShareUrl(
      stationSlug: widget.currentStationName != null ? widget.currentStationSlug : null,
    );
    
    String messageTemplate;
    if (widget.currentStationName != null) {
      messageTemplate = _shareLinkData!.shareStationMessage
        .replaceAll('{station_name}', widget.currentStationName!)
        .replaceAll('{url}', shareUrl);
    } else {
      messageTemplate = _shareLinkData!.shareMessage
        .replaceAll('{url}', shareUrl);
    }
    
    return messageTemplate;
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
    // Call the onClose callback if provided
    if (widget.onClose != null) {
      widget.onClose!();
    }
    
    // Navigate to settings page with a delay
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => SettingsPage()),
      );
      
      // Add a small delay to allow the settings page to load before toggling
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }
}