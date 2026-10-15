import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../services/analytics_service.dart';
import '../services/share_service.dart';
import '../theme.dart';
import '../utils.dart';
import '../utils/share_utils.dart';
import 'share_handler.dart';

/// How long the copy button reads "Copiat" before it turns back.
const Duration _copiedFor = Duration(milliseconds: 1800);

/// Labels may grow with the system text size up to this factor; beyond it
/// four actions no longer fit side by side.
const double _maxActionLabelTextScale = 1.35;

const Color _whatsAppGreen = Color(0xFF25D366);
const Color _facebookBlue = Color(0xFF1877F2);

/// Bottom sheet that invites a friend to listen to a station, or to the app.
///
/// One tap on WhatsApp, Facebook or "Mai multe" closes the sheet and hands
/// the link over, like YouTube's share panel; "Copiază" copies the same
/// invitation WhatsApp gets and confirms in place. The footer shows how
/// many friends opened the user's personal link: the last known count at
/// once, refreshed by [loader] while the sheet is already up.
class ShareSheet extends StatefulWidget {
  const ShareSheet({
    super.key,
    required this.shareUrl,
    required this.shareMessage,
    this.stationName,
    this.stationThumbnailUrl,
    this.songName,
    this.songArtist,
    this.songId,
    this.initialData,
    this.loader,
  });

  /// The link shared until the user's personal one is known.
  final String shareUrl;

  /// The message shared with the app link when no station is given.
  final String shareMessage;

  /// The station being shared; null shares the app itself.
  final String? stationName;

  /// The station's logo; the app icon shows when it is null or empty.
  final String? stationThumbnailUrl;

  /// What the station plays now, mentioned in the shared message.
  final String? songName;
  final String? songArtist;
  final int? songId;

  /// The user's personal share link, when it is already known.
  final ShareLinkData? initialData;

  /// Fetches the user's personal share link and its visit count.
  final Future<ShareLinkData?> Function()? loader;

  /// Shows the sheet above the whole app (mini player included).
  static Future<void> show(
    BuildContext context, {
    required String shareUrl,
    required String shareMessage,
    String? stationName,
    String? stationThumbnailUrl,
    String? songName,
    String? songArtist,
    int? songId,
    ShareLinkData? initialData,
    Future<ShareLinkData?> Function()? loader,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      barrierColor: Colors.black.withValues(alpha: isDark ? 0.4 : 0.32),
      builder: (_) => ShareSheet(
        shareUrl: shareUrl,
        shareMessage: shareMessage,
        stationName: stationName,
        stationThumbnailUrl: stationThumbnailUrl,
        songName: songName,
        songArtist: songArtist,
        songId: songId,
        initialData: initialData,
        loader: loader,
      ),
    );
  }

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  ShareLinkData? _data;
  late bool _isLoading;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void initState() {
    super.initState();
    // The last link fetched shows at once, its count and personal link
    // included, while [ShareSheet.loader] fetches a fresh one.
    _data = widget.initialData ?? ShareLinkCache.read();
    _isLoading = widget.loader != null && _data == null;
    if (widget.loader != null) _load();
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  /// Fetches the personal link; on failure keeps what the sheet already has.
  Future<void> _load() async {
    ShareLinkData? result;
    try {
      result = await widget.loader!();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _data = result ?? _data;
      _isLoading = false;
    });
  }

  String get _shareUrl {
    final data = _data;
    if (data == null) return widget.shareUrl;
    return data.generateShareUrl(
      stationSlug: widget.stationName != null ? _stationSlug : null,
      songId: widget.songId,
    );
  }

  /// The first path segment of [ShareSheet.shareUrl], the station's slug.
  String? get _stationSlug {
    final segments = Uri.tryParse(widget.shareUrl)?.pathSegments;
    return segments == null || segments.isEmpty ? null : segments.first;
  }

  String get _shareMessage {
    final data = _data;
    if (data == null) return widget.shareMessage;
    return ShareUtils.formatShareMessage(
      shareLinkData: data,
      stationName: widget.stationName,
      songId: widget.songId,
    );
  }

  /// The invitation WhatsApp, the system share sheet and the clipboard get:
  /// the message, the song playing now and the link.
  String get _invitation => ShareUtils.formatMessageWithStation(
        _shareMessage,
        _shareUrl,
        widget.stationName,
        songName: widget.songName,
        songArtist: widget.songArtist,
      );

