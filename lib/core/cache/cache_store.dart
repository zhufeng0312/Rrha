import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../utils/logger.dart';

/// 一条被缓存下来的原始响应。
///
/// **缓存的是「原始响应文本」，不是解析后的模型**：解析规则升级后旧缓存仍然
/// 可用（重新解析一遍即可），而存模型的话每次加字段都得把缓存清空。
///
/// 历史上这段文本是 RSSHub 的 XML；RSSHub 移除后（2026-10-22）现在是 B 站与
/// 微博官方接口的 JSON 原文。目录名保持 `rss_cache` 不变 —— 改了会让老用户
/// 已有的缓存变成孤儿目录，白占磁盘。
class CachedBody {
  const CachedBody({
    required this.url,
    required this.body,
    required this.fetchedAt,
    this.statusCode = 200,
    this.fromDisk = false,
  });

  final String url;
  final String body;
  final DateTime fetchedAt;
  final int statusCode;
  final bool fromDisk;

  Duration get age => DateTime.now().difference(fetchedAt);

  bool isFresh(Duration ttl) => age < ttl;

  /// 人类可读的新鲜度描述，用于「数据可能过期」角标。
  String get ageLabel {
    final a = age;
    if (a.inMinutes < 1) return '刚刚';
    if (a.inMinutes < 60) return '${a.inMinutes} 分钟前';
    if (a.inHours < 24) return '${a.inHours} 小时前';
    return '${a.inDays} 天前';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'body': body,
        'fetchedAt': fetchedAt.toIso8601String(),
        'statusCode': statusCode,
      };

  static CachedBody? fromJson(Map<String, dynamic> json) {
    final body = json['body'];
    final url = json['url'];
    final fetchedAt = json['fetchedAt'];
    if (body is! String || url is! String || fetchedAt is! String) return null;
    final dt = DateTime.tryParse(fetchedAt);
    if (dt == null) return null;
    return CachedBody(
      url: url,
      body: body,
      fetchedAt: dt,
      statusCode: (json['statusCode'] as num?)?.toInt() ?? 200,
      fromDisk: true,
    );
  }
}

/// 缓存目录统计，供设置页展示。
class CacheStats {
  const CacheStats({required this.entries, required this.bytes});

  final int entries;
  final int bytes;

  static const CacheStats empty = CacheStats(entries: 0, bytes: 0);

  String get humanSize {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

/// 文件 + 内存双层缓存，TTL 默认 5 分钟（[AppConfig.timelineCacheTtl]）。
///
/// 刻意不使用 dio 缓存拦截器：显式读写更容易单测，也便于在
/// 「网络失败但缓存可用」时做 stale-while-error 降级。
class CacheStore {
  CacheStore({Duration? ttl}) : ttl = ttl ?? AppConfig.timelineCacheTtl;

  final Duration ttl;

  Directory? _dir;
  final Map<String, CachedBody> _memory = <String, CachedBody>{};

  /// 缓存键：URL 的 sha1。
  static String keyFor(String url) => sha1.convert(utf8.encode(url)).toString();

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}rss_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  Future<void> ensureReady() async {
    try {
      await _ensureDir();
    } catch (e, st) {
      // 缓存不可用不应导致 App 无法工作。
      Log.e('CacheStore', '初始化缓存目录失败，将退化为纯内存缓存', e, st);
    }
  }

  /// 读取缓存。
  ///
  /// [ignoreTtl] 为 true 时忽略新鲜度（用于降级路径：哪怕过期也想拿旧的顶上）。
  Future<CachedBody?> read(String url, {bool ignoreTtl = false}) async {
    final key = keyFor(url);

    final mem = _memory[key];
    if (mem != null) {
      if (ignoreTtl || mem.isFresh(ttl)) return mem;
      // 内存里的是过期的，继续尝试磁盘（磁盘可能更新，虽然少见）。
    }

    try {
      final dir = await _ensureDir();
      final file = File('${dir.path}${Platform.pathSeparator}$key.json');
      if (!await file.exists()) return mem != null && ignoreTtl ? mem : null;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final cached = CachedBody.fromJson(decoded);
      if (cached == null) return null;
      _memory[key] = cached;
      if (ignoreTtl || cached.isFresh(ttl)) return cached;
      return cached; // 由调用方通过 isFresh 判断是否需要重新请求。
    } catch (e) {
      Log.w('CacheStore', '读取缓存失败 key=$key: $e');
      return null;
    }
  }

  /// 只读取「新鲜」的缓存，命中即代表无需发请求。
  Future<CachedBody?> readFresh(String url) async {
    final c = await read(url);
    if (c == null) return null;
    return c.isFresh(ttl) ? c : null;
  }

  Future<void> write(String url, String body, {int statusCode = 200}) async {
    final key = keyFor(url);
    final entry = CachedBody(
      url: url,
      body: body,
      fetchedAt: DateTime.now(),
      statusCode: statusCode,
    );
    _memory[key] = entry;
    try {
      final dir = await _ensureDir();
      final file = File('${dir.path}${Platform.pathSeparator}$key.json');
      await file.writeAsString(jsonEncode(entry.toJson()), flush: true);
    } catch (e) {
      Log.w('CacheStore', '写入缓存失败 key=$key: $e');
    }
  }

  Future<void> remove(String url) async {
    final key = keyFor(url);
    _memory.remove(key);
    try {
      final dir = await _ensureDir();
      final file = File('${dir.path}${Platform.pathSeparator}$key.json');
      if (await file.exists()) await file.delete();
    } catch (e) {
      Log.w('CacheStore', '删除缓存失败 key=$key: $e');
    }
  }

  /// 清空全部缓存（设置页「清除缓存」）。
  Future<void> clear() async {
    _memory.clear();
    try {
      final dir = await _ensureDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _dir = null;
      await _ensureDir();
    } catch (e, st) {
      Log.e('CacheStore', '清空缓存失败', e, st);
      rethrow;
    }
  }

  Future<CacheStats> stats() async {
    try {
      final dir = await _ensureDir();
      if (!await dir.exists()) return CacheStats.empty;
      var count = 0;
      var bytes = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          count++;
          bytes += await entity.length();
        }
      }
      return CacheStats(entries: count, bytes: bytes);
    } catch (e) {
      Log.w('CacheStore', '统计缓存失败: $e');
      return CacheStats.empty;
    }
  }
}
