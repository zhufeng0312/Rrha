import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/cache_store.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/weibo/weibo_api_client.dart';
import 'package:rrha/data/weibo/weibo_timeline_source.dart';

/// 微博昵称透出（[WeiboFetchResult.authorName]）的离线验收。
///
/// 背景：订阅源页显示的是 `Subscription.displayName`，没有别名时回退成
/// 「微博 <uid>」。博主真名其实**就在同一份响应里**（`mblog.user.screen_name`，
/// 解析器已填进 `ContentItem.authorName`），所以这里只验证「它被原样带出来」，
/// 一个请求都不多发。
///
/// 两条返回路径（缓存命中 / 网络拉取）都要覆盖：只填一条会让「刷新时不改名」
/// 这种 bug 时有时无，极难复现。

class _FakeClient extends WeiboApiClient {
  _FakeClient({required this.body});

  final String body;
  int callCount = 0;

  @override
  Future<WeiboPage> userTimeline({
    required String uid,
    required String cookie,
    String? sinceId,
  }) async {
    callCount += 1;
    return WeiboApiClient.parsePage(status: 200, body: body);
  }
}

class _FakeCache extends CacheStore {
  final Map<String, CachedBody> store = <String, CachedBody>{};

  @override
  Future<CachedBody?> read(String url, {bool ignoreTtl = false}) async =>
      store[url];

  @override
  Future<void> write(String url, String body, {int statusCode = 200}) async {
    store[url] = CachedBody(
      url: url,
      body: body,
      fetchedAt: DateTime.now(),
      statusCode: statusCode,
    );
  }
}

WeiboCookieSource _cookies(String value) =>
    WeiboCookieSource(loader: () async => value);

Subscription _sub({String uid = '1782488734', String? alias}) => Subscription(
      platform: Platform.weibo,
      uid: uid,
      routes: const <FeedRoute>{FeedRoute.weiboUser},
      alias: alias,
      addedAt: DateTime.utc(2026, 1, 1),
    );

/// 两条 mblog，作者昵称 `_warma_`（真机上的实际形态：昵称带下划线）。
const String _body = '{"ok":1,"data":{"cards":['
    '{"card_type":9,"mblog":{"id":"1001","mid":"1001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"第一条",'
    '"user":{"id":1782488734,"screen_name":"_warma_"}}},'
    '{"card_type":9,"mblog":{"id":"1002","mid":"1002",'
    '"created_at":"Mon Aug 07 19:00:00 +0800 2023","text":"第二条",'
    '"user":{"id":1782488734,"screen_name":"_warma_"}}}]}}';

/// 第一条作者与第二条不同（真实世界不会发生，这里用来钉住「取第一条」）。
const String _mixedAuthors = '{"ok":1,"data":{"cards":['
    '{"card_type":9,"mblog":{"id":"2001","mid":"2001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"甲",'
    '"user":{"id":1782488734,"screen_name":"第一条作者"}}},'
    '{"card_type":9,"mblog":{"id":"2002","mid":"2002",'
    '"created_at":"Mon Aug 07 19:00:00 +0800 2023","text":"乙",'
    '"user":{"id":1782488734,"screen_name":"第二条作者"}}}]}}';

/// 空页。
const String _empty = '{"ok":1,"data":{"cards":[]}}';

/// 有内容但没有 `screen_name`：解析器会回退成 `sub.displayName`
/// （「微博 1782488734」）。这种值**不能**当成昵称透出去。
const String _noScreenName = '{"ok":1,"data":{"cards":['
    '{"card_type":9,"mblog":{"id":"3001","mid":"3001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"没有昵称",'
    '"user":{"id":1782488734}}}]}}';

void main() {
  group('authorName：网络拉取路径', () {
    test('有内容 → 取自第一条 item 的作者名', () async {
      final _FakeClient client = _FakeClient(body: _body);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(result.fromCache, isFalse);
      expect(result.items, isNotEmpty);
      expect(result.authorName, '_warma_');
      expect(result.authorName, result.items.first.authorName,
          reason: '契约：就是第一条 item 的作者名');
      // 零额外请求：两次 mblog 只发一次。
      expect(client.callCount, 1);
    });

    test('多条作者不一致时取第一条（钉住「第一条」而不是「任意一条」）', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _mixedAuthors),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(result.items, hasLength(2));
      expect(result.authorName, '第一条作者');
    });

    test('无内容 → authorName 为 null', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _empty),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(result.items, isEmpty);
      expect(result.authorName, isNull);
    });

    test('缺 screen_name（作者名只是「微博 <uid>」兜底）→ 不透出，避免把占位值写进别名',
        () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _noScreenName),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFetchResult result = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(result.items, hasLength(1));
      expect(result.authorName, isNull);
    });
  });

  group('authorName：缓存命中路径', () {
    test('第二次（未 force）命中缓存，authorName 仍然带出来', () async {
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

      expect(second.fromCache, isTrue, reason: 'TTL 内必须走缓存');
      expect(client.callCount, 1, reason: '缓存命中不许再发请求');
      expect(first.authorName, '_warma_');
      expect(second.authorName, '_warma_',
          reason: '只看网络路径会漏掉这条，进而「刷新后昵称时有时无」');
      expect(second.authorName, first.authorName);
    });

    test('缓存里是空页 → null', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _empty),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      await source.fetch(sub: _sub(), route: FeedRoute.weiboUser);
      final WeiboFetchResult cached = await source.fetch(
        sub: _sub(),
        route: FeedRoute.weiboUser,
      );

      expect(cached.fromCache, isTrue);
      expect(cached.authorName, isNull);
    });
  });

  group('回归：authorName 不改变既有契约', () {
    test('items 的 sourceId / platform 不受影响', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _body),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final Subscription sub = _sub();
      final WeiboFetchResult result =
          await source.fetch(sub: sub, route: FeedRoute.weiboUser);

      for (final ContentItem item in result.items) {
        expect(item.sourceId, sub.id);
        expect(item.platform, Platform.weibo);
      }
    });
  });
}
