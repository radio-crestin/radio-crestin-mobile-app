import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../services/announcement.dart';
import '../services/announcement_actions.dart';
import '../services/announcement_copy.dart';
import '../services/announcements_service.dart';
import '../theme.dart';
import 'announcement_icons.dart';
import 'announcement_image.dart';
import 'announcement_theme_colors.dart';
import 'inline_markdown.dart';

/// The home announcements: one card that swipes between them, with a dot
/// per announcement in its top-right corner.
///
/// The look is the announcements design (`.ann--mobile`): the icon beside
/// the category tag, then the title, a body of at most three lines and
/// the buttons across the card, on a faint wash of the announcement's
/// color. Tapping the card anywhere runs its main button.
///
/// The card is as tall as the announcement it shows. Its height changes
/// only after the listener's own swipe, arrow tap or "Ascunde", or a
/// refresh that changed the list, and then eases over [_resizeDuration];
/// on the first frame it is already right.
///
/// With [autoplaySeconds] it moves to the next announcement on its own,
/// as the announcements spec says: it waits while touched, while the app
/// is in the background and while less than half the card shows, and
/// stops for good at the last one or after the listener pages or closes
/// one. It is then as tall as its tallest announcement, from the first
/// frame, so moving on its own never changes its height. Reduced motion
/// turns it off.
class AnnouncementCard extends StatefulWidget {
  const AnnouncementCard({
    super.key,
    required this.items,
    required this.service,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 4),
    this.autoplaySeconds = 0,
  });

  final List<Announcement> items;
  final AnnouncementsService service;
  final EdgeInsetsGeometry margin;

  /// Seconds between moves to the next announcement; 0 is off.
  final int autoplaySeconds;

  @override
  State<AnnouncementCard> createState() => _AnnouncementCardState();
}