  void _track(String buttonName) {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': buttonName,
      'station_name': widget.stationName,
      'song_id': widget.songId,
    });
  }

  void _shareToWhatsApp() {
    _track('share_whatsapp');
    final message = _shareMessage;
    final url = _shareUrl;
    Navigator.of(context).pop();
    ShareHandler.shareToWhatsApp(
      message,
      url,
      widget.stationName,
      songName: widget.songName,
      songArtist: widget.songArtist,
    );
  }

  void _shareToFacebook() {
    _track('share_facebook');
    final url = _shareUrl;
    Navigator.of(context).pop();
    ShareHandler.shareToFacebook(url);
  }

  /// Opens the system share sheet; on iPad its popover points at [origin],
  /// read before this sheet closes.
  void _shareViaSystem(Rect? origin) {
    _track('share_generic');
    final message = _shareMessage;
    final url = _shareUrl;
    Navigator.of(context).pop();
    ShareHandler.shareViaSystem(
      shareUrl: url,
      shareMessage: message,
      stationName: widget.stationName,
      songName: widget.songName,
      songArtist: widget.songArtist,
      sharePositionOrigin: origin,
    );
  }

  void _copyInvitation() {
    _track('copy_share_link');
    Clipboard.setData(ClipboardData(text: _invitation));
    HapticFeedback.lightImpact();
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(_copiedFor, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = _SharePalette.of(context);
    final stationName = widget.stationName;
    return _SheetFrame(
      palette: palette,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          MediaQuery.viewPaddingOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Grabber(color: palette.grabber),
            const SizedBox(height: 20),
            _SheetHeader(
              palette: palette,
              thumbnailUrl: widget.stationThumbnailUrl,
              subtitle: stationName != null
                  ? '$stationName · radio creștin, gratuit'
                  : 'Radio Creștin · peste 60 de stații, gratuit',
            ),
            const SizedBox(height: 28),
            _ShareActions(
              palette: palette,
              copied: _copied,
              onWhatsApp: _shareToWhatsApp,
              onFacebook: _shareToFacebook,
              onCopy: _copyInvitation,
              onMore: _shareViaSystem,
            ),
            _VisitFooter(
              palette: palette,
              isLoading: _isLoading,
              visitCount: _data?.visitCount,
            ),
          ],
        ),
      ),
    );
  }
}

/// Colors of the sheet: the player's own in the light theme, a warm wine in
/// the dark one.
@immutable
class _SharePalette {
  const _SharePalette({
    required this.isDark,
    required this.isApple,
    required this.backdrop,
    required this.backdropStops,
    required this.edge,
    required this.text,
    required this.secondaryText,
    required this.grabber,
    required this.chip,
    required this.divider,
    required this.success,
    required this.accent,
  });

  factory _SharePalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final onSurface = theme.colorScheme.onSurface;
    final background = theme.scaffoldBackgroundColor;
    return _SharePalette(
      isDark: isDark,
      isApple: theme.platform == TargetPlatform.iOS ||
          theme.platform == TargetPlatform.macOS,
      // Light: white fading into the background, like the sleep timer
      // sheet.
      backdrop: isDark
          ? AppColors.darkSheetBackdrop
          : [Colors.white, background, background],
      backdropStops: isDark ? const [0, 0.55, 1] : const [0, 0.45, 1],
      // A faint rim that lifts the dark sheet off the dark player.
      edge: isDark ? Colors.white.withValues(alpha: 0.09) : null,
      text: onSurface,
      secondaryText: onSurface.withValues(alpha: isDark ? 0.74 : 0.6),
      grabber: onSurface.withValues(alpha: isDark ? 0.35 : 0.22),
      chip: isDark
          ? Colors.white.withValues(alpha: 0.13)
          : Colors.black.withValues(alpha: 0.08),
      divider: onSurface.withValues(alpha: isDark ? 0.12 : 0.09),
      success: isDark ? const Color(0xFF81C995) : const Color(0xFF1E7E34),
      accent:
          isDark ? AppColors.inviteAccent : AppColors.inviteAccentOnLight,
    );
  }

  final bool isDark;

  /// Apple platforms get a highlight on tap instead of a Material ripple.
  final bool isApple;

  final List<Color> backdrop;
  final List<double> backdropStops;
  final Color? edge;
  final Color text;
  final Color secondaryText;
  final Color grabber;
  final Color chip;
  final Color divider;
  final Color success;

  /// Marks how many friends opened the user's link, once some did.
  final Color accent;

  Color get successFill => success.withValues(alpha: isDark ? 0.16 : 0.12);
}

