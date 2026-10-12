import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Space between the end of the text and its repeated start.
const double _gap = 48.0;

/// Width of the faded edges of scrolling text.
const double _fadeWidth = 16.0;

/// Single-line text that scrolls horizontally when it doesn't fit, like the
/// now-playing title in Apple Music and Spotify.
///
/// Always exactly one line tall, even for an empty string, so the widgets
/// around it never move when the text changes. Text that fits is shown
/// statically with [textAlign]. Text that overflows rests at its start with a
/// faded trailing edge, scrolls one full loop after a pause, and repeats. It
/// stays at rest while [animate] is false or the platform asks for reduced
/// motion.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.center,
    this.animate = true,
  });

  final String text;
  final TextStyle? style;

  /// Alignment of text that fits. Overflowing text always starts at the
  /// leading edge.
  final TextAlign textAlign;

  /// Whether overflowing text may scroll. Pass false while the text is off
  /// screen so it doesn't repaint every frame for nothing.
  final bool animate;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  static const _pause = Duration(milliseconds: 2500);

  /// Scroll speed in logical pixels per second. The loop duration follows
  /// the text width so every title reads at the same pace.
  static const _velocity = 35.0;

  late final AnimationController _controller;
  Timer? _pauseTimer;

  /// Distance of one loop (text width + gap), or 0 when the text fits.
  double _loopDistance = 0;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addStatusListener(_onStatusChanged);
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _stop();
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // The repeated copy now sits exactly where the text started, so jumping
    // back to 0 is seamless.
    _controller.value = 0;
    _schedulePass();
  }

  void _schedulePass() {
    _pauseTimer?.cancel();
    _pauseTimer = Timer(_pause, () {
      if (mounted && _running) _controller.forward(from: 0);
    });
  }

  void _stop() {
    _pauseTimer?.cancel();
    _controller.value = 0;
    _running = false;
  }

  /// Starts or stops scrolling to match the latest layout. Runs after the
  /// frame because the overflow is only known during layout.
  void _sync(double loopDistance, bool run) {
    if (loopDistance == _loopDistance && run == _running) return;
    _stop();
    _loopDistance = loopDistance;
    if (!run) return;
    _running = true;
    _controller.duration = Duration(
      milliseconds: (loopDistance / _velocity * 1000).round(),
    );
    _schedulePass();
  }

  bool _reduceMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;

  @override
  Widget build(BuildContext context) {
    final painter = TextPainter(
      // A space gives an empty line the same height as a real one.
      text: TextSpan(
        text: widget.text.isEmpty ? ' ' : widget.text,
        style: DefaultTextStyle.of(context).style.merge(widget.style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final textWidth = painter.width;
    final lineHeight = painter.height;
    painter.dispose();
    final canRun = widget.animate && !_reduceMotion(context);

    return SizedBox(
      height: lineHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final overflows = textWidth > constraints.maxWidth;
          final loopDistance = overflows ? textWidth + _gap : 0.0;
          final run = overflows && canRun;
          if (loopDistance != _loopDistance || run != _running) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _sync(loopDistance, run);
            });
          }
          if (!overflows) {
            // Full width, so a crossfade to a longer or shorter title keeps
            // the same alignment instead of re-centering.
            return SizedBox(
              width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
              child: Text(
                widget.text,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
                textAlign: widget.textAlign,
              ),
            );
          }
          return _ScrollingLine(
            text: widget.text,
            style: widget.style,
            animation: _controller,
            loopDistance: loopDistance,
          );
        },
      ),
    );
  }
}

/// The overflowing text followed by a gap and a repeated copy, translated by
/// [animation] and faded at the edges.
class _ScrollingLine extends StatelessWidget {
  const _ScrollingLine({
    required this.text,
    required this.style,
    required this.animation,
    required this.loopDistance,
  });

  final String text;
  final TextStyle? style;
  final Animation<double> animation;
  final double loopDistance;

  @override
  Widget build(BuildContext context) {
    final line = Text(text, style: style, maxLines: 1, softWrap: false);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: ClipRect(
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              final offset = animation.value * loopDistance;
              return ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => _edgeFade(rect, offset),
                child: Transform.translate(
                  offset: Offset(-offset, 0),
                  child: child,
                ),
              );
            },
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [line, const SizedBox(width: _gap), line],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Fades the trailing edge always, and the leading edge only while the
  /// text is away from its resting position, so the first letter is never
  /// dimmed at rest and the fade comes and goes smoothly.
  Shader _edgeFade(Rect rect, double offset) {
    final edge = (_fadeWidth / rect.width).clamp(0.0, 0.5);
    final awayFromRest = math.min(offset, loopDistance - offset);
    final leadingAlpha = 1 - (awayFromRest / _fadeWidth).clamp(0.0, 1.0);
    return LinearGradient(
      colors: [
        Colors.white.withValues(alpha: leadingAlpha),
        Colors.white,
        Colors.white,
        Colors.white.withValues(alpha: 0),
      ],
      stops: [0, edge, 1 - edge, 1],
    ).createShader(rect);
  }
}
