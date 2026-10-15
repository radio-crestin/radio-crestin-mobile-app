import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import '../types/Station.dart';
import 'mini_player_bottom_inset.dart';
import 'status_snackbar_controller.dart';

/// Gap between the snackbar and the screen's side edges.
const double kStatusSnackbarMargin = 12.0;

/// Gap between the snackbar and the collapsed mini player below it.
const double kStatusSnackbarPlayerGap = 8.0;

/// Gap between the snackbar and the bottom safe area, with no mini player
/// below it (no station selected yet).
const double kStatusSnackbarEdgeGap = 12.0;

/// Gap between the snackbar and the top safe area (the status bar), the
/// highest it rises with the open full player.
const double kStatusSnackbarTopGap = 4.0;

/// From this panel position on, the snackbar shows its one-line form.
///
/// Over the open full player it sits in the short gap under the status bar,
/// where its docked form would cover the player's header.
const double kStatusSnackbarDenseFromPanelPosition = 0.5;

const _contentDuration = Duration(milliseconds: 250);

/// Over the open full player: in, and out.
const _enterDuration = Duration(milliseconds: 250);
const _exitDuration = Duration(milliseconds: 200);

/// Docked above the mini player, in and out, by way of under the player.
const _hopDuration = Duration(milliseconds: 380);

/// A swiped snackbar's way on down out of sight, or back to its place.
const _swipeDuration = Duration(milliseconds: 200);
const _radius = BorderRadius.all(Radius.circular(14));

/// The snackbar's distance from the screen's bottom with the player panel
/// collapsed.
///
/// [kStatusSnackbarPlayerGap] above the collapsed mini player, which sits
/// [panelBottomInset] above the bottom. With no mini player (no station
/// selected yet), [kStatusSnackbarEdgeGap] above the bottom safe area,
/// [bottomSafeArea] tall, or above [panelBottomInset] when that is taller
/// (an iPhone with a home button).
double statusSnackbarDockedBottom({
  required bool hasMiniPlayer,
  required double bottomSafeArea,
  required double panelBottomInset,
}) {
  if (hasMiniPlayer) {
    return panelBottomInset +
        kMiniPlayerCollapsedHeight +
        kStatusSnackbarPlayerGap;
  }
  return math.max(bottomSafeArea, panelBottomInset) + kStatusSnackbarEdgeGap;
}

/// The top of a snackbar [height] tall in an area [areaHeight] tall: its
/// bottom [bottom] above the area's bottom, raised by the panel's [rise],
/// but never above [minTop].
double statusSnackbarTop({
  required double areaHeight,
  required double height,
  required double bottom,
  required double rise,
  required double minTop,
}) =>
    math.max(minTop, areaHeight - bottom - rise - height);

/// A calm Material 3 status snackbar: offline, back online, a station
/// that failed to play, with a retry, or a station just hidden, with an
/// undo.
///
/// Docked above the mini player, it rises from under the player when
/// [message] appears, a little past its place, and settles; when it goes it
/// lifts a little, like a spring, and drops back under the player. Cut off
/// at the player's edge, it never covers the player. Over the open full
/// player ([dense]) it slides up and fades in, and back. It cross-fades its
/// content (resizing smoothly) when it changes. A station error or a hidden
/// station can be swiped down, under the player. It has no scrim and never
/// takes touches outside its own box.
class StatusSnackbar extends StatefulWidget {
  /// Creates the snackbar for [message].
  const StatusSnackbar({
    super.key,
    required this.message,
    required this.onDismissed,
    required this.onRetry,
    this.onUndo,
    this.dense = false,
    this.hideDepth = kStatusSnackbarPlayerGap,
  });

  /// Finds the card, which follows a swipe, in tests.
  @visibleForTesting
  static const Key cardKey = ValueKey('status-snackbar-card');

  /// What to show; null hides the snackbar.
  final StatusMessage? message;

  /// Shows one line: the status (or, for a station error, its reason)
  /// without the explanation, which screen readers still read.
  final bool dense;

  /// How far below its bottom edge the docked snackbar is out of sight:
  /// the gap down to the mini player it slides under, or with no mini
  /// player its whole way down to the screen's bottom edge.
  final double hideDepth;

  /// The listener dismissed the station error or the hidden station (a
  /// swipe down, or the screen reader's dismiss action). The network
  /// statuses cannot be dismissed.
  final VoidCallback onDismissed;

