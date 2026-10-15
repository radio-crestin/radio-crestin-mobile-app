import 'dart:io';

import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:radio_crestin/services/analytics_service.dart';

const Color _whatsAppGreen = Color(0xFF25D366);
const Color _facebookBlue = Color(0xFF1877F2);

/// The home page card that asks the listener to share the app.
///
/// A plain surface with one accent: WhatsApp and Facebook are round neutral
/// buttons, and the system share sheet is the card's only filled button.
class SharePromotionCard extends StatefulWidget {
  final GraphQLClient client;
  final String? currentStationSlug;
  final String? currentStationName;
  final VoidCallback? onClose;

  const SharePromotionCard({
    super.key,
    required this.client,
    this.currentStationSlug,
    this.currentStationName,
    this.onClose,
  });

  @override
  State<SharePromotionCard> createState() => SharePromotionCardState();
}

class SharePromotionCardState extends State<SharePromotionCard> {
  ShareLinkData? _shareLinkData;
  String? _anonymousId;

  @override
  void initState() {
    super.initState();
    // The last link fetched draws the card on its first frame, so the card
    // keeps its size when the fresh one arrives instead of moving the
    // stations below it.
    _shareLinkData = ShareLinkCache.read();
    _loadShareLink();
  }

  /// Fetches a fresh link; the card keeps showing the current one meanwhile.
  Future<void> refreshShareLink() => _loadShareLink();

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

      // getShareLink also saves the link to ShareLinkCache.
      final shareService = ShareService(widget.client);
      final data = await shareService.getShareLink(_anonymousId!);

      if (mounted && data != null) {
        setState(() {
          _shareLinkData = data;
        });
      }
    } catch (e) {
      print('Error loading share link: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _shareLinkData;
    if (data == null) {
      return const SizedBox.shrink();
    }
    final palette = _CardPalette.of(Theme.of(context));

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.edge),
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(
                  title: data.shareSectionTitle.isNotEmpty
                      ? data.shareSectionTitle
                      : 'Distribuie aplicația',
                  palette: palette,
                ),
                const SizedBox(height: 10),
                Text(
                  data.shareSectionMessage.isNotEmpty
                      ? data.shareSectionMessage
                      : 'Ajută la răspândirea Evangheliei prin intermediul '
                          'radioului creștin. Apasă aici pentru a trimite '
                          'această aplicație prietenilor tăi.',
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: palette.body,
                  ),
                ),
                const SizedBox(height: 10),
                _VisitCount(count: data.visitCount, palette: palette),
                const SizedBox(height: 14),
                _ShareActions(
                  palette: palette,
                  onWhatsApp: () {
                    AnalyticsService.instance.capture('button_clicked',
                        {'button_name': 'promo_share_whatsapp'});
                    _shareToWhatsApp();
                  },
                  onFacebook: () {
                    AnalyticsService.instance.capture('button_clicked',
                        {'button_name': 'promo_share_facebook'});
                    _shareToFacebook();
                  },
                  onShare: (buttonContext) {
                    AnalyticsService.instance.capture('button_clicked',
                        {'button_name': 'promo_share_generic'});
                    _shareGeneric(buttonContext);
                  },
                ),
              ],
            ),
          ),
          // Centred on the title row.
          Positioned(
            top: 4,
            right: 2,
            child: _CloseButton(
              palette: palette,
              onTap: () {
                AnalyticsService.instance.capture('button_clicked',
                    {'button_name': 'promo_card_close'});
                _handleClose();
              },
            ),
          ),
        ],
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
    await ShareHandler.shareToFacebook(shareUrl);
  }

  void _shareToWhatsApp() async {
    final message = _getShareMessage();
    final shareUrl = _getShareUrl();
    await ShareHandler.shareToWhatsApp(message, shareUrl, widget.currentStationName);
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

/// The card's colors for the current theme.
@immutable
class _CardPalette {
  const _CardPalette({
    required this.isApple,
    required this.surface,
    required this.edge,
    required this.shadow,
    required this.text,
    required this.body,
    required this.secondary,
    required this.chip,
    required this.closeFill,
    required this.closeIcon,
  });

  factory _CardPalette.of(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final onSurface = theme.colorScheme.onSurface;
    final ink = isDark ? Colors.white : Colors.black;
    return _CardPalette(
      isApple: theme.platform == TargetPlatform.iOS ||
          theme.platform == TargetPlatform.macOS,
      surface: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      edge: ink.withValues(alpha: 0.08),
      shadow: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
      text: onSurface,
      body: onSurface.withValues(alpha: 0.78),
      secondary: onSurface.withValues(alpha: 0.62),
      chip: ink.withValues(alpha: isDark ? 0.08 : 0.05),
      closeFill: ink.withValues(alpha: isDark ? 0.06 : 0.04),
      closeIcon: onSurface.withValues(alpha: 0.45),
    );
  }

  /// iOS and macOS get the iOS share icon, the rest the Material one.
  final bool isApple;
  final Color surface;
  final Color edge;
  final Color shadow;
  final Color text;

  /// The message under the title.
  final Color body;

  /// The visit count.
  final Color secondary;

  /// The WhatsApp and Facebook circles.
  final Color chip;
  final Color closeFill;
  final Color closeIcon;
}

/// The people icon in the brand pink, beside the title.
class _Header extends StatelessWidget {
  const _Header({required this.title, required this.palette});

  final String title;
  final _CardPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.people_outline_rounded,
          size: 20,
          color: AppColors.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              height: 1.3,
              color: palette.text,
            ),
          ),
        ),
        // Keeps the title clear of the close button, which reaches 18 px
        // past the card's padding, so the usual title still fits on one
        // line on 390 pt wide phones.
        const SizedBox(width: 24),
      ],
    );
  }
}

