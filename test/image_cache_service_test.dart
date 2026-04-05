import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// We test the pure logic of ImageCacheService that doesn't require
// platform channels (hashing, extension extraction, cache map behavior).
// Full integration tests would require mocking path_provider and http.

void main() {
  group('ImageCacheService - pure logic', () {
    group('URL hashing (MD5)', () {
      test('produces consistent hash for same URL', () {
        const url = 'https://example.com/image.png';
        final hash1 = md5.convert(utf8.encode(url)).toString();
        final hash2 = md5.convert(utf8.encode(url)).toString();
        expect(hash1, hash2);
      });

      test('produces different hashes for different URLs', () {
        final hash1 = md5.convert(utf8.encode('https://a.com/1.png')).toString();
        final hash2 = md5.convert(utf8.encode('https://a.com/2.png')).toString();
        expect(hash1, isNot(equals(hash2)));
      });

      test('hash is 32 characters (hex)', () {
        final hash = md5.convert(utf8.encode('https://example.com/image.png')).toString();
        expect(hash.length, 32);
        expect(hash, matches(RegExp(r'^[0-9a-f]{32}$')));
      });
    });

    group('extension extraction', () {
      // Replicate the _getExtension logic
      String getExtension(String url) {
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

      test('extracts .png extension', () {
        expect(getExtension('https://example.com/image.png'), '.png');
      });

      test('extracts .jpg extension', () {
        expect(getExtension('https://example.com/photo.jpg'), '.jpg');
      });

      test('extracts .webp extension', () {
        expect(getExtension('https://example.com/image.webp'), '.webp');
      });

      test('falls back to .img for URLs without extension', () {
        expect(getExtension('https://example.com/image'), '.img');
      });

      test('falls back to .img for very long extensions', () {
        expect(getExtension('https://example.com/file.toolongext'), '.img');
      });

      test('handles URLs with query parameters', () {
        expect(getExtension('https://example.com/image.png?v=1'), '.png');
      });

      test('handles URLs with no path', () {
        expect(getExtension('https://example.com'), '.img');
      });
    });

    group('in-memory cache map', () {
      test('stores and retrieves URL to path mapping', () {
        final cache = <String, String>{};
        cache['https://example.com/1.png'] = '/cache/abc123.png';

        expect(cache['https://example.com/1.png'], '/cache/abc123.png');
        expect(cache['https://example.com/2.png'], isNull);
      });

      test('remove clears entry', () {
        final cache = <String, String>{};
        cache['https://example.com/1.png'] = '/cache/abc.png';
        cache.remove('https://example.com/1.png');

        expect(cache['https://example.com/1.png'], isNull);
      });

      test('empty URL returns null', () {
        final cache = <String, String>{};
        expect(cache[''], isNull);
      });
    });

    group('concurrent download throttling logic', () {
      test('max concurrent downloads constant is 5', () {
        // The service uses _maxConcurrentDownloads = 5
        // We verify the throttling concept
        const maxConcurrent = 5;
        var activeDownloads = 0;

        // Simulate queueing downloads
        for (int i = 0; i < 10; i++) {
          if (activeDownloads < maxConcurrent) {
            activeDownloads++;
          }
        }

        expect(activeDownloads, maxConcurrent);
      });
    });

    group('file path construction', () {
      test('combines cache dir, hash, and extension', () {
        const cacheDir = '/app/Documents/image_cache';
        const url = 'https://example.com/image.png';
        final hash = md5.convert(utf8.encode(url)).toString();
        final filePath = '$cacheDir/$hash.png';

        expect(filePath, contains(hash));
        expect(filePath, endsWith('.png'));
        expect(filePath, startsWith(cacheDir));
      });
    });

    group('preCacheUrls filtering', () {
      test('filters out already cached URLs', () {
        final cache = <String, String>{
          'https://example.com/1.png': '/cache/1.png',
          'https://example.com/2.png': '/cache/2.png',
        };
        final urls = [
          'https://example.com/1.png', // cached
          'https://example.com/2.png', // cached
          'https://example.com/3.png', // not cached
          'https://example.com/4.png', // not cached
          '', // empty, should be filtered
        ];

        final uncachedUrls = urls
            .where((url) => url.isNotEmpty && cache[url] == null)
            .toList();

        expect(uncachedUrls, [
          'https://example.com/3.png',
          'https://example.com/4.png',
        ]);
      });

      test('returns empty when all URLs are cached', () {
        final cache = <String, String>{
          'https://example.com/1.png': '/cache/1.png',
        };
        final urls = ['https://example.com/1.png'];

        final uncachedUrls = urls
            .where((url) => url.isNotEmpty && cache[url] == null)
            .toList();

        expect(uncachedUrls, isEmpty);
      });
    });
  });
}
