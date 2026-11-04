import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../utils/logger.dart';

/// 图片缓存的占用统计（设置页展示）。
class ImageCacheStats {
  const ImageCacheStats({required this.entries, required this.bytes});

  final int entries;
  final int bytes;

  static const ImageCacheStats empty = ImageCacheStats(entries: 0, bytes: 0);

  String get humanSize {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

/// 索引里的一条记录。
class _Entry {
  _Entry({
    required this.url,
    required this.file,
    required this.at,
    required this.bytes,
    required this.lastAccess,
  });

  final String url;

  /// 文件名（不含目录）。
  final String file;

  /// 落盘时间。
  final DateTime at;

  final int bytes;

  /// 最近一次命中时间（LRU 依据）。
  DateTime lastAccess;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'file': file,
        'at': at.toIso8601String(),
        'bytes': bytes,
        'lastAccess': lastAccess.toIso8601String(),
      };

  static _Entry? fromJson(String url, Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final file = m['file'];
    if (file is! String || file.isEmpty) return null;
    final at = DateTime.tryParse('${m['at']}') ?? DateTime.now();
    final lastAccess = DateTime.tryParse('${m['lastAccess']}') ?? at;
    final bytes = (m['bytes'] as num?)?.toInt() ?? 0;
    return _Entry(
      url: url,
      file: file,
      at: at,
      bytes: bytes < 0 ? 0 : bytes,
      lastAccess: lastAccess,
    );
  }
}

/// 图片的**磁盘**缓存（内存那一层交给 Flutter 自带的 [ImageCache]）。
///
/// 为什么不能复用 `CacheStore`：那个缓存的是 RSS 的 **JSON 文本**
/// （`CachedBody.body` 是 String），图片塞进去要 base64，体积膨胀约 33%，
/// 而且每次读都要解码字符串 —— 两个问题都不该出现在「滚动列表的封面」这条热路径上。
///
/// 目录刻意与 `rss_cache` **分开**（`<ApplicationSupport>/image_cache`）：
/// 两者的淘汰策略完全不同（图片按 LRU、RSS 按 TTL），
/// 放一个目录里迟早会互相误删。
///
/// ## 为什么 [lookup] 必须是**同步**的
///
/// 列表滚回时要「立即显示真图」。如果每张图都要 `await` 一次文件存在性检查，
/// 那一帧必然是灰底占位 —— 用户看到的就是「滚回来闪一下灰」。
/// 所以启动时 [ensureReady] 把索引整个读进内存，之后查索引是**纯内存操作**，
/// `build` 里直接就能拿到文件。
///
/// ## 索引损坏的自愈
///
/// 索引文件缺失/损坏时**重建**而不是清空：扫目录把文件收进索引，
/// 但把这些「只认文件名、不认 URL」的条目 `lastAccess` 置为最早，
/// 让它们**优先被 LRU 淘汰** —— 既不会因为一次索引损坏就丢掉几十 MB
/// 有效缓存，也不会让它们永久占位（它们已经无法通过 URL 命中了）。
class ImageCacheStore {
  ImageCacheStore({
    this.maxBytes = 200 * 1024 * 1024,
    this.maxEntries = 1000,
    Dio? dio,
  }) : _dio = dio;

  /// LRU 字节上限。
  final int maxBytes;

  /// LRU 条数上限。
  final int maxEntries;

  Dio? _dio;
  Directory? _dir;

  /// URL → 条目。**同步**读取的数据源。
  final Map<String, _Entry> _index = <String, _Entry>{};

  /// 进行中的下载（同一 URL 并发去重）。
  final Map<String, Future<File?>> _inflight = <String, Future<File?>>{};

  bool _ready = false;

  /// 索引或内容发生变化时自增。
  ///
  /// 界面靠它知道「后台落盘完成了，可以换成 Image.file 了」；
  /// 也是真机上验证「命中计数」的观测点。
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  /// 命中磁盘的次数（真机取证用：滚动往返后这个数应该增加而网络请求数不增加）。
  int _hits = 0;
  int get hits => _hits;

