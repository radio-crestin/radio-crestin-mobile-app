import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Android's page transition, with each fading page drawn once into an image
/// for the length of the fade.
///
/// The pages move as with [FadeForwardsPageTransitionsBuilder]: the new page
/// slides in from the right while it fades in, and the old one slides to the
/// left while it fades out. That builder fades the live pages through
/// opacity layers, and on a low-end GPU (moto g7 plus) the two full-screen
/// layers took ~28 ms a frame, which dropped 4–5 frames at the start of
/// every page change. Drawing an image with an alpha costs next to nothing.
///
/// What a page shows is frozen while it fades (450 ms), as with
/// [ZoomPageTransitionsBuilder]. During a predictive back gesture (Android 14
/// and later) the pages follow [PredictiveBackPageTransitionsBuilder].
class SnapshotFadeForwardsPageTransitionsBuilder
    extends PageTransitionsBuilder {
  /// Creates the builder, with [backgroundColor] behind the fading pages.
  const SnapshotFadeForwardsPageTransitionsBuilder({
    required this.backgroundColor,
  });

  /// Painted behind a page while the page above it comes or goes.
  final Color backgroundColor;

  @override
  Duration get transitionDuration => const Duration(
        milliseconds: FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds,
      );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // The predictive back builder is what hears the back gesture, so it
    // stays in the tree. Outside a gesture it gets settled animations and
    // only shows the page, and this transition moves it.
    final inGesture = route.popGestureInProgress;
    return PredictiveBackPageTransitionsBuilder(fallbackColor: backgroundColor)
        .buildTransitions(
      route,
      context,
      inGesture ? animation : kAlwaysCompleteAnimation,
      inGesture ? secondaryAnimation : kAlwaysDismissedAnimation,
      inGesture
          ? child
          : _FadeForwardsTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              allowSnapshotting: route.allowSnapshotting,
              backgroundColor: backgroundColor,
              child: child,
            ),
    );
  }
}

const _curve = Curves.easeInOutCubicEmphasized;

final _fadeIn = Tween<double>(begin: 0, end: 1)
    .chain(CurveTween(curve: const Interval(0, 0.75)));
final _fadeOut = Tween<double>(begin: 1, end: 0)
    .chain(CurveTween(curve: const Interval(0, 0.25)));

final _slideIn = Tween<Offset>(begin: const Offset(0.25, 0), end: Offset.zero)
    .chain(CurveTween(curve: _curve));
final _slideOut = Tween<Offset>(begin: Offset.zero, end: const Offset(0.25, 0))
    .chain(CurveTween(curve: _curve));
final _slideCovered =
    Tween<Offset>(begin: Offset.zero, end: const Offset(-0.25, 0))
        .chain(CurveTween(curve: _curve));
final _slideUncovered =
    Tween<Offset>(begin: const Offset(-0.25, 0), end: Offset.zero)
        .chain(CurveTween(curve: _curve));

/// The framework's FadeForwards transition with [_SnapshotFadeTransition]
/// in place of `FadeTransition`.
///
/// Each slide sits outside its fade, so the image doesn't change while it
/// moves; sliding and fading commute, so the pages look the same.
class _FadeForwardsTransition extends StatelessWidget {
  const _FadeForwardsTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.allowSnapshotting,
    required this.backgroundColor,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final bool allowSnapshotting;
  final Color backgroundColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, animation, child) => SlideTransition(
        position: _slideIn.animate(animation),
        child: _SnapshotFadeTransition(
          opacity: _fadeIn.animate(animation),
          allowSnapshotting: allowSnapshotting,
          child: child!,
        ),
      ),
      reverseBuilder: (context, animation, child) => IgnorePointer(
        ignoring: animation.status == AnimationStatus.forward,
        child: SlideTransition(
          position: _slideOut.animate(animation),
          child: _SnapshotFadeTransition(
            opacity: _fadeOut.animate(animation),
            allowSnapshotting: allowSnapshotting,
            child: child!,
          ),
        ),
      ),
      child: _CoveredTransition(
        secondaryAnimation: secondaryAnimation,
        allowSnapshotting: allowSnapshotting,
        backgroundColor: backgroundColor,
        child: child,
      ),
    );
  }
}

/// How a page moves while the page above it comes or goes.
class _CoveredTransition extends StatelessWidget {
  const _CoveredTransition({
    required this.secondaryAnimation,
    required this.allowSnapshotting,
    required this.backgroundColor,
    required this.child,
  });

