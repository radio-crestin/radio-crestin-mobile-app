import 'dart:async';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';

import '../services/image_retry_signal.dart';

/// A network image that loads again by itself after a failure.
///
/// `ExtendedImage` stays failed until asked to load again, so an image
/// that failed while offline kept its placeholder for as long as the
/// widget lived — for the mini player, until the app was closed. This one
/// tries again on [ImageRetrySignal], keeps [failed] on screen while it
/// does, and fades the image in over it once it arrives.
class RetryingNetworkImage extends StatefulWidget {
  const RetryingNetworkImage({
    super.key,
    required this.url,
    required this.loading,
    required this.failed,
    this.cache = false,
    this.cacheWidth,
    this.cacheMaxAge,
  });

  final String url;

  /// Shown while the image loads for the first time.
  final WidgetBuilder loading;

  /// Shown once the image failed, and while it loads again.
  final WidgetBuilder failed;

  final bool cache;
  final int? cacheWidth;
  final Duration? cacheMaxAge;

  @override
  State<RetryingNetworkImage> createState() => _RetryingNetworkImageState();
}

class _RetryingNetworkImageState extends State<RetryingNetworkImage> {
  /// The failed image, kept to load it again.
  ExtendedImageState? _failedImage;
  StreamSubscription<void>? _retrySubscription;

  /// Whether the failed image is loading again: [RetryingNetworkImage.failed]
  /// stays up instead of the loading look.
  bool _retrying = false;

  /// Whether a retry brought the image, which then fades in. Kept for the
  /// life of the widget so its tree never changes shape mid-fade.
  bool _recovered = false;

  @override
  void dispose() {
    _retrySubscription?.cancel();
    super.dispose();
  }

  void _watchForRetry(ExtendedImageState image) {
    _failedImage = image;
    _retrySubscription ??= ImageRetrySignal.stream.listen((_) => _retry());
  }

  void _stopWatching() {
    _failedImage = null;
    _retrySubscription?.cancel();
    _retrySubscription = null;
  }

  void _retry() {
    final image = _failedImage;
    if (!mounted || image == null) return;
    _retrying = true;
    image.reLoadImage();
  }

  Widget? _onLoadStateChanged(ExtendedImageState state) {
    switch (state.extendedImageLoadState) {
      case LoadState.loading:
        return _retrying ? widget.failed(context) : widget.loading(context);
      case LoadState.completed:
        _stopWatching();
        if (_retrying) {
          _retrying = false;
          _recovered = true;
        }
        if (!_recovered) return null;
        return _FadeInOver(
          under: widget.failed(context),
          child: state.completedWidget,
        );
      case LoadState.failed:
        _retrying = false;
        _watchForRetry(state);
        return widget.failed(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExtendedImage.network(
      widget.url,
      fit: BoxFit.cover,
      cache: widget.cache,
      retries: 3,
      timeLimit: const Duration(seconds: 3),
      cacheWidth: widget.cacheWidth,
      cacheMaxAge: widget.cacheMaxAge,
      // The URL changes with every song (current artwork), and the same
      // element is reused, so without this each song change blanks the
      // thumbnail to grey until the new artwork downloads.
      gaplessPlayback: true,
      loadStateChanged: _onLoadStateChanged,
    );
  }
}

/// Fades [child] in over [under], then shows [child] alone.
class _FadeInOver extends StatefulWidget {
  const _FadeInOver({required this.under, required this.child});

  final Widget under;
  final Widget child;

  @override
  State<_FadeInOver> createState() => _FadeInOverState();
}

class _FadeInOverState extends State<_FadeInOver>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  )..forward();

  late final Animation<double> _opacity =
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          if (!_controller.isCompleted) widget.under,
          FadeTransition(opacity: _opacity, child: child),
        ],
      ),
    );
  }
}
