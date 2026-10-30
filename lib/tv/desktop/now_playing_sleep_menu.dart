import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../services/sleep_timer_service.dart';
import '../../theme.dart';
import '../tv_theme.dart';
import 'now_playing_controls.dart';

/// The durations the desktop sleep menu offers, in minutes: the ones of the
/// phone's sleep sheet.
const List<int> desktopSleepPresets = [15, 30, 45, 60, 90, 120];

/// A preset as the menu names it: "15 min", "1 oră", "1,5 ore", "2 ore".
String desktopSleepPresetLabel(int minutes) => switch (minutes) {
      60 => '1 oră',
      90 => '1,5 ore',
      120 => '2 ore',
      _ => '$minutes min',
    };

/// The wall-clock time a timer ends at, as "23:05".
String desktopSleepClock(DateTime time) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
}

/// The "Somn" button of the desktop now-playing panel and the menu it opens.
///
/// The menu arms the sleep timer for one of [desktopSleepPresets], or
/// cancels the one running. While a timer runs the button counts down the
/// time left, in the sleep accent, and the menu says when the radio stops.
class NowPlayingSleepMenu extends StatefulWidget {
  const NowPlayingSleepMenu({
    super.key,
    required this.service,
    required this.labeled,
    this.quiet = false,
    this.onOpened,
    this.onClosed,
    this.onDurationChosen,
    this.onCancelled,
  });

  /// The timer the menu controls.
  final SleepTimerService service;

  /// Whether the button shows its label (see [DesktopActionButton]). While
  /// a timer runs it always shows the countdown.
  final bool labeled;

  /// Whether the button has no fill until the pointer is on it, while no
  /// timer runs (see [DesktopActionButton.quiet]).
  final bool quiet;

  /// Called as the menu opens, and once it closed.
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  /// Called right after a duration was chosen and the timer started.
  final ValueChanged<Duration>? onDurationChosen;

  /// Called right after the running timer was cancelled.
  final VoidCallback? onCancelled;

  /// Names the button, and the menu's cancel action.
  static const String label = 'Somn';
  static const String cancelLabel = 'Anulează oprirea';

  @override
  State<NowPlayingSleepMenu> createState() => _NowPlayingSleepMenuState();
}

class _NowPlayingSleepMenuState extends State<NowPlayingSleepMenu> {
  final MenuController _menu = MenuController();

  /// The button's focus, which takes the keyboard as the menu opens, so
  /// Esc closes the menu rather than the panel around it.
  final FocusNode _buttonFocus = FocusNode(debugLabel: 'desktop-np-sleep');
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
  void didUpdateWidget(NowPlayingSleepMenu oldWidget) {
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
    _buttonFocus.dispose();
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

  void _choose(int minutes) {
    final duration = Duration(minutes: minutes);
    widget.service.start(duration);
    widget.onDurationChosen?.call(duration);
  }

  void _cancel() {
    widget.service.cancel();
    widget.onCancelled?.call();
  }

  void _toggle() => _menu.isOpen ? _menu.close() : _menu.open();

  @override
  Widget build(BuildContext context) {
    final armed = _armed;
    final now = widget.service.now;
    final countdown =
        armed == null ? null : formatSleepCountdown(armed.remainingAt(now));
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _buttonFocus,
      style: DesktopMenuTheme.menuStyle,
      useRootOverlay: true,
      consumeOutsideTap: true,
      alignmentOffset: const Offset(0, 6),
      onOpen: widget.onOpened,
      onClose: widget.onClosed,
      menuChildren: [
        DesktopMenuHeader(
          title: armed == null
              ? 'Somn'
              : 'Se oprește la ${desktopSleepClock(armed.endsAt)}',
          subtitle: Text(
            countdown == null ? 'Oprește radioul după' : 'Mai sunt $countdown',
          ),
        ),
        const DesktopMenuDivider(),
        for (final minutes in desktopSleepPresets)
          MenuItemButton(
            style: DesktopMenuTheme.itemStyle(),
            leadingIcon: SizedBox.square(
              dimension: 18,
              child: armed?.duration == Duration(minutes: minutes)
                  ? const Icon(Icons.check_rounded,
                      size: 18, color: AppColors.sleepAccent)
                  : null,
            ),
            onPressed: () => _choose(minutes),
            child: Text(desktopSleepPresetLabel(minutes)),
          ),
        if (armed != null) ...[
          const DesktopMenuDivider(),
          MenuItemButton(
            style: DesktopMenuTheme.itemStyle(),
            leadingIcon: const Icon(Icons.timer_off_outlined, size: 18),
            onPressed: _cancel,
            child: const Text(NowPlayingSleepMenu.cancelLabel),
          ),
        ],
      ],
      // The countdown repaints the button every second, not the panel.
      builder: (context, controller, child) => RepaintBoundary(
        child: DesktopActionButton(
          focusNode: _buttonFocus,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: armed == null
                ? const Icon(CupertinoIcons.moon_zzz_fill,
                    key: ValueKey('idle'))
                : _RingedMoon(
                    key: const ValueKey('armed'),
                    fractionLeft: armed.fractionLeftAt(now),
                  ),
          ),
          label: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: Text(
              countdown ?? NowPlayingSleepMenu.label,
              key: ValueKey(countdown == null),
            ),
          ),
          tooltip: armed == null
              ? 'Somn: oprește radioul după un timp'
              : 'Somn: se oprește la ${desktopSleepClock(armed.endsAt)}',
          labeled: widget.labeled || armed != null,
          quiet: widget.quiet && armed == null,
          accent: armed == null ? null : AppColors.sleepAccent,
          onPressed: _toggle,
        ),
      ),
    );
  }
}

/// A small moon in a ring that drains as the sleep timer runs down.
class _RingedMoon extends StatelessWidget {
  const _RingedMoon({super.key, required this.fractionLeft});

  final double fractionLeft;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 19,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: fractionLeft,
              strokeWidth: 2,
              strokeCap: StrokeCap.round,
              color: AppColors.sleepAccent,
              backgroundColor: TvColors.divider,
            ),
          ),
          const Icon(
            CupertinoIcons.moon_fill,
            size: 9,
            color: AppColors.sleepAccent,
          ),
        ],
      ),
    );
  }
}