  /// The listener tapped "Reîncearcă" on a station error.
  final VoidCallback onRetry;

  /// The listener tapped "Anulează" on a hidden station.
  final VoidCallback? onUndo;

  @override
  State<StatusSnackbar> createState() => _StatusSnackbarState();
}

class _StatusSnackbarState extends State<StatusSnackbar>
    with TickerProviderStateMixin {
  /// How far it slides over the open full player, fading.
  static const double _slideDistance = 16;

  /// On its way out it first lifts this much; on its way in it rises this
  /// much past its place before it settles.
  static const double _hopLift = 7;
  static const double _hopOvershoot = 5;

  /// Where the hops turn: out, from lifting to dropping; in, from rising
  /// to settling (as shares of [_hopDuration]).
  static const double _hopOutTurn = 0.26;
  static const double _hopInTurn = 0.72;

  /// A swipe down this far (as a share of the card's height), or this
  /// fast (logical pixels a second), dismisses it; a shorter one lets it
  /// back up.
  static const double _swipeShare = 0.4;
  static const double _swipeVelocity = 700;

  /// Over the open full player a swipe fades it out over this distance.
  static const double _denseSwipeFade = 48;

  /// 1 when shown; how it moves between depends on [StatusSnackbar.dense].
  late final AnimationController _visibility = AnimationController(
    vsync: this,
    duration: _hopDuration,
  )..addStatusListener(_onVisibilityStatus);
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _visibility,
    curve: Curves.fastOutSlowIn,
    reverseCurve: Curves.easeIn,
  );

  /// How far the listener dragged it down, in logical pixels; once let go
  /// it runs on out of sight, or back up.
  late final AnimationController _drag =
      AnimationController.unbounded(vsync: this);

  late final Listenable _motion = Listenable.merge([_visibility, _drag]);

  /// What is on screen; outlives [StatusSnackbar.message] during the exit.
  StatusMessage? _shown;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusSnackbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message != oldWidget.message) _sync();
  }

  @override
  void dispose() {
    _curve.dispose();
    _visibility.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _sync() {
    final next = widget.message;
    if (next == null) {
      if (_shown == null) return;
      if (_visibility.isDismissed) {
        // Gone before it began to show.
        _shown = null;
      } else if (TickerMode.valuesOf(context).enabled) {
        _setDurations();
        _visibility.reverse();
      } else {
        // Out of sight, under another page: gone at once. Its exit can't
        // play there, and would only start once the page shows again,
        // after a frame or more of the message drawn in full.
        _shown = null;
        _visibility.value = 0;
        _drag.value = 0;
      }
      return;
    }
    final appearing = _shown == null;
    _shown = next;
    _setDurations();
    if (!appearing) {
      _visibility.forward();
      return;
    }
    _drag.value = 0;
    // A message often comes with the change it tells of (a station hidden,
    // a stream failing), in a frame busy with that change. Started there,
    // its first frames would be skipped and it would pop up near its place
    // instead of rising from under the player: it starts with the next
    // frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _shown != null && widget.message != null) {
        _visibility.forward();
      }
    });
  }

  void _setDurations() {
    _visibility
      ..duration = widget.dense ? _enterDuration : _hopDuration
      ..reverseDuration = widget.dense ? _exitDuration : _hopDuration;
  }

  void _onVisibilityStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    if (widget.message != null || _shown == null) return;
    setState(() => _shown = null);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _drag.value = math.max(0, _drag.value + details.delta.dy);
  }

  /// Down far or fast enough, it goes on out of sight and is dismissed;
  /// otherwise it goes back to its place.
  void _onDragEnd(DragEndDetails details) {
    final height = context.size?.height ?? 0;
    final flung = details.velocity.pixelsPerSecond.dy >= _swipeVelocity;
    if (!flung && _drag.value < height * _swipeShare) {
      _letGo();
      return;
    }
    final out = widget.dense ? _denseSwipeFade : height + widget.hideDepth;
    _drag
        .animateTo(
          math.max(out, _drag.value),
          duration: _swipeDuration,
          curve: Curves.easeOut,
        )
        .whenComplete(_onSwiped);
  }

  void _letGo() => _drag.animateTo(
        0,
        duration: _swipeDuration,
        curve: Curves.easeOut,
      );

  /// Already out of sight by the swipe: no exit animation, just gone.
  void _onSwiped() {
    if (!mounted) return;
    setState(() => _shown = null);
    _visibility.value = 0;
    _drag.value = 0;
    widget.onDismissed();
  }

  /// Where the card is drawn: [fraction] of its own height plus [pixels]
  /// below its place, how opaque, and whether it is cut off at the edge it
  /// hides under.
  ({double fraction, double pixels, double opacity, bool clip}) _placement() {
    final drag = _drag.value;
    if (widget.dense) {
      final shown = _curve.value.clamp(0.0, 1.0);
      final kept = 1 - (drag / _denseSwipeFade).clamp(0.0, 1.0);
      return (
        fraction: 0,
        pixels: (1 - shown) * _slideDistance + drag,
        opacity: shown * kept,
        clip: false,
      );
    }
    final depth = widget.hideDepth;
    final t = _visibility.value;
    final (fraction, pixels) = switch (_visibility.status) {
      AnimationStatus.forward => _hopIn(t, depth),
      AnimationStatus.reverse => _hopOut(1 - t, depth),
      AnimationStatus.completed => (0.0, 0.0),
      AnimationStatus.dismissed => (1.0, depth),
    };
    return (fraction: fraction, pixels: pixels + drag, opacity: 1, clip: true);
  }

  /// Up from under the player, a little past its place, then settling.
  static (double, double) _hopIn(double t, double depth) {
    if (t < _hopInTurn) {
      final s = Easing.emphasizedDecelerate.transform(t / _hopInTurn);
      return (1 - s, lerpDouble(depth, -_hopOvershoot, s)!);
    }
    final s = Curves.easeInOut.transform(
      (t - _hopInTurn) / (1 - _hopInTurn),
    );
    return (0, lerpDouble(-_hopOvershoot, 0, s)!);
  }

  /// A little lift, like a spring, then down under the player.
  static (double, double) _hopOut(double p, double depth) {
    if (p < _hopOutTurn) {
      final s = Easing.legacyDecelerate.transform(p / _hopOutTurn);
      return (0, -_hopLift * s);
    }
    final s = Easing.emphasizedAccelerate.transform(
      (p - _hopOutTurn) / (1 - _hopOutTurn),
    );
    return (s, lerpDouble(-_hopLift, depth, s)!);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    final swipeable = shown.isDismissible;
    final card = GestureDetector(
      key: StatusSnackbar.cardKey,
      onVerticalDragStart: swipeable ? (_) => _drag.stop() : null,
      onVerticalDragUpdate: swipeable ? _onDragUpdate : null,
      onVerticalDragEnd: swipeable ? _onDragEnd : null,
      onVerticalDragCancel: swipeable ? _letGo : null,
      child: _Surface(
        onDismiss: swipeable ? widget.onDismissed : null,
        child: AnimatedSwitcher(
          duration: _contentDuration,
          child: _Content(
            key: ValueKey('${shown.contentKey}|${widget.dense}'),
            message: shown,
            dense: widget.dense,
            onRetry: widget.onRetry,
            onUndo: widget.onUndo ?? () {},
          ),
        ),
      ),
    );
    return AnimatedBuilder(
      animation: _motion,
      child: card,
      builder: (context, card) {
        final place = _placement();
        return ClipRect(
          clipper: _AboveEdge(widget.hideDepth),
          clipBehavior: place.clip ? Clip.hardEdge : Clip.none,
          child: FractionalTranslation(
            translation: Offset(0, place.fraction),
            child: Transform.translate(
              offset: Offset(0, place.pixels),
              child: Opacity(opacity: place.opacity, child: card),
            ),
          ),
        );
      },
    );
  }
}

