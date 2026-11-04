import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A [DecoratedBox] that shades its [decoration] once per size into an image
/// and draws that image on every frame after.
///
/// The player's backdrop gradient took a slow phone's GPU about 7 ms a frame
/// (moto g7 plus), whatever its stops or shape, and every frame of a sheet
/// sliding over the player, a song change or the panel opening redraws it:
/// a sheet lost a quarter of its frames. The image holds the same pixels
/// (one screen's worth, about 8 MB at 1080p) and costs next to nothing to
/// draw.
///
/// The image is shaded only while the app is in the foreground. iOS takes
/// the GPU away from an app in the background, and Impeller then silently
/// skips rendering a `toImageSync` image: drawn later, it showed whatever
/// its texture held, a flat magenta, until something made it shade again.
/// In the background the decoration is painted directly, and the image is
/// shaded afresh when the app comes back.
class BakedDecoration extends SingleChildRenderObjectWidget {
  /// Creates a box that draws [decoration] behind [child] from an image.
  const BakedDecoration({super.key, required this.decoration, super.child});

  /// What the box draws.
  final Decoration decoration;

  @override
  RenderBakedDecoration createRenderObject(BuildContext context) =>
      RenderBakedDecoration(
        decoration: decoration,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );

  @override
  void updateRenderObject(
      BuildContext context, RenderBakedDecoration renderObject) {
    renderObject
      ..decoration = decoration
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

/// The render object of [BakedDecoration].
class RenderBakedDecoration extends RenderProxyBox
    with WidgetsBindingObserver {
  /// Creates the render object for [decoration] at [devicePixelRatio].
  RenderBakedDecoration({
    required Decoration decoration,
    required double devicePixelRatio,
  })  : _decoration = decoration,
        _devicePixelRatio = devicePixelRatio;

  Decoration _decoration;
  set decoration(Decoration value) {
    if (value == _decoration) return;
    _decoration = value;
    _dropImage();
    markNeedsPaint();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _dropImage();
    markNeedsPaint();
  }

  ui.Image? _image;

  /// The size [_image] was shaded for.
  Size? _imageSize;

  /// Whether a shaded image is kept for the next frames.
  @visibleForTesting
  bool get hasBakedImage => _image != null;

  /// Whether an image can be shaded in [state]: only in the foreground,
  /// the one state in which the app is sure to have the GPU.
  static bool canBakeIn(AppLifecycleState? state) =>
      state == AppLifecycleState.resumed;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void detach() {
    WidgetsBinding.instance.removeObserver(this);
    super.detach();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // An image shaded just as the app went to the background may have been
    // skipped by the GPU: shade it again.
    _dropImage();
    markNeedsPaint();
  }

  void _dropImage() {
    _image?.dispose();
    _image = null;
  }

  ui.Image _imageFor(Size size) {
    final cached = _image;
    if (cached != null && _imageSize == size) return cached;
    _dropImage();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(_devicePixelRatio);
    _paintDecoration(canvas, Offset.zero, size);
    final picture = recorder.endRecording();
    // Rendered on the GPU, never read back.
    final image = picture.toImageSync(
      (size.width * _devicePixelRatio).ceil(),
      (size.height * _devicePixelRatio).ceil(),
    );
    picture.dispose();
    _imageSize = size;
    return _image = image;
  }

  void _paintDecoration(Canvas canvas, Offset offset, Size size) {
    final painter = _decoration.createBoxPainter();
    painter.paint(canvas, offset, ImageConfiguration(size: size));
    painter.dispose();
  }

  // Taps on the bare backdrop land on the panel, as on a DecoratedBox,
  // instead of falling through to what is under it.
  @override
  bool hitTestSelf(Offset position) => _decoration.hitTest(size, position);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!size.isEmpty) {
      if (canBakeIn(SchedulerBinding.instance.lifecycleState)) {
        _drawImage(context.canvas, offset);
      } else {
        _paintDecoration(context.canvas, offset, size);
      }
    }
    super.paint(context, offset);
  }

  void _drawImage(Canvas canvas, Offset offset) {
    final image = _imageFor(size);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      offset &
          Size(image.width / _devicePixelRatio,
              image.height / _devicePixelRatio),
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  void dispose() {
    _dropImage();
    super.dispose();
  }
}
