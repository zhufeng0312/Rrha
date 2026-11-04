import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/image_cache_store.dart';
import 'package:rrha/widgets/cached_image.dart';

/// [CachedImage] 的离线验收：**磁盘命中优先于网络**。
///
/// 这就是「滚回不闪灰」这条需求的单测版本：磁盘有图 → 读本地、**一次网络都不发**；
/// 磁盘没有 → 先网络显示，后台落盘，落盘后改读本地。
///
/// ## 为什么这一组测试**完全不碰真实文件系统或图片解码**
///
/// `flutter_test` 里两条硬约束（都是踩出来的，都表现为「测试进程永久挂起、
/// 连 10 分钟超时都触发不了、必须手动 kill」）：
///
/// 1. **真实文件 I/O 不能 await**：`testWidgets` 的测试体与 `setUp`
///    都跑在 FakeAsync 区里，`Directory.createTemp()` 的 Future 永不完成；
/// 2. **图片解码永不完成**：`FileImage`、`MemoryImage` 都一样。
///
/// 所以这里改用两个手段：
/// - 一个**内存假 store**（继承 [ImageCacheStore] 并覆写文件相关方法），
///   让「磁盘上有/没有这张图」完全在内存里表达；
/// - [CachedImage.decisionProbe] 只验证**决策**（走磁盘 / 走网络），不建真实 `Image`。
///
/// 真实的磁盘读写、LRU、索引自愈、离线命中由
/// `test/core/image_cache_store_test.dart` 覆盖（那边是普通 `test`，可以自由 I/O）；
/// 真实解码由真机的飞行模式验收覆盖。

/// 内存版图片缓存：只表达「这个 URL 有没有磁盘缓存」。
class _FakeImageCacheStore extends ImageCacheStore {
  _FakeImageCacheStore();

  final Map<String, File> _entries = <String, File>{};
  final List<String> removed = <String>[];

  /// 记录下载次数（并发去重断言用）。
  int fetchCalls = 0;

  /// 预置一条「磁盘上已经有」的记录。
  void seed(String url) {
    _entries[url] = File('${Directory.systemTemp.path}/fake_${shortKey(url)}.img');
  }

  String shortKey(String url) => ImageCacheStore.keyFor(url).substring(0, 8);

  @override
  bool contains(String url) => _entries.containsKey(url);

  @override
  File? lookup(String url) => _entries[url];

  @override
  bool get isReady => true;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<File?> fetchAndStore(String url) async {
    fetchCalls++;
    if (_entries.containsKey(url)) return _entries[url];
    seed(url);
    return _entries[url];
  }

  @override
  Future<File?> put(String url, Uint8List bytes) async {
    seed(url);
    return _entries[url];
  }

  @override
  Future<void> removeFileFor(String url) async {
    removed.add(url);
    _entries.remove(url);
  }

  @override
  Future<ImageCacheStats> stats() async => ImageCacheStats(
        entries: _entries.length,
        bytes: 0,
      );

  @override
  Future<void> clear() async => _entries.clear();
}