class _AnnouncementCardState extends State<AnnouncementCard>
    with WidgetsBindingObserver {
  final PageController _pages = PageController();
  int _index = 0;

  // Autoplay: what holds it back right now, and whether it ended.
  Timer? _autoplay;
  bool _autoplayEnded = false;
  bool _autoplayMoving = false;
  bool _touched = false;
  bool _halfVisible = false;
  bool _foreground = true;
  bool _reduceMotion = false;

  static const _resizeDuration = Duration(milliseconds: 280);
  static const _easing = Cubic(0.2, 0.8, 0.2, 1);
  static const _slideDuration = Duration(milliseconds: 420);

  List<Announcement> get _items => widget.items;
  int get _shown => _index.clamp(0, _items.length - 1);

  /// Whether this card moves on its own (and so is as tall as its tallest
  /// announcement).
  bool get _autoplays =>
      widget.autoplaySeconds > 0 && _items.length > 1 && !_reduceMotion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = _onScreen(WidgetsBinding.instance.lifecycleState);
  }

  /// Whether the app shows: an inactive app (a system alert over it, the
  /// Control Center) still does; a hidden or paused one is in the
  /// background.
  static bool _onScreen(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _scheduleAutoplay();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _onScreen(state);
    _scheduleAutoplay();
  }

  /// Starts the wait for the next move when nothing holds it back, and
  /// cancels it when something does; a pause starts the wait over.
  void _scheduleAutoplay() {
    final runs = _autoplays &&
        !_autoplayEnded &&
        !_autoplayMoving &&
        !_touched &&
        _halfVisible &&
        _foreground;
    if (!runs) {
      _autoplay?.cancel();
      _autoplay = null;
      return;
    }
    _autoplay ??=
        Timer(Duration(seconds: widget.autoplaySeconds), _autoAdvance);
  }

  Future<void> _autoAdvance() async {
    _autoplay = null;
    if (!mounted || !_pages.hasClients) return;
    final next = _shown + 1;
    if (next >= _items.length) return _endAutoplay();
    _autoplayMoving = true;
    await _pages.animateToPage(next,
        duration: _slideDuration, curve: _easing);
    _autoplayMoving = false;
    if (!mounted) return;
    // It stops at the last announcement: paging stops at the ends.
    if (_shown >= _items.length - 1) return _endAutoplay();
    _scheduleAutoplay();
  }

  /// Stops autoplay for good: the listener took over, or it reached the
  /// end.
  void _endAutoplay() {
    _autoplayEnded = true;
    _scheduleAutoplay();
  }

  void _onTouch(bool touched) {
    _touched = touched;
    _scheduleAutoplay();
  }

  void _onCardVisibility(VisibilityInfo info) {
    if (!mounted) return;
    _halfVisible = info.visibleFraction >= 0.5;
    _scheduleAutoplay();
  }

  @override
  void didUpdateWidget(AnnouncementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.items;
    if (identical(old, _items) || _items.isEmpty) return;
    // The announcement on screen stays on screen; a closed one gives its
    // place to the next.
    final shownSlug =
        old.isEmpty ? null : old[_index.clamp(0, old.length - 1)].slug;
    final kept = _items.indexWhere((item) => item.slug == shownSlug);
    // The listener closed the one on screen: autoplay ends.
    if (kept < 0) _endAutoplay();
    final target = kept >= 0 ? kept : _index.clamp(0, _items.length - 1);
    if (target == _index) return;
    _index = target;
    if (_pages.hasClients) _pages.jumpToPage(target);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoplay?.cancel();
    _pages.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    // A page the listener turned ends autoplay.
    if (!_autoplayMoving) _endAutoplay();
    setState(() => _index = index);
  }

  /// Moves [by] one announcement, stopping at the ends like a swipe; the
  /// card's height then follows, as after a swipe.
  void _step(int by) {
    _endAutoplay();
    final target = _shown + by;
    if (target < 0 || target >= _items.length) return;
    _pages.animateToPage(target, duration: _slideDuration, curve: _easing);
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final count = _items.length;
    final card = Semantics(
      container: true,
      label: AnnouncementCopy.carouselLabel,
      child: _CardFrame(
        key: const ValueKey('announcement-card'),
        margin: widget.margin,
        child: AnimatedSize(
          // Never zero: a zero-length AnimatedSize re-dirties itself in
          // layout. The first frame does not animate anyway.
          duration: _resizeDuration,
          curve: _easing,
          alignment: Alignment.topCenter,
          child: Stack(
            children: [
              // The shown slide (with autoplay, every slide: the tallest
              // wins), invisible, sizes the card in the same frame; the
              // pages fill that box.
              for (final index in _autoplays
                  ? List.generate(count, (index) => index)
                  : [_shown])
                Visibility(
                  visible: false,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child:
                      ExcludeSemantics(child: _slide(index, measuring: true)),
                ),
              Positioned.fill(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: count,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) => OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: _slide(index),
                  ),
                ),
              ),
              if (count > 1)
                Positioned(
                  // In the top-right corner, mirroring a station tile's
                  // heart in the bottom-right one.
                  top: StationTileMetrics.pagerTop,
                  right: StationTileMetrics.pagerRight,
                  height: _PagerButtons.target,
                  child: _PagerButtons(
                    position: AnnouncementCopy.count(_shown + 1, count),
                    onPrevious: _shown > 0 ? () => _step(-1) : null,
                    onNext: _shown < count - 1 ? () => _step(1) : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (widget.autoplaySeconds <= 0) return card;
    return VisibilityDetector(
      key: const ValueKey('announcement-card-visibility'),
      onVisibilityChanged: _onCardVisibility,
      child: Listener(
        onPointerDown: (_) => _onTouch(true),
        onPointerUp: (_) => _onTouch(false),
        onPointerCancel: (_) => _onTouch(false),
        child: card,
      ),
    );
  }

  Widget _slide(int index, {bool measuring = false}) {
    final item = _items[index];
    final slide = _Slide(
      item: item,
      position: index,
      count: _items.length,
      service: widget.service,
      stationTile: true,
    );
    if (measuring) return slide;
    return _ImpressionCounter(
      item: item,
      position: index,
      service: widget.service,
      child: slide,
    );
  }
}

/// One announcement on its own card, without dots or swiping: in the
/// station sheet and the push banner.
class AnnouncementStaticCard extends StatelessWidget {
  const AnnouncementStaticCard({
    super.key,
    required this.item,
    required this.service,
    this.position = 0,
    this.station,
    this.margin = EdgeInsets.zero,
    this.onDone,
  });

  final Announcement item;
  final AnnouncementsService service;
  final int position;

  /// The station playing, for a station announcement's events.
  final String? station;
  final EdgeInsetsGeometry margin;

  /// Called after a button, a link or "Ascunde" was tapped.
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return _CardFrame(
      key: ValueKey('announcement-static-${item.slug}'),
      margin: margin,
      outlined: true,
      child: _ImpressionCounter(
        item: item,
        position: position,
        service: service,
        station: station,
        child: _Slide(
          item: item,
          position: position,
          count: 1,
          service: service,
          station: station,
          onDone: onDone,
        ),
      ),
    );
  }
}

/// The card's surface: theme color, 1 px outline, 16 px corners and, in
/// the light theme, a soft shadow.
class _CardFrame extends StatelessWidget {
  const _CardFrame({
    super.key,
    required this.margin,
    required this.child,
    this.outlined = false,
  });

  final EdgeInsetsGeometry margin;
  final Widget child;

  /// A 1 px outline, for a card on a sheet or over the screen, where the
  /// background is close to the card's.
  final bool outlined;

  static final _radius = BorderRadius.circular(16);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        // The station cards' surface, made opaque on the page background
        // so a card in a sheet or over the screen looks the same.
        color: Color.alphaBlend(theme.cardColor, theme.scaffoldBackgroundColor),
        borderRadius: _radius,
        border: outlined
            ? Border.all(color: theme.announcementColors.border)
            : null,
      ),
      child: ClipRRect(borderRadius: _radius, child: child),
    );
  }
}