  final Animation<double> secondaryAnimation;
  final bool allowSnapshotting;
  final Color backgroundColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final transition = DualTransitionBuilder(
      animation: ReverseAnimation(secondaryAnimation),
      forwardBuilder: (context, animation, child) => SlideTransition(
        position: _slideUncovered.animate(animation),
        child: _SnapshotFadeTransition(
          opacity: _fadeIn.animate(animation),
          allowSnapshotting: allowSnapshotting,
          child: child!,
        ),
      ),
      reverseBuilder: (context, animation, child) => SlideTransition(
        position: _slideCovered.animate(animation),
        child: _SnapshotFadeTransition(
          opacity: _fadeOut.animate(animation),
          allowSnapshotting: allowSnapshotting,
          child: child!,
        ),
      ),
      child: child,
    );
    if (!(ModalRoute.opaqueOf(context) ?? true)) return transition;
    return ColoredBox(
      color: secondaryAnimation.isAnimating
          ? backgroundColor
          : Colors.transparent,
      child: transition,
    );
  }
}

/// A `FadeTransition` that, while [opacity] runs, fades an image of [child]
/// taken when the fade starts instead of [child] itself.
class _SnapshotFadeTransition extends StatefulWidget {
  const _SnapshotFadeTransition({
    required this.opacity,
    required this.allowSnapshotting,
    required this.child,
  });

  final Animation<double> opacity;
  final bool allowSnapshotting;
  final Widget child;

  @override
  State<_SnapshotFadeTransition> createState() =>
      _SnapshotFadeTransitionState();
}

class _SnapshotFadeTransitionState extends State<_SnapshotFadeTransition> {
  final _controller = SnapshotController();
  late final _FadePainter _painter;

  @override
  void initState() {
    super.initState();
    _painter = _FadePainter(widget.opacity);
    _listen(widget.opacity);
    _updateSnapshotting();
  }

  @override
  void didUpdateWidget(_SnapshotFadeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.opacity != widget.opacity) {
      _stopListening(oldWidget.opacity);
      _listen(widget.opacity);
      _painter.opacity = widget.opacity;
    }
    _updateSnapshotting();
  }

  @override
  void dispose() {
    _stopListening(widget.opacity);
    _painter.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _listen(Animation<double> opacity) => opacity
    ..addListener(_updateSnapshotting)
    ..addStatusListener(_onStatusChanged);

  void _stopListening(Animation<double> opacity) => opacity
    ..removeListener(_updateSnapshotting)
    ..removeStatusListener(_onStatusChanged);

  void _onStatusChanged(AnimationStatus _) => _updateSnapshotting();

  /// An image only while the page fades and shows; a settled page paints
  /// live and keeps updating.
  ///
  /// The image is taken at the first frame the page shows, not before. A
  /// covered page's animations stop, and a page coming back starts at
  /// opacity 0: by its next frame they have caught up, so the image doesn't
  /// keep, say, the ink of the button that opened the page above, frozen
  /// half-faded.
  void _updateSnapshotting() {
    _controller.allowSnapshotting = widget.allowSnapshotting &&
        widget.opacity.isAnimating &&
        widget.opacity.value > 0;
  }

  @override
  Widget build(BuildContext context) {
    return SnapshotWidget(
      controller: _controller,
      painter: _painter,
      // A platform view can't be drawn into an image: such a page fades
      // live, through a layer.
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: widget.child,
    );
  }
}

/// Paints the page, or the image of it, with the [opacity]'s alpha.
class _FadePainter extends SnapshotPainter {
  _FadePainter(this._opacity) {
    _opacity.addListener(notifyListeners);
  }

  Animation<double> _opacity;
  final _layer = LayerHandle<OpacityLayer>();

  set opacity(Animation<double> value) {
    if (value == _opacity) return;
    final oldValue = _opacity.value;
    _opacity.removeListener(notifyListeners);
    _opacity = value..addListener(notifyListeners);
    if (value.value != oldValue) notifyListeners();
  }

  int get _alpha => ui.Color.getAlphaFromOpacity(_opacity.value);

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) {
    final alpha = _alpha;
    if (alpha == 0 || alpha == 255) {
      _layer.layer = null;
      if (alpha == 255) painter(context, offset);
      return;
    }
    _layer.layer = context.pushOpacity(
      offset,
      alpha,
      painter,
      oldLayer: _layer.layer,
    );
  }

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final alpha = _alpha;
    if (alpha == 0) return;
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    context.canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width, height),
      offset & Size(width / pixelRatio, height / pixelRatio),
      Paint()
        ..color = Color.fromARGB(alpha, 0, 0, 0)
        ..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _FadePainter oldPainter) =>
      oldPainter._opacity.value != _opacity.value;

  @override
  void dispose() {
    _opacity.removeListener(notifyListeners);
    _layer.layer = null;
    super.dispose();
  }
}
