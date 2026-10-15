import 'package:flutter/material.dart';

import '../theme.dart';

/// A short confirmation that something was copied: a card near the bottom of
/// the screen that rises with a little spring, draws its check mark, and
/// fades away on its own.
///
/// It looks like the status snackbar (the same inverse surface and success
/// check), so the app speaks with one voice. It never takes touches, so the
/// controls under it stay usable while it shows, and a new one replaces the
/// one on screen.
class CopiedToast {
  CopiedToast._();

  static OverlayEntry? _current;

  /// Shows [message] over the whole app, its bottom edge [bottom] above the
  /// screen's, or just above the safe area when null.
  static void show(
    BuildContext context, {
    required String message,
    double? bottom,
  }) {
    _current?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => CopiedToastView(
        message: message,
        bottom: bottom,
        onDone: () {
          // Already removed if a newer toast replaced it.
          if (_current != entry) return;
          _current = null;
          entry.remove();
        },
      ),
    );
    _current = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }
}

/// The toast itself, placed at the bottom of an [Overlay]; [onDone] is
/// called once it has faded away.
@visibleForTesting
class CopiedToastView extends StatefulWidget {
  const CopiedToastView({
    super.key,
    required this.message,
    this.bottom,
    required this.onDone,
  });

  final String message;

  /// See [CopiedToast.show].
  final double? bottom;

  final VoidCallback onDone;

  /// From the start of the rise to the end of the fade.
  static const Duration lifetime = Duration(milliseconds: 2000);

  @override
  State<CopiedToastView> createState() => _CopiedToastViewState();
}

class _CopiedToastViewState extends State<CopiedToastView>
    with SingleTickerProviderStateMixin {
  static const _rise = Duration(milliseconds: 300);
  static const _checkStart = Duration(milliseconds: 120);
  static const _checkEnd = Duration(milliseconds: 400);
  static const _fade = Duration(milliseconds: 200);

  /// How far below its place the card starts, and sinks as it fades.
  static const double _riseDistance = 16;
  static const double _sinkDistance = 8;

  late final AnimationController _controller;

  /// 0 to 1 as the card rises, past 1 for a moment: the spring.
  late final Animation<double> _risen;
  late final Animation<double> _shown;
  late final Animation<double> _checkDrawn;
  late final Animation<double> _gone;

  /// [curve] played from [start] to [end] of the toast's lifetime.
  Animation<double> _between(Duration start, Duration end, Curve curve) {
    final total = CopiedToastView.lifetime.inMilliseconds;
    return CurvedAnimation(
      parent: _controller,
      curve: Interval(
        start.inMilliseconds / total,
        end.inMilliseconds / total,
        curve: curve,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: CopiedToastView.lifetime,
    );
    const lifetime = CopiedToastView.lifetime;
    _risen = _between(Duration.zero, _rise, Curves.easeOutBack);
    _shown = _between(Duration.zero, _rise, Curves.easeOut);
    _checkDrawn = _between(_checkStart, _checkEnd, Curves.easeOut);
    _gone = _between(lifetime - _fade, lifetime, Curves.easeIn);
    _controller.forward().whenComplete(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Positioned(
      left: 24,
      right: 24,
      bottom: widget.bottom ?? MediaQuery.paddingOf(context).bottom + 24,
      child: IgnorePointer(
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final risen = reduceMotion ? 1.0 : _risen.value;
              final sunk = reduceMotion ? 0.0 : _gone.value;
              return Opacity(
                opacity: (_shown.value * (1 - _gone.value)).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(
                    0,
                    (1 - risen) * _riseDistance + sunk * _sinkDistance,
                  ),
                  child: Transform.scale(
                    scale: 0.92 + 0.08 * risen,
                    child: child,
                  ),
                ),
              );
            },
            child: _Card(
              message: widget.message,
              checkDrawn: reduceMotion
                  ? const AlwaysStoppedAnimation(1.0)
                  : _checkDrawn,
            ),
          ),
        ),
      ),
    );
  }
}

/// The status snackbar's surface, shrunk to a check mark and one line.
class _Card extends StatelessWidget {
  const _Card({required this.message, required this.checkDrawn});

  final String message;
  final Animation<double> checkDrawn;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return Semantics(
      container: true,
      liveRegion: true,
      // Text above the app's pages has no Material to take its style from.
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: const BorderRadius.all(Radius.circular(14)),
            boxShadow: const [
              BoxShadow(
                color: AppColors.statusSnackbarShadow,
                blurRadius: 20,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 18, 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CustomPaint(
                  size: const Size.square(20),
                  painter: _CheckPainter(
                    drawn: checkDrawn,
                    color: colors.success,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      height: 20 / 14.5,
                      color: colors.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A check mark drawn stroke by stroke as [drawn] goes from 0 to 1, the
/// shape of `Icons.check_rounded`.
class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.drawn, required this.color})
      : super(repaint: drawn);

  final Animation<double> drawn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (drawn.value <= 0) return;
    final check = Path()
      ..moveTo(size.width * 0.2, size.height * 0.53)
      ..lineTo(size.width * 0.4, size.height * 0.72)
      ..lineTo(size.width * 0.81, size.height * 0.31);
    final metric = check.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * drawn.value),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) =>
      oldDelegate.drawn != drawn || oldDelegate.color != color;
}