/// Counts [item] as seen once it stayed at least half visible for a
/// second, and takes it off after its `hide_after_seconds`.
class _ImpressionCounter extends StatefulWidget {
  const _ImpressionCounter({
    required this.item,
    required this.position,
    required this.service,
    required this.child,
    this.station,
  });

  final Announcement item;
  final int position;
  final AnnouncementsService service;
  final String? station;
  final Widget child;

  @override
  State<_ImpressionCounter> createState() => _ImpressionCounterState();
}

class _ImpressionCounterState extends State<_ImpressionCounter> {
  Timer? _impression;
  Timer? _hide;

  static const _delay = Duration(seconds: 1);

  @override
  void dispose() {
    _impression?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    if (info.visibleFraction < 0.5) {
      _impression?.cancel();
      _impression = null;
      return;
    }
    _impression ??= Timer(_delay, _counted);
  }

  void _counted() {
    final item = widget.item;
    widget.service
        .recordImpression(item, widget.position, station: widget.station);
    final seconds = item.hideAfterSeconds;
    if (seconds != null && seconds > 0 && !widget.service.alwaysShow) {
      _hide ??= Timer(Duration(seconds: seconds),
          () => widget.service.hideForThisLaunch(item));
    }
  }

  @override
  Widget build(BuildContext context) => VisibilityDetector(
        key: ObjectKey(this),
        onVisibilityChanged: _onVisibilityChanged,
        child: widget.child,
      );
}

/// One announcement: the icon row, title, body and buttons. A tap
/// anywhere on it runs the main button.
class _Slide extends StatelessWidget {
  const _Slide({
    required this.item,
    required this.position,
    required this.count,
    required this.service,
    this.station,
    this.onDone,
    this.stationTile = false,
  });

  final Announcement item;
  final int position;
  final int count;
  final AnnouncementsService service;
  final String? station;
  final VoidCallback? onDone;

  /// Laid out like a station tile in the list under it (the home card);
  /// otherwise the compact header (the station sheet, the push banner).
  final bool stationTile;

  static const double paddingTop = 14;

  void _runPrimary(ClickTarget target) {
    final button = item.button!;
    service.report(AnnouncementEvent.clicked, item, position,
        target: target, station: station);
    unawaited(AnnouncementActions.run(item, button.action));
    onDone?.call();
  }

  void _onDismiss() {
    unawaited(service.dismiss(item, position, station: station));
    onDone?.call();
  }

