import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../services/announcement.dart';
import '../services/announcement_actions.dart';
import '../services/announcement_copy.dart';
import '../services/announcements_service.dart';
import '../theme.dart';
import 'announcement_icons.dart';
import 'inline_markdown.dart';
import 'retrying_network_image.dart';

/// The announcements above the station list: one card that swipes
/// between them, plays through them, and fills a dot as the next one
/// nears.
///
/// The look is the announcements design (`.ann--mobile`): an icon tile,
/// a category tag, a title, a short markdown body and up to two buttons
/// on a faint wash of the announcement's color.
class AnnouncementCard extends StatefulWidget {
  const AnnouncementCard({
    super.key,
    required this.items,
    required this.settings,
    required this.service,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 4),
    this.onDone,
  });

  final List<Announcement> items;
  final AnnouncementSettings settings;
  final AnnouncementsService service;
  final EdgeInsetsGeometry margin;

  /// Called after a button, a link or the X was tapped (the push banner
  /// then hides).
  final VoidCallback? onDone;

  @override
  State<AnnouncementCard> createState() => _AnnouncementCardState();
}

class _AnnouncementCardState extends State<AnnouncementCard>
    with SingleTickerProviderStateMixin {
  final PageController _pages = PageController();
  late final AnimationController _autoplay = AnimationController(vsync: this)
    ..addStatusListener(_onAutoplayStatus);

  /// Each slide's natural height, by slug, so the card fits the one shown.
  final Map<String, double> _heights = {};

  int _index = 0;
  bool _touched = false;
  bool _visible = false;
  Timer? _impressionTimer;
  final Map<String, Timer> _hideTimers = {};

  static const _impressionDelay = Duration(seconds: 1);
  static const _slideDuration = Duration(milliseconds: 420);
  static const _slideCurve = Cubic(0.2, 0.8, 0.2, 1);

  List<Announcement> get _items => widget.items;
  Announcement get _current => _items[_index.clamp(0, _items.length - 1)];

  @override
  void initState() {
    super.initState();
    _autoplay.duration = Duration(seconds: widget.settings.autoplaySeconds);
  }

  /// The home page rebuilds every few seconds (live song titles): only a
  /// different list starts the dot over.
  @override
  void didUpdateWidget(AnnouncementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameItems = _slugs(oldWidget.items).join() == _slugs(_items).join();
    final sameSettings =
        oldWidget.settings.autoplaySeconds == widget.settings.autoplaySeconds;
    if (sameItems && sameSettings) return;
    if (_index >= _items.length && _items.isNotEmpty) {
      _index = _items.length - 1;
      if (_pages.hasClients) _pages.jumpToPage(_index);
    }
    _restartAutoplay();
    _watchImpression();
  }

  static Iterable<String> _slugs(List<Announcement> items) =>
      items.map((item) => '${item.slug}\n');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resumeAutoplay();
  }

  @override
  void dispose() {
    _impressionTimer?.cancel();
    for (final timer in _hideTimers.values) {
      timer.cancel();
    }
    _autoplay.dispose();
    _pages.dispose();
    super.dispose();
  }

  // ── Autoplay ───────────────────────────────────────────────────────────

  bool get _autoplays =>
      _items.length > 1 &&
      widget.settings.autoplaySeconds > 0 &&
      !MediaQuery.of(context).disableAnimations;

  void _restartAutoplay() {
    _autoplay.duration = Duration(seconds: widget.settings.autoplaySeconds);
    _autoplay.value = 0;
    _resumeAutoplay();
  }

  /// Runs the dot on while the card is on screen and not touched.
  void _resumeAutoplay() {
    if (_autoplays && _visible && !_touched) {
      _autoplay.forward();
    } else {
      _autoplay.stop();
    }
  }

  void _onAutoplayStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_pages.hasClients) return;
    final next = (_index + 1) % _items.length;
    _pages.animateToPage(next, duration: _slideDuration, curve: _slideCurve);
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    _restartAutoplay();
    _watchImpression();
  }

  void _setTouched(bool touched) {
    _touched = touched;
    _resumeAutoplay();
  }

  // ── Impressions ────────────────────────────────────────────────────────

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    final visible = info.visibleFraction >= 0.5;
    if (visible == _visible) return;
    _visible = visible;
    _resumeAutoplay();
    _watchImpression();
  }

  /// Counts the slide shown once it stayed half visible for a second.
  void _watchImpression() {
    _impressionTimer?.cancel();
    if (!_visible || _items.isEmpty) return;
    final item = _current;
    final position = _index;
    _impressionTimer = Timer(_impressionDelay, () {
      widget.service.recordImpression(item, position);
      _scheduleHide(item);
    });
  }

  /// Takes [item] off the screen after its `hide_after_seconds`.
  void _scheduleHide(Announcement item) {
    final seconds = item.hideAfterSeconds;
    if (seconds == null || seconds <= 0) return;
    _hideTimers.putIfAbsent(
      item.slug,
      () => Timer(Duration(seconds: seconds),
          () => widget.service.hideForThisLaunch(item)),
    );
  }

  // ── Taps ───────────────────────────────────────────────────────────────

  void _onPrimary(Announcement item, AnnouncementButton button) {
    widget.service.report(AnnouncementEvent.clicked, item, _index);
    unawaited(AnnouncementActions.run(item, button.action));
    widget.onDone?.call();
  }

  void _onSecondary(Announcement item, AnnouncementSecondaryButton button) {
    final service = widget.service;
    service.report(AnnouncementEvent.secondaryClicked, item, _index);
    switch (button.kind) {
      case SecondaryButtonKind.close:
        unawaited(service.dismiss(item, _index));
      case SecondaryButtonKind.later:
        unawaited(service.snooze(item, button.laterDays ?? 1));
      case SecondaryButtonKind.action:
        unawaited(AnnouncementActions.run(item, button.action!));
    }
    widget.onDone?.call();
  }

  void _onLink(Announcement item, String href) {
    widget.service.report(AnnouncementEvent.clicked, item, _index);
    final uri = Uri.tryParse(href);
    if (uri != null) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
    }
  }

  void _onClose() {
    unawaited(widget.service.dismiss(_current, _index));
    widget.onDone?.call();
  }

  // ── Layout ─────────────────────────────────────────────────────────────

  void _onSlideMeasured(String slug, double height) {
    if (_heights[slug] == height) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _heights[slug] = height);
    });
  }

  /// The card's height: the shown slide's, blended with the next one's
  /// while a swipe is between them.
  double? _heightAt(double page) {
    final lower = page.floor().clamp(0, _items.length - 1);
    final upper = page.ceil().clamp(0, _items.length - 1);
    final from = _heights[_items[lower].slug];
    final to = _heights[_items[upper].slug];
    if (from == null || to == null) return from ?? to;
    return lerpDouble(from, to, page - lower);
  }

  _Slide _slide(int index) {
    final item = _items[index];
    return _Slide(
      item: item,
      index: index,
      count: _items.length,
      onPrimary: (button) => _onPrimary(item, button),
      onSecondary: (button) => _onSecondary(item, button),
      onLink: (href) => _onLink(item, href),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).announcementColors;
    return VisibilityDetector(
      key: ObjectKey(this),
      onVisibilityChanged: _onVisibilityChanged,
      child: Semantics(
        container: true,
        label: AnnouncementCopy.carouselLabel,
        child: Container(
          key: const ValueKey('announcement-card'),
          margin: widget.margin,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.border),
            boxShadow: colors.shadows,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Listener(
              onPointerDown: (_) => _setTouched(true),
              onPointerUp: (_) => _setTouched(false),
              onPointerCancel: (_) => _setTouched(false),
              child: Stack(
                children: [
                  _measuredSlides(),
                  _viewport(),
                  if (_items.length > 1)
                    Positioned(
                      right: 16,
                      bottom: 27,
                      child: _Dots(
                        count: _items.length,
                        index: _index,
                        progress: _autoplay,
                        autoplays: _autoplays,
                      ),
                    ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: _current.dismissible
                          ? _CloseButton(
                              key: const ValueKey('close'),
                              onTap: _onClose,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Every slide laid out but not painted, to learn its height.
  Widget _measuredSlides() => Offstage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _items.length; i++)
              _SizeReporter(
                onSize: (size) => _onSlideMeasured(_items[i].slug, size.height),
                child: ExcludeSemantics(child: _slide(i)),
              ),
          ],
        ),
      );

  Widget _viewport() => AnimatedBuilder(
        animation: _pages,
        builder: (context, child) {
          final page = _pages.hasClients && _pages.position.haveDimensions
              ? _pages.page ?? _index.toDouble()
              : _index.toDouble();
          final height = _heightAt(page);
          if (height == null) return const SizedBox.shrink();
          return SizedBox(height: height, child: child);
        },
        child: PageView.builder(
          controller: _pages,
          itemCount: _items.length,
          onPageChanged: _onPageChanged,
          allowImplicitScrolling: true,
          itemBuilder: (context, index) => OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: _slide(index),
          ),
        ),
      );
}

/// One announcement: icon, tag and count, title, body and buttons.
class _Slide extends StatelessWidget {
  const _Slide({
    required this.item,
    required this.index,
    required this.count,
    required this.onPrimary,
    required this.onSecondary,
    required this.onLink,
  });

  final Announcement item;
  final int index;
  final int count;
  final ValueChanged<AnnouncementButton> onPrimary;
  final ValueChanged<AnnouncementSecondaryButton> onSecondary;
  final ValueChanged<String> onLink;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final accent = item.color;
    final button = item.button;
    final secondary = item.secondaryButton;
    final hasActions = button != null || secondary != null;
    return Semantics(
      key: ValueKey('announcement-${item.slug}'),
      label: count > 1 ? AnnouncementCopy.slideLabel(index + 1, count) : null,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: colors.washOf(accent)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnnouncementIconTile(item: item),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Meta(item: item, index: index, count: count),
                    const SizedBox(height: 5),
                    Text(
                      item.title,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.08,
                        color: colors.strong,
                      ),
                    ),
                    if (item.bodyMarkdown.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      InlineMarkdownText(
                        item.bodyMarkdown,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.48,
                          color: colors.muted,
                        ),
                        strongColor: colors.strong,
                        emphasisColor: colors.text,
                        linkColor: colors.inkOf(accent),
                        onTapLink: onLink,
                      ),
                    ],
                    if (hasActions) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (button != null)
                            AnnouncementPrimaryButton(
                              button: button,
                              onTap: () => onPrimary(button),
                            ),
                          if (secondary != null)
                            _SecondaryButton(
                              label: secondary.label,
                              onTap: () => onSecondary(secondary),
                            ),
                        ],
                      ),
                    ] else if (count > 1)
                      // Room for the dots under the text.
                      const SizedBox(height: 20),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The category tag, then "1 din 3" when there are several.
