import 'dart:io';

import 'package:flutter/material.dart';

import '../services/image_cache_service.dart';

/// An announcement's picture (icon, cover, a picture in its page), kept
/// on disk by [ImageCacheService]: drawn in the first frame when it is
/// already there, faded in otherwise, with [placeholder] until it comes or
/// when it can't.
class AnnouncementImage extends StatefulWidget {
  const AnnouncementImage({
    super.key,
    required this.url,
    required this.placeholder,
    this.fit = BoxFit.cover,
    this.fillsBox = true,
  });

  final String url;
  final Widget placeholder;
  final BoxFit fit;

  /// Fills its box (a tile, a cover); otherwise it takes the width given
  /// and the height of its own proportions (a picture in a page).
  final bool fillsBox;

  @override
  State<AnnouncementImage> createState() => _AnnouncementImageState();
}

class _AnnouncementImageState extends State<AnnouncementImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AnnouncementImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _resolve();
  }

  void _resolve() {
    final cache = _cacheOrNull;
    _file = cache?.cachedFileSync(widget.url);
    if (_file != null || cache == null) return;
    final url = widget.url;
    cache.getOrDownload(url).then((file) {
      if (mounted && file != null && url == widget.url) {
        setState(() => _file = file);
      }
    });
  }

  static ImageCacheService? get _cacheOrNull {
    try {
      return ImageCacheService.instance;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: file == null
          ? KeyedSubtree(
              key: const ValueKey('placeholder'), child: widget.placeholder)
          : Image.file(
              file,
              key: ValueKey(file.path),
              fit: widget.fit,
              width: double.infinity,
              height: widget.fillsBox ? double.infinity : null,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => widget.placeholder,
            ),
    );
  }
}
