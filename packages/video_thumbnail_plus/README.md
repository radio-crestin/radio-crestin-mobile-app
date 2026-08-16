# video_thumbnail_plus

A Flutter plugin for generating thumbnail images from video files or URLs. Supports Android and iOS, returns images in memory or saves them as files with customizable format, resolution, and quality.

Based on [video_thumbnail](https://github.com/justsoft/video_thumbnail.git) with bug fixes and improvements.

[![license](https://img.shields.io/github/license/mashape/apistatus.svg)]()

![video-file](video_file.png) ![video-url](video_url.png)

## Platform Requirements

| Platform | Minimum Version |
|----------|-----------------|
| Android  | API 24 (Android 7.0) |
| iOS      | 13.0 |

## Features

- Generate thumbnails from local video files
- Generate thumbnails from video URLs (http/https)
- Support `content://` URIs on Android (gallery/file picker)
- Custom HTTP headers for authenticated video URLs
- Configurable output format (JPEG, PNG, WebP)
- Configurable resolution and quality
- Extract frame at specific timestamp

## Methods

| Method | Description | Return |
|--------|-------------|--------|
| `thumbnailData` | Generate thumbnail as bytes in memory | `Future<Uint8List?>` |
| `thumbnailFile` | Generate thumbnail and save to file | `Future<String?>` |

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `video` | `String` | **Required.** Video file path, URL, or content:// URI |
| `headers` | `Map<String, String>?` | HTTP headers for network videos |
| `thumbnailPath` | `String?` | Output directory (file method only) |
| `imageFormat` | `ImageFormat` | JPEG, PNG, or WEBP (default: PNG) |
| `maxHeight` | `int` | Max height in pixels (0 = original) |
| `maxWidth` | `int` | Max width in pixels (0 = original) |
| `timeMs` | `int` | Frame timestamp in milliseconds (default: 0) |
| `quality` | `int` | Compression quality 0-100 (default: 100) |

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  video_thumbnail_plus: ^0.0.2
```

## Usage

```dart
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart';
```

### Generate thumbnail in memory

```dart
final uint8list = await VideoThumbnailPlus.thumbnailData(
  video: videoFile.path,
  imageFormat: ImageFormat.JPEG,
  maxWidth: 128,
  quality: 75,
);
```

### Generate thumbnail file from URL

```dart
final filePath = await VideoThumbnailPlus.thumbnailFile(
  video: "https://example.com/video.mp4",
  thumbnailPath: (await getTemporaryDirectory()).path,
  imageFormat: ImageFormat.PNG,
  maxHeight: 64,
  quality: 100,
);
```

### Generate thumbnail from gallery video (Android)

```dart
// Using file_picker or image_picker
final result = await FilePicker.platform.pickFiles(type: FileType.video);
if (result != null) {
  final uint8list = await VideoThumbnailPlus.thumbnailData(
    video: result.files.single.path!, // Also supports content:// URIs
    imageFormat: ImageFormat.JPEG,
    maxWidth: 256,
    quality: 80,
  );
}
```

### Generate thumbnail with custom headers

```dart
final uint8list = await VideoThumbnailPlus.thumbnailData(
  video: "https://example.com/protected-video.mp4",
  headers: {
    "Authorization": "Bearer your-token",
  },
  imageFormat: ImageFormat.JPEG,
  maxWidth: 128,
  quality: 75,
);
```

## Platform Notes

### Android
- Supports `content://` URIs from gallery/file picker
- WebP format is natively supported

### iOS
- WebP encoding is not supported; falls back to PNG format
- Videos from Photo Library require appropriate permissions

### Scaling Behavior
- When both `maxWidth` and `maxHeight` are specified, the image is scaled to fit within bounds while maintaining aspect ratio
- When only one dimension is specified, the other is scaled proportionally

## Notes

Fork or pull requests are always welcome.