/// Cuts off what goes [depth] below the box's bottom edge: the edge of the
/// mini player, which the snackbar slides under. Leaves room on the other
/// sides for the lift and the shadow.
class _AboveEdge extends CustomClipper<Rect> {
  const _AboveEdge(this.depth);

  final double depth;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
        -size.width,
        -size.height,
        size.width * 2,
        size.height + depth,
      );

  @override
  bool shouldReclip(_AboveEdge oldClipper) => oldClipper.depth != depth;
}

/// The inverse-surface card: rounded, shadowed, announced to screen readers
/// whenever its content changes.
class _Surface extends StatelessWidget {
  const _Surface({required this.onDismiss, required this.child});

  /// The screen reader's dismiss action; null when it cannot be dismissed.
  final VoidCallback? onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return Semantics(
      container: true,
      liveRegion: true,
      onDismiss: onDismiss,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: _radius,
          boxShadow: const [
            BoxShadow(
              color: AppColors.statusSnackbarShadow,
              blurRadius: 20,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedSize(
            duration: _contentDuration,
            curve: Curves.easeInOut,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    super.key,
    required this.message,
    required this.dense,
    required this.onRetry,
    required this.onUndo,
  });

  final StatusMessage message;
  final bool dense;
  final VoidCallback onRetry;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) => switch (message.kind) {
        StatusKind.offline => dense
            ? _DenseOfflineContent(message: message)
            : _OfflineContent(message: message),
        StatusKind.backOnline =>
          _BackOnlineContent(message: message, dense: dense),
        StatusKind.stationError => _station(
            _StatusAction(
              label: 'Reîncearcă',
              icon: Icons.refresh_rounded,
              onPressed: onRetry,
            ),
          ),
        StatusKind.stationHidden => _station(
            _StatusAction(
              label: 'Anulează',
              icon: Icons.undo_rounded,
              onPressed: onUndo,
            ),
          ),
      };

  Widget _station(_StatusAction action) => dense
      ? _DenseStationContent(message: message, action: action)
      : _StationContent(message: message, action: action);
}

/// The button on a station's status: its label, the icon that stands in
/// for it in the one-line form at large text sizes, and what it does.
class _StatusAction {
  const _StatusAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

TextStyle _titleStyle(Color color) => TextStyle(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      height: 20 / 14.5,
      color: color,
    );

TextStyle _bodyStyle(Color color) =>
    TextStyle(fontSize: 13, height: 18 / 13, color: color);

/// One line of the network statuses, at least this tall.
const _minLineHeight = 52.0;

/// The one-line form, at least this tall.
const _denseLineHeight = 40.0;

/// What a screen reader says for [message]: the title and its explanation,
/// also when the one-line form leaves the explanation out.
String _spoken(StatusMessage message) {
  final body = message.body;
  return body == null ? message.title : '${message.title}. $body';
}

class _OfflineContent extends StatelessWidget {
  const _OfflineContent({required this.message});

