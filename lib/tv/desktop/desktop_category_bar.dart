import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../queries/getStations.graphql.dart';
import '../../services/station_group_categories.dart';
import '../../widgets/station_group_picture.dart';
import '../tv_theme.dart';

/// The categories as a row of chips, each with its picture and number of
/// stations, "Toate stațiile" first: the phone's filter sheet laid out for
/// a wide window, one click away.
///
/// The row scrolls sideways when it doesn't fit: dragged with the mouse
/// or the trackpad, with the mouse wheel, or with the arrows that show at
/// an edge with more chips past it. A click whose mouse slips a little
/// still chooses its chip.
class DesktopCategoryBar extends StatefulWidget {
  const DesktopCategoryBar({
    super.key,
    required this.offer,
    required this.selectedGroupId,
    required this.onSelected,
  });

  /// The categories and their station counts.
  final StationGroupCategories offer;

  /// The chosen category's group id; null shows every station.
  final int? selectedGroupId;

  /// Called with the group the listener picked, or null for every station.
  final ValueChanged<Query$GetStations$station_groups?> onSelected;

  static const String allLabel = 'Toate stațiile';

  @override
  State<DesktopCategoryBar> createState() => _DesktopCategoryBarState();
}

class _DesktopCategoryBarState extends State<DesktopCategoryBar> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _selectedKey = GlobalKey(debugLabel: 'selected category');

  bool _canScrollBack = false;
  bool _canScrollForward = false;

  /// The mouse's drag of the row, as the list's own drag does a finger's.
  Drag? _drag;
  ScrollHoldController? _hold;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateEdges());
  }

  @override
  void didUpdateWidget(DesktopCategoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateEdges();
      if (oldWidget.selectedGroupId != widget.selectedGroupId) {
        _revealSelected();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _updateEdges() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    final back = position.pixels > position.minScrollExtent + 1;
    final forward = position.pixels < position.maxScrollExtent - 1;
    if (back != _canScrollBack || forward != _canScrollForward) {
      setState(() {
        _canScrollBack = back;
        _canScrollForward = forward;
      });
    }
  }

  /// Brings the chosen chip into view when part of it is past an edge, by
  /// as little as it takes; a chip in view stays where the click found it.
  void _revealSelected() {
    final chip = _selectedKey.currentContext;
    if (!mounted || chip == null) return;
    // At most one of the two moves the row: past the end, the first
    // brings the chip's end in; past the start, the second its start.
    for (final policy in const [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ]) {
      Scrollable.ensureVisible(
        chip,
        alignmentPolicy: policy,
        duration: DesktopTokens.contentDuration,
        curve: Curves.easeInOut,
      );
    }
  }

  void _page({required bool forward}) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final step = position.viewportDimension * 0.7;
    final target = (position.pixels + (forward ? step : -step))
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: DesktopTokens.contentDuration,
      curve: Curves.easeInOut,
    );
  }

  void _onMouseDragDown(DragDownDetails details) {
    if (_scroll.hasClients) _hold = _scroll.position.hold(() => _hold = null);
  }

  void _onMouseDragStart(DragStartDetails details) {
    if (!_scroll.hasClients) return;
    _drag = _scroll.position.drag(details, () => _drag = null);
    _hold?.cancel();
  }

  void _onMouseDragUpdate(DragUpdateDetails details) {
    _drag?.update(details);
  }

  void _onMouseDragEnd(DragEndDetails details) {
    _drag?.end(details);
  }

  void _onMouseDragCancel() {
    _hold?.cancel();
    _drag?.cancel();
  }

  /// A mouse wheel scrolls the row sideways: it has no other way to go.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    final delta = event.scrollDelta;
    if (delta.dy == 0 || delta.dx.abs() > delta.dy.abs()) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final position = _scroll.position;
      final dy = (event as PointerScrollEvent).scrollDelta.dy;
      _scroll.jumpTo(
        (position.pixels + dy)
            .clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final selected = widget.selectedGroupId;
    final chips = <Widget>[
      _CategoryChip(
        key: selected == null ? _selectedKey : null,
        slug: null,
        label: DesktopCategoryBar.allLabel,
        count: offer.stationCount,
        selected: selected == null,
        onPressed: () => widget.onSelected(null),
      ),
      for (final category in offer.categories)
        _CategoryChip(
          key: category.group.id == selected ? _selectedKey : null,
          slug: category.group.slug,
          label: category.group.name,
          count: category.stationCount,
          selected: category.group.id == selected,
          // The chosen category again shows every station, as on the phone.
          onPressed: () => widget.onSelected(
            category.group.id == selected ? null : category.group,
          ),
        ),
    ];
    return SizedBox(
      height: DesktopTokens.categoryBarHeight,
      child: Stack(
        children: [
          Listener(
            onPointerSignal: _onPointerSignal,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _updateEdges();
                return false;
              },
              // A drag with the mouse moves the row too, as with a finger,
              // once it is past a click's slip.
              child: RawGestureDetector(
                gestures: {
                  _MouseDragRecognizer: GestureRecognizerFactoryWithHandlers<
                      _MouseDragRecognizer>(
                    () => _MouseDragRecognizer(debugOwner: this),
                    (recognizer) => recognizer
                      // The row follows the mouse from where it was
                      // pressed, without a jump past the slip.
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onDown = _onMouseDragDown
                      ..onStart = _onMouseDragStart
                      ..onUpdate = _onMouseDragUpdate
                      ..onEnd = _onMouseDragEnd
                      ..onCancel = _onMouseDragCancel,
                  ),
                },
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: const {
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.touch,
                    },
                    scrollbars: false,
                  ),
                  child: ListView.separated(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: DesktopTokens.gutter,
                      vertical: 8,
                    ),
                    itemCount: chips.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, index) => chips[index],
                  ),
                ),
              ),
            ),
          ),
          _EdgeArrow(
            visible: _canScrollBack,
            forward: false,
            onPressed: () => _page(forward: false),
          ),
          _EdgeArrow(
            visible: _canScrollForward,
            forward: true,
            onPressed: () => _page(forward: true),
          ),
        ],
      ),
    );
  }
}

