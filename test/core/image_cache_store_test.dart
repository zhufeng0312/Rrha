import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/image_cache_store.dart';

/// 图片磁盘缓存的离线单测。
///
/// 全部用临时目录 + 注入的假下载器，**不联网、不碰 platform channel**。
void main() {
  late Directory tmp;
  late ImageCacheStore store;

  /// 一张最小的合法 PNG（1×1 透明）—— `Image.file` 需要真实可解码的内容，
  /// 真机验证里「离线命中还能显示」靠的就是它。
  final pngBytes = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rrha_imgcache_test');
    store = ImageCacheStore(
      maxBytes: 1024 * 1024,
      maxEntries: 100,
    )..attachDir(tmp);
    await store.ensureReady();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('基本读写', () {
    test('未命中返回 null，put 之后同步命中', () async {
      const url = 'https://i0.hdslb.com/bfs/a.jpg';
      expect(store.lookup(url), isNull);

      final file = await store.put(url, pngBytes);
      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);

      final hit = store.lookup(url);
      expect(hit, isNotNull, reason: 'lookup 必须同步返回，否则列表会闪灰');
      expect(hit!.path, file.path);
    });

    test('文件名是 URL 的 sha1（同一 URL 不同查询串是两份缓存）', () async {
      const url = 'https://i0.hdslb.com/bfs/a.jpg';
      await store.put(url, pngBytes);
      final expected = ImageCacheStore.keyFor(url);
      expect(store.lookup(url)!.path, contains(expected));

      store.lookup('https://i0.hdslb.com/bfs/a.jpg?x=1');
      expect(store.lookup('https://i0.hdslb.com/bfs/a.jpg?x=1'), isNull);
    });

    test('空 URL / 空字节不写盘', () async {
      expect(await store.put('', pngBytes), isNull);
      expect(await store.put('https://x/a.jpg', Uint8List(0)), isNull);
      expect((await store.stats()).entries, 0);
    });

    test('stats 汇总条数与字节', () async {
      await store.put('https://x/1.jpg', pngBytes);
      await store.put('https://x/2.jpg', pngBytes);
      final s = await store.stats();
      expect(s.entries, 2);
      expect(s.bytes, pngBytes.length * 2);
      expect(s.humanSize, isNotEmpty);
    });

    test('命中计数每次 lookup 自增（真机取证的观测点）', () async {
      const url = 'https://x/counter.jpg';
      await store.put(url, pngBytes);
      final before = store.hits;
      store.lookup(url);
      store.lookup(url);
      expect(store.hits, before + 2);
    });

    test('clear 之后不再命中，且目录可继续使用', () async {
      const url = 'https://x/clear.jpg';
      await store.put(url, pngBytes);
      expect(store.contains(url), isTrue);

      await store.clear();
      expect(store.contains(url), isFalse);
      expect(store.lookup(url), isNull);

      // 清空后还能继续写（目录被重建过）。
      expect(await store.put(url, pngBytes), isNotNull);
      expect(store.lookup(url), isNotNull);
    });
  });

  group('下载与并发去重', () {
    test('已有磁盘缓存时上层不会再来下载（fetchAndStore 只负责写）', () async {
      var downloads = 0;
      store.downloaderOverride = (url) async {
        downloads++;
        return pngBytes;
      };

      const url = 'https://x/fetch.jpg';
      final first = await store.fetchAndStore(url);
      expect(first, isNotNull);
      expect(downloads, 1);

      // 真实调用方（CachedImage）会先 lookup，命中就不再调 fetchAndStore：
      // 这里就是那条路径的等价断言。
      expect(store.lookup(url), isNotNull);
    });

    test('同一 URL 并发调用只真正下载一次', () async {
      var downloads = 0;
      final gate = Completer<void>();
      store.downloaderOverride = (url) async {
        downloads++;
        await gate.future;
        return pngBytes;
      };

      const url = 'https://x/concurrent.jpg';
      final futures = <Future<File?>>[
        store.fetchAndStore(url),
        store.fetchAndStore(url),
        store.fetchAndStore(url),
      ];
      gate.complete();
      final results = await Future.wait(futures);

      expect(downloads, 1, reason: '并发去重失效的话同一张图会被下 3 次');
      for (final r in results) {
        expect(r, isNotNull);
      }
    });

    test('下载失败返回 null 而不抛异常', () async {
      store.downloaderOverride = (url) async => null;
      expect(await store.fetchAndStore('https://x/fail.jpg'), isNull);

      store.downloaderOverride = (url) async => throw StateError('网络炸了');
      expect(await store.fetchAndStore('https://x/throw.jpg'), isNull);
    });

    test('没有任何下载器时不崩（退化为「不落盘」）', () async {
      final bare = ImageCacheStore()..attachDir(tmp);
      await bare.ensureReady();
      expect(await bare.fetchAndStore('https://x/none.jpg'), isNull);
    });
  });

  group('LRU 淘汰', () {
    test('超过条数上限时淘汰最久未访问的', () async {
      final small = ImageCacheStore(maxEntries: 2, maxBytes: 1 << 20)
        ..attachDir(tmp);
      await small.ensureReady();

      await small.put('https://x/1.jpg', pngBytes);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await small.put('https://x/2.jpg', pngBytes);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // 摸一下 1 号，让它变成「最近使用」。
      small.lookup('https://x/1.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await small.put('https://x/3.jpg', pngBytes);

      expect(small.contains('https://x/2.jpg'), isFalse, reason: '最久未访问的应被淘汰');
      expect(small.contains('https://x/1.jpg'), isTrue);
      expect(small.contains('https://x/3.jpg'), isTrue);
      expect((await small.stats()).entries, 2);
    });

    test('超过字节上限时按 LRU 淘汰到上限内', () async {
      final small = ImageCacheStore(
        maxBytes: pngBytes.length * 2,
        maxEntries: 100,
      )..attachDir(tmp);
      await small.ensureReady();

      for (int i = 1; i <= 5; i++) {
        await small.put('https://x/big$i.jpg', pngBytes);
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
      final s = await small.stats();
      expect(s.bytes, lessThanOrEqualTo(pngBytes.length * 2));
      expect(s.entries, lessThanOrEqualTo(2));
    });

    test('淘汰会真的删掉文件（不能只删索引）', () async {
      final small = ImageCacheStore(maxEntries: 1, maxBytes: 1 << 20)
        ..attachDir(tmp);
      await small.ensureReady();

      await small.put('https://x/old.jpg', pngBytes);
      final oldPath = small.lookup('https://x/old.jpg')!.path;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await small.put('https://x/new.jpg', pngBytes);

      expect(await File(oldPath).exists(), isFalse, reason: '不删文件就是纯漏空间');
    });
  });

  group('索引自愈', () {
    test('索引文件损坏 → 重建并按文件名收编现有文件', () async {
      const url = 'https://x/keep.jpg';
      await store.put(url, pngBytes);
      final filePath = store.lookup(url)!.path;

      // 把索引写坏。
      await File('${tmp.path}${Platform.pathSeparator}index.json')
          .writeAsString('{ not json at all');

      final reopened = ImageCacheStore()..attachDir(tmp);
      await reopened.ensureReady();

      // 文件还在（没有被清空）。
      expect(await File(filePath).exists(), isTrue);
      // 重建后的条目「收编」在索引里，且被排到 LRU 最前 —— 但按 URL 查不到，
      // 需要重新联网（这是索引损坏的必然代价，已在实现里注释说明）。
      expect(reopened.contains(url), isFalse);
      expect((await reopened.stats()).entries, 1);
    });

    test('索引指向的文件被删掉 → 启动时剔除该条', () async {
      const url = 'https://x/gone.jpg';
      await store.put(url, pngBytes);
      await File(store.lookup(url)!.path).delete();
      store.lookup(url); // 确认本来是在的

      final reopened = ImageCacheStore()..attachDir(tmp);
      await reopened.ensureReady();
      expect(reopened.contains(url), isFalse, reason: '指向空气的索引条目必须剔除');
    });

    test('索引里的垃圾条目（非 Map / 缺 file）被跳过', () async {
      await File('${tmp.path}${Platform.pathSeparator}index.json').writeAsString(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'entries': <String, dynamic>{
            'https://x/a.jpg': 'not-a-map',
            'https://x/b.jpg': <String, dynamic>{'at': '2026-01-01T00:00:00Z'},
          },
        }),
      );
      final reopened = ImageCacheStore()..attachDir(tmp);
      await reopened.ensureReady();
      expect((await reopened.stats()).entries, 0);
    });

    test('索引完全缺失 → 建空索引，不报错', () async {
      final fresh = await Directory.systemTemp.createTemp('rrha_imgcache_fresh');
      addTearDown(() async {
        if (await fresh.exists()) await fresh.delete(recursive: true);
      });
      final reopened = ImageCacheStore()..attachDir(fresh);
      await reopened.ensureReady();
      expect(reopened.isReady, isTrue);
      expect((await reopened.stats()).entries, 0);
    });

    test('重启后仍能命中（索引被真正持久化）', () async {
      const url = 'https://x/persist.jpg';
      await store.put(url, pngBytes);

      final reopened = ImageCacheStore()..attachDir(tmp);
      await reopened.ensureReady();
      final hit = reopened.lookup(url);
      expect(hit, isNotNull, reason: '重启命中是「滚回不重复请求」的前提');
      expect(await hit!.exists(), isTrue);
    });
  });

  group('离线命中（最硬的验收）', () {
    test('磁盘已有该图时，download 记数不增加', () async {
      const url = 'https://i0.hdslb.com/bfs/offline.jpg';
      var downloads = 0;
      store.downloaderOverride = (u) async {
        downloads++;
        return pngBytes;
      };

      // 第一次：需要下载。
      await store.fetchAndStore(url);
      expect(downloads, 1);

      // 模拟「断网后重启 App」：新实例读同一份索引。
      final offline = ImageCacheStore()..attachDir(tmp);
      offline.downloaderOverride = (u) async {
        downloads++;
        return null; // 断网：下载必然失败
      };
      await offline.ensureReady();

      final hit = offline.lookup(url);
      expect(hit, isNotNull, reason: '断网也必须命中磁盘');
      expect(await hit!.exists(), isTrue);
      expect(await hit.readAsBytes(), pngBytes, reason: '内容要能原样读出来（可被 Image.file 解码）');
      expect(downloads, 1, reason: '离线这次不该产生任何下载');
    });
  });

  group('坏文件处理', () {
    test('removeFileFor 同时清索引与文件', () async {
      const url = 'https://x/broken.jpg';
      await store.put(url, pngBytes);
      final path = store.lookup(url)!.path;

      await store.removeFileFor(url);
      expect(store.contains(url), isFalse);
      expect(await File(path).exists(), isFalse);
    });

    test('removeFileFor 对未知 URL 是安全的空操作', () async {
      await store.removeFileFor('https://x/never.jpg');
      expect((await store.stats()).entries, 0);
    });
  });
}