  void _onLink(String href) {
    service.report(AnnouncementEvent.clicked, item, position,
        target: ClickTarget.card, station: station);
    unawaited(
        AnnouncementActions.openLink(href, LaunchMode.externalApplication));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.announcementColors;
    final hasPrimary = item.button != null;
    return Semantics(
      key: ValueKey('announcement-${item.slug}'),
      label:
          count > 1 ? AnnouncementCopy.slideLabel(position + 1, count) : null,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: hasPrimary ? () => _runPrimary(ClickTarget.card) : null,
          child: stationTile
              ? Padding(
                  padding: StationTileMetrics.contentPadding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StationTileHeader(
                          item: item, count: count, onLink: _onLink),
                      _Actions(
                        item: item,
                        onPrimary: () => _runPrimary(ClickTarget.button),
                        onDismiss: _onDismiss,
                      ),
                    ],
                  ),
                )
              : Padding(
            padding: const EdgeInsets.fromLTRB(14, paddingTop, 16, 16),
            // The icon beside the tag over the title, exactly as tall as
            // that block (the pager sits at the tag line's end, in the
            // card's corner); then the description and buttons from the
            // icon's left edge. As tall as its content wherever it sits:
            // the push banner gives it the whole screen.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(item: item, count: count),
                if (item.bodyMarkdown.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  InlineMarkdownText(
                    item.bodyMarkdown,
                    maxLines: 3,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.48,
                      color: colors.muted,
                    ),
                    strongColor: colors.strong,
                    emphasisColor: colors.text,
                    // Links read as text: the button is the one accent.
                    linkColor: colors.strong,
                    onTapLink: _onLink,
                  ),
                ],
                _Actions(
                  item: item,
                  onPrimary: () => _runPrimary(ClickTarget.button),
                  onDismiss: _onDismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The station tile's measures (StationsList), which the home card takes
/// so it reads as one of the list's tiles.
abstract final class StationTileMetrics {
  /// The logo's side and corner.
  static const double logo = 70;
  static const double logoRadius = AppRadius.thumbnail;

  /// Between the logo and the text.
  static const double logoGap = 14;

  /// Inside the card: the row's padding plus its border.
  static const EdgeInsets contentPadding =
      EdgeInsets.symmetric(horizontal: 11.5, vertical: 13.5);

  static const double titleSize = 16;
  static const double subtitleSize = 13;

  /// The title wraps to this many lines, then ends in "…".
  static const int titleLines = 3;

  /// A station tile's one corner control, the heart, sits this far from
  /// the card's bottom-right corner (its icon box): across, the row's
  /// border and padding, less its -7 offset, plus its 8 px padding; down,
  /// the border plus that padding.
  static const double cornerRight = 12.5;
  static const double cornerEdge = 9.5;

  /// The pager mirrors it in the top-right corner: its next circle as far
  /// from the card's top and right as the heart is from the bottom and
  /// right.
  static const double pagerTop = cornerEdge - _PagerButtons.circleInset;
  static const double pagerRight = cornerRight - _PagerButtons.circleInset;
}

/// The home card's top, as a station tile: the icon tile at the logo's
/// size and place, the title in the station-title style, the category as
/// a line in the announcement's hue, and the description as the grey
/// subtitle.
class _StationTileHeader extends StatelessWidget {
  const _StationTileHeader({
    required this.item,
    required this.count,
    required this.onLink,
  });

  final Announcement item;
  final int count;
  final void Function(String href) onLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.announcementColors;
    final subtitle = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);
    return LayoutBuilder(builder: (context, constraints) {
      final pager = count > 1 ? _PagerButtons.width : 0.0;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnnouncementIconTile(
            item: item,
            size: StationTileMetrics.logo,
            radius: StationTileMetrics.logoRadius,
          ),
          const SizedBox(width: StationTileMetrics.logoGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  // Clear of the pager in the card's corner.
                  padding: EdgeInsets.only(
                    right: pager > 0
                        ? pager -
                            StationTileMetrics.contentPadding.right +
                            StationTileMetrics.pagerRight
                        : 0,
                  ),
                  child: Text(
                    item.title,
                    key: const ValueKey('announcement-title'),
                    maxLines: StationTileMetrics.titleLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                      fontSize: StationTileMetrics.titleSize,
                    ),
                  ),
                ),
                if (item.category.name.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.category.name,
                    key: const ValueKey('announcement-category-line'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: StationTileMetrics.subtitleSize,
                      fontWeight: FontWeight.w600,
                      color: theme.announcementCategoryLine(item),
                    ),
                  ),
                ],
                if (item.bodyMarkdown.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  InlineMarkdownText(
                    item.bodyMarkdown,
                    maxLines: 3,
                    style: TextStyle(
                      fontSize: StationTileMetrics.subtitleSize,
                      height: 1.35,
                      color: subtitle,
                    ),
                    strongColor: colors.strong,
                    emphasisColor: colors.text,
                    linkColor: colors.strong,
                    onTapLink: onLink,
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    });
  }
}

