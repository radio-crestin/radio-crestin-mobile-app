import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ImageCacheService {
  static ImageCacheService? _instance;
  static ImageCacheService get instance => _instance!;

  final Map<String, String> _cache = {};
  late final Directory _cacheDir;
  bool _initialized = false;

  static const int _maxConcurrentDownloads = 5;
  int _activeDownloads = 0;

  static void _log(String message) {
    developer.log("ImageCacheService: $message");
  }

  ImageCacheService._();

  factory ImageCacheService() {
    _instance ??= ImageCacheService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_initialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDir.path}/image_cache');
    if (!await _cacheDir.exists()) {
      await _cacheDir.create(recursive: true);
    }

    // Build in-memory map from existing files on disk
    await _loadExistingCache();
    _initialized = true;
    _log("Initialized with ${_cache.length} cached images");
  }

  Future<void> _loadExistingCache() async {
    try {
      await for (final entity in _cacheDir.list()) {
        if (entity is File) {
          // File name format: <md5hash>.<ext>
          // We can't reverse hash → URL, but we populate _cache in getOrDownload
          // For now, just verify files exist. The URL→path mapping is built lazily.
        }
      }
    } catch (e) {
      _log("Error loading existing cache: $e");
    }
  }

  String _hashUrl(String url) {
    return md5.convert(utf8.encode(url)).toString();
  }

  String _getExtension(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final lastDot = path.lastIndexOf('.');
      if (lastDot != -1) {
        final ext = path.substring(lastDot);
        if (ext.length <= 5 && ext.length > 1) return ext;
      }
    } catch (_) {}
    return '.img';
  }

  String _filePathForUrl(String url) {
    final hash = _hashUrl(url);
    final ext = _getExtension(url);
    return '${_cacheDir.path}/$hash$ext';
  }

  /// Sync lookup — returns local file path if cached, null otherwise.
  String? getCachedPath(String url) {
    return _cache[url];
  }

  /// Returns cached file or downloads and caches it. Returns null on failure.
  Future<File?> getOrDownload(String url) async {
    if (url.isEmpty) return null;

    // Already cached in memory
    final existing = _cache[url];
    if (existing != null) {
      final file = File(existing);
      if (await file.exists()) return file;
      // File was deleted from disk, remove from map
      _cache.remove(url);
    }

    // Check disk (file might exist from a previous session)
    final filePath = _filePathForUrl(url);
    final file = File(filePath);
    if (await file.exists()) {
      _cache[url] = filePath;
      return file;
    }

    // Download
    return _download(url, filePath);
  }

  Future<File?> _download(String url, String filePath) async {
    // Throttle concurrent downloads
    while (_activeDownloads >= _maxConcurrentDownloads) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _activeDownloads++;
    try {
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);
        _cache[url] = filePath;
        _log("Downloaded: $url");
        return file;
      }
      _log("Download failed (${response.statusCode}): $url");
      return null;
    } catch (e) {
      _log("Download error: $url - $e");
      return null;
    } finally {
      _activeDownloads--;
    }
  }

  /// Pre-cache a list of URLs in background. Only downloads URLs not already cached.
  Future<void> preCacheUrls(List<String> urls) async {
    final uncachedUrls = urls.where((url) => url.isNotEmpty && _cache[url] == null).toList();
    if (uncachedUrls.isEmpty) return;

    _log("Pre-caching ${uncachedUrls.length} images");

    // Process in batches of _maxConcurrentDownloads
    for (int i = 0; i < uncachedUrls.length; i += _maxConcurrentDownloads) {
      final batch = uncachedUrls.sublist(
        i,
        (i + _maxConcurrentDownloads).clamp(0, uncachedUrls.length),
      );
      await Future.wait(batch.map((url) => getOrDownload(url)));
    }

    _log("Pre-caching complete");
  }
}
