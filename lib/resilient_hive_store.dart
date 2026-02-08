import 'dart:developer' as developer;
import 'dart:io';

import 'package:graphql_flutter/graphql_flutter.dart';

/// A [Store] wrapper that delegates to [HiveStore] but falls back to
/// [InMemoryStore] when the underlying Hive file is closed at runtime
/// (e.g. a second FlutterEngine from Android Auto / CarPlay opens the same
/// .hive file and invalidates the file handle).
class ResilientHiveStore extends Store {
  Store _delegate; // ignore: must_be_immutable
  bool _degraded = false; // ignore: must_be_immutable

  ResilientHiveStore(HiveStore hiveStore) : _delegate = hiveStore;

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
      e.toString().contains('File closed') ||
      e.toString().contains('HiveError');

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
