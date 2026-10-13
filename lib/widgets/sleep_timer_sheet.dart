import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sleep_timer_service.dart';
import '../theme.dart';

/// Durations offered by the sheet, in minutes.
const List<int> _presetMinutes = [15, 30, 45, 60, 90, 120];

/// How long a tapped duration stays highlighted before the sheet closes.
const Duration _confirmDelay = Duration(milliseconds: 700);

/// How long the "cancelled" confirmation shows before the sheet closes.
const Duration _cancelledDelay = Duration(milliseconds: 1100);

const List<FontFeature> _tabularFigures = [FontFeature.tabularFigures()];

enum _HeaderMode { choose, running, cancelled }

enum _CircleState { idle, active, confirming }

/// Bottom sheet that arms or cancels the sleep timer ("Somn").
///
/// One tap on a duration starts the timer and closes the sheet. While a timer
/// runs, the header shows the countdown and a cancel button appears;
/// cancelling shows a short confirmation and then closes. It is dressed like
/// the full player it opens over: the same backdrop gradient, the player's
/// chip fills for the durations and the play button's color for the chosen
/// one.
class SleepTimerSheet extends StatefulWidget {
  const SleepTimerSheet({
    super.key,
    required this.service,
    this.onDurationChosen,
    this.onCancelled,
  });

  /// The timer this sheet controls.
  final SleepTimerService service;

  /// Called right after a duration is chosen and the timer started.
  final ValueChanged<Duration>? onDurationChosen;

  /// Called right after a running timer is cancelled.
  final VoidCallback? onCancelled;

  /// Shows the sheet above the whole app (mini player included).
  static Future<void> show(
    BuildContext context, {
    required SleepTimerService service,
    ValueChanged<Duration>? onDurationChosen,
    VoidCallback? onCancelled,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      barrierColor: Colors.black.withValues(alpha: isDark ? 0.5 : 0.32),
      builder: (_) => SleepTimerSheet(
        service: service,
        onDurationChosen: onDurationChosen,
        onCancelled: onCancelled,
      ),
    );
  }

