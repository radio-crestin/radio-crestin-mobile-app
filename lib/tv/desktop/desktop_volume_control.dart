import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../tv_theme.dart';
import 'desktop_quiet_icon_button.dart';
import 'desktop_shortcuts.dart';

/// The player bar's volume: a speaker that mutes and unmutes, and a slim
/// slider, as music apps have on a computer.
///
/// The slider shows its knob and takes the brand pink under the pointer;
/// the mouse wheel over it turns the volume up or down a notch at a time.
///
/// Starting to play while muted, or moving to another station, would
/// leave the listener wondering why nothing is heard: a bubble over the
/// speaker then says the sound is off, and a click on it turns it back on.
/// It goes after a few seconds, or as soon as the sound is on or the
/// player stops; a station that keeps restarting shows it once a minute
/// at most.
class DesktopVolumeControl extends StatefulWidget {
  const DesktopVolumeControl({
    super.key,
    required this.volume,
    required this.onChanged,
    required this.onToggleMute,
    this.stationSlug,
    this.playing = false,
    this.sliderWidth = 84,
  });

  /// The width of the slider; a narrow window gets a shorter one.
  final double sliderWidth;

  /// The listener's volume, 0..1, as it changes.
  final Stream<double> volume;

  /// Each change of the volume as it happens, only when it changes: about
  /// 60 a second while the slider is dragged.
  final ValueChanged<double> onChanged;

  /// Mutes, or unmutes back to the volume before.
  final VoidCallback onToggleMute;

  /// The station the player is on, and whether it plays, for the muted
  /// reminder.
  final String? stationSlug;
  final bool playing;

  /// How much a wheel notch or a keyboard step changes the volume.
  static const double step = 0.05;

  /// How long the muted reminder stays, unless the pointer rests on it.
  static const Duration reminderDuration = Duration(seconds: 6);

  /// How soon the same station starting again, as one that keeps failing
  /// retries, can show the reminder again.
  static const Duration remindAgainAfter = Duration(minutes: 1);

  static const String mutedTitle = 'Sunetul e oprit';
  static const String mutedAction = 'Pornește-l cu un clic aici sau cu '
      '${DesktopShortcuts.muteHint}';

  /// The speaker for [volume]: crossed out at 0, then by level.
  static IconData iconFor(double volume) {
    if (volume <= 0) return Icons.volume_off_rounded;
    if (volume < 0.34) return Icons.volume_mute_rounded;
    if (volume < 0.67) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  State<DesktopVolumeControl> createState() => _DesktopVolumeControlState();
}

/// The slider knob's radius under the pointer.
const double _thumbRadius = 6;

/// The side of the speaker button.
const double _speakerSize = 36;

/// The knob's room with nothing drawn in it, for the slider at rest.
class _HiddenThumb extends SliderComponentShape {
  const _HiddenThumb();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.square(_thumbRadius * 2);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {}
}

class _DesktopVolumeControlState extends State<DesktopVolumeControl>
    with SingleTickerProviderStateMixin {
  StreamSubscription<double>? _subscription;
  double _volume = 1;

  bool _hovered = false;

  /// Where the muted reminder points.
  final LayerLink _speaker = LayerLink();
  final OverlayPortalController _reminder = OverlayPortalController();
  late final AnimationController _reminderFade = AnimationController(
    vsync: this,
    duration: DesktopTokens.hoverDuration,
  );
  Timer? _reminderTimer;
  bool _reminderHovered = false;

  /// The station the reminder last showed for, and when.
  String? _remindedSlug;
  DateTime? _remindedAt;

  @override
  void initState() {
    super.initState();
    _listen();
    // Once the volume has come in.
    if (widget.playing) _remindIfMutedAfterFrame();
  }

  @override
  void didUpdateWidget(DesktopVolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.volume != widget.volume) _listen();
    final started = widget.playing &&
        (!oldWidget.playing || oldWidget.stationSlug != widget.stationSlug);
    if (started) _remindIfMutedAfterFrame();
    // Stopped, nothing is meant to be heard.
    if (oldWidget.playing && !widget.playing) _hideReminder();
  }

  void _listen() {
    _subscription?.cancel();
    _subscription = widget.volume.listen((volume) {
      if (!mounted || volume == _volume) return;
      setState(() => _volume = volume);
      if (volume > 0) _hideReminder();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _reminderTimer?.cancel();
    _reminderFade.dispose();
    super.dispose();
  }

  void _set(double volume) {
    final value = volume.clamp(0.0, 1.0).toDouble();
    // A wheel notch past either end changes nothing.
    if (value == _volume) return;
    setState(() => _volume = value);
    widget.onChanged(value);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final dy = (event as PointerScrollEvent).scrollDelta.dy;
      if (dy == 0) return;
      // Up raises the volume, as on the system's own sliders.
      _set(_volume + (dy < 0 ? 1 : -1) * DesktopVolumeControl.step);
    });
  }

  // ─── Muted reminder ───

