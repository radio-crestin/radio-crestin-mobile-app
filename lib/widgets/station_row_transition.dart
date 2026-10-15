import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../utils/PositionRetainedScrollPhysics.dart';

/// The station rows on their way out of the lists, or back in.
///
/// Hiding a station first plays its rows out, every row of it at once (in
/// the Favorite section and in the full list), and only then hides it, so
/// the rows below slide up instead of jumping. Undoing a hide marks the
/// station as entering, so its rows grow back in when they appear.
class StationRowTransitions extends ChangeNotifier {
  final Map<String, VoidCallback> _leaving = {};
  final Set<String> _entering = {};

  /// Keeps the rows in view in place while rows grow or shrink, for the
  /// list's [PositionRetainedScrollPhysics]: the rows below a closing slot
  /// move up, and the ones above it stay.
  final RowScrollAnchor scrollAnchor = RowScrollAnchor();

  /// Whether the rows of [slug] are playing out.
  bool isLeaving(String slug) => _leaving.containsKey(slug);

  /// Plays the rows of [slug] out, then calls [onLeft], which hides the
  /// station. A station already leaving is left alone.
  void leave(String slug, VoidCallback onLeft) {
    if (isLeaving(slug)) return;
    _entering.remove(slug);
    _leaving[slug] = onLeft;
    notifyListeners();
  }

  /// A row of [slug] finished playing out, or went away meanwhile: calls
  /// the station's `onLeft`, once for all its rows.
  ///
  /// It tells no listener: the rows are gone at the next build, and one
  /// drawn in full again before that would flash.
  void left(String slug) => _leaving.remove(slug)?.call();

  /// Whether rows of [slug] that appear now should grow in.
  bool isEntering(String slug) => _entering.contains(slug);

  /// Makes the next rows of [slug] grow in: the station is coming back.
  void enter(String slug) {
    _entering.add(slug);
    // Before the rows come back, in the layout still on screen.
    scrollAnchor.hold();
  }

  /// The rows of [slug] have grown in.
  void entered(String slug) => _entering.remove(slug);
}

/// A station row that plays out, or grows in, as [transitions] says for the
/// station with [slug].
///
/// Out: a pink eye pops up over the row and a line crosses it out, the row
/// fades away, then the eye goes and the row's slot closes, so the rows
/// below slide up. In: the slot opens and the row fades in. Only a list of
/// one column can close the slot ([collapses]); a grid can't move its other
/// tiles, so there the row only fades.
class StationRowTransition extends StatefulWidget {
  const StationRowTransition({
    super.key,
    required this.slug,
    required this.transitions,
    required this.collapses,
    required this.child,
  });

  final String slug;
  final StationRowTransitions transitions;
  final bool collapses;

  /// The row, at its full height.
  final Widget child;

  /// From the eye popping up to the slot closed.
  static const Duration leaveDuration = Duration(milliseconds: 640);

  /// From the slot starting to open to the row shown.
  static const Duration enterDuration = Duration(milliseconds: 360);

  @override
  State<StationRowTransition> createState() => _StationRowTransitionState();
}