  @override
  State<SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<SleepTimerSheet> {
  StreamSubscription<SleepTimerState?>? _subscription;
  Timer? _closer;
  SleepTimerState? _armed;
  int? _confirmingMinutes;
  bool _cancelled = false;

  /// Whether the cancel button's slot was there when a duration was tapped.
  /// Held through the confirmation so the sheet keeps its height until it
  /// closes, instead of growing or shrinking right before it slides away.
  bool _cancelSlotAtTap = false;

  @override
  void initState() {
    super.initState();
    _armed = widget.service.state.value;
    _subscription = widget.service.state.listen((armed) {
      if (mounted) setState(() => _armed = armed);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _closer?.cancel();
    super.dispose();
  }

  void _choose(int minutes) {
    HapticFeedback.selectionClick();
    _cancelSlotAtTap = _hasCancelSlot;
    final duration = Duration(minutes: minutes);
    widget.service.start(duration);
    widget.onDurationChosen?.call(duration);
    setState(() {
      _confirmingMinutes = minutes;
      _cancelled = false;
    });
    _closeAfter(_confirmDelay);
  }

  void _cancel() {
    HapticFeedback.lightImpact();
    widget.service.cancel();
    widget.onCancelled?.call();
    setState(() {
      _cancelled = true;
      _confirmingMinutes = null;
    });
    _closeAfter(_cancelledDelay);
  }

  void _closeAfter(Duration delay) {
    _closer?.cancel();
    _closer = Timer(delay, () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  /// Whether the sheet keeps room for the cancel button. After cancelling it
  /// stays (faded) until the sheet closes, so the sheet never resizes while
  /// it shows a confirmation.
  bool get _hasCancelSlot => _confirmingMinutes != null
      ? _cancelSlotAtTap
      : _armed != null || _cancelled;

  /// Whether the cancel button is visible and tappable: whenever a timer is
  /// armed, including while switching to another duration.
  bool get _cancelEnabled => _armed != null;

  _HeaderMode get _headerMode {
    if (_armed != null) return _HeaderMode.running;
    return _cancelled ? _HeaderMode.cancelled : _HeaderMode.choose;
  }

  _CircleState _circleStateFor(int minutes) {
    if (_confirmingMinutes == minutes) return _CircleState.confirming;
    final isArmed = _armed?.duration == Duration(minutes: minutes);
    if (_confirmingMinutes == null && isArmed) return _CircleState.active;
    return _CircleState.idle;
  }

  @override
  Widget build(BuildContext context) {
    final palette = _SheetPalette.of(context);
    return _SheetFrame(
      palette: palette,
      child: _SheetContent(
        palette: palette,
        bottomInset: MediaQuery.viewPaddingOf(context).bottom,
        header: _SheetHeader(
          palette: palette,
          mode: _headerMode,
          armed: _armed,
          now: () => widget.service.now,
        ),
        grid: _DurationGrid(
          palette: palette,
          stateFor: _circleStateFor,
          onChoose: _choose,
        ),
        hasCancelSlot: _hasCancelSlot,
        cancelEnabled: _cancelEnabled,
        onCancel: _cancel,
      ),
    );
  }
}

/// Colors borrowed from the full player, so the sheet reads as part of it.
@immutable
class _SheetPalette {
  const _SheetPalette({
    required this.isDark,
    required this.isApple,
    required this.backdrop,
    required this.text,
    required this.secondaryText,
    required this.grabber,
    required this.chip,
    required this.selected,
  });

  factory _SheetPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final onSurface = theme.colorScheme.onSurface;
    final background = theme.scaffoldBackgroundColor;
    return _SheetPalette(
      isDark: isDark,
      isApple: theme.platform == TargetPlatform.iOS ||
          theme.platform == TargetPlatform.macOS,
      // The player panel's gradient; its light middle stop is the panel's
      // translucent pink already blended over the background, since the
      // sheet has nothing behind it to blend with.
      backdrop: isDark
          ? [const Color(0xFF2C1018), const Color(0xFF1A0A0F), background]
          : [const Color(0xFFFCE4EC), const Color(0xFFF9E7ED), background],
      text: onSurface,
      secondaryText: onSurface.withValues(alpha: isDark ? 0.7 : 0.6),
      grabber: onSurface.withValues(alpha: isDark ? 0.35 : 0.22),
      // A neutral fill that reads on the panel gradient.
      chip: isDark
          ? Colors.white.withValues(alpha: 0.12)
          : Colors.black.withValues(alpha: 0.08),
      // The brand color of the bottom bar.
      selected: theme.bottomAppBarTheme.color ?? AppColors.primary,
    );
  }

  final bool isDark;

  /// Apple platforms get a highlight on tap instead of a Material ripple.
  final bool isApple;

  final List<Color> backdrop;
  final Color text;
  final Color secondaryText;
  final Color grabber;
  final Color chip;
  final Color selected;

  Color get selectedGlow => selected.withValues(alpha: isDark ? 0.55 : 0.35);
}

/// Full-width card with rounded top corners and the player's gradient.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.palette, required this.child});

  final _SheetPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: palette.backdrop,
          stops: const [0.0, 0.45, 1.0],
        ),
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

/// Grabber, header, duration grid and (while armed) the cancel button.
class _SheetContent extends StatelessWidget {
  const _SheetContent({
    required this.palette,
    required this.bottomInset,
    required this.header,
    required this.grid,
    required this.hasCancelSlot,
    required this.cancelEnabled,
    required this.onCancel,
  });

  final _SheetPalette palette;
  final double bottomInset;
  final Widget header;
  final Widget grid;
  final bool hasCancelSlot;
  final bool cancelEnabled;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // The same 24 as the sides, on top of the home indicator / navigation
      // bar inset, so the last row never sits right on the indicator.
      padding: EdgeInsets.fromLTRB(24, 0, 24, bottomInset + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Grabber(color: palette.grabber),
          const SizedBox(height: 22),
          // The countdown changes every second. Its box is tight (fixed width
          // and height) so the change re-lays out only the header, and the
          // repaint boundary above that box keeps the repaint to the header
          // too, instead of the whole sheet with its gradient and shadows.
          RepaintBoundary(
            child: SizedBox(width: double.infinity, height: 72, child: header),
          ),
          const SizedBox(height: 18),
          grid,
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: hasCancelSlot
                ? Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: IgnorePointer(
                      ignoring: !cancelEnabled,
                      child: AnimatedOpacity(
                        opacity: cancelEnabled ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: _CancelButton(
                          palette: palette,
                          onCancel: onCancel,
                        ),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
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

/// Title, live countdown or "cancelled" confirmation, crossfading between
/// them.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.palette,
    required this.mode,
    required this.armed,
    required this.now,
  });

  final _SheetPalette palette;
  final _HeaderMode mode;
  final SleepTimerState? armed;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final armed = this.armed;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: switch (mode) {
        _HeaderMode.running when armed != null => _RunningHeader(
            key: const ValueKey(_HeaderMode.running),
            palette: palette,
            armed: armed,
            now: now,
          ),
        _HeaderMode.cancelled => _CancelledHeader(
            key: const ValueKey(_HeaderMode.cancelled),
            palette: palette,
          ),
        _ => _ChooseHeader(
            key: const ValueKey(_HeaderMode.choose),
            palette: palette,
          ),
      },
    );
  }
}

class _ChooseHeader extends StatelessWidget {
  const _ChooseHeader({super.key, required this.palette});

  final _SheetPalette palette;

  @override
  Widget build(BuildContext context) {
    return _HeaderLines(
      top: Text(
        'Somn',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: palette.secondaryText,
        ),
      ),
      gap: 4,
      bottom: const Text(
        'Oprește radioul după',
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}

/// Countdown that refreshes itself every second while a timer is armed.
class _RunningHeader extends StatefulWidget {
  const _RunningHeader({
    super.key,
    required this.palette,
    required this.armed,
    required this.now,
  });

  final _SheetPalette palette;
  final SleepTimerState armed;
  final DateTime Function() now;

  @override
  State<_RunningHeader> createState() => _RunningHeaderState();
}

class _RunningHeaderState extends State<_RunningHeader> {
  late final SleepCountdownTicker _ticker = SleepCountdownTicker(
    now: () => widget.now(),
    onTick: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    _ticker.follow(widget.armed);
  }

  @override
  void didUpdateWidget(_RunningHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.armed != widget.armed) _ticker.follow(widget.armed);
  }

  @override
  void dispose() {
    _ticker.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.armed.remainingAt(widget.now());
    final endsAt = _formatClock(widget.armed.endsAt);
    return Semantics(
      label: 'Oprire automată activă. Se oprește la $endsAt.',
      excludeSemantics: true,
      child: _HeaderLines(
        top: Text(
          formatSleepCountdown(remaining),
          style: const TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w300,
            height: 1,
            letterSpacing: -0.5,
            fontFeatures: _tabularFigures,
          ),
        ),
        gap: 8,
        bottom: Text(
          'Se oprește la $endsAt',
          style: TextStyle(
            fontSize: 14,
            color: widget.palette.secondaryText,
            fontFeatures: _tabularFigures,
          ),
        ),
      ),
    );
  }
}

class _CancelledHeader extends StatelessWidget {
  const _CancelledHeader({super.key, required this.palette});

  final _SheetPalette palette;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: _HeaderLines(
        top: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: palette.selected,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 17,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Oprirea a fost anulată',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        gap: 8,
        bottom: Text(
          'Radioul merge mai departe',
          style: TextStyle(fontSize: 14, color: palette.secondaryText),
        ),
      ),
    );
  }
}