class _Meta extends StatelessWidget {
  const _Meta({required this.item, required this.index, required this.count});

  final Announcement item;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 22),
      child: Padding(
        // Clear of the X.
        padding: const EdgeInsets.only(right: 36),
        child: Row(
          children: [
            if (item.category.name.isNotEmpty)
              Flexible(child: AnnouncementTag(category: item.category)),
            if (count > 1) ...[
              const SizedBox(width: 8),
              Text(
                AnnouncementCopy.count(index + 1, count),
                style: TextStyle(
                  fontSize: 12,
                  color: colors.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The category's name on a pill of its color.
class AnnouncementTag extends StatelessWidget {
  const AnnouncementTag({super.key, required this.category});

  final AnnouncementCategory category;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 21,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: category.color,
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
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.12,
            color: category.textColor,
          ),
        ),
      ),
    );
  }
}

/// The 44 px tile: the uploaded image, or a glyph on a tint of the color.
class AnnouncementIconTile extends StatelessWidget {
  const AnnouncementIconTile({super.key, required this.item});

  final Announcement item;

  static const double _size = 44;
  static final _radius = BorderRadius.circular(13);

  @override
  Widget build(BuildContext context) {
    final url = item.iconUrl;
    if (url == null) return _glyphTile(context);
    return ClipRRect(
      borderRadius: _radius,
      child: SizedBox.square(
        dimension: _size,
        child: RetryingNetworkImage(
          url: url,
          cache: true,
          loading: _glyphTile,
          failed: _glyphTile,
        ),
      ),
    );
  }

  Widget _glyphTile(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final icon =
        announcementIcons[item.iconName] ?? announcementIcons['megaphone']!;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: item.color.withValues(alpha: 0.18),
        borderRadius: _radius,
      ),
      child: Icon(
        icon,
        size: 23 * announcementIconScale(icon),
        color: colors.inkOf(item.color),
      ),
    );
  }
}

