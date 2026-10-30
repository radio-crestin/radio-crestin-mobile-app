import 'package:flutter/material.dart';

import '../../types/Station.dart';
import '../../utils/romanian_count.dart';
import '../tv_theme.dart';
import 'now_playing_controls.dart';

/// What a station's link leads to.
enum StationLinkKind { website, facebook, email, action }

/// One of a station's links, as the now-playing panel lists it.
@immutable
class StationLink {
  const StationLink({
    required this.kind,
    required this.uri,
    required this.label,
    required this.tooltip,
  });

  final StationLinkKind kind;
  final Uri uri;

  /// What the link shows: the site's address, the e-mail address.
  final String label;

  /// What the link does, under the pointer.
  final String tooltip;

  /// What copying it puts on the clipboard: the e-mail address itself,
  /// or the link.
  String get copyText =>
      kind == StationLinkKind.email ? uri.path : uri.toString();
}

/// What the station says about itself, from the API: its description,
/// its links and how listeners rate it.
@immutable
class StationAbout {
  const StationAbout({
    required this.description,
    required this.action,
    required this.links,
    required this.rating,
    required this.reviewCount,
  });

  /// What [station] tells about itself.
  factory StationAbout.of(Station station) {
    final data = station.rawStationData;
    final website = webUri(data.website);
    final facebook = facebookUri(data.facebook_page_id);
    final email = emailUri(data.email);
    final actionUri = webUri(data.description_link);
    return StationAbout(
      description: cleanDescription(data.description),
      action: actionUri == null
          ? null
          : StationLink(
              kind: StationLinkKind.action,
              uri: actionUri,
              label: _actionLabel(data.description_action_title) ??
                  webLabel(actionUri),
              tooltip: webLabel(actionUri),
            ),
      links: [
        if (website != null)
          StationLink(
            kind: StationLinkKind.website,
            uri: website,
            label: webLabel(website),
            tooltip: 'Deschide site-ul stației',
          ),
        if (facebook != null)
          StationLink(
            kind: StationLinkKind.facebook,
            uri: facebook,
            label: 'Pagina de Facebook',
            tooltip: webLabel(facebook),
          ),
        if (email != null)
          StationLink(
            kind: StationLinkKind.email,
            uri: email,
            label: email.path,
            tooltip: 'Scrie-le un e-mail',
          ),
      ],
      rating: station.averageRating,
      reviewCount: station.reviewCount,
    );
  }

  /// The description, without the blank lines the API keeps; null when
  /// it has none.
  final String? description;

  /// A link the station adds to its description ("Instalează aplicația
  /// ..."), if any.
  final StationLink? action;

  /// The site, the Facebook page and the e-mail, those it has.
  final List<StationLink> links;

  /// The average of its reviews, 0 without any.
  final double rating;
  final int reviewCount;

  /// Whether there is anything to tell besides the name.
  bool get isEmpty =>
      description == null && action == null && links.isEmpty && rating <= 0;

  /// [text] with the API's Windows line ends and runs of blank lines
  /// made single, trimmed; null when nothing is left.
  static String? cleanDescription(String? text) {
    final cleaned = (text ?? '')
        .replaceAll(RegExp(r'\r\n?'), '\n')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  /// The web address [text] names, "https://" added when it has no
  /// scheme; null unless it is a web address.
  static Uri? webUri(String? text) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) return null;
    final uri = parsed.hasScheme ? parsed : Uri.tryParse('https://$trimmed');
    if (uri == null || uri.host.isEmpty) return null;
    return uri.isScheme('http') || uri.isScheme('https') ? uri : null;
  }

  /// [uri] as people write it: its host without "www." and its path
  /// without the closing slash.
  static String webLabel(Uri uri) {
    final host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return '$host$path';
  }

  /// The Facebook page [pageId] names: its name or number, or its whole
  /// address.
  static Uri? facebookUri(String? pageId) {
    final id = pageId?.trim() ?? '';
    if (id.isEmpty) return null;
    if (id.contains('facebook.com')) return webUri(id);
    return Uri.https('www.facebook.com', '/$id');
  }

  /// A "mailto:" link to [address]; null unless it looks like one.
  static Uri? emailUri(String? address) {
    final email = address?.trim() ?? '';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) return null;
    return Uri(scheme: 'mailto', path: email);
  }

  /// The action's title without its closing period, as a link reads.
  static String? _actionLabel(String? title) {
    var label = title?.trim() ?? '';
    if (label.endsWith('.') && !label.endsWith('..')) {
      label = label.substring(0, label.length - 1);
    }
    return label.isEmpty ? null : label;
  }
}

