import 'package:flutter/foundation.dart';

/// 轻量日志。
///
/// 除了 dev 期输出，还把最近若干条记录留在内存环形缓冲里，
/// 供设置页「数据源状态」展示——因为在没有网络的真机上排查问题，
/// 只能靠 App 自己把诊断信息留在屏幕上。
class Log {
  Log._();

  static const int _capacity = 200;
  static final List<String> _recent = <String>[];

  /// 最近日志（旧 -> 新）。
  static List<String> get recent => List.unmodifiable(_recent);

  static void clear() => _recent.clear();

  static void _record(String level, String tag, Object? message) {
    final line = '${DateTime.now().toIso8601String()} [$level][$tag] $message';
    _recent.add(line);
    if (_recent.length > _capacity) {
      _recent.removeRange(0, _recent.length - _capacity);
    }
  }

  static void d(String tag, Object? message) {
    _record('D', tag, message);
    if (kDebugMode) debugPrint('[D][$tag] $message');
  }

  static void w(String tag, Object? message) {
    _record('W', tag, message);
    if (kDebugMode) debugPrint('[W][$tag] $message');
  }

  static void e(String tag, Object? message, [Object? error, StackTrace? st]) {
    _record('E', tag, error == null ? message : '$message | $error');
    if (kDebugMode) {
      debugPrint('[E][$tag] $message');
      if (error != null) debugPrint('    $error');
      if (st != null) debugPrint('$st');
    }
  }
}
