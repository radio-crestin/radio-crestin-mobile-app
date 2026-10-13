import 'dart:math' as math;

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
const _enterDuration = Duration(milliseconds: 250);
const _exitDuration = Duration(milliseconds: 200);
const _radius = BorderRadius.all(Radius.circular(14));

/// The snackbar's distance from the bottom of the home page's Stack with the
/// player panel collapsed.
///
/// [kStatusSnackbarPlayerGap] above the collapsed mini player. With no mini
/// player (no station selected yet), [kStatusSnackbarEdgeGap] above the
/// bottom safe area, [bottomSafeArea] tall, of which [stackBottomInset]
/// already lies below the Stack.
double statusSnackbarDockedBottom({
  required bool hasMiniPlayer,
  required double bottomSafeArea,
  required double stackBottomInset,
}) {
  if (hasMiniPlayer) {
    return kMiniPlayerCollapsedHeight + kStatusSnackbarPlayerGap;
  }
  return math.max(0.0, bottomSafeArea - stackBottomInset) +
      kStatusSnackbarEdgeGap;
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

/// A calm Material 3 status snackbar: offline, back online, or a station
/// that failed to play, with a retry.
///
/// It slides up and fades in when [message] appears, slides down and fades
/// out when it goes, and cross-fades its content (resizing smoothly) when
/// it changes. A station error can be swiped away. It has no scrim and
/// never takes touches outside its own box.
class StatusSnackbar extends StatefulWidget {
  /// Creates the snackbar for [message].
  const StatusSnackbar({
    super.key,
    required this.message,
    required this.onDismissed,
    required this.onRetry,
    this.dense = false,
  });

  /// What to show; null hides the snackbar.
  final StatusMessage? message;

  /// Shows one line: the status (or, for a station error, its reason)
  /// without the explanation, which screen readers still read.
  final bool dense;

  /// The listener dismissed the station error (a swipe, or the screen
  /// reader's dismiss action). The network statuses cannot be dismissed.
  final VoidCallback onDismissed;

  /// The listener tapped "Reîncearcă" on a station error.
  final VoidCallback onRetry;

  @override
  State<StatusSnackbar> createState() => _StatusSnackbarState();
}

class _StatusSnackbarState extends State<StatusSnackbar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _visibility;
  late final CurvedAnimation _curve;

  /// What is on screen; outlives [StatusSnackbar.message] during the exit.
  StatusMessage? _shown;

  /// Counts swipes, so the next message gets a fresh `Dismissible`.
  int _swipes = 0;

  @override
  void initState() {
    super.initState();
    _visibility = AnimationController(
      vsync: this,
      duration: _enterDuration,
      reverseDuration: _exitDuration,
    )..addStatusListener(_onVisibilityStatus);
    _curve = CurvedAnimation(
      parent: _visibility,
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.easeIn,
    );
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
    super.dispose();
  }

  void _sync() {
    final next = widget.message;
    if (next == null) {
      if (_shown != null) _visibility.reverse();
      return;
    }
    _shown = next;
    _visibility.forward();
  }

  void _onVisibilityStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    if (widget.message != null || _shown == null) return;
    setState(() => _shown = null);
  }

  /// Already slid off by the swipe: no exit animation, just gone.
  void _onSwiped(DismissDirection _) {
    setState(() {
      _shown = null;
      _swipes++;
    });
    _visibility.value = 0;
    widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    return _SlideFade(
      animation: _curve,
      child: Dismissible(
        key: ValueKey(_swipes),
        // Always a Dismissible, so the content still cross-fades when the
        // status changes kind; only a station error follows the swipe.
        direction: shown.isDismissible
            ? DismissDirection.horizontal
            : DismissDirection.none,
        // The swipe ends it; the page decides what shows next.
        resizeDuration: null,
        onDismissed: _onSwiped,
        child: _Surface(
          onDismiss: shown.isDismissible ? widget.onDismissed : null,
          child: AnimatedSwitcher(
            duration: _contentDuration,
            child: _Content(
              key: ValueKey('${shown.contentKey}|${widget.dense}'),
              message: shown,
              dense: widget.dense,
              onRetry: widget.onRetry,
            ),
          ),
        ),
      ),
    );
  }
}