/// Two centered header lines that shrink rather than overflow at large text
/// sizes.
class _HeaderLines extends StatelessWidget {
  const _HeaderLines({
    required this.top,
    required this.gap,
    required this.bottom,
  });

  final Widget top;
  final double gap;
  final Widget bottom;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [top, SizedBox(height: gap), bottom],
        ),
      ),
    );
  }
}

/// Two rows of three duration circles, sized to the available width.
class _DurationGrid extends StatelessWidget {
  const _DurationGrid({
    required this.palette,
    required this.stateFor,
    required this.onChoose,
  });

  final _SheetPalette palette;
  final _CircleState Function(int minutes) stateFor;
  final ValueChanged<int> onChoose;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final diameter = math.min(92.0, (constraints.maxWidth - 24) / 3);
        Widget row(Iterable<int> minutes) => Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final m in minutes)
                  _DurationCircle(
                    minutes: m,
                    diameter: diameter,
                    palette: palette,
                    state: stateFor(m),
                    onTap: () => onChoose(m),
                  ),
              ],
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row(_presetMinutes.take(3)),
            const SizedBox(height: 14),
            row(_presetMinutes.skip(3)),
          ],
        );
      },
    );
  }
}

/// One duration: a chip-colored circle, filled with the play button's color
/// while it is the running timer, reading "pornit" right after it was tapped.
class _DurationCircle extends StatelessWidget {
  const _DurationCircle({
    required this.minutes,
    required this.diameter,
    required this.palette,
    required this.state,
    required this.onTap,
  });