  /// 落盘次数。
  int _stores = 0;
  int get stores => _stores;

  bool get isReady => _ready;

  /// 注入/替换下载器（单测用假下载器）。
  void attachDio(Dio dio) => _dio = dio;

  /// 覆盖下载实现。
  ///
  /// 存在的唯一理由是单测：`dio.get` 内部的 `HttpClient` 在
  /// `flutter_test` 里被替换成一个固定返回 400 的假客户端，
  /// 无法用它验证「离线命中」「并发去重」这些**纯逻辑**。
  /// 生产代码永远走 [fetchAndStore] 里的 Dio 分支。
  @visibleForTesting
  Future<Uint8List?> Function(String url)? downloaderOverride;

  /// 覆盖缓存目录。
  ///
  /// 只在单测里用（临时目录）：`getApplicationSupportDirectory()` 依赖
  /// platform channel，在单测里拿不到真实目录。
  @visibleForTesting
  void attachDir(Directory dir) => _dir = dir;

  static String keyFor(String url) => sha1.convert(utf8.encode(url)).toString();

  // ------------------------------------------------------------ 初始化

  /// 读索引进内存。启动时调用一次即可（幂等）。
  Future<void> ensureReady() async {
    if (_ready) return;
    try {
      final dir = await _ensureDir();
      final indexFile = File(_indexPath(dir));
      Map<String, dynamic>? decoded;
      if (await indexFile.exists()) {
        try {
          final raw = await indexFile.readAsString();
          final obj = jsonDecode(raw);
          if (obj is Map) decoded = Map<String, dynamic>.from(obj);
        } catch (e) {
          Log.w('ImageCacheStore', '索引无法解析，将重建：$e');
        }
      }

      if (decoded == null) {
        await _rebuildIndexFromDisk(dir);
      } else {
        await _loadIndex(dir, decoded);
      }
      _ready = true;
      version.value++;
    } catch (e, st) {
      // 图片缓存不可用绝不能影响 App 运行：退化为「纯内存 + 不落盘」。
      Log.e('ImageCacheStore', '初始化失败，图片将不落盘', e, st);
      _ready = true;
    }
  }

  /// 索引存在：逐条校验文件是否真的还在（文件被系统清理时索引会指向空气）。
  Future<void> _loadIndex(Directory dir, Map<String, dynamic> decoded) async {
    final entries = decoded['entries'];
    if (entries is! Map) {
      await _rebuildIndexFromDisk(dir);
      return;
    }
    var dropped = 0;
    for (final e in entries.entries) {
      final url = '${e.key}';
      final entry = _Entry.fromJson(url, e.value);
      if (entry == null) {
        dropped++;
        continue;
      }
      if (!await File('${dir.path}${Platform.pathSeparator}${entry.file}').exists()) {
        dropped++;
        continue;
      }
      _index[url] = entry;
    }
    if (dropped > 0) {
      Log.w('ImageCacheStore', '索引里有 $dropped 条指向已不存在的文件，已剔除');
      await _saveIndex();
    }
  }