/// The icon tile beside the tag over the title. The tile is a square as
/// tall as that block, so nothing is left empty under it: at least the
/// admin's icon size, at most [_maxTile] (a longer title then runs on
/// beside a top-aligned tile).
class _Header extends StatelessWidget {
  const _Header({required this.item, required this.count});

  final Announcement item;
  final int count;

  /// The tag pill's height, and so the tag line's.
  static const double tagHeight = AnnouncementTag.height;
  static const double _tagGap = 6;
  static const double _iconGap = 14;
  static const double _maxTile = 72;

  static const _titleStyle = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.08,
  );

  /// The tile's side for a header [width] wide.
  double _tileSide(BuildContext context, double width) {
    final hasTag = item.category.name.isNotEmpty || count > 1;
    double blockBeside(double side) {
      final title = _paint(context, item.title, _titleStyle,
          maxWidth: width - side - _iconGap);
      final height = title.height;
      title.dispose();
      return (hasTag ? tagHeight + _tagGap : 0) + height;
    }

    // The title's width depends on the tile's: settle in two rounds.
    var side = item.iconSize.extent;
    for (var round = 0; round < 2; round++) {
      side = blockBeside(side).clamp(item.iconSize.extent, _maxTile);
    }
    return side;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return LayoutBuilder(builder: (context, constraints) {
      final side = _tileSide(context, constraints.maxWidth);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnnouncementIconTile(item: item, size: side),
          const SizedBox(width: _iconGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.category.name.isNotEmpty || count > 1) ...[
                  SizedBox(
                    height: tagHeight,
                    // The label itself, not its pill, starts on the title's
                    // left edge and the icon's top.
                    child: Transform.translate(
                      offset: -AnnouncementTag.labelInset(
                          context, item.category.name),
                      child: _TagRow(item: item, count: count),
                    ),
                  ),
                  const SizedBox(height: _tagGap),
                ],
                Text(
                  item.title,
                  key: const ValueKey('announcement-title'),
                  style: _titleStyle.copyWith(color: colors.strong),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

/// The category tag, clear of the pager in the card's corner.
class _TagRow extends StatelessWidget {
  const _TagRow({required this.item, required this.count});

  final Announcement item;
  final int count;

  @override
  Widget build(BuildContext context) {
    final pager = count > 1 ? _PagerButtons.width : 0.0;
    return Padding(
      // The slide's own right padding already keeps some of it clear.
      padding: EdgeInsets.only(
        right: pager > 0 ? pager + _PagerButtons.rightInset - 16 + 4 : 0,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: item.category.name.isEmpty
            ? const SizedBox.shrink()
            : AnnouncementTag(item: item),
      ),
    );
  }
}

/// The main button, then "Ascunde", under the text, spanning the card's
/// content from the icon's left edge to the right padding, so no corner of
/// the card is left empty. The main button takes the row's width that
/// "Ascunde" leaves (a text-link button keeps its own width, on the left);
/// labels keep to one line and both buttons are one height. When they
/// don't fit side by side, each takes a full-width line, "Ascunde" under
/// the main button; only a label wider than the card is cut, its full text
/// still read out. "Ascunde" alone keeps its width, on the right.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.item,
    required this.onPrimary,
    required this.onDismiss,
  });

  final Announcement item;
  final VoidCallback onPrimary;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final button = item.button;
    final showsButton = button != null && button.isVisible;
    if (!showsButton && !item.dismissible) return const SizedBox.shrink();
    // One height for both, from whichever label is taller at this text size.
    final height = max(
      showsButton ? AnnouncementPrimaryButton.heightIn(context) : 0.0,
      item.dismissible ? _DismissButton.heightIn(context) : 0.0,
    );
    final primary = showsButton
        ? AnnouncementPrimaryButton(
            button: button, onTap: onPrimary, height: height)
        : null;
    final dismiss =
        item.dismissible ? _DismissButton(onTap: onDismiss, height: height) : null;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: LayoutBuilder(builder: (context, constraints) {
        final dismissWidth =
            dismiss == null ? 0.0 : _DismissButton.widthIn(context) + _gap;
        final oneRow = primary == null ||
            dismiss == null ||
            AnnouncementPrimaryButton.fits(
                context, button!, constraints.maxWidth - dismissWidth,
                maxLines: 1);
        final isLink = button?.style == AnnouncementButtonStyle.text;
        // The content's full width, so the right edge is the card's.
        return SizedBox(
          width: constraints.maxWidth,
          child: oneRow
              ? Row(
                  mainAxisAlignment: primary == null
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.spaceBetween,
                  children: [
                    if (primary != null)
                      isLink ? Flexible(child: primary) : Expanded(child: primary),
                    if (primary != null && dismiss != null)
                      const SizedBox(width: _gap),
                    if (dismiss != null) dismiss,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [primary, const SizedBox(height: _gap), dismiss],
                ),
        );
      }),
    );
  }

  static const double _gap = 8;
}