  final int minutes;
  final double diameter;
  final _SheetPalette palette;
  final _CircleState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (number, unit) = _presetLabel(minutes);
    final isSelected = state != _CircleState.idle;
    final ink = isSelected ? Colors.white : palette.text;

    return Semantics(
      button: true,
      selected: isSelected,
      label: _presetSemanticLabel(minutes),
      onTap: onTap,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: diameter,
        child: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? palette.selected : palette.chip,
                // No shadow at all on idle circles: even a transparent one
                // costs a blur on every repaint. AnimatedContainer still
                // fades the glow in and out from nothing.
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: palette.selectedGlow,
                          blurRadius: 22,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : const [],
              ),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(diameter * 0.12),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          number,
                          style: TextStyle(
                            fontSize: 30,
                            height: 1,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.5,
                            color: ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          state == _CircleState.confirming ? 'pornit' : unit,
                          style: TextStyle(
                            fontSize: 12,
                            color: ink.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Above the fill so the Material ripple stays visible on Android.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
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
      ),
    );
  }
}

/// Full-width chip-style capsule shown while a timer runs.
class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.palette, required this.onCancel});

  final _SheetPalette palette;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: Material(
        color: palette.chip,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onCancel,
          splashFactory: palette.isApple ? NoSplash.splashFactory : null,
          highlightColor:
              palette.isApple ? palette.text.withValues(alpha: 0.08) : null,
          child: Center(
            child: Text(
              'Anulează oprirea',
              style: TextStyle(
                color: palette.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The big number and the unit under it, e.g. `('1,5', 'ore')`.
(String, String) _presetLabel(int minutes) => switch (minutes) {
      60 => ('1', 'oră'),
      90 => ('1,5', 'ore'),
      120 => ('2', 'ore'),
      _ => ('$minutes', 'min'),
    };

/// Spoken form of a preset, with Romanian's "de" for 20 and above.
String _presetSemanticLabel(int minutes) => switch (minutes) {
      60 => 'O oră',
      90 => 'O oră și jumătate',
      120 => 'Două ore',
      < 20 => '$minutes minute',
      _ => '$minutes de minute',
    };

String _formatClock(DateTime time) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
}