/// The mouse's drag of the category row. Flutter's own drag takes the row
/// from the first pixel a mouse moves, which turns a click whose mouse
/// slips a little into a drag that chooses nothing; this one waits for
/// [slop].
class _MouseDragRecognizer extends HorizontalDragGestureRecognizer {
  _MouseDragRecognizer({super.debugOwner})
      : super(supportedDevices: const {PointerDeviceKind.mouse});

  /// How far a press moves sideways before it drags the row. A click
  /// still counts up to the tap's own slip of 18.
  static const double slop = 8;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved.abs() > slop;
}

/// A category's chip: its picture, its name and how many stations it has;
/// tinted and outlined while chosen. Its text keeps one weight either way,
/// so choosing a chip never changes its width and nudges the others.
///
/// A press shows as the chip sinking a little, without Material's ripple;
/// choosing it fades in the tint and the outline.
class _CategoryChip extends StatefulWidget {
  const _CategoryChip({
    super.key,
    required this.slug,
    required this.label,
    required this.count,
    required this.selected,
    required this.onPressed,
  });

  /// The category's slug for its picture; null is "Toate stațiile".
  final String? slug;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<_CategoryChip> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final Color fill;
    if (selected) {
      fill = TvColors.primary.withValues(alpha: 0.18);
    } else if (_pressed) {
      fill = Colors.white.withValues(alpha: 0.14);
    } else if (_hovered) {
      fill = DesktopTokens.controlHoverFill;
    } else {
      fill = DesktopTokens.controlFill;
    }
    return Semantics(
      selected: selected,
      button: true,
      label: '${widget.label}, ${widget.count}',
      excludeSemantics: true,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: DesktopTokens.hoverDuration,
          curve: Curves.easeOut,
          decoration: ShapeDecoration(
            color: fill,
            shape: StadiumBorder(
              side: BorderSide(
                color: selected
                    ? TvColors.primary.withValues(alpha: 0.6)
                    : DesktopTokens.hairline,
              ),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onPressed,
              onHover: (value) => setState(() => _hovered = value),
              onHighlightChanged: (value) => setState(() => _pressed = value),
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(5, 4, 14, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StationGroupPicture(slug: widget.slug, size: 26),
                    const SizedBox(width: 8),
                    AnimatedDefaultTextStyle(
                      duration: DesktopTokens.hoverDuration,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? TvColors.primaryLight
                            : TvColors.textPrimary,
                      ),
                      child: Text(widget.label),
                    ),
                    const SizedBox(width: 6),
                    AnimatedDefaultTextStyle(
                      duration: DesktopTokens.hoverDuration,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? TvColors.primaryLight.withValues(alpha: 0.8)
                            : TvColors.textTertiary,
                      ),
                      child: Text('${widget.count}'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An arrow at an edge of the row, over a fade into the background, that
/// pages the row that way; it shows only while there are chips past it.
class _EdgeArrow extends StatelessWidget {
  const _EdgeArrow({
    required this.visible,
    required this.forward,
    required this.onPressed,
  });

  final bool visible;
  final bool forward;
  final VoidCallback onPressed;

  static const double _width = 64;

  @override
  Widget build(BuildContext context) {
    final fade = LinearGradient(
      begin: forward ? Alignment.centerRight : Alignment.centerLeft,
      end: forward ? Alignment.centerLeft : Alignment.centerRight,
      colors: [
        TvColors.background,
        TvColors.background.withValues(alpha: 0),
      ],
      stops: const [0.45, 1],
    );
    return Positioned(
      top: 0,
      bottom: 0,
      left: forward ? null : 0,
      right: forward ? 0 : null,
      width: _width,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: DesktopTokens.hoverDuration,
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: fade),
            child: Align(
              alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: math.max(4, DesktopTokens.gutter - 16),
                ),
                child: IconButton(
                  tooltip: forward ? 'Mai multe categorii' : 'Înapoi',
                  onPressed: onPressed,
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    backgroundColor: DesktopTokens.raisedSurface,
                    foregroundColor: TvColors.textPrimary,
                    side: const BorderSide(color: DesktopTokens.hairline),
                  ),
                  icon: Icon(
                    forward
                        ? Icons.chevron_right_rounded
                        : Icons.chevron_left_rounded,
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