/// [text] in [style], laid out at the text size the listener chose.
TextPainter _paint(BuildContext context, String text, TextStyle style,
        {double maxWidth = double.infinity, int? maxLines}) =>
    TextPainter(
      text: TextSpan(
          text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);

/// The width [text] takes on one line in [style].
double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = _paint(context, text, style);
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Whether [text] in [style] fits in [maxLines] lines of [maxWidth].
bool _textFits(BuildContext context, String text, TextStyle style,
    {required double maxWidth, required int maxLines}) {
  if (maxWidth <= 0) return false;
  final painter =
      _paint(context, text, style, maxWidth: maxWidth, maxLines: maxLines);
  final fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}

/// The category's name on a soft pill of the announcement's hue.
class AnnouncementTag extends StatelessWidget {
  const AnnouncementTag({super.key, required this.item, this.surface});

  final Announcement item;

  /// What the tag sits on, when not the card (the page).
  final Color? surface;

  static const double height = 21;
  static const double padding = 9;
  static const labelStyle = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.12,
  );

  /// How far the label sits inside the pill: its padding across, and the
  /// room over it down.
  static Offset labelInset(BuildContext context, String name) {
    final label = _paint(context, name, labelStyle);
    final inset = Offset(padding, max(0, (height - label.height) / 2));
    label.dispose();
    return inset;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final category = item.category;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: padding),
      decoration: BoxDecoration(
        color: theme.announcementTagColor(item),
        borderRadius: BorderRadius.circular(999),
      ),
      // As wide as the name: a Container's own alignment would fill the
      // row.
      child: Align(
        widthFactor: 1,
        child: Text(
          category.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: labelStyle.copyWith(
            color: theme.announcementTagLabel(item, surface: surface),
          ),
        ),
      ),
    );
  }
}

/// The 44 px tile: the uploaded image, or a glyph on a neutral surface.
class AnnouncementIconTile extends StatelessWidget {
  const AnnouncementIconTile(
      {super.key, required this.item, this.size, this.radius});

  final Announcement item;

  /// The tile's side; the admin's choice (`icon.size`) when not given.
  final double? size;

  /// Its corner; in proportion to its side when not given.
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final size = this.size ?? item.iconSize.extent;
    final radius = BorderRadius.circular(this.radius ?? size * 13 / 44);
    final url = item.iconUrl;
    final glyph = _GlyphTile(item: item, size: size, radius: radius);
    if (url == null) return glyph;
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox.square(
        dimension: size,
        child: AnnouncementImage(url: url, placeholder: glyph),
      ),
    );
  }
}

class _GlyphTile extends StatelessWidget {
  const _GlyphTile({
    required this.item,
    required this.size,
    required this.radius,
  });