  void _remindIfMutedAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _volume > 0 || _reminder.isShowing) return;
      final now = DateTime.now();
      final remindedAt = _remindedAt;
      if (widget.stationSlug == _remindedSlug &&
          remindedAt != null &&
          now.difference(remindedAt) < DesktopVolumeControl.remindAgainAfter) {
        return;
      }
      _remindedSlug = widget.stationSlug;
      _remindedAt = now;
      // A bubble taken away under the pointer never heard it leave.
      _reminderHovered = false;
      _reminder.show();
      _reminderFade.forward();
      _scheduleHide();
    });
  }

  void _scheduleHide() {
    _reminderTimer?.cancel();
    if (_reminderHovered) return;
    _reminderTimer =
        Timer(DesktopVolumeControl.reminderDuration, _hideReminder);
  }

  void _hideReminder() {
    _reminderTimer?.cancel();
    if (!_reminder.isShowing) return;
    _reminderFade.reverse().whenCompleteOrCancel(() {
      // Unless it was shown again meanwhile.
      if (!mounted || !_reminderFade.isDismissed) return;
      _reminder.hide();
      // Its pointer region is gone without telling the pointer left.
      _reminderHovered = false;
    });
  }

  void _onReminderHover(bool hovered) {
    _reminderHovered = hovered;
    if (hovered) {
      _reminderTimer?.cancel();
    } else {
      _scheduleHide();
    }
  }

  Widget _buildReminder(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _reminderFade,
      curve: Curves.fastOutSlowIn,
    );
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _speaker,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -2),
        child: FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.12),
              end: Offset.zero,
            ).animate(curve),
            child: _MutedReminder(
              onTap: widget.onToggleMute,
              onHover: _onReminderHover,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_volume * 100).round();
    final accent = _hovered ? TvColors.primary : TvColors.textPrimary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OverlayPortal(
              controller: _reminder,
              overlayChildBuilder: _buildReminder,
              child: CompositedTransformTarget(
                link: _speaker,
                child: DesktopQuietIconButton(
                  onPressed: widget.onToggleMute,
                  tooltip: _volume > 0
                      ? 'Fără sunet (${DesktopShortcuts.muteHint})'
                      : 'Pornește sunetul (${DesktopShortcuts.muteHint})',
                  iconSize: 20,
                  // Snug, so the speaker sits close to its slider; the
                  // knob's own room is the gap between them.
                  size: _speakerSize,
                  icon: AnimatedSwitcher(
                    duration: DesktopTokens.hoverDuration,
                    child: Icon(
                      DesktopVolumeControl.iconFor(_volume),
                      key: ValueKey(DesktopVolumeControl.iconFor(_volume)),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: widget.sliderWidth,
              child: Semantics(
                label: 'Volum',
                value: '$percent%',
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    activeTrackColor: accent,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
                    // The knob keeps its room and only shows under the
                    // pointer, so the track never shifts as it appears.
                    thumbColor: Colors.white,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: _hovered
                        ? const RoundSliderThumbShape(
                            enabledThumbRadius: _thumbRadius,
                            elevation: 2,
                          )
                        : const _HiddenThumb(),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(
                    value: _volume,
                    onChanged: _set,
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()}%',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bubble over the speaker saying the sound is off; a click on it
/// turns the sound back on.
class _MutedReminder extends StatelessWidget {
  const _MutedReminder({required this.onTap, required this.onHover});

  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      button: true,
      label: '${DesktopVolumeControl.mutedTitle}. '
          '${DesktopVolumeControl.mutedAction}',
      excludeSemantics: true,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: GestureDetector(
          onTap: onTap,
          child: const DecoratedBox(
            decoration: ShapeDecoration(
              color: TvColors.surfaceHigh,
              shape: _BubbleBorder(),
              shadows: [
                BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                10,
                16,
                10 + _BubbleBorder.tail,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.volume_off_rounded,
                    size: 20,
                    color: TvColors.primary,
                  ),
                  SizedBox(width: 10),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        DesktopVolumeControl.mutedTitle,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: TvColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        DesktopVolumeControl.mutedAction,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: TvColors.textSecondary,
                        ),
                      ),
                    ],
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

/// A rounded bubble with a small tail under its middle, pointing down at
/// what it is about.
class _BubbleBorder extends ShapeBorder {
  const _BubbleBorder();

  /// How far the tail reaches below the bubble.
  static const double tail = 7;

  static const double _radius = 12;

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.only(bottom: tail);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final body = Rect.fromLTRB(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom - tail,
    );
    final middle = body.center.dx;
    const corner = Radius.circular(_radius);
    return Path()
      ..moveTo(body.left + _radius, body.top)
      ..lineTo(body.right - _radius, body.top)
      ..arcToPoint(Offset(body.right, body.top + _radius), radius: corner)
      ..lineTo(body.right, body.bottom - _radius)
      ..arcToPoint(Offset(body.right - _radius, body.bottom), radius: corner)
      ..lineTo(middle + tail, body.bottom)
      ..lineTo(middle, rect.bottom)
      ..lineTo(middle - tail, body.bottom)
      ..lineTo(body.left + _radius, body.bottom)
      ..arcToPoint(Offset(body.left, body.bottom - _radius), radius: corner)
      ..lineTo(body.left, body.top + _radius)
      ..arcToPoint(Offset(body.left + _radius, body.top), radius: corner)
      ..close();
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}
