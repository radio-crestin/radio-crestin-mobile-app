import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Lightweight performance monitor for profiling app startup, frame rendering,
/// and key operations. Logs via dart:developer so output appears in DevTools
/// timeline and `flutter logs`.
///
/// All monitoring is **debug/profile-mode only** — production builds compile
/// the guards to no-ops so there is zero runtime cost in release.
class PerformanceMonitor {
  PerformanceMonitor._();

  static final Map<String, List<DateTime>> _operationStarts = {};
  static final Map<String, List<int>> _operationHistory = {};
  static DateTime? _appStartTime;
  static bool _frameCallbackRegistered = false;
  static int _jankyFrames = 0;
  static int _totalFrames = 0;

  // ───────────────────────── App startup ─────────────────────────

  /// Call at the very beginning of `main()`.
  static void markAppStart() {
    if (kReleaseMode) return;
    _appStartTime = DateTime.now();
    _log('[STARTUP] App start marked');
  }

  /// Call right after `runApp()` to record total cold-start time.
  static void markAppReady() {
    if (kReleaseMode) return;
    if (_appStartTime == null) return;
    final elapsed = DateTime.now().difference(_appStartTime!).inMilliseconds;
    _log('[STARTUP] App ready in ${elapsed}ms');
    _recordOperation('app_startup', elapsed);
  }

  // ───────────────────── Operation timing ────────────────────────

  /// Begin timing an operation identified by [name].
  /// Supports concurrent operations with the same name (e.g. polling REST calls).
  static void startOperation(String name) {
    if (kReleaseMode) return;
    _operationStarts.putIfAbsent(name, () => []).add(DateTime.now());
  }

  /// End timing for [name] and log the duration.
  /// Returns the elapsed milliseconds (or -1 in release mode / if not started).
  static int endOperation(String name) {
    if (kReleaseMode) return -1;
    final starts = _operationStarts[name];
    if (starts == null || starts.isEmpty) {
      _log('[PERF] endOperation("$name") called without matching startOperation');
      return -1;
    }
    final start = starts.removeAt(0);
    if (starts.isEmpty) _operationStarts.remove(name);
    final elapsed = DateTime.now().difference(start).inMilliseconds;
    _log('[PERF] $name completed in ${elapsed}ms');
    _recordOperation(name, elapsed);
    return elapsed;
  }

  /// Wrap an async function with automatic start/end timing.
  static Future<T> trackAsync<T>(String name, Future<T> Function() fn) async {
    if (kReleaseMode) return fn();
    startOperation(name);
    try {
      return await fn();
    } finally {
      endOperation(name);
    }
  }

  // ───────────────────── Frame monitoring ────────────────────────

  /// Start monitoring frame rendering. Call once after first frame.
  static void startFrameMonitoring() {
    if (kReleaseMode) return;
    if (_frameCallbackRegistered) return;
    _frameCallbackRegistered = true;

    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _log('[FRAMES] Frame monitoring started');
  }

  /// Stop monitoring frame rendering.
  static void stopFrameMonitoring() {
    if (kReleaseMode) return;
    if (!_frameCallbackRegistered) return;
    _frameCallbackRegistered = false;
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _log('[FRAMES] Frame monitoring stopped');
  }

  static void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _totalFrames++;
      final buildMs = timing.buildDuration.inMilliseconds;
      final rasterMs = timing.rasterDuration.inMilliseconds;
      final totalMs = timing.totalSpan.inMilliseconds;

      // A frame is "janky" if it takes longer than 16ms (60fps budget)
      if (totalMs > 16) {
        _jankyFrames++;
        if (totalMs > 32) {
          // Only log significantly slow frames to avoid noise
          _log('[FRAMES] Slow frame: total=${totalMs}ms build=${buildMs}ms raster=${rasterMs}ms');
        }
      }
    }
  }

  // ───────────────────── Widget rebuild tracking ─────────────────

  /// Wrap a widget build method to log when it rebuilds.
  /// Use sparingly — only for widgets you suspect are rebuilding too often.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// Widget build(BuildContext context) {
  ///   PerformanceMonitor.trackBuild('MyWidget');
  ///   return ...;
  /// }
  /// ```
  static void trackBuild(String widgetName) {
    if (kReleaseMode) return;
    _log('[REBUILD] $widgetName');
  }

  // ─────────────────────── Reporting ─────────────────────────────

  /// Print a summary of all tracked metrics. Call this e.g. 10 seconds
  /// after app start to get a snapshot, or on-demand from a debug menu.
  static void printReport() {
    if (kReleaseMode) return;

    final buffer = StringBuffer();
    buffer.writeln('');
    buffer.writeln('========== PERFORMANCE REPORT ==========');

    // Startup
    if (_operationHistory.containsKey('app_startup')) {
      buffer.writeln('Startup: ${_operationHistory['app_startup']!.last}ms');
    }

    // Frames
    if (_totalFrames > 0) {
      final jankyPct = (_jankyFrames / _totalFrames * 100).toStringAsFixed(1);
      buffer.writeln('Frames: $_totalFrames total, $_jankyFrames janky ($jankyPct%)');
    }

    // Operations
    buffer.writeln('--- Operations ---');
    for (final entry in _operationHistory.entries) {
      if (entry.key == 'app_startup') continue;
      final values = entry.value;
      final avg = values.reduce((a, b) => a + b) / values.length;
      final max = values.reduce((a, b) => a > b ? a : b);
      final min = values.reduce((a, b) => a < b ? a : b);
      buffer.writeln(
          '  ${entry.key}: avg=${avg.toStringAsFixed(0)}ms min=${min}ms max=${max}ms (${values.length} calls)');
    }

    buffer.writeln('========================================');
    _log(buffer.toString());
  }

  /// Reset all collected data.
  static void reset() {
    _operationStarts.clear();
    _operationHistory.clear();
    _jankyFrames = 0;
    _totalFrames = 0;
  }

  // ─────────────────────── Internals ─────────────────────────────

  static void _recordOperation(String name, int elapsedMs) {
    _operationHistory.putIfAbsent(name, () => []).add(elapsedMs);
  }

  static void _log(String message) {
    // Use debugPrint so output appears in logcat/console in profile mode
    // (developer.log only shows in DevTools Observatory)
    debugPrint('PerfMon: $message');
  }
}