  final Announcement item;
  final double size;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon =
        announcementIcons[item.iconName] ?? announcementIcons['megaphone']!;
    // A soft tint of the announcement's hue with the glyph in that hue;
    // without one, a quiet raised surface like "Ascunde".
    return Container(
      key: const ValueKey('announcement-icon-tile'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.announcementIconTileColor(item),
        borderRadius: radius,
        border: Border.all(color: theme.announcementIconTileBorder(item)),
      ),
      child: Icon(
        icon,
        // Just over half the tile, never under 18.
        size: max(18.0, size * 0.55) * announcementIconScale(icon),
        color: theme.announcementGlyphColor(item),
      ),
    );
  }
}

/// The main button, filled, outlined or as a text link, with the icon
/// that says what it does after its bold label.
class AnnouncementPrimaryButton extends StatelessWidget {
  const AnnouncementPrimaryButton({
    super.key,
    required this.button,
    required this.onTap,
    this.height,
  });

  final AnnouncementButton button;
  final VoidCallback onTap;

  /// Its height, shared with "Ascunde"; its own when not given.
  final double? height;

  static const _labelStyle = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.07,
  );
  static const _labelLines = 1;
  static const _iconGap = 7.0;

  static EdgeInsets _padding(bool isText) => isText
      ? const EdgeInsets.symmetric(horizontal: 4)
      : const EdgeInsets.only(left: 15, right: 14);

  static const double _minHeight = 36;
  static const double _labelLineHeight = 1.25;

  /// The button's height at this text size: its label's line and some air,
  /// at least [_minHeight].
  static double heightIn(BuildContext context) {
    final line = _paint(context, ' ',
        _labelStyle.copyWith(height: _labelLineHeight));
    final height = line.height;
    line.dispose();
    return max(_minHeight, height + 16);
  }

  static double _iconSize(IconData icon) => 15 * announcementIconScale(icon);

  /// Whether [button]'s label fits in [maxLines] lines (one unless given)
  /// on a button at most [maxWidth] wide.
  static bool fits(
      BuildContext context, AnnouncementButton button, double maxWidth,
      {int maxLines = _labelLines}) {
    final icon = announcementButtonIcon(button);
    final chrome = _padding(button.style == AnnouncementButtonStyle.text)
            .horizontal +
        (icon == null ? 0 : _iconGap + _iconSize(icon));
    return _textFits(context, button.label, _labelStyle,
        maxWidth: maxWidth - chrome, maxLines: maxLines);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.announcementColors;
    final fill = theme.announcementButtonColor(button);
    final ink = colors.inkOf(fill);
    final filled = button.style == AnnouncementButtonStyle.filled;
    final isText = button.style == AnnouncementButtonStyle.text;
    final foreground = filled ? theme.announcementButtonLabel(button) : ink;
    final icon = announcementButtonIcon(button);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: button.style == AnnouncementButtonStyle.outline
          ? BorderSide(color: ink, width: 1.5)
          : BorderSide.none,
    );
    return Material(
      color: filled ? fill : Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height ?? heightIn(context),
          padding: _padding(isText),
          // As wide as its content, and centered in the minimum height.
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  button.label,
                  maxLines: _labelLines,
                  overflow: TextOverflow.ellipsis,
                  // Two lines hug the text, so the icon follows it.
                  textWidthBasis: TextWidthBasis.longestLine,
                  style: _labelStyle.copyWith(
                      color: foreground, height: _labelLineHeight),
                ),
              ),
              if (icon != null) ...[
                const SizedBox(width: _iconGap),
                Icon(
                  icon,
                  size: _iconSize(icon),
                  color: foreground.withValues(alpha: 0.9),
                ),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// "✕ Ascunde": hides the announcement for good on this device. A quiet
/// outlined button that sinks a little while pressed.
class _DismissButton extends StatefulWidget {
  const _DismissButton({required this.onTap, required this.height});

  final VoidCallback onTap;

  /// Its height, shared with the main button.
  final double height;

  /// Its own height at this text size: its label's line and some air, at
  /// least 36.
  static double heightIn(BuildContext context) {
    final line = _paint(context, ' ', _DismissButtonState._labelStyle);
    final height = line.height;
    line.dispose();
    return max(36, height + 16);
  }

  /// Its width at the text size the listener chose.
  static double widthIn(BuildContext context) =>
      _DismissButtonState._padding.horizontal +
      _DismissButtonState._iconSize +
      _DismissButtonState._iconGap +
      _textWidth(context, AnnouncementCopy.dismiss,
          _DismissButtonState._labelStyle);

  @override
  State<_DismissButton> createState() => _DismissButtonState();
}

class _DismissButtonState extends State<_DismissButton> {
  bool _pressed = false;

  static const _labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
  static const _padding = EdgeInsets.only(left: 11, right: 13);
  static const _iconSize = 14.0;
  static const _iconGap = 6.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: colors.border),
    );
    return Semantics(
      button: true,
      label: AnnouncementCopy.dismissLabel,
      excludeSemantics: true,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: const Duration(milliseconds: 150),
        child: Material(
          color: colors.control,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('announcement-dismiss'),
            onTap: widget.onTap,
            onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
            highlightColor: colors.dot,
            child: Container(
              height: widget.height,
              padding: _padding,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                // Centered when it is given a full-width line.
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.close_rounded, size: _iconSize, color: colors.text),
                  const SizedBox(width: _iconGap),
                  Text(
                    AnnouncementCopy.dismiss,
                    maxLines: 1,
                    softWrap: false,
                    style: _labelStyle.copyWith(color: colors.text),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Previous" and "next", at the end of the icon row: quiet round buttons
/// like "Ascunde", each in a 44 pt touch area as tall as the row. At the
/// first and the last announcement the way out is faded and disabled.
class _PagerButtons extends StatelessWidget {
  const _PagerButtons({
    required this.position,
    required this.onPrevious,
    required this.onNext,
  });

  /// "2 din 4": read out by a screen reader, never shown, so the title
  /// gets the room.
  final String position;

  /// Null on the first announcement.
  final VoidCallback? onPrevious;

  /// Null on the last announcement.
  final VoidCallback? onNext;

  /// Each arrow's touch area.
  static const double target = 44;

  /// Each arrow's circle, centered in its touch area.
  static const double circle = 32;
  static const double circleInset = (target - circle) / 2;

  /// From the card's right edge, so the circles sit 10 px in from it.
  static const double rightInset = 4;

  /// The two arrows side by side.
  static const double width = 2 * target;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('announcement-position'),
      container: true,
      label: position,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PagerButton(
            semanticsKey: const ValueKey('announcement-previous'),
            icon: Icons.chevron_left_rounded,
            label: AnnouncementCopy.previous,
            onTap: onPrevious,
          ),
          _PagerButton(
            semanticsKey: const ValueKey('announcement-next'),
            icon: Icons.chevron_right_rounded,
            label: AnnouncementCopy.next,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

class _PagerButton extends StatelessWidget {
  const _PagerButton({
    required this.semanticsKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// Keys the semantics node, which says whether the button is enabled.
  final Key semanticsKey;
  final IconData icon;
  final String label;

  /// Null when there is nothing that way: the button fades and is off.
  final VoidCallback? onTap;

  /// How much shows of a button that leads nowhere.
  static const double _disabledOpacity = 0.38;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final enabled = onTap != null;
    return Tooltip(
      message: label,
      child: Semantics(
        key: semanticsKey,
        button: true,
        enabled: enabled,
        label: label,
        excludeSemantics: true,
        // The whole touch area takes the tap, also when off, so it never
        // reaches the card under it (which would open the announcement).
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: InkResponse(
            onTap: onTap,
            radius: 18,
            highlightColor: colors.dot,
            child: SizedBox.square(
              dimension: _PagerButtons.target,
              child: AnimatedOpacity(
                opacity: enabled ? 1 : _disabledOpacity,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                child: Center(
                  child: Container(
                    key: const ValueKey('announcement-pager-circle'),
                    width: _PagerButtons.circle,
                    height: _PagerButtons.circle,
                    decoration: BoxDecoration(
                      color: colors.control,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.border),
                    ),
                    child: Icon(icon, size: 20, color: colors.text),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