class _StationRowTransitionState extends State<StationRowTransition>
    with TickerProviderStateMixin {
  // The way out, over the 640 ms of [StationRowTransition.leaveDuration],
  // each step setting off before the last one ends, so the row never stands
  // still: the eye pops up (140 ms), its line is drawn (from 100 ms, for
  // 180 ms), the row fades (from 220 ms, for 200 ms), then the eye goes
  // (140 ms) while the slot closes (220 ms).
  static const _eyeIn = Interval(0, 140 / 640, curve: Easing.standard);
  static const _lineIn = Interval(100 / 640, 280 / 640, curve: Easing.legacy);
  static const _rowOut =
      Interval(220 / 640, 420 / 640, curve: Easing.legacyDecelerate);
  static const _eyeOut =
      Interval(420 / 640, 560 / 640, curve: Easing.legacyAccelerate);
  static const _slotCloses = Interval(420 / 640, 1, curve: Easing.legacy);

  // The way back in, over 360 ms: the slot opens (280 ms) while the row
  // fades in from 120 ms.
  static const _slotOpens = Interval(0, 280 / 360, curve: Easing.legacy);
  static const _rowIn =
      Interval(120 / 360, 1, curve: Easing.legacyDecelerate);

  /// The eye's size, and how small it pops up from and goes back to.
  static const double _eyeSize = 40;
  static const double _eyeSmall = .6;

  /// How small the row grows in from.
  static const double _rowSmall = .97;

  // Each frame holds the rows in view before it lays them out, ahead of
  // the hide at the end too.
  late final AnimationController _leave = AnimationController(
    vsync: this,
    duration: StationRowTransition.leaveDuration,
  )
    ..addListener(_holdRowsInView)
    ..addStatusListener(_onLeaveStatus);

  /// At 1 when the row is in, as it is unless it grows in.
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: StationRowTransition.enterDuration,
    value: 1,
  )
    ..addListener(_holdRowsInView)
    ..addStatusListener(_onEnterStatus);

  @override
  void initState() {
    super.initState();
    _attach(widget.transitions);
    if (widget.transitions.isEntering(widget.slug)) _enter.forward(from: 0);
    _sync();
  }

  @override
  void didUpdateWidget(StationRowTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitions != widget.transitions) {
      _detach(oldWidget.transitions);
      _attach(widget.transitions);
      _sync();
    }
  }

  void _attach(StationRowTransitions transitions) {
    transitions.addListener(_sync);
    transitions.scrollAnchor.attach(context);
  }

  void _detach(StationRowTransitions transitions) {
    transitions.removeListener(_sync);
    transitions.scrollAnchor.detach(context);
  }

  void _holdRowsInView() => widget.transitions.scrollAnchor.hold();

  @override
  void dispose() {
    _detach(widget.transitions);
    // Gone mid-way (scrolled far off): the station is hidden all the same.
    // Not from here, though: hiding updates other widgets, and the tree is
    // locked while it disposes this one.
    if (_leave.isAnimating) {
      final transitions = widget.transitions;
      final slug = widget.slug;
      scheduleMicrotask(() => transitions.left(slug));
    }
    _leave.dispose();
    _enter.dispose();
    super.dispose();
  }

  void _sync() {
    if (_leave.isDismissed && widget.transitions.isLeaving(widget.slug)) {
      _leave.forward();
    }
  }

  void _onLeaveStatus(AnimationStatus status) {
    if (status.isCompleted) widget.transitions.left(widget.slug);
  }

  void _onEnterStatus(AnimationStatus status) {
    if (status.isCompleted) widget.transitions.entered(widget.slug);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_leave, _enter]),
      child: widget.child,
      builder: (context, row) {
        final out = _leave.value;
        final into = _enter.value;
        final moving = out > 0 || into < 1;
        final height = widget.collapses
            ? (1 - _slotCloses.transform(out)) * _slotOpens.transform(into)
            : 1.0;
        final shown = _rowIn.transform(into);
        return IgnorePointer(
          ignoring: moving,
          child: ClipRect(
            clipBehavior: height < 1 ? Clip.hardEdge : Clip.none,
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: (1 - _rowOut.transform(out)) * shown,
                    child: Transform.scale(
                      scale: lerpDouble(_rowSmall, 1, shown),
                      child: row,
                    ),
                  ),
                  if (out > 0) _eye(out),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _eye(double out) {
    final shown = _eyeIn.transform(out) - _eyeOut.transform(out);
    return Opacity(
      opacity: shown.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: lerpDouble(_eyeSmall, 1, shown),
        child: CustomPaint(
          size: const Size.square(_eyeSize),
          painter: _CrossedEyePainter(line: _lineIn.transform(out)),
        ),
      ),
    );
  }
}

/// A pink disc with a white eye, crossed out by a line drawn up to [line]
/// (0 to 1), like the eye on "Ascunde stația" in the menu.
class _CrossedEyePainter extends CustomPainter {
  const _CrossedEyePainter({required this.line});

  final double line;

  /// The eye is drawn in a 24-unit box, as icons are, and takes this much of
  /// the disc.
  static const double _box = 24;
  static const double _iconShare = .55;

  static final Path _eye = Path()
    ..moveTo(2, 12)
    ..cubicTo(2, 12, 5.6, 6, 12, 6)
    ..cubicTo(18.4, 6, 22, 12, 22, 12)
    ..cubicTo(22, 12, 18.4, 18, 12, 18)
    ..cubicTo(5.6, 18, 2, 12, 2, 12)
    ..close();

  static const _lineStart = Offset(4, 4);
  static const _lineEnd = Offset(20, 20);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      size.shortestSide / 2,
      Paint()..color = AppColors.primary,
    );
    final icon = size.shortestSide * _iconShare;
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..save()
      ..translate(center.dx - icon / 2, center.dy - icon / 2)
      ..scale(icon / _box)
      ..drawPath(_eye, stroke)
      ..drawCircle(const Offset(12, 12), 3, stroke);
    if (line > 0) {
      canvas.drawLine(
        _lineStart,
        Offset.lerp(_lineStart, _lineEnd, line)!,
        stroke,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CrossedEyePainter oldDelegate) =>
      oldDelegate.line != line;
}