/// Enters by sliding up 16pt while fading in; exits the reverse way.
class _SlideFade extends AnimatedWidget {
  const _SlideFade({required Animation<double> animation, required this.child})
      : super(listenable: animation);

  static const _distance = 16.0;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    return Transform.translate(
      offset: Offset(0, (1 - t) * _distance),
      child: Opacity(opacity: t, child: child),
    );
  }
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
  });

  final StatusMessage message;
  final bool dense;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (message.kind) {
        StatusKind.offline => dense
            ? _DenseOfflineContent(message: message)
            : _OfflineContent(message: message),
        StatusKind.backOnline =>
          _BackOnlineContent(message: message, dense: dense),
        StatusKind.stationError => dense
            ? _DenseStationErrorContent(message: message, onRetry: onRetry)
            : _StationErrorContent(message: message, onRetry: onRetry),
      };
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

class _StationErrorContent extends StatelessWidget {
  const _StationErrorContent({required this.message, required this.onRetry});

  /// Left padding, artwork and the gap after it.
  static const _leading = 12.0 + _StationArtwork.size + 12.0;
  static const _trailing = 6.0;

  final StatusMessage message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final retryWidth = _RetryButton.widthIn(context);
    return LayoutBuilder(builder: (context, constraints) {
      final textRoom = constraints.maxWidth - _leading - _trailing - retryWidth;
      // With large text the action moves under the text, rather than
      // leaving it less room than the action itself.
      final stacked = textRoom < retryWidth;
      final summary = Row(
        children: [
          _StationArtwork(station: message.station),
          const SizedBox(width: 12),
          Expanded(child: _TitleAndBody(message: message, titleMaxLines: 1)),
          if (!stacked) _RetryButton(onPressed: onRetry),
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
            _RetryButton(onPressed: onRetry),
          ],
        ),
      );
    });
  }
}

/// A station error in one line: the artwork, the reason and the retry. The
/// station's name is left to the full player's header below it.
class _DenseStationErrorContent extends StatelessWidget {
  const _DenseStationErrorContent({
    required this.message,
    required this.onRetry,
  });

  static const _artwork = 28.0;

  /// Left padding, artwork and the gap after it.
  static const _leading = 10.0 + _artwork + 10.0;
  static const _trailing = 6.0;

  final StatusMessage message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    final retryWidth = _RetryButton.widthIn(context);
    return LayoutBuilder(builder: (context, constraints) {
      final textRoom = constraints.maxWidth - _leading - _trailing - retryWidth;
      // With large text the labelled action would crowd out the reason;
      // its icon keeps the line, and the label for screen readers.
      final iconOnly = textRoom < retryWidth;
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
                ? _RetryIconButton(onPressed: onRetry)
                : _RetryButton(onPressed: onRetry),
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

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onPressed});

  static const _label = 'Reîncearcă';
  static const _padding = 14.0;
  static const _minSize = 48.0;
  static const _style = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700);

  final VoidCallback onPressed;

  /// The label's style: the theme's button text, at the design's size.
  static TextStyle _textStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge?.merge(_style) ?? _style;

  /// Its width at the current text scale.
  static double widthIn(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: _label, style: _textStyle(context)),
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
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: colors.action,
        padding: const EdgeInsets.symmetric(horizontal: _padding),
        minimumSize: const Size(_minSize, _minSize),
        tapTargetSize: MaterialTapTargetSize.padded,
        textStyle: _textStyle(context),
      ),
      child: const Text(_label),
    );
  }
}

/// "Reîncearcă" as an icon, for the one-line form at large text sizes.
class _RetryIconButton extends StatelessWidget {
  const _RetryIconButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return IconButton(
      onPressed: onPressed,
      tooltip: _RetryButton._label,
      color: colors.action,
      icon: const Icon(Icons.refresh_rounded, size: 22),
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
            onDismissed: controller.clearError,
            onRetry: _retry,
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