  final StatusMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    // Title only (nothing to explain): one centred line, 52pt tall.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _minLineHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        child: Row(
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 22,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 14),
            Expanded(child: _TitleAndBody(message: message)),
          ],
        ),
      ),
    );
  }
}

/// Offline in one line: the icon and "Nu ai conexiune la internet".
class _DenseOfflineContent extends StatelessWidget {
  const _DenseOfflineContent({required this.message});

  final StatusMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _denseLineHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Row(
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 18,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message.title,
                style: _titleStyle(colors.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                semanticsLabel: _spoken(message),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackOnlineContent extends StatelessWidget {
  const _BackOnlineContent({required this.message, required this.dense});

  final StatusMessage message;

  /// The one-line form's height and padding; the content is the same.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    final suffix = message.body;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: dense ? _denseLineHeight : _minLineHeight,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: dense ? 14 : 16),
        child: Row(
          children: [
            Icon(Icons.check_rounded, size: 20, color: colors.success),
            const SizedBox(width: 12),
            Flexible(
              child: Text.rich(
                TextSpan(
                  text: message.title,
                  style: _titleStyle(colors.text),
                  children: [
                    if (suffix != null)
                      TextSpan(
                        text: ' · $suffix',
                        style: _titleStyle(colors.textSecondary)
                            .copyWith(fontWeight: FontWeight.w400),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A station's status (a failure, or the station hidden): its artwork, the
/// station and what happened, and the [action].
class _StationContent extends StatelessWidget {
  const _StationContent({required this.message, required this.action});

  /// Left padding, artwork and the gap after it.
  static const _leading = 12.0 + _StationArtwork.size + 12.0;
  static const _trailing = 6.0;

  final StatusMessage message;
  final _StatusAction action;

  @override
  Widget build(BuildContext context) {
    final actionWidth = _ActionButton.widthIn(context, action.label);
    return LayoutBuilder(builder: (context, constraints) {
      final textRoom =
          constraints.maxWidth - _leading - _trailing - actionWidth;
      // With large text the action moves under the text, rather than
      // leaving it less room than the action itself.
      final stacked = textRoom < actionWidth;
      final summary = Row(
        children: [
          _StationArtwork(station: message.station),
          const SizedBox(width: 12),
          Expanded(child: _TitleAndBody(message: message, titleMaxLines: 1)),
          if (!stacked) _ActionButton(action: action),
        ],
      );
      if (!stacked) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, _trailing, 10),
          child: summary,
        );
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, _trailing, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 16 - _trailing),
              child: summary,
            ),
            _ActionButton(action: action),
          ],
        ),
      );
    });
  }
}

/// A station's status in one line: the artwork, what happened (the reason
/// for an error) and the [action]. The station's name is left to the full
/// player's header below it.
class _DenseStationContent extends StatelessWidget {
  const _DenseStationContent({
    required this.message,
    required this.action,
  });

  static const _artwork = 28.0;

  /// Left padding, artwork and the gap after it.
  static const _leading = 10.0 + _artwork + 10.0;
  static const _trailing = 6.0;

  final StatusMessage message;
  final _StatusAction action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    final actionWidth = _ActionButton.widthIn(context, action.label);
    return LayoutBuilder(builder: (context, constraints) {
      final textRoom =
          constraints.maxWidth - _leading - _trailing - actionWidth;
      // With large text the labelled action would crowd out the reason;
      // its icon keeps the line, and the label for screen readers.
      final iconOnly = textRoom < actionWidth;
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, _trailing, 0),
        child: Row(
          children: [
            _StationArtwork(
              station: message.station,
              dimension: _artwork,
              radius: 8,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message.body ?? message.title,
                style: _titleStyle(colors.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                semanticsLabel: _spoken(message),
              ),
            ),
            iconOnly
                ? _ActionIconButton(action: action)
                : _ActionButton(action: action),
          ],
        ),
      );
    });
  }
}

class _TitleAndBody extends StatelessWidget {
  const _TitleAndBody({required this.message, this.titleMaxLines});

