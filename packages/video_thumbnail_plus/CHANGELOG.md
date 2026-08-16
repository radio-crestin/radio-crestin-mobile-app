## 0.0.1

* fork form [video_thumbnail](https://github.com/justsoft/video_thumbnail.git)
* rewrite native ios code with swift
* rewrite native android code with kotlin
* update dependencies and configurations to adapt to the latest version of flutter

## [0.0.2] - 2025-01-19

### Fixed

#### Critical
- **[Android]** Added `content://` URI support - videos from gallery/file picker now work correctly
- **[Android/iOS]** Thumbnail generation failures now return proper errors instead of `success(null)`

#### Medium
- **[Android]** Fixed integer overflow when `timeMs` exceeds ~35 minutes (2,147,483ms)
- **[Android/iOS]** Added input validation: `timeMs` clamped to ≥0, `quality` clamped to 0-100
- **[Android]** Fixed potential crash when `scaleBitmap` produces zero-width/height dimensions
- **[Android]** `compress()` return value is now checked - failures are properly reported
- **[Android]** `mkdirs()` return value is now checked - directory creation failures are reported
- **[Android]** Thread pool limited to 4 concurrent threads (was unbounded)

#### Low
- **[Android]** `Bitmap.recycle()` now guaranteed to be called even when exceptions occur
- **[iOS]** Fixed potential crash from force-unwrapping cache directory
- **[iOS]** Replaced deprecated `CC_MD5` with `CryptoKit.Insecure.MD5`
- **[iOS]** WebP format fallback now correctly uses `.png` extension instead of `.webp`

### Changed
- **[Android]** `MediaMetadataRetriever` now uses `close()` on Android 10+ instead of deprecated `release()`
- **[Android]** Replaced `newCachedThreadPool()` with bounded `ThreadPoolExecutor(0, 4, ...)`

