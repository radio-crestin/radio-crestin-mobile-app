import 'dart:typed_data';

import 'video_thumbnail_plus_platform_interface.dart';

/// Supported image formats for thumbnail generation.
enum ImageFormat {
  JPEG,
  PNG,
  WEBP,
}

/// A Flutter plugin for generating video thumbnails.
///
/// This plugin provides methods to generate thumbnail images from video files
/// or URLs, supporting both file output and in-memory byte data.
class VideoThumbnailPlus {
  /// Generates a thumbnail image file from a video.
  ///
  /// [video] - The path to a local video file or a URL to a remote video.
  /// [headers] - Optional HTTP headers for remote video URLs.
  /// [thumbnailPath] - The directory path where the thumbnail will be saved.
  ///   If null, a default cache directory will be used.
  /// [imageFormat] - The output image format. Defaults to [ImageFormat.PNG].
  /// [maxHeight] - Maximum height of the thumbnail. 0 means original height.
  /// [maxWidth] - Maximum width of the thumbnail. 0 means original width.
  /// [timeMs] - The time position in milliseconds to capture the thumbnail.
  /// [quality] - The quality of the output image (0-100). Only applies to JPEG and WEBP.
  ///
  /// Returns the file path of the generated thumbnail, or null if generation failed.
  static Future<String?> thumbnailFile({
    required String video,
    Map<String, String>? headers,
    String? thumbnailPath,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 100,
  }) {
    return VideoThumbnailPlusPlatform.instance.thumbnailFile(
      video: video,
      headers: headers,
      thumbnailPath: thumbnailPath,
      imageFormat: imageFormat,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );
  }

  /// Generates a thumbnail image as byte data from a video.
  ///
  /// [video] - The path to a local video file or a URL to a remote video.
  /// [headers] - Optional HTTP headers for remote video URLs.
  /// [imageFormat] - The output image format. Defaults to [ImageFormat.PNG].
  /// [maxHeight] - Maximum height of the thumbnail. 0 means original height.
  /// [maxWidth] - Maximum width of the thumbnail. 0 means original width.
  /// [timeMs] - The time position in milliseconds to capture the thumbnail.
  /// [quality] - The quality of the output image (0-100). Only applies to JPEG and WEBP.
  ///
  /// Returns the thumbnail image as a [Uint8List], or null if generation failed.
  /// The returned data can be used with [Image.memory()].
  static Future<Uint8List?> thumbnailData({
    required String video,
    Map<String, String>? headers,
    ImageFormat imageFormat = ImageFormat.PNG,
    int maxHeight = 0,
    int maxWidth = 0,
    int timeMs = 0,
    int quality = 100,
  }) {
    return VideoThumbnailPlusPlatform.instance.thumbnailData(
      video: video,
      headers: headers,
      imageFormat: imageFormat,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );
  }
}