/// How many friends opened the link, as quiet secondary text.
class _VisitCount extends StatelessWidget {
  const _VisitCount({required this.count, required this.palette});

  final int count;
  final _CardPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.visibility_outlined, size: 14, color: palette.secondary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            ShareUtils.visitCountText(count),
            style: TextStyle(fontSize: 12.5, color: palette.secondary),
          ),
        ),
      ],
    );
  }
}

/// WhatsApp and Facebook as round buttons, then "Distribuie link-ul", which
/// opens the system share sheet.
class _ShareActions extends StatelessWidget {
  const _ShareActions({
    required this.palette,
    required this.onWhatsApp,
    required this.onFacebook,
    required this.onShare,
  });

  final _CardPalette palette;
  final VoidCallback onWhatsApp;
  final VoidCallback onFacebook;

  /// Gets the button's own context, so the iPad share popover points at it.
  final ValueChanged<BuildContext> onShare;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _RoundShareButton(
          label: 'Trimite pe WhatsApp',
          fill: palette.chip,
          onTap: onWhatsApp,
          icon: Icon(
            FontAwesomeIcons.whatsapp.data,
            size: 22,
            color: _whatsAppGreen,
          ),
        ),
        const SizedBox(width: 8),
        _RoundShareButton(
          label: 'Trimite pe Facebook',
          fill: palette.chip,
          onTap: onFacebook,
          icon: const _FacebookLogo(),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Builder(
            builder: (buttonContext) => FilledButton.icon(
              onPressed: () => onShare(buttonContext),
              icon: Icon(
                palette.isApple
                    ? Icons.ios_share_rounded
                    : Icons.share_rounded,
                size: 18,
              ),
              label: const Text(
                'Distribuie link-ul',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.shareAction,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(44),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: const StadiumBorder(),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A 44 px round button with only an icon; [label] is its tooltip and what
/// screen readers say.
class _RoundShareButton extends StatelessWidget {
  const _RoundShareButton({
    required this.label,
    required this.fill,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final Color fill;
  final Widget icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Material(
        color: fill,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(dimension: 44, child: Center(child: icon)),
        ),
      ),
    );
  }
}

/// Facebook's white "f" on its blue circle, which reads the same on the
/// light and the dark button.
class _FacebookLogo extends StatelessWidget {
  const _FacebookLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: _facebookBlue,
        shape: BoxShape.circle,
      ),
      child: Icon(
        FontAwesomeIcons.facebookF.data,
        size: 13,
        color: Colors.white,
      ),
    );
  }
}

/// The small X in the corner, with a 44 px tap area around it.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.palette, required this.onTap});

  final _CardPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Închide',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: palette.closeFill,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.close, size: 16, color: palette.closeIcon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