/// "Despre stație": the station's logo, name and rating, its description
/// (four lines, "Mai mult" for the rest), and its links, each opening in
/// the browser or the mail app; a right-click on one offers to copy it.
class NowPlayingAbout extends StatelessWidget {
  const NowPlayingAbout({
    super.key,
    required this.station,
    required this.about,
    required this.onOpenLink,
    required this.onCopyLink,
    this.onMenuClosed,
  });

  final Station station;
  final StationAbout about;
  final ValueChanged<StationLink> onOpenLink;
  final ValueChanged<StationLink> onCopyLink;

  /// Called once a link's menu closed, for the keyboard to go back.
  final VoidCallback? onMenuClosed;

  static const String title = 'Despre stație';

  /// The items of a link's menu: open it, copy it.
  static String openLabel(StationLinkKind kind) =>
      kind == StationLinkKind.email ? 'Scrie un e-mail' : 'Deschide în browser';
  static String copyLabel(StationLinkKind kind) =>
      kind == StationLinkKind.email ? 'Copiază adresa' : 'Copiază linkul';

  static IconData _icon(StationLinkKind kind) => switch (kind) {
        StationLinkKind.website => Icons.language_rounded,
        StationLinkKind.facebook => Icons.facebook_rounded,
        StationLinkKind.email => Icons.mail_outline_rounded,
        StationLinkKind.action => Icons.link_rounded,
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const NowPlayingSectionHeader(title: title),
        const SizedBox(height: 10),
        _Identity(station: station, about: about),
        if (about.description case final description?) ...[
          const SizedBox(height: 14),
          _Description(text: description),
        ],
        if (about.action case final action?) ...[
          const SizedBox(height: 4),
          _LinkButton(
            icon: _icon(action.kind),
            link: action,
            accent: DesktopTokens.focusRing,
            onOpen: () => onOpenLink(action),
            onCopy: () => onCopyLink(action),
            onMenuClosed: onMenuClosed,
          ),
        ],
        if (about.links.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final link in about.links)
            _LinkButton(
              icon: _icon(link.kind),
              link: link,
              onOpen: () => onOpenLink(link),
              onCopy: () => onCopyLink(link),
              onMenuClosed: onMenuClosed,
            ),
        ],
      ],
    );
  }
}

/// The station's logo, its name and its rating.
class _Identity extends StatelessWidget {
  const _Identity({required this.station, required this.about});

  final Station station;
  final StationAbout about;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox.square(dimension: 44, child: station.logo),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                station.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: TvColors.textPrimary,
                ),
              ),
              if (about.rating > 0) ...[
                const SizedBox(height: 3),
                _Rating(rating: about.rating, reviews: about.reviewCount),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "★ 4.2 · 5 recenzii".
class _Rating extends StatelessWidget {
  const _Rating({required this.rating, required this.reviews});

  final double rating;
  final int reviews;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.star_rounded, size: 15, color: DesktopTokens.rating),
        const SizedBox(width: 3),
        Text(
          rating.toStringAsFixed(1),
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: DesktopTokens.rating,
          ),
        ),
        if (reviews > 0)
          Flexible(
            child: Text(
              '  ·  ${romanianCount(reviews, one: 'recenzie', many: 'recenzii')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: TvColors.textTertiary,
              ),
            ),
          ),
      ],
    );
  }
}

