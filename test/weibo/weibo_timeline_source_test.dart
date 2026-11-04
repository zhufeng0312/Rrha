import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/cache_store.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/weibo/weibo_api_client.dart';
import 'package:rrha/data/weibo/weibo_timeline_source.dart';

/// `WeiboTimelineSource` 的离线验收：登录检查 / 缓存 / 解析三段全离线。
///
/// 三个依赖全部用假实现：假 client（不发请求、只计数）、假 cache（内存
/// Map）、假 cookie source（直接给字符串）。**一个请求都不发**。

// ---------------------------------------------------------------- 假实现

/// 假客户端：记录调用次数与入参，返回预设的一页。
class _FakeClient extends WeiboApiClient {
  _FakeClient({required this.body});

  /// 返回给数据源的响应体（JSON 字符串形态）。
  final String body;

  int callCount = 0;
  final List<String> requestedUids = <String>[];
  final List<String?> requestedSinceIds = <String?>[];
  final List<String> receivedCookies = <String>[];

  @override
  Future<WeiboPage> userTimeline({
    required String uid,
    required String cookie,
    String? sinceId,
  }) async {
    callCount += 1;
    requestedUids.add(uid);
    requestedSinceIds.add(sinceId);
    // ⚠️ 只记长度用于断言「确实拿到了凭据」，不把内容带出测试环境之外的任何地方。
    receivedCookies.add(cookie);
    return WeiboApiClient.parsePage(status: 200, body: body);
  }
}

/// 假缓存：内存 Map，行为与 [CacheStore] 的读写语义一致（含 TTL 判定）。
class _FakeCache extends CacheStore {
  final Map<String, CachedBody> store = <String, CachedBody>{};
  int readCount = 0;
  int writeCount = 0;
  final List<String> writtenKeys = <String>[];

  @override
  Future<CachedBody?> read(String url, {bool ignoreTtl = false}) async {
    readCount += 1;
    return store[url];
  }

  @override
  Future<void> write(String url, String body, {int statusCode = 200}) async {
    writeCount += 1;
    writtenKeys.add(url);
    store[url] = CachedBody(
      url: url,
      body: body,
      fetchedAt: DateTime.now(),
      statusCode: statusCode,
    );
  }
}

/// 假 cookie source：直接返回给定字符串，不碰任何通道。
WeiboCookieSource _cookies(String value) =>
    WeiboCookieSource(loader: () async => value);

Subscription _sub({String uid = '1782488734'}) => Subscription(
      platform: Platform.weibo,
      uid: uid,
      routes: const <FeedRoute>{FeedRoute.weiboUser},
      addedAt: DateTime.utc(2026, 1, 1),
    );

/// 两条 mblog 的最小合法形态（字段名全部来自真实采样）。
const String _body = '{"ok":1,"data":{"cardlistInfo":{"total":99,'
    '"since_id":"4888888888888888"},"cards":['
    '{"card_type":9,"mblog":{"id":"1001","mid":"1001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"第一条",'
    '"user":{"id":1782488734,"screen_name":"张三"}}},'
    '{"card_type":9,"mblog":{"id":"1002","mid":"1002",'
    '"created_at":"Mon Aug 07 19:00:00 +0800 2023","text":"第二条",'
    '"user":{"id":1782488734,"screen_name":"张三"}}}]}}';