  /// 索引损坏：按目录重建，并把无法归属 URL 的条目排到 LRU 最前（优先淘汰）。
  Future<void> _rebuildIndexFromDisk(Directory dir) async {
    _index.clear();
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    var adopted = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name == _indexFileName) continue;
      final ok = await _isHashLike(name);
      if (ok) {
        // 文件名就是 URL 的 sha1，但我们拿不回 URL —— 只能等待被淘汰。
        _index[name] = _Entry(
          url: name,
          file: name,
          at: epoch,
          bytes: await entity.length(),
          lastAccess: epoch,
        );
        adopted++;
      } else {
        // 既不是索引也不是 sha1 文件名的残留（例如写了一半的临时文件）→ 直接删。
        try {
          await entity.delete();
        } catch (_) {
          // 删不掉也无所谓，下次启动再试。
        }
      }
    }
    Log.w('ImageCacheStore', '索引已重建：收编 $adopted 个文件（优先淘汰）');
    await _saveIndex();
  }

  static final RegExp _hashRe = RegExp(r'^[0-9a-f]{40}(\.[A-Za-z0-9]{1,5})?$');
  Future<bool> _isHashLike(String name) async => _hashRe.hasMatch(name);

  /// 清空全部图片缓存。
  Future<void> clear() async {
    _index.clear();
    _inflight.clear();
    try {
      final dir = await _ensureDir();
      if (await dir.exists()) await dir.delete(recursive: true);
      // ⚠️ 不能把 `_dir` 置空再走 `_ensureDir()`：`ensureDir` 只在 `_dir == null`
      // 时才去问 `getApplicationSupportDirectory()`，而清空之后目录是**不存在**的，
      // 那条路径会重新解析目录（单测里会直接抛 MissingPluginException）。
      // 正确做法是沿用同一个目录对象把它重建出来。
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (e, st) {
      Log.e('ImageCacheStore', '清空图片缓存失败', e, st);
      rethrow;
    }
    version.value++;
  }

  Future<ImageCacheStats> stats() async {
    // 用内存索引统计即可：它已经在启动时校验过文件存在性。
    var bytes = 0;
    for (final e in _index.values) {
      bytes += e.bytes;
    }
    return ImageCacheStats(entries: _index.length, bytes: bytes);
  }

  // ------------------------------------------------------------ 读

  /// **同步**查磁盘缓存。命中返回文件，未命中返回 null。
  ///
  /// 会顺手更新 LRU 的 `lastAccess` 并计数 —— 这个方法是「命中」的唯一入口。
  File? lookup(String url) {
    final entry = _index[url];
    if (entry == null) return null;
    final dir = _dir;
    if (dir == null) return null;
    final file = File('${dir.path}${Platform.pathSeparator}${entry.file}');
    entry.lastAccess = DateTime.now();
    _hits++;
    return file;
  }

  /// 只查不改（不更新 LRU、不计数）。给「是否存在」这类判断用。
  bool contains(String url) => _index.containsKey(url);

  /// 磁盘上的这张图坏掉了：从索引删掉并把文件删掉，让下次走网络重下。
  ///
  /// 触发场景：文件被系统清理成 0 字节、或写盘时被杀进程留下半张图。
  /// 不做这件事的话，这一张图会**永远**显示不出来（每次都命中同一个坏文件）。
  Future<void> removeFileFor(String url) async {
    final entry = _index.remove(url);
    if (entry == null) return;
    final dir = _dir;
    if (dir != null) {
      try {
        final f = File('${dir.path}${Platform.pathSeparator}${entry.file}');
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 删不掉也没关系，索引里已经没有了，不会再被命中。
      }
    }
    await _saveIndex();
    version.value++;
  }

  // ------------------------------------------------------------ 写

  /// 下载并落盘。同一 URL 并发调用只会真正下载一次。
  ///
  /// 返回落盘后的文件；失败返回 null（**不抛异常**：封面加载失败不该冒泡到 UI）。
  Future<File?> fetchAndStore(String url) {
    final existing = _inflight[url];
    if (existing != null) return existing;

    // 用 async + try/finally 而不是 `whenComplete(...)`：
    // 后者的链在某些情况下会让返回的 Future 一直处于未完成状态
    // （真机表现是「封面永远停在占位图」，单测表现是 30 秒超时）。
    Future<File?> run() async {
      try {
        return await _doFetchAndStore(url);
      } finally {
        _inflight.remove(url);
      }
    }

    final future = run();
    _inflight[url] = future;
    return future;
  }

  Future<File?> _doFetchAndStore(String url) async {
    if (url.isEmpty) return null;
    try {
      final override = downloaderOverride;
      if (override != null) {
        final bytes = await override(url);
        if (bytes == null || bytes.isEmpty) return null;
        return await put(url, bytes);
      }

      final dio = _dio;
      if (dio == null) return null;
      final resp = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          // B 站图床对 Referer 敏感，缺了会 403 —— 与 CoverImage 的请求头保持一致。
          headers: const <String, String>{
            'Referer': 'https://www.bilibili.com/',
            'User-Agent': AppConfig.browserUserAgent,
          },
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status < 200 || status >= 300) return null;
      final data = resp.data;
      if (data == null || data.isEmpty) return null;
      return await put(url, Uint8List.fromList(data));
    } on DioException catch (e) {
      Log.w('ImageCacheStore', '下载图片失败 ${_short(url)}: ${e.type}');
      return null;
    } catch (e) {
      Log.w('ImageCacheStore', '下载图片失败 ${_short(url)}: $e');
      return null;
    }
  }

  /// 直接把已知的字节写进缓存（全屏预览页保存图片前先落盘，避免重复下载）。
  Future<File?> put(String url, Uint8List bytes) async {
    if (url.isEmpty || bytes.isEmpty) return null;
    try {
      final dir = await _ensureDir();
      final key = keyFor(url);
      final name = '$key${_extensionOf(url)}';
      final file = File('${dir.path}${Platform.pathSeparator}$name');

      // 先写临时文件再 rename：中途被杀进程不会留下「半张图」被当成有效缓存。
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);

      final now = DateTime.now();
      _index[url] = _Entry(
        url: url,
        file: name,
        at: now,
        bytes: bytes.length,
        lastAccess: now,
      );
      _stores++;
      await _saveIndex();
      await _evictIfNeeded();
      version.value++;
      return file;
    } catch (e) {
      Log.w('ImageCacheStore', '写入图片缓存失败 ${_short(url)}: $e');
      return null;
    }
  }

  /// LRU 淘汰：先按 `lastAccess` 升序，超限就删最旧的。
  Future<void> _evictIfNeeded() async {
    var total = 0;
    for (final e in _index.values) {
      total += e.bytes;
    }
    if (total <= maxBytes && _index.length <= maxEntries) return;

    final ordered = _index.values.toList()
      ..sort((a, b) => a.lastAccess.compareTo(b.lastAccess));

    final dir = _dir;
    for (final e in ordered) {
      if (total <= maxBytes && _index.length <= maxEntries) break;
      _index.remove(e.url);
      total -= e.bytes;
      if (dir == null) continue;
      try {
        final f = File('${dir.path}${Platform.pathSeparator}${e.file}');
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 删不掉只是占点空间，不该影响功能。
      }
    }
    await _saveIndex();
  }

  // ------------------------------------------------------------ 内部

  static const String _indexFileName = 'index.json';

  static String _indexPath(Directory dir) =>
      '${dir.path}${Platform.pathSeparator}$_indexFileName';

  Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}image_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<void> _saveIndex() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final payload = <String, dynamic>{
        'version': 1,
        'entries': <String, dynamic>{
          for (final e in _index.entries) e.key: e.value.toJson(),
        },
      };
      final tmp = File('${_indexPath(dir)}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(_indexPath(dir));
    } catch (e) {
      Log.w('ImageCacheStore', '写索引失败：$e');
    }
  }

  /// 从 URL 猜扩展名。
  ///
  /// ⚠️ 这个扩展名**只影响可读性**，解码靠文件内容（`Image.file` 不嗅探后缀）。
  /// 所以猜不到时退回 `.img` 也不影响功能。
  static String _extensionOf(String url) {
    final withoutQuery = url.split('?').first.split('@').first;
    final slash = withoutQuery.lastIndexOf('/');
    final name = slash >= 0 ? withoutQuery.substring(slash + 1) : withoutQuery;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '.img';
    final ext = name.substring(dot).toLowerCase();
    const known = <String>['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.img'];
    return known.contains(ext) ? ext : '.img';
  }

  static String _short(String url) =>
      url.length <= 48 ? url : '${url.substring(0, 48)}…';
}