/// The station's description, four lines at first; "Mai mult" shows the
/// rest when there is more, "Mai puțin" folds it again.
class _Description extends StatefulWidget {
  const _Description({required this.text});

  final String text;

  static const int collapsedLines = 4;
  static const String moreLabel = 'Mai mult';
  static const String lessLabel = 'Mai puțin';

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  bool _expanded = false;

  static const TextStyle _style = TextStyle(
    fontSize: 13.5,
    height: 1.5,
    color: TvColors.textSecondary,
  );

  @override
  void didUpdateWidget(_Description oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  /// Whether the text takes more than the collapsed lines at [width].
  bool _overflows(BuildContext context, double width) {
    final painter = TextPainter(
      text: TextSpan(
        text: widget.text,
        style: DefaultTextStyle.of(context).style.merge(_style),
      ),
      maxLines: _Description.collapsedLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final overflows = painter.didExceedMaxLines;
    painter.dispose();
    return overflows;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = _overflows(context, constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: DesktopTokens.contentDuration,
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: Text(
                widget.text,
                style: _style,
                maxLines: _expanded ? null : _Description.collapsedLines,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
            ),
            if (overflows)
              TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                iconAlignment: IconAlignment.end,
                icon: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                ),
                label: Text(_expanded
                    ? _Description.lessLabel
                    : _Description.moreLabel),
                style: TextButton.styleFrom(
                  foregroundColor: DesktopTokens.focusRing,
                  overlayColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 4, 0),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A link of the station: its icon, what it shows and an arrow, as it
/// leaves the app. Under the pointer or the keyboard it brightens and
/// underlines. A right-click opens a menu to open it or copy it.
class _LinkButton extends StatefulWidget {
  const _LinkButton({
    required this.icon,
    required this.link,
    required this.onOpen,
    required this.onCopy,
    this.onMenuClosed,
    this.accent,
  });

  final IconData icon;
  final StationLink link;
  final VoidCallback onOpen;
  final VoidCallback onCopy;
  final VoidCallback? onMenuClosed;

  /// The resting color, the quiet secondary text when null.
  final Color? accent;

  @override
  State<_LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<_LinkButton> {
  final MenuController _menu = MenuController();

  /// The link's keyboard focus, which its menu takes while open, so Esc
  /// closes the menu rather than the panel.
  final FocusNode _focus = FocusNode(debugLabel: 'desktop-np-link');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final email = link.kind == StationLinkKind.email;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _focus,
      style: DesktopMenuTheme.menuStyle,
      useRootOverlay: true,
      consumeOutsideTap: true,
      onClose: widget.onMenuClosed,
      menuChildren: [
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: Icon(
            email ? Icons.mail_outline_rounded : Icons.open_in_new_rounded,
            size: 18,
          ),
          onPressed: widget.onOpen,
          child: Text(NowPlayingAbout.openLabel(link.kind)),
        ),
        MenuItemButton(
          style: DesktopMenuTheme.itemStyle(),
          leadingIcon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: widget.onCopy,
          child: Text(NowPlayingAbout.copyLabel(link.kind)),
        ),
      ],
      builder: (context, controller, child) => GestureDetector(
        onSecondaryTapUp: (details) =>
            controller.open(position: details.localPosition),
        child: child,
      ),
      child: _link(),
    );
  }

  Widget _link() {
    final link = widget.link;
    final accent = widget.accent;
    bool lit(Set<WidgetState> states) =>
        states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused);
    return Tooltip(
      message: link.tooltip,
      waitDuration: DesktopTokens.tooltipWait,
      child: TextButton(
        onPressed: widget.onOpen,
        focusNode: _focus,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: AlignmentDirectional.centerStart,
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => lit(states)
                ? accent ?? TvColors.textPrimary
                : accent ?? TvColors.textSecondary,
          ),
          textStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              decoration: lit(states) ? TextDecoration.underline : null,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, size: 17),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                link.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.arrow_outward_rounded,
              size: 14,
              color: TvColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