  final StatusMessage message;
  final int? titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    final body = message.body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message.title,
          style: _titleStyle(colors.text),
          maxLines: titleMaxLines,
          overflow: titleMaxLines == null ? null : TextOverflow.ellipsis,
        ),
        if (body != null) Text(body, style: _bodyStyle(colors.textSecondary)),
      ],
    );
  }
}

/// The failed station's thumbnail, as the mini player shows it.
class _StationArtwork extends StatelessWidget {
  const _StationArtwork({
    required this.station,
    this.dimension = size,
    this.radius = 10,
  });

  /// The docked form's size.
  static const size = 40.0;

  final Station? station;
  final double dimension;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        child: SizedBox.square(
          dimension: dimension,
          child: station?.thumbnail ??
              ColoredBox(
                color: colors.textSecondary.withValues(alpha: 0.14),
                child: Icon(
                  Icons.radio_rounded,
                  size: dimension * 0.55,
                  color: colors.textSecondary,
                ),
              ),
        ),
      ),
    );
  }
}

/// The action as a text button, like "Reîncearcă" on a station error.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});

  static const _padding = 14.0;
  static const _minSize = 48.0;
  static const _style = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700);

  final _StatusAction action;

  /// The label's style: the theme's button text, at the design's size.
  static TextStyle _textStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge?.merge(_style) ?? _style;

  /// Its width with [label] at the current text scale.
  static double widthIn(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _textStyle(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width + 2 * _padding;
    painter.dispose();
    return math.max(width, _minSize);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return TextButton(
      onPressed: action.onPressed,
      style: TextButton.styleFrom(
        foregroundColor: colors.action,
        padding: const EdgeInsets.symmetric(horizontal: _padding),
        minimumSize: const Size(_minSize, _minSize),
        tapTargetSize: MaterialTapTargetSize.padded,
        textStyle: _textStyle(context),
      ),
      child: Text(action.label),
    );
  }
}

/// The action as an icon, for the one-line form at large text sizes.
class _ActionIconButton extends StatelessWidget {
  const _ActionIconButton({required this.action});

  final _StatusAction action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return IconButton(
      onPressed: action.onPressed,
      tooltip: action.label,
      color: colors.action,
      icon: Icon(action.icon, size: 22),
    );
  }
}

