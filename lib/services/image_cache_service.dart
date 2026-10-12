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
  final Map<String, Future<File?>> _inFlight = {};
  late final Directory _cacheDir;
  bool _initialized = false;

  static const int _maxConcurrentDownloads = 5;
  int _activeDownloads = 0;

  /// One client for every download, so the ~64 logos from the same CDN
  /// reuse connections instead of each paying a TCP + TLS handshake.
  /// Created with the singleton rather than lazily, so a test's
  /// `http.runWithClient` zone cannot leak into it later.
  final http.Client _client;

  static void _log(String message) {
    developer.log("ImageCacheService: $message");
  }

  ImageCacheService._() : _client = http.Client();

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

    _initialized = true;
    _log("Initialized");
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
    if (url.isEmpty || !_initialized) return null;

    // Already cached in memory
    final existing = _cache[url];
    if (existing != null) {
      final file = File(existing);
      if (await file.exists()) return file;
      // File was deleted from disk, remove from map
      _cache.remove(url);
    }

    // Check disk (file might exist from a previous session). A 0-byte file
    // is a write that older builds left behind when killed mid-download:
    // treat it as a miss so it heals instead of being served forever.
    final filePath = _filePathForUrl(url);
    final file = File(filePath);
    if (await file.exists() && await file.length() > 0) {
      _cache[url] = filePath;
      return file;
    }

    // Deduplicate in-flight downloads
    if (_inFlight.containsKey(url)) return _inFlight[url]!;

    // Download
    final future = _download(url, filePath);
    _inFlight[url] = future;
    future.whenComplete(() => _inFlight.remove(url));
    return future;
  }

  Future<File?> _download(String url, String filePath) async {
    // Throttle concurrent downloads
    while (_activeDownloads >= _maxConcurrentDownloads) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _activeDownloads++;
    // Written under a temp name and renamed into place, so a process kill
    // mid-write never leaves a truncated file at the final path.
    final tmp = File('$filePath.part');
    try {
      final response = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 &&
          response.bodyBytes.isNotEmpty &&
          _isImageResponse(response)) {
        await tmp.writeAsBytes(response.bodyBytes, flush: true);
        final file = await tmp.rename(filePath);
        _cache[url] = filePath;
        _log("Downloaded: $url");
        return file;
      }
      _log("Download failed (${response.statusCode}, "
          "${response.headers['content-type']}): $url");
      return null;
    } catch (e) {
      _log("Download error: $url - $e");
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    } finally {
      _activeDownloads--;
    }
  }

  /// Rejects 200 responses that are not images (a proxy or CDN error page),
  /// which would otherwise be cached and served forever. A missing header
  /// is accepted.
  static bool _isImageResponse(http.Response response) =>
      (response.headers['content-type'] ?? 'image/')
          .toLowerCase()
          .startsWith('image/');

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