/// Full-width card with rounded top corners and the palette's backdrop.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.palette, required this.child});

  final _SharePalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final edge = palette.edge;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: palette.backdrop,
          stops: palette.backdropStops,
        ),
        border: edge == null ? null : Border.all(color: edge),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 30,
            offset: Offset(0, -10),
          ),
        ],
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: palette.text),
        child: child,
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// The station's logo (or the app icon) beside the invitation.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.palette,
    required this.thumbnailUrl,
    required this.subtitle,
  });

  final _SharePalette palette;
  final String? thumbnailUrl;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final url = thumbnailUrl;
    return Row(
      children: [
        ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox.square(
              dimension: 52,
              child: url != null && url.isNotEmpty
                  ? Utils.displayImage(url, cache: true, cacheWidth: 156)
                  : Image.asset(
                      'assets/icons/ic_logo_filled.png',
                      fit: BoxFit.cover,
                      cacheWidth: 156,
                    ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Invită un prieten să asculte',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: palette.secondaryText),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// WhatsApp, Facebook, copy invitation and the system share sheet, side by
/// side.
class _ShareActions extends StatelessWidget {
  const _ShareActions({
    required this.palette,
    required this.copied,
    required this.onWhatsApp,
    required this.onFacebook,
    required this.onCopy,
    required this.onMore,
  });

  final _SharePalette palette;

  /// Whether the invitation was just copied; the copy action confirms it.
  final bool copied;

  final VoidCallback onWhatsApp;
  final VoidCallback onFacebook;
  final VoidCallback onCopy;
  final ValueChanged<Rect?> onMore;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxActionLabelTextScale,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _ShareAction(
              palette: palette,
              label: 'WhatsApp',
              fill: _whatsAppGreen,
              ink: Colors.white,
              icon: Icon(FontAwesomeIcons.whatsapp.data, size: 28),
              onTap: onWhatsApp,
            ),
          ),
          Expanded(
            child: _ShareAction(
              palette: palette,
              label: 'Facebook',
              fill: _facebookBlue,
              ink: Colors.white,
              icon: Icon(FontAwesomeIcons.facebookF.data, size: 24),
              onTap: onFacebook,
            ),
          ),
          Expanded(
            child: _ShareAction(
              palette: palette,
              label: copied ? 'Copiat' : 'Copiază',
              semanticLabel:
                  copied ? 'Invitație copiată' : 'Copiază invitația',
              labelColor: copied ? palette.success : null,
              fill: copied ? palette.successFill : palette.chip,
              ink: copied ? palette.success : palette.text,
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: Icon(
                  copied ? Icons.check_rounded : Icons.copy_rounded,
                  key: ValueKey(copied),
                  size: copied ? 28 : 24,
                ),
              ),
              onTap: onCopy,
            ),
          ),
          Expanded(
            // Its own context, so the iPad share popover can point at it.
            child: Builder(
              builder: (actionContext) => _ShareAction(
                palette: palette,
                label: 'Mai multe',
                fill: palette.chip,
                ink: palette.text,
                icon: Icon(
                  palette.isApple
                      ? Icons.ios_share_rounded
                      : Icons.share_rounded,
                  size: 24,
                ),
                onTap: () => onMore(ShareHandler.originOf(actionContext)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A colored circle with a label under it; the whole of it is the button.
class _ShareAction extends StatelessWidget {
  const _ShareAction({
    required this.palette,
    required this.label,
    required this.fill,
    required this.ink,
    required this.icon,
    required this.onTap,
    this.semanticLabel,
    this.labelColor,
  });

  final _SharePalette palette;
  final String label;
  final Color fill;

  /// The icon's color.
  final Color ink;

  final Widget icon;
  final VoidCallback onTap;

  /// What a screen reader announces; [label] when null.
  final String? semanticLabel;

  /// The label's color; the palette's text color when null.
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      onTap: onTap,
      excludeSemantics: true,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fill,
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(color: ink),
                    child: Center(child: icon),
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: Text(
                    label,
                    key: ValueKey(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          labelColor != null ? FontWeight.w600 : FontWeight.w500,
                      color: labelColor ?? palette.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Above the circle so the Material ripple stays visible on Android.
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                splashFactory:
                    palette.isApple ? NoSplash.splashFactory : null,
                highlightColor: palette.isApple
                    ? palette.text.withValues(alpha: 0.08)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A divider and how many friends opened the user's link.
///
/// A placeholder bar shows while the count loads. Without a count (the
/// link could not be fetched) the footer folds away instead of claiming
/// nobody opened it.
class _VisitFooter extends StatelessWidget {
  const _VisitFooter({
    required this.palette,
    required this.isLoading,
    required this.visitCount,
  });

  final _SharePalette palette;
  final bool isLoading;
  final int? visitCount;

  @override
  Widget build(BuildContext context) {
    final count = visitCount;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: isLoading || count != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 26),
                Divider(height: 1, thickness: 1, color: palette.divider),
                const SizedBox(height: 14),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: count == null
                      ? _VisitPlaceholder(
                          key: const ValueKey('loading'),
                          color: palette.chip,
                        )
                      : _VisitCount(
                          key: ValueKey(count),
                          count: count,
                          palette: palette,
                        ),
                ),
              ],
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

class _VisitPlaceholder extends StatelessWidget {
  const _VisitPlaceholder({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: Center(
        child: Container(
          width: 200,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }
}

/// The visit count, with the friends who came in highlighted.
class _VisitCount extends StatelessWidget {
  const _VisitCount({super.key, required this.count, required this.palette});

  final int count;
  final _SharePalette palette;

  @override
  Widget build(BuildContext context) {
    final parts = ShareUtils.visitCountParts(count);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.people_outline_rounded,
          size: 16,
          color: parts == null ? palette.secondaryText : palette.accent,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text.rich(
            switch (parts) {
              (final friends, final rest) => TextSpan(
                  children: [
                    TextSpan(
                      text: friends,
                      style: TextStyle(
                        color: palette.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(text: rest),
                  ],
                ),
              null => TextSpan(text: ShareUtils.visitCountText(count)),
            },
            maxLines: 2,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.secondaryText),
          ),
        ),
      ],
    );
  }
}