/// The main button, filled, outlined or as a text link, with the icon
/// that says what it does after its label.
class AnnouncementPrimaryButton extends StatelessWidget {
  const AnnouncementPrimaryButton({
    super.key,
    required this.button,
    required this.onTap,
  });

  final AnnouncementButton button;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final ink = colors.inkOf(button.color);
    final filled = button.style == AnnouncementButtonStyle.filled;
    final isText = button.style == AnnouncementButtonStyle.text;
    final foreground = filled ? button.textColor : ink;
    final icon = announcementButtonIcon(button);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: button.style == AnnouncementButtonStyle.outline
          ? BorderSide(color: ink, width: 1.5)
          : BorderSide.none,
    );
    return Material(
      color: filled ? button.color : Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: isText ? 32 : 36,
          padding: isText
              ? const EdgeInsets.symmetric(horizontal: 4)
              : const EdgeInsets.only(left: 15, right: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  button.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
              if (icon != null) ...[
                const SizedBox(width: 7),
                Icon(
                  icon,
                  size: 15 * announcementIconScale(icon),
                  color: foreground.withValues(alpha: 0.9),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The quiet second button: "Mai târziu", "Închide" or another action.
class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        highlightColor: colors.control,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Align(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: colors.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The X: a 32 px circle 8 px in from the corner, inside a 48 px target.
class _CloseButton extends StatelessWidget {
  const _CloseButton({super.key, required this.onTap});

  final VoidCallback onTap;

  static const double _target = 48;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return Tooltip(
      message: AnnouncementCopy.close,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: onTap,
          radius: 16,
          highlightColor: colors.control,
          child: SizedBox.square(
            dimension: _target,
            child: Icon(Icons.close_rounded, size: 18, color: colors.muted),
          ),
        ),
      ),
    );
  }
}

/// One dot per announcement; the shown one is wider and fills up as the
/// next one nears.
class _Dots extends StatelessWidget {
  const _Dots({
    required this.count,
    required this.index,
    required this.progress,
    required this.autoplays,
  });

  final int count;
  final int index;
  final Animation<double> progress;
  final bool autoplays;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              width: i == index ? 22 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.dot,
                borderRadius: BorderRadius.circular(999),
              ),
              clipBehavior: Clip.antiAlias,
              child: i == index ? _fill(colors) : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _fill(AnnouncementColors colors) => AnimatedBuilder(
        animation: progress,
        builder: (context, _) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: autoplays ? progress.value : 1,
          child: ColoredBox(color: colors.strong.withValues(alpha: 0.85)),
        ),
      );
}

/// Reports its child's size after each layout.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReporter renderObject,
  ) =>
      renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}
