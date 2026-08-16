import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart';

/// Shows the first frame of a network video as an image, decoded natively and
/// cached in-memory per URL. While the frame is being produced (and if it can't
/// be produced) the [placeholder] is shown instead — so this never regresses an
/// item to a blank box, it only upgrades it when a frame is available.
///
/// Used as the thumbnail fallback for `video` playlist items that ship no
/// `thumbnail_url`. Generation is throttled globally (a few at a time) so a long
/// list doesn't spawn dozens of concurrent native decodes.
class VideoThumbnailImage extends StatefulWidget {
  const VideoThumbnailImage({
    super.key,
    required this.videoUrl,
    required this.placeholder,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.maxDecodeWidth = 128,
  });

  final String videoUrl;
  final Widget placeholder;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Native decode width cap — the frame is downscaled to roughly this many
  /// pixels wide before returning, keeping memory tiny for list thumbnails.
  final int maxDecodeWidth;

  @override
  State<VideoThumbnailImage> createState() => _VideoThumbnailImageState();
}

class _VideoThumbnailImageState extends State<VideoThumbnailImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _scheduleResolve();
  }

  @override
  void didUpdateWidget(VideoThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _bytes = null;
      _scheduleResolve();
    }
  }

  /// Defers native thumbnail generation until after the current frame is
  /// rendered. During app bootstrap (e.g. restoring a playlist station) many
  /// rows mount at once; kicking the platform-channel decodes off the first
  /// frame keeps them from racing engine warm-up.
  void _scheduleResolve() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resolve();
    });
  }

  Future<void> _resolve() async {
    final bytes = await _VideoThumbnailCache.instance
        .get(widget.videoUrl, widget.maxDecodeWidth);
    if (!mounted) return;
    if (bytes != null) setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return widget.placeholder;
    return Image.memory(
      bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => widget.placeholder,
    );
  }
}

/// Process-wide first-frame cache with per-URL de-duplication and a small
/// concurrency gate, so building many video rows generates each frame once and
/// only a few decodes run at a time.
class _VideoThumbnailCache {
  _VideoThumbnailCache._();
  static final _VideoThumbnailCache instance = _VideoThumbnailCache._();

  static const int _maxConcurrent = 3;

  /// url → bytes (success) or null (tried and failed — don't retry this session).
  final Map<String, Uint8List?> _done = {};
  final Map<String, Future<Uint8List?>> _inflight = {};

  int _running = 0;
  final _waiters = <Completer<void>>[];

  Future<Uint8List?> get(String url, int maxWidth) {
    if (_done.containsKey(url)) return Future.value(_done[url]);
    return _inflight[url] ??= _generate(url, maxWidth);
  }

  Future<Uint8List?> _generate(String url, int maxWidth) async {
    await _acquire();
    try {
      final bytes = await VideoThumbnailPlus.thumbnailData(
        video: url,
        imageFormat: ImageFormat.JPEG,
        maxWidth: maxWidth,
        timeMs: 0, // first frame
        quality: 60,
      );
      _done[url] = bytes;
      return bytes;
    } catch (_) {
      _done[url] = null; // remember the failure; fall back to the placeholder
      return null;
    } finally {
      _inflight.remove(url);
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_running < _maxConcurrent) {
      _running++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
    _running++;
  }

  void _release() {
    _running--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}