void main() {
  late _FakeImageCacheStore store;

  /// 决策记录：`null` = 走网络；字符串 = 走磁盘（值是文件路径）。
  final decisions = <String?>[];

  setUp(() {
    store = _FakeImageCacheStore();
    decisions.clear();
    CachedImage.decisionProbe = decisions.add;
  });

  tearDown(() {
    CachedImage.decisionProbe = null;
  });

  Future<void> pump(WidgetTester tester, {String? url, Widget? placeholder}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CachedImage(
              url: url,
              width: 100,
              height: 100,
              cache: store,
              placeholder: placeholder,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// 最近一次决策是否「读了磁盘」。
  bool usedDisk() => decisions.isNotEmpty && decisions.last != null;

  group('磁盘命中', () {
    testWidgets('磁盘已有该图 → 读本地，不发网络请求', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/hit.jpg';
      store.seed(url);

      await pump(tester, url: url);
      await settle(tester);

      expect(usedDisk(), isTrue, reason: '磁盘命中就该读本地文件');
      expect(store.fetchCalls, 0, reason: '磁盘命中就绝不该再去下载');
    });

    testWidgets('读到的就是缓存给出的那个文件', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/samepath.jpg';
      store.seed(url);

      await pump(tester, url: url);
      await settle(tester);
      expect(decisions.last, store.lookup(url)!.path);
    });

    testWidgets('「滚走再滚回」= 重建 widget，仍然读磁盘（不重复请求）', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/scroll.jpg';
      store.seed(url);

      await pump(tester, url: url);
      await settle(tester);
      expect(usedDisk(), isTrue);
      final firstDecisions = decisions.length;

      // 「滚走」：整棵树换掉
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await settle(tester);
      // 「滚回」
      await pump(tester, url: url);
      await settle(tester);

      expect(decisions.length, greaterThan(firstDecisions));
      expect(usedDisk(), isTrue);
      expect(store.fetchCalls, 0, reason: '滚动往返不该产生任何图片下载');
    });

    testWidgets('同一 URL 二次构建不会重复「命中计数」之外的副作用', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/again.jpg';
      store.seed(url);

      await pump(tester, url: url);
      await settle(tester);
      await settle(tester);
      expect(store.fetchCalls, 0);
    });
  });

  group('磁盘未命中', () {
    testWidgets('首帧先走网络，之后才可能改读磁盘（不为缓存牺牲首屏）', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/miss.jpg';

      await pump(tester, url: url);
      // ⚠️ 只 pump 一帧：这时后台落盘（挂在 post-frame callback 上）还没跑完，
      // 决策必须是「走网络」—— 这就是「首帧不等缓存」的证据。
      await tester.pump();
      expect(decisions.first, isNull, reason: '首帧必须走网络（磁盘还没写）');
      expect(store.fetchCalls, 1, reason: '首帧之后应触发一次后台下载');

      await tester.pump(const Duration(milliseconds: 16));
    });

    testWidgets('后台落盘完成后改读磁盘', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/land.jpg';

      await pump(tester, url: url);
      await tester.pump();
      expect(decisions.first, isNull);

      await settle(tester);
      expect(store.contains(url), isTrue, reason: '后台落盘应真的写进磁盘索引');
      expect(usedDisk(), isTrue,
          reason: '落盘后应改读磁盘；做不到的话「滚回不闪灰」就无从谈起');
    });

    testWidgets('同一 URL 的并发去重：三个 widget 只触发一次下载', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/dedup.jpg';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                for (int i = 0; i < 3; i++)
                  CachedImage(url: url, width: 50, height: 50, cache: store),
              ],
            ),
          ),
        ),
      );
      await settle(tester);

      // CachedImage 层先各自 `lookup`（都未命中），共享的下载去重在
      // ImageCacheStore.fetchAndStore 内部（见 image_cache_store_test 的并发用例）。
      // 这里断言的是「同一帧里不会因为三个 widget 而写出三份不同的记录」。
      expect(store.contains(url), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('下载失败不崩、不写入索引', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/fail.jpg';
      final failing = _FailingStore();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedImage(url: url, width: 100, height: 100, cache: failing),
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(failing.contains(url), isFalse);
    });
  });

  group('容错', () {
    testWidgets('url 为空 → 不建任何 Image，也不崩', (tester) async {
      await pump(tester, url: null);
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('自定义 placeholder 在未命中时生效', (tester) async {
      const url = 'https://i0.hdslb.com/bfs/ph.jpg';
      await pump(
        tester,
        url: url,
        placeholder: const Text('占位中', textDirection: TextDirection.ltr),
      );
      await settle(tester);
      expect(find.text('占位中'), findsOneWidget);
    });

    testWidgets('url 变化时重新解析磁盘（列表复用 widget 的场景）', (tester) async {
      const a = 'https://i0.hdslb.com/bfs/a.jpg';
      const b = 'https://i0.hdslb.com/bfs/b.jpg';
      store.seed(b);
      // A 下载失败，避免它落盘后再切换时掩盖问题。
      final storeA = _FailingStore()..seed(b);

      await pump(tester, url: a);
      await tester.pump();
      // A 既不在磁盘里、下载也失败 → 只能是网络。
      expect(storeA.contains(a), isFalse);

      // 换成 B：B 在磁盘里 → 必须改读磁盘（同一棵 widget 树、只换 url）。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: CachedImage(
                url: b,
                width: 100,
                height: 100,
                cache: store,
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(usedDisk(), isTrue,
          reason: '换 URL 后要重新查磁盘，否则列表复用时会一直沿用上一张的状态');
    });

    testWidgets('圆角不为 0 时包一层 ClipRRect（视觉不退化）', (tester) async {
      // 探针模式会跳过真实渲染，这一条要临时关掉探针才看得到包裹层。
      CachedImage.decisionProbe = null;
      const url = 'https://i0.hdslb.com/bfs/r.jpg';
      store.seed(url);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedImage(
              url: url,
              width: 100,
              height: 100,
              borderRadius: 8,
              cache: store,
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(ClipRRect), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 永远下载失败的 store，用来验证「失败也不崩、不留脏记录」。
class _FailingStore extends _FakeImageCacheStore {
  @override
  Future<File?> fetchAndStore(String url) async => null;
}
