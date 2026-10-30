import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../services/analytics_service.dart';
import '../../services/share_service.dart';
import '../../types/Station.dart';
import '../../utils/share_utils.dart';
import '../../widgets/copied_toast.dart';
import '../../widgets/share_handler.dart';
import 'now_playing_controls.dart';

/// The app's download page, shared when no station is.
const String _appUrl =
    'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin';

/// What a desktop share hands over: the link, the message around it and
/// the invitation made of both, as the phone's share sheet builds them.
@immutable
class DesktopShareContent {
  const DesktopShareContent({
    required this.url,
    required this.message,
    this.stationName,
    this.songName,
    this.songArtist,
    this.songId,
  });

  /// The share of [station], or of the app without one. With the user's
  /// personal [link] the shared link counts the friends who open it.
  factory DesktopShareContent.of({Station? station, ShareLinkData? link}) {
    final String? slug = station?.slug;
    final String? stationName = station?.title;
    final int? songId = station?.songId;
    final fallbackUrl = slug != null && slug.isNotEmpty
        ? 'https://www.radiocrestin.ro/$slug'
        : _appUrl;
    return DesktopShareContent(
      url: link?.generateShareUrl(
            stationSlug: stationName != null ? slug : null,
            songId: songId,
          ) ??
          fallbackUrl,
      message: link == null
          ? 'Instalează și tu aplicația Radio Creștin și ascultă peste 60 '
              'de stații de radio creștin:\n$fallbackUrl'
          : ShareUtils.formatShareMessage(
              shareLinkData: link,
              stationName: stationName,
              songId: songId,
            ),
      stationName: stationName,
      songName: station?.songTitle,
      songArtist: station?.songArtist,
      songId: songId,
    );
  }

  /// The link shared.
  final String url;

  /// The message shared with the link.
  final String message;

  /// The station shared; null shares the app.
  final String? stationName;

  /// What the station plays now, mentioned in the invitation.
  final String? songName;
  final String? songArtist;
  final int? songId;

  /// What WhatsApp, the system share and the clipboard get: the message,
  /// the song playing now and the link.
  String get invitation => ShareUtils.formatMessageWithStation(
        message,
        url,
        stationName,
        songName: songName,
        songArtist: songArtist,
      );
}

/// Opens a menu to share [station] (or the app, without one): WhatsApp,
/// Facebook, copying the invitation, or the system share ("Mai multe…"),
/// which on macOS points its picker at the button.
///
/// The phone's share sheet slides up from the bottom; a desktop menu
/// opens at the button instead. [builder] draws the button, given what
/// opens and closes the menu.
class DesktopShareMenu extends StatefulWidget {
  const DesktopShareMenu({
    super.key,
    required this.station,
    required this.builder,
    this.loader,
    this.initialLink,
    this.onOpened,
    this.onClosed,
  });

  /// The station shared; null shares the app.
  final Station? station;

  /// Draws the button that opens the menu with `toggle`. The button takes
  /// `focusNode`, which gets the keyboard as the menu opens, so Esc closes
  /// the menu rather than what is around it.
  final Widget Function(
    BuildContext context,
    VoidCallback toggle,
    FocusNode focusNode,
  ) builder;

  /// Fetches the user's personal share link, once, as the menu first
  /// opens.
  final Future<ShareLinkData?> Function()? loader;

  /// The personal link, when already known; else the last one cached.
  final ShareLinkData? initialLink;

  /// Called as the menu opens, and once it closed.
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  static const String whatsAppLabel = 'WhatsApp';
  static const String facebookLabel = 'Facebook';
  static const String copyLabel = 'Copiază invitația';
  static const String moreLabel = 'Mai multe…';

  @override
  State<DesktopShareMenu> createState() => _DesktopShareMenuState();
}

class _DesktopShareMenuState extends State<DesktopShareMenu> {
  final MenuController _menu = MenuController();
  final FocusNode _buttonFocus = FocusNode(debugLabel: 'desktop-share');
  late ShareLinkData? _link = widget.initialLink ?? ShareLinkCache.read();
  bool _loadStarted = false;