/// Places the [StatusSnackbar] on the home page, over the sliding player
/// panel.
///
/// With the panel collapsed it docks [dockedBottom] above the bottom (see
/// [statusSnackbarDockedBottom]), gliding when that changes. As the panel
/// opens it rises with the panel's top edge and stays above the open full
/// player, but never closer to the status bar than [kStatusSnackbarTopGap].
/// Past [kStatusSnackbarDenseFromPanelPosition] it turns into its one-line
/// form, which fits the short gap above the open panel instead of covering
/// the full player's header.
class StatusSnackbarOverlay extends StatefulWidget {
  /// Creates the overlay; it fills the home page's Stack.
  const StatusSnackbarOverlay({
    super.key,
    required this.controller,
    required this.panelPosition,
    required this.panelTravel,
    required this.dockedBottom,
    required this.listInset,
    required this.listReservedInset,
    required this.onRetry,
    this.onUndo,
    this.hasMiniPlayer = true,
  });

  /// Decides what the snackbar says.
  final StatusSnackbarController controller;

  /// The panel's position: 0 collapsed, 1 open.
  final ValueListenable<double> panelPosition;

  /// How far the panel's top edge rises from collapsed to open.
  final double panelTravel;

  /// The snackbar's distance from the bottom with the panel collapsed.
  final double dockedBottom;

  /// Set to the room the station list must add at its end, so its last
  /// rows stay reachable above the docked offline snackbar.
  final ValueNotifier<double> listInset;

  /// The room the list already keeps at its end (the mini player's).
  final double listReservedInset;

  /// Retries the current station; the error is dismissed first.
  final VoidCallback onRetry;

  /// Shows the station just hidden again; its message is dismissed first.
  final VoidCallback? onUndo;

  /// Whether the mini player is below the docked snackbar, which then
  /// comes and goes from under it; without one, from under the screen's
  /// bottom edge.
  final bool hasMiniPlayer;

  @override
  State<StatusSnackbarOverlay> createState() => _StatusSnackbarOverlayState();
}

class _StatusSnackbarOverlayState extends State<StatusSnackbarOverlay> {
  /// The docked snackbar's laid-out height (0 while hidden).
  double _height = 0;

  /// Whether the open panel calls for the one-line form.
  late bool _dense;

  static bool _denseAt(double panelPosition) =>
      panelPosition >= kStatusSnackbarDenseFromPanelPosition;

  @override
  void initState() {
    super.initState();
    _dense = _denseAt(widget.panelPosition.value);
    widget.controller.addListener(_updateListInset);
    widget.panelPosition.addListener(_onPanelMoved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.controller.holdErrors = MediaQuery.accessibleNavigationOf(context);
    // Another page covers this one, like Settings over Home, whatever its
    // route: the navigator then mutes this page's tickers. A sheet or a
    // dialog leaves the page in sight, and its tickers on. The listener
    // moved on from the station they hid, and may even show it again from
    // there, so its undo goes rather than wait for them on the way back.
    // A station error stays: it is about what plays.
    if (!TickerMode.valuesOf(context).enabled) {
      widget.controller.clearStationHidden();
    }
  }

  @override
  void didUpdateWidget(StatusSnackbarOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_updateListInset);
      widget.controller.addListener(_updateListInset);
      widget.controller.holdErrors = MediaQuery.accessibleNavigationOf(context);
    }
    if (oldWidget.panelPosition != widget.panelPosition) {
      oldWidget.panelPosition.removeListener(_onPanelMoved);
      widget.panelPosition.addListener(_onPanelMoved);
      _dense = _denseAt(widget.panelPosition.value);
    }
    if (oldWidget.dockedBottom != widget.dockedBottom ||
        oldWidget.listReservedInset != widget.listReservedInset) {
      // The list listens to the inset: never notify it mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateListInset();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateListInset);
    widget.panelPosition.removeListener(_onPanelMoved);
    super.dispose();
  }

  /// Rebuilds only when the panel crosses into or out of the one-line form;
  /// the position itself only moves the snackbar (see [_PlacementDelegate]).
  void _onPanelMoved() {
    final dense = _denseAt(widget.panelPosition.value);
    if (dense != _dense) setState(() => _dense = dense);
  }

  /// The list makes room for the docked form only: the one-line form shows
  /// over the open full player, where the list is out of sight.
  void _onHeight(double height) {
    if (!mounted || _dense || height == _height) return;
    _height = height;
    _updateListInset();
  }

  /// Only the persistent offline status earns list room; transient ones
  /// leave on their own.
  void _updateListInset() {
    final offline = widget.controller.message?.kind == StatusKind.offline;
    final room = _height + widget.dockedBottom - widget.listReservedInset;
    widget.listInset.value = offline && _height > 0 ? math.max(0.0, room) : 0.0;
  }

