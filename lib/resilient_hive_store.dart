import 'dart:developer' as developer;
import 'dart:io';

import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:hive_ce/hive.dart' as hive;
import 'package:path_provider/path_provider.dart';

/// A [Store] wrapper that delegates to [HiveStore] but falls back to
/// [InMemoryStore] when the underlying Hive file is closed at runtime
/// (e.g. a second FlutterEngine from Android Auto / CarPlay opens the same
/// .hive file and invalidates the file handle).
class ResilientHiveStore extends Store {
  Store _delegate; // ignore: must_be_immutable
  bool _degraded = false; // ignore: must_be_immutable

  ResilientHiveStore(HiveStore hiveStore) : _delegate = hiveStore;

  /// Try to open HiveStore, clearing corrupted files if needed.
  static Future<Store> create() async {
    try {
      return ResilientHiveStore(HiveStore());
    } catch (e) {
      developer.log('HiveStore open failed, clearing corrupted data: $e');
      await _deleteHiveFiles();
      try {
        return ResilientHiveStore(HiveStore());
      } catch (e2) {
        developer.log('HiveStore still broken after cleanup, using InMemoryStore: $e2');
        return InMemoryStore();
      }
    }
  }

  static Future<void> _deleteHiveFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final hiveFiles = dir.listSync().where((f) =>
          f.path.contains('graphqlclientstore') ||
          f.path.endsWith('.hive') ||
          f.path.endsWith('.hivec') ||
          f.path.endsWith('.lock'));
      for (final file in hiveFiles) {
        try {
          await file.delete();
          developer.log('Deleted corrupted Hive file: ${file.path}');
        } catch (_) {}
      }
    } catch (e) {
      developer.log('Error cleaning Hive files: $e');
    }
  }

  void _fallbackToMemory(Object error) {
    if (!_degraded) {
      developer.log(
        'HiveStore failed at runtime, falling back to InMemoryStore: $error',
      );
      _degraded = true;
      _delegate = InMemoryStore();
    }
  }

  bool _isStorageError(Object e) =>
      e is FileSystemException ||
      e is PathNotFoundException ||
      e is AssertionError ||
      e.toString().contains('File closed') ||
      e.toString().contains('HiveError') ||
      e.toString().contains('BufferedFileReader');

  @override
  Map<String, dynamic>? get(String dataId) {
    try {
      return _delegate.get(dataId);
    } catch (e) {
      if (_isStorageError(e)) {
        _fallbackToMemory(e);
        return _delegate.get(dataId);
      }
      rethrow;
    }
  }

  @override
  void put(String dataId, Map<String, dynamic>? value) {
    try {
      _delegate.put(dataId, value);
    } catch (e) {
      if (_isStorageError(e)) {
        _fallbackToMemory(e);
        _delegate.put(dataId, value);
      } else {
        rethrow;
      }
    }
  }

  @override
  void putAll(Map<String, Map<String, dynamic>?> data) {
    try {
      _delegate.putAll(data);
    } catch (e) {
      if (_isStorageError(e)) {
        _fallbackToMemory(e);
        _delegate.putAll(data);
      } else {
        rethrow;
      }
    }
  }

  @override
  void delete(String dataId) {
    try {
      _delegate.delete(dataId);
    } catch (e) {
      if (_isStorageError(e)) {
        _fallbackToMemory(e);
        _delegate.delete(dataId);
      } else {
        rethrow;
      }
    }
  }

  @override
  void reset() {
    try {
      _delegate.reset();
    } catch (e) {
      if (_isStorageError(e)) {
        _fallbackToMemory(e);
        _delegate.reset();
      } else {
        rethrow;
      }
    }
  }

  @override
  Map<String, Map<String, dynamic>?> toMap() {
    try {
      return _delegate.toMap();
    } catch (e) {
      if (_isStorageError(e)) {
        _fallbackToMemory(e);
        return _delegate.toMap();
      }
      rethrow;
    }
  }
}