  @override
  void didUpdateWidget(DesktopShareMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A link the page fetched since takes the place of the cached one.
    final link = widget.initialLink;
    if (link != null && link != oldWidget.initialLink) _link = link;
  }

  @override
  void dispose() {
    _buttonFocus.dispose();
    super.dispose();
  }

  DesktopShareContent get _content =>
      DesktopShareContent.of(station: widget.station, link: _link);

  void _onOpen() {
    widget.onOpened?.call();
    _loadLink();
  }

  /// Fetches the personal link; on failure keeps the one the menu has.
  Future<void> _loadLink() async {
    final loader = widget.loader;
    if (loader == null || _loadStarted) return;
    _loadStarted = true;
    ShareLinkData? link;
    try {
      link = await loader();
    } catch (_) {}
    if (mounted && link != null) setState(() => _link = link);
  }

  void _track(String buttonName) {
    final content = _content;
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': buttonName,
      'station_name': content.stationName,
      'song_id': content.songId,
      'source': 'desktop',
    });
  }

  void _shareToWhatsApp() {
    _track('share_whatsapp');
    final content = _content;
    ShareHandler.shareToWhatsApp(
      content.message,
      content.url,
      content.stationName,
      songName: content.songName,
      songArtist: content.songArtist,
    );
  }

  void _shareToFacebook() {
    _track('share_facebook');
    ShareHandler.shareToFacebook(_content.url);
  }

  Future<void> _copyInvitation() async {
    _track('copy_share_link');
    try {
      await Clipboard.setData(ClipboardData(text: _content.invitation));
    } catch (_) {
      return;
    }
    if (mounted) CopiedToast.show(context, message: 'Invitație copiată');
  }

  /// Opens the system share, its picker pointing at [anchor]'s button.
  void _shareViaSystem(BuildContext anchor) {
    _track('share_generic');
    final content = _content;
    ShareHandler.shareViaSystem(
      shareUrl: content.url,
      shareMessage: content.message,
      stationName: content.stationName,
      songName: content.songName,
      songArtist: content.songArtist,
      sharePositionOrigin: ShareHandler.originOf(anchor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stationName = widget.station?.title;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _buttonFocus,
      style: DesktopMenuTheme.menuStyle,
      useRootOverlay: true,
      consumeOutsideTap: true,
      alignmentOffset: const Offset(0, 6),
      onOpen: _onOpen,
      onClose: widget.onClosed,
      builder: (anchor, controller, child) => widget.builder(
        anchor,
        () => controller.isOpen ? controller.close() : controller.open(),
        _buttonFocus,
      ),
      menuChildren: [
        DesktopMenuHeader(
          title: stationName == null
              ? 'Distribuie aplicația'
              : 'Invită pe cineva să asculte',
          subtitle: Text(
            stationName ?? 'Radio Creștin',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const DesktopMenuDivider(),
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: Icon(
            FontAwesomeIcons.whatsapp.data,
            size: 18,
            color: const Color(0xFF25D366),
          ),
          onPressed: _shareToWhatsApp,
          child: const Text(DesktopShareMenu.whatsAppLabel),
        ),
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: Icon(
            FontAwesomeIcons.facebookF.data,
            size: 16,
            color: const Color(0xFF1877F2),
          ),
          onPressed: _shareToFacebook,
          child: const Text(DesktopShareMenu.facebookLabel),
        ),
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: const Icon(Icons.link_rounded, size: 18),
          onPressed: _copyInvitation,
          child: const Text(DesktopShareMenu.copyLabel),
        ),
        const DesktopMenuDivider(),
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: const Icon(CupertinoIcons.share, size: 18),
          // The picker points at the share button, which stays put,
          // rather than at this row, which closes with the menu.
          onPressed: () => _shareViaSystem(context),
          child: const Text(DesktopShareMenu.moreLabel),
        ),
      ],
    );
  }
}
