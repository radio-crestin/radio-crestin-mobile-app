import 'dart:async';

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
/// only after the listener's own swipe, dot tap or "Ascunde", and then
/// eases over [_resizeDuration]; on the first frame it is already right.
class AnnouncementCard extends StatefulWidget {
  const AnnouncementCard({
    super.key,
    required this.items,
    required this.service,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 4),
  });

  final List<Announcement> items;
  final AnnouncementsService service;
  final EdgeInsetsGeometry margin;

  @override
  State<AnnouncementCard> createState() => _AnnouncementCardState();
}

class _AnnouncementCardState extends State<AnnouncementCard> {
  final PageController _pages = PageController();
  int _index = 0;

  /// Whether the listener moved the card, so its height may now animate.
  bool _resizeAnimates = false;

  static const _resizeDuration = Duration(milliseconds: 280);
  static const _easing = Cubic(0.2, 0.8, 0.2, 1);
  static const _slideDuration = Duration(milliseconds: 420);

  List<Announcement> get _items => widget.items;
  int get _shown => _index.clamp(0, _items.length - 1);

  @override
  void didUpdateWidget(AnnouncementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSlugs = oldWidget.items.map((item) => item.slug).join('\n');
    if (oldSlugs == _items.map((item) => item.slug).join('\n')) return;
    // One was closed: the next one takes its place.
    _resizeAnimates = true;
    if (_index >= _items.length && _items.isNotEmpty) {
      _index = _items.length - 1;
      if (_pages.hasClients) _pages.jumpToPage(_index);
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) => setState(() {
        _index = index;
        _resizeAnimates = true;
      });

  void _goTo(int index) =>
      _pages.animateToPage(index, duration: _slideDuration, curve: _easing);

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final count = _items.length;
    return Semantics(
      container: true,
      label: AnnouncementCopy.carouselLabel,
      child: _CardFrame(
        key: const ValueKey('announcement-card'),
        margin: widget.margin,
        child: AnimatedSize(
          duration: _resizeAnimates ? _resizeDuration : Duration.zero,
          curve: _easing,
          alignment: Alignment.topCenter,
          child: Stack(
            children: [
              // The shown slide, invisible, sizes the card in the same
              // frame; the pages fill that box.
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: ExcludeSemantics(child: _slide(_shown, measuring: true)),
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
                  top: _Slide.iconRowTop,
                  right: 10,
                  height: _Slide.iconSize,
                  child: _Dots(count: count, index: _shown, onTap: _goTo),
                ),
            ],
          ),
        ),
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
  const _CardFrame({super.key, required this.margin, required this.child});

  final EdgeInsetsGeometry margin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
        boxShadow: colors.shadows,
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(15), child: child),
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
    if (seconds != null && seconds > 0) {
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
  });

  final Announcement item;
  final int position;
  final int count;
  final AnnouncementsService service;
  final String? station;
  final VoidCallback? onDone;

  static const double iconSize = 44;
  static const double iconRowTop = 14;

  void _runPrimary(ClickTarget target) {
    final button = item.button!;
    service.report(AnnouncementEvent.clicked, item, position,
        target: target, station: station);
    unawaited(AnnouncementActions.run(item, button.action));
    onDone?.call();
  }

