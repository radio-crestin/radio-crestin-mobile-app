import 'dart:async';

import 'package:flutter/material.dart';

import '../services/sleep_timer_service.dart';
import '../theme.dart';

/// The player's "somn" action.
///
/// Idle it is the moon icon with the "somn" label. While a sleep timer runs,
/// a draining ring circles a smaller moon and the label becomes the time
/// left, refreshed every second.
class SleepTimerButton extends StatefulWidget {
  const SleepTimerButton({
    super.key,
    required this.service,
    required this.onTap,
  });

  /// The timer whose state this button mirrors.
  final SleepTimerService service;

  /// Opens the sleep timer sheet.
  final VoidCallback onTap;

  @override
  State<SleepTimerButton> createState() => _SleepTimerButtonState();
}

class _SleepTimerButtonState extends State<SleepTimerButton> {
  StreamSubscription<SleepTimerState?>? _subscription;
  SleepTimerState? _armed;
  late final SleepCountdownTicker _ticker = SleepCountdownTicker(
    now: () => widget.service.now,
    onTick: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(SleepTimerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      _subscription?.cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _ticker.stop();
    super.dispose();
  }

  /// Mirrors the service's timer; ticks only while one is armed.
  void _listen() {
    _armed = widget.service.state.value;
    _ticker.follow(_armed);
    _subscription = widget.service.state.listen((armed) {
      if (!mounted) return;
      setState(() => _armed = armed);
      _ticker.follow(armed);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final armed = _armed;
    final accent = theme.brightness == Brightness.dark
        ? AppColors.sleepAccent
        : AppColors.sleepAccentOnLight;
    final now = widget.service.now;
    final countdown =
        armed == null ? null : formatSleepCountdown(armed.remainingAt(now));

    return Semantics(
      button: true,
      label: countdown == null
          ? 'Somn, oprire automată'
          : 'Oprire automată activă, mai sunt $countdown',
      onTap: widget.onTap,
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onTap,
        // The countdown changes every second. The label keeps a fixed box
        // (see _CountdownLabel), so the change re-lays out only the label,
        // and this boundary keeps the repaint to the button instead of the
        // whole player around it.
        child: RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 24,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: armed == null
                        ? Icon(
                            Icons.nights_stay_sharp,
                            key: const ValueKey('idle'),
                            size: 24,
                            color: theme.colorScheme.onSurface,
                          )
                        : _RingedMoon(
                            key: const ValueKey('armed'),
                            fractionLeft: armed.fractionLeftAt(now),
                            color: accent,
                            trackColor: theme.colorScheme.onSurface
                                .withValues(alpha: 0.14),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: _CountdownLabel(
                      countdown ?? 'somn',
                      key: ValueKey(countdown == null),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: countdown == null ? null : FontWeight.w600,
                        color: countdown == null
                            ? theme.colorScheme.onSurfaceVariant
                            : accent,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
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

/// One line of text in a box that only resizes when its digit pattern
/// changes (`9:59` → `10:00`), not on every tick.
///
/// With tabular figures every digit has the same advance, so the box is sized
/// from the text with its digits zeroed. A fixed box makes the label its own
/// relayout boundary: a new second re-lays out the label alone instead of the
/// whole action row and player above it.
class _CountdownLabel extends StatelessWidget {
  const _CountdownLabel(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  static final RegExp _digit = RegExp(r'\d');

  @override
  Widget build(BuildContext context) {
    var effective = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      text: TextSpan(text: text.replaceAll(_digit, '0'), style: effective),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return SizedBox(
      width: size.width.ceilToDouble(),
      height: size.height.ceilToDouble(),
      child: Text(
        text,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// A small moon inside a ring that drains as the timer runs down.
class _RingedMoon extends StatelessWidget {
  const _RingedMoon({
    super.key,
    required this.fractionLeft,
    required this.color,
    required this.trackColor,
  });

  final double fractionLeft;
  final Color color;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    // Sized to the 24px icon slot so the ring and the moon share one centre;
    // the ring overhangs by a pixel to weigh the same as the neighbouring
    // icons while keeping the usual gap above the label.
    return SizedBox.square(
      dimension: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -1,
            top: -1,
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              value: fractionLeft,
              strokeWidth: 2,
              strokeCap: StrokeCap.round,
              color: color,
              backgroundColor: trackColor,
            ),
          ),
          // Painted rather than an icon font glyph: the Material moons sit
          // off-centre in their box and look lopsided inside a small ring.
          Center(
            child: SizedBox.square(
              dimension: 11,
              child: CustomPaint(painter: _CrescentPainter(color)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A crescent moon, optically centred in its box.
class _CrescentPainter extends CustomPainter {
  const _CrescentPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    // The crescent's mass is on its left, so the disc is nudged right to
    // balance it within the ring.
    final center = size.center(Offset.zero).translate(radius * 0.14, 0);
    final disc = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    final bite = Path()
      ..addOval(Rect.fromCircle(
        center: center.translate(radius * 0.62, -radius * 0.42),
        radius: radius * 0.86,
      ));
    canvas.drawPath(
      Path.combine(PathOperation.difference, disc, bite),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_CrescentPainter oldDelegate) =>
      oldDelegate.color != color;
}