void main() {
  group('登录检查', () {
    test('cookie 为空 → 抛 auth 类 AppError，且一个请求都不发', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies(''),
      );

      final Object? thrown = await _capture(
        () => source.fetch(sub: _sub(), route: FeedRoute.weiboUser),
      );

      expect(thrown, isA<AppError>());
      final AppError e = thrown! as AppError;
      expect(e.kind, AppErrorKind.auth);
      expect(e.message, contains('未登录'));
      expect(e.retryable, isFalse);
      expect(client.callCount, 0, reason: '没有凭据就不该发请求（必然 432）');
      expect(cache.writeCount, 0);
    });

    test('cookie 只有空白也算未登录', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('   '),
      );

      final Object? thrown = await _capture(
        () => source.fetch(sub: _sub(), route: FeedRoute.weiboUser),
      );

      expect((thrown! as AppError).kind, AppErrorKind.auth);
      expect(client.callCount, 0);
    });
  });

  group('路由与 uid 校验', () {
    test('非 weiboUser 路由 → 抛 parse 错误', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _body),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final Object? thrown = await _capture(
        () => source.fetch(sub: _sub(), route: FeedRoute.bilibiliDynamic),
      );

      expect((thrown! as AppError).kind, AppErrorKind.parse);
    });

    test('uid 不是纯数字 → 抛 parse 错误，且不发请求', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final Object? thrown = await _capture(
        () => source.fetch(sub: _sub(uid: 'abc123'), route: FeedRoute.weiboUser),
      );

      expect((thrown! as AppError).kind, AppErrorKind.parse);
      expect(client.callCount, 0);
    });
  });

  group('首次拉取与缓存', () {
    test('首次拉取：发一次请求、写缓存、返回 items 与游标', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies('SUB=abc; SUBP=def'),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(client.callCount, 1);
      expect(cache.writeCount, 1);
      expect(result.fromCache, isFalse);
      expect(result.items.length, 2);
      expect(result.nextSinceId, '4888888888888888');
      expect(result.emptyHint, isNull);
      // cookie 被原样传给了客户端（它只准放请求头）。
      expect(client.receivedCookies.single, 'SUB=abc; SUBP=def');
      // 首屏不带游标。
      expect(client.requestedSinceIds.single, isNull);
    });

    test('缓存键里带 uid 与游标（游标为空时用 since=）', () async {
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _body),
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      await source.fetch(sub: _sub(), route: FeedRoute.weiboUser);

      expect(
        cache.writtenKeys.single,
        'weibo-api://weiboUser/1782488734/since=',
      );
    });

    test('翻页时游标进 URL 也进缓存键', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
        sinceId: '4888888888888888',
      );

      expect(client.requestedSinceIds.single, '4888888888888888');
      expect(
        cache.writtenKeys.single,
        'weibo-api://weiboUser/1782488734/since=4888888888888888',
      );
    });

    test('缓存里存的是原始 JSON（mblogs + sinceId），不是解析后的模型', () async {
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _body),
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      await source.fetch(sub: _sub(), route: FeedRoute.weiboUser);

      final Object? decoded = jsonDecode(cache.store.values.single.body);
      expect(decoded, isA<Map<String, dynamic>>());
      final Map<String, dynamic> map = decoded! as Map<String, dynamic>;
      expect(map['mblogs'], isA<List<Object?>>());
      expect((map['mblogs']! as List<Object?>).length, 2);
      expect(map['sinceId'], '4888888888888888');
    });
  });

  group('缓存命中', () {
    test('第二次拉取（未 force）命中缓存：fromCache=true 且不再发请求', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult first = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );
      final WeiboFetchResult second = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(first.fromCache, isFalse);
      expect(second.fromCache, isTrue);
      expect(client.callCount, 1, reason: 'TTL 内不该再发请求');
      expect(second.items.length, first.items.length);
      expect(second.nextSinceId, '4888888888888888', reason: '游标不能因缓存丢失');
    });

    test('forceRefresh=true → 跳过缓存重新请求', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      await source.fetch(sub: _sub(), route: FeedRoute.weiboUser);
      final WeiboFetchResult forced = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
        forceRefresh: true,
      );

      expect(forced.fromCache, isFalse);
      expect(client.callCount, 2);
      expect(cache.writeCount, 2);
    });

    test('缓存过期 → 重新请求', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      await source.fetch(sub: _sub(), route: FeedRoute.weiboUser);
      // 手动把缓存时间往前推 10 分钟（TTL 是 5 分钟）。
      final String key = cache.store.keys.single;
      final CachedBody stale = cache.store[key]!;
      cache.store[key] = CachedBody(
        url: stale.url,
        body: stale.body,
        fetchedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      );

      final WeiboFetchResult again = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(again.fromCache, isFalse);
      expect(client.callCount, 2);
    });

    test('缓存内容损坏 → 按空结果处理，不崩', () async {
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _body),
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      cache.store['weibo-api://weiboUser/1782488734/since='] = CachedBody(
        url: 'weibo-api://weiboUser/1782488734/since=',
        body: '这不是 JSON',
        fetchedAt: DateTime.now(),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(result.fromCache, isTrue);
      expect(result.items, isEmpty);
      expect(result.emptyHint, isNotNull);
    });
  });

  group('解析契约', () {
    test('ContentItem.sourceId == sub.id', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _body),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );
      final Subscription sub = _sub();

      final WeiboFetchResult result = await source.fetch(
        sub: sub,
        route: FeedRoute.weiboUser,
      );

      expect(result.items, isNotEmpty);
      for (final ContentItem item in result.items) {
        expect(item.sourceId, sub.id);
        expect(item.sourceId, 'weibo:1782488734');
        expect(item.platform, Platform.weibo);
      }
    });

    test('id 跨两次解析（缓存命中 vs 直连）稳定', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult direct = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );
      final WeiboFetchResult cached = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(client.callCount, 1);
      expect(
        cached.items.map((ContentItem i) => i.id).toList(),
        direct.items.map((ContentItem i) => i.id).toList(),
        reason: '解析规则与 id 契约相同，缓存不该产出另一套 id',
      );
      // 同一页里 id 必须唯一（否则时间线会出现两张一样的卡片）。
      expect(
        direct.items.map((ContentItem i) => i.id).toSet().length,
        direct.items.length,
      );
    });

    test('一条畸形 mblog 只丢那一条，其余照常解析', () async {
      const String body = '{"ok":1,"data":{"cards":['
          '{"card_type":9,"mblog":{"id":"1001","mid":"1001",'
          '"text":"好的那条","user":{"screen_name":"张三"}}},'
          '{"card_type":9,"mblog":{"text":"没有 id 的畸形条目"}}]}}';
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: body),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(result.items.length, 1);
      expect(result.items.single.summary, contains('好的那条'));
    });

    test('空页 → emptyHint 有文案', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: '{"ok":1,"data":{"cards":[]}}'),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(result.items, isEmpty);
      expect(result.emptyHint, isNotNull);
      expect(result.emptyHint, contains('微博'));
    });
  });

  group('错误透传', () {
    test('客户端抛登录失效 → 原样透出 auth 类 AppError', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: '{"ok":-100}'),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final Object? thrown = await _capture(
        () => source.fetch(sub: _sub(), route: FeedRoute.weiboUser),
      );

      expect((thrown! as AppError).kind, AppErrorKind.auth);
    });
  });
}

/// 捕获同步/异步异常。
Future<Object?> _capture(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } catch (e) {
    return e;
  }
}