  void _onSecondary(AnnouncementSecondaryButton button) {
    service.report(AnnouncementEvent.secondaryClicked, item, position,
        station: station);
    switch (button.kind) {
      case SecondaryButtonKind.close:
        unawaited(service.dismiss(item, position, station: station));
      case SecondaryButtonKind.later:
        unawaited(service.snooze(item, button.laterDays ?? 1));
      case SecondaryButtonKind.action:
        unawaited(AnnouncementActions.run(item, button.action!));
    }
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
    final colors = Theme.of(context).announcementColors;
    final accent = item.color;
    final hasPrimary = item.button != null;
    return Semantics(
      key: ValueKey('announcement-${item.slug}'),
      label:
          count > 1 ? AnnouncementCopy.slideLabel(position + 1, count) : null,
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(gradient: colors.washOf(accent)),
          child: InkWell(
            onTap: hasPrimary ? () => _runPrimary(ClickTarget.card) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, iconRowTop, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IconRow(item: item, position: position, count: count),
                  const SizedBox(height: 12),
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
                      maxLines: 3,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.48,
                        color: colors.muted,
                      ),
                      strongColor: colors.strong,
                      emphasisColor: colors.text,
                      linkColor: colors.inkOf(accent),
                      onTapLink: _onLink,
                    ),
                  ],
                  _Actions(
                    item: item,
                    onPrimary: () => _runPrimary(ClickTarget.button),
                    onSecondary: _onSecondary,
                    onDismiss: _onDismiss,
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

/// The 44 px icon, then the category tag and "1 din 3", centered on it.
class _IconRow extends StatelessWidget {
  const _IconRow({
    required this.item,
    required this.position,
    required this.count,
  });

  final Announcement item;
  final int position;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return SizedBox(
      height: _Slide.iconSize,
      child: Row(
        children: [
          AnnouncementIconTile(item: item),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              // Clear of the dots in the corner.
              padding: EdgeInsets.only(right: count > 1 ? 66 : 0),
              child: Row(
                children: [
                  if (item.category.name.isNotEmpty)
                    Flexible(child: AnnouncementTag(category: item.category)),
                  if (count > 1) ...[
                    const SizedBox(width: 8),
                    Text(
                      AnnouncementCopy.count(position + 1, count),
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
          ),
        ],
      ),
    );
  }
}

/// The main button, the second one, and "Ascunde" on the right.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.item,
    required this.onPrimary,
    required this.onSecondary,
    required this.onDismiss,
  });

  final Announcement item;
  final VoidCallback onPrimary;
  final ValueChanged<AnnouncementSecondaryButton> onSecondary;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final button = item.button;
    final secondary = item.secondaryButton;
    // "Ascunde" already closes a dismissible one.
    final showSecondary = secondary != null &&
        !(item.dismissible && secondary.kind == SecondaryButtonKind.close);
    final buttons = [
      if (button != null && button.isVisible)
        AnnouncementPrimaryButton(button: button, onTap: onPrimary),
      if (showSecondary)
        _SecondaryButton(
          label: secondary.label,
          onTap: () => onSecondary(secondary),
        ),
    ];
    if (buttons.isEmpty && !item.dismissible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: buttons,
            ),
          ),
          if (item.dismissible) ...[
            const SizedBox(width: 6),
            _DismissButton(onTap: onDismiss),
          ],
        ],
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
  const AnnouncementIconTile({super.key, required this.item, this.size = 44});

  final Announcement item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 13 / 44);
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
    final colors = Theme.of(context).announcementColors;
    final icon =
        announcementIcons[item.iconName] ?? announcementIcons['megaphone']!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: item.color.withValues(alpha: 0.18),
        borderRadius: radius,
      ),
      child: Icon(
        icon,
        size: size * 23 / 44 * announcementIconScale(icon),
        color: colors.inkOf(item.color),
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
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.07,
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

/// The quiet second button: "Mai târziu" or another action.
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

/// "✕ Ascunde": hides the announcement for good on this device. A quiet
/// outlined button that sinks a little while pressed.
class _DismissButton extends StatefulWidget {
  const _DismissButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_DismissButton> createState() => _DismissButtonState();
}

class _DismissButtonState extends State<_DismissButton> {
  bool _pressed = false;

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
              height: 36,
              padding: const EdgeInsets.only(left: 11, right: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close_rounded, size: 14, color: colors.text),
                  const SizedBox(width: 6),
                  Text(
                    AnnouncementCopy.dismiss,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
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
}

/// One dot per announcement; the shown one is longer. A dot takes the
/// card to its announcement.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index, required this.onTap});

  final int count;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          Semantics(
            button: true,
            selected: i == index,
            label: AnnouncementCopy.slideLabel(i + 1, count),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 2.5, vertical: 13),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  width: i == index ? 22 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == index
                        ? colors.strong.withValues(alpha: 0.85)
                        : colors.dot,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
