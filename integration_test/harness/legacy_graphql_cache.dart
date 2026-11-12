import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:radio_crestin/services/legacy_graphql_cache.dart';

/// The GraphQL cache file versions up to 1.6.1 left on a listener's phone:
/// a Hive box holding every song and artist the station list ever carried.
///
/// Written byte for byte as Hive writes it (frames of a string key, a map
/// value and a CRC32), so the old app would open and parse it.
abstract final class LegacyGraphqlCacheFile {
  static Future<File> get file async => File(
      '${(await getApplicationDocumentsDirectory()).path}/'
      '${LegacyGraphqlCache.fileNames.first}');

  /// Writes a cache that holds [songs] songs, and an artist for every two.
  /// 150 000 songs make ~40 MB, what months of daily listening left.
  static Future<File> plant({required int songs}) async {
    final bytes = BytesBuilder(copy: false);
    for (var id = 0; id < songs; id++) {
      bytes.add(_frame('SongType:$id', {
        '__typename': 'SongType',
        'id': '$id',
        'name': 'Cântarea numărul $id din lista de redare',
        'thumbnail_url': 'https://cdn.radiocrestin.ro/songs/$id.jpg',
        'artist': {r'$ref': 'ArtistType:${id ~/ 2}'},
      }));
      if (id.isEven) {
        bytes.add(_frame('ArtistType:${id ~/ 2}', {
          '__typename': 'ArtistType',
          'id': '${id ~/ 2}',
          'name': 'Grupul de laudă ${id ~/ 2}',
          'thumbnail_url': null,
        }));
      }
    }
    final target = await file;
    await target.writeAsBytes(bytes.takeBytes(), flush: true);
    return target;
  }

  static Uint8List _frame(String key, Map<String, Object?> value) {
    final body = BytesBuilder()
      ..add([0, 0, 0, 0]) // the frame's length, set below
      ..addByte(_utf8StringKey)
      ..addByte(utf8.encode(key).length)
      ..add(utf8.encode(key));
    _writeValue(body, value);
    final bytes = Uint8List(body.length + 4)..setAll(0, body.takeBytes());
    final view = ByteData.view(bytes.buffer)
      ..setUint32(0, bytes.length, Endian.little);
    view.setUint32(
        bytes.length - 4, _crc32(bytes, bytes.length - 4), Endian.little);
    return bytes;
  }

  // Hive's type ids (hive_ce's FrameKeyType and FrameValueType).
  static const _utf8StringKey = 1;
  static const _nullValue = 0;
  static const _stringValue = 4;
  static const _mapValue = 11;

  static void _writeValue(BytesBuilder out, Object? value) {
    switch (value) {
      case null:
        out.addByte(_nullValue);
      case String text:
        final encoded = utf8.encode(text);
        out
          ..addByte(_stringValue)
          ..add(_uint32(encoded.length))
          ..add(encoded);
      case Map<String, Object?> map:
        out
          ..addByte(_mapValue)
          ..add(_uint32(map.length));
        for (final MapEntry(:key, :value) in map.entries) {
          _writeValue(out, key);
          _writeValue(out, value);
        }
      default:
        throw ArgumentError.value(value, 'value', 'not written by this cache');
    }
  }

  static Uint8List _uint32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

  static final _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crc32(Uint8List bytes, int length) {
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < length; i++) {
      crc = _crcTable[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }
}