  void _retry() {
    widget.controller.clearError();
    widget.onRetry();
  }

  void _undo() {
    widget.controller.clearStationHidden();
    widget.onUndo?.call();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return _PanelFollowingPlacement(
      panelPosition: widget.panelPosition,
      travel: widget.panelTravel,
      bottom: widget.dockedBottom,
      child: _HeightReporter(
        onHeight: _onHeight,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => StatusSnackbar(
            message: controller.message,
            dense: _dense,
            hideDepth: widget.hasMiniPlayer
                ? kStatusSnackbarPlayerGap
                : widget.dockedBottom,
            onDismissed: controller.dismiss,
            onRetry: _retry,
            onUndo: _undo,
          ),
        ),
      ),
    );
  }
}

/// Docks its child [bottom] above the bottom and lifts it with the panel,
/// up to just below the status bar.
class _PanelFollowingPlacement extends StatelessWidget {
  const _PanelFollowingPlacement({
    required this.panelPosition,
    required this.travel,
    required this.bottom,
    required this.child,
  });

  final ValueListenable<double> panelPosition;
  final double travel;
  final double bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final minTop = MediaQuery.paddingOf(context).top + kStatusSnackbarTopGap;
    // The mini player coming or going moves the dock: glide, don't jump.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: bottom),
      duration: _contentDuration,
      curve: Curves.easeInOut,
      child: child,
      builder: (context, bottom, child) => CustomSingleChildLayout(
        delegate: _PlacementDelegate(
          panelPosition: panelPosition,
          travel: travel,
          bottom: bottom,
          minTop: minTop,
        ),
        child: child,
      ),
    );
  }
}

/// Lays the snackbar out across the width, inside the side margins, and
/// moves it with the panel. Only its position changes as the panel slides:
/// its content keeps its layout.
class _PlacementDelegate extends SingleChildLayoutDelegate {
  _PlacementDelegate({
    required this.panelPosition,
    required this.travel,
    required this.bottom,
    required this.minTop,
  }) : super(relayout: panelPosition);

  final ValueListenable<double> panelPosition;
  final double travel;
  final double bottom;
  final double minTop;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width =
        math.max(0.0, constraints.maxWidth - 2 * kStatusSnackbarMargin);
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
        kStatusSnackbarMargin,
        statusSnackbarTop(
          areaHeight: size.height,
          height: childSize.height,
          bottom: bottom,
          rise: panelPosition.value * travel,
          minTop: minTop,
        ),
      );

  @override
  bool shouldRelayout(_PlacementDelegate oldDelegate) =>
      oldDelegate.panelPosition != panelPosition ||
      oldDelegate.travel != travel ||
      oldDelegate.bottom != bottom ||
      oldDelegate.minTop != minTop;
}

/// Takes a hidden station's undo away once the listener scrolls [child],
/// the station list: they moved on, and the message would only cover the
/// rows. A station error stays, it still asks for an answer; and the list
/// moving on its own (a slot closing, a jump) leaves the undo too.
class StatusSnackbarScrollListener extends StatelessWidget {
  /// Watches [child] for the listener's scrolls.
  const StatusSnackbarScrollListener({
    super.key,
    required this.controller,
    required this.child,
  });

  final StatusSnackbarController controller;
  final Widget child;

  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.depth == 0 &&
        notification.direction != ScrollDirection.idle) {
      controller.clearStationHidden();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<UserScrollNotification>(
      onNotification: _onUserScroll,
      child: child,
    );
  }
}

/// A trailing sliver spacer that keeps the last station rows reachable
/// above the docked offline snackbar. Belongs once, at the very end of the
/// list, next to `MiniPlayerBottomInset`.
class StatusSnackbarListInset extends StatelessWidget {
  /// Creates the spacer, as tall as [inset].
  const StatusSnackbarListInset({super.key, required this.inset});

  /// The extra room, from [StatusSnackbarOverlay.listInset].
  final ValueListenable<double> inset;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: ValueListenableBuilder<double>(
        valueListenable: inset,
        builder: (context, height, _) => AnimatedContainer(
          duration: _contentDuration,
          curve: Curves.easeInOut,
          height: height,
        ),
      ),
    );
  }
}

/// Reports its child's laid-out height after each frame it changes.
class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHeightReporter renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Listeners may rebuild other widgets, which is not allowed mid-layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}
