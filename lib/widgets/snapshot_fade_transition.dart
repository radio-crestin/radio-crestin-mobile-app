import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A `FadeTransition` that, while [opacity] runs, fades an image of [child]
/// taken when the fade starts instead of [child] itself.
///
/// A live fade draws [child] through an offscreen opacity layer every
/// frame, which for a large area costs a low-end GPU ~10 ms a frame;
/// drawing an image with an alpha costs next to nothing. What [child] shows
/// is frozen while it fades; settled, it paints live and keeps updating.
///
/// A [child] holding a platform view can't be drawn into an image: it
/// fades live, through a layer. A texture (video) is drawn into the image,
/// at the frame it shows when the fade starts.
class SnapshotFadeTransition extends StatefulWidget {
  /// Creates the transition.
  const SnapshotFadeTransition({
    super.key,
    required this.opacity,
    this.allowSnapshotting = true,
    required this.child,
  });

  /// How opaque [child] is, from 0 to 1.
  final Animation<double> opacity;

  /// Whether [child] may be drawn into an image while it fades, as a
  /// route's [ModalRoute.allowSnapshotting] tells.
  final bool allowSnapshotting;

  /// What fades.
  final Widget child;

  @override
  State<SnapshotFadeTransition> createState() =>
      _SnapshotFadeTransitionState();
}

class _SnapshotFadeTransitionState extends State<SnapshotFadeTransition> {
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
  void didUpdateWidget(SnapshotFadeTransition oldWidget) {
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

  /// An image only while [child] fades and shows; settled, it paints live.
  ///
  /// The image is taken at the first frame [child] shows, not before, so
  /// it holds what [child] could show by then: while it is invisible, it
  /// is neither drawn nor frozen.
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
      // A platform view can't be drawn into an image: such a child fades
      // live, through a layer, rather than throw.
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: widget.child,
    );
  }
}

/// Paints the child, or the image of it, with the [opacity]'s alpha.
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
