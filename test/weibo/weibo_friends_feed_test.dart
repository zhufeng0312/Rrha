import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/cache_store.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/weibo/weibo_api_client.dart';
import 'package:rrha/data/weibo/weibo_parser.dart';
import 'package:rrha/data/weibo/weibo_timeline_source.dart';

/// `WeiboTimelineSource.fetchFriendsFeed`（`/feed/friends`）的离线验收。
///
/// 三条被钉死的东西，全都是真机探针踩出来的：
/// 1. 解析路径是 **`data.statuses[]`**（裸 mblog，没有 `cards[].mblog` 外壳）；
/// 2. 空 cookie → auth 错误，**一个请求都不发**；
/// 3. 游标走 `since_id`，并且**进缓存键**。
///
/// 全部离线：假 client（不发请求、只计数）、假 cache（内存 Map）、假 cookie。

// ---------------------------------------------------------------- 假实现

/// 假客户端：记录入参，返回预设的关注流一页。
class _FakeClient extends WeiboApiClient {
  _FakeClient({required this.body}) : super(dio: Dio());

  final String body;

  int callCount = 0;
  final List<String?> requestedMaxIds = <String?>[];
  final List<String> receivedCookies = <String>[];

  @override
  Future<WeiboFriendsPage> friendsFeed({
    required String cookie,
    String? maxId,
  }) async {
    callCount += 1;
    requestedMaxIds.add(maxId);
    // 只用于断言「凭据确实到了客户端」，不外传、不打日志。
    receivedCookies.add(cookie);
    return WeiboApiClient.parseFriendsPage(status: 200, body: body);
  }
}

/// 假缓存：内存 Map，语义与 [CacheStore] 一致。
class _FakeCache extends CacheStore {
  final Map<String, CachedBody> store = <String, CachedBody>{};
  int writeCount = 0;
  final List<String> writtenKeys = <String>[];

  @override
  Future<CachedBody?> read(String url, {bool ignoreTtl = false}) async =>
      store[url];

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

WeiboCookieSource _cookies(String value) =>
    WeiboCookieSource(loader: () async => value);

/// 两条关注流微博的最小合法形态：**裸 mblog**（`data.statuses[]`）。
const String _twoStatuses = '{"ok":1,"data":{"since_id":4912345678901234,'
    '"statuses":['
    '{"id":"2001","mid":"2001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"关注流第一条",'
    '"user":{"id":11,"screen_name":"甲"}},'
    '{"id":"2002","mid":"2002",'
    '"created_at":"Mon Aug 07 19:00:00 +0800 2023","text":"关注流第二条",'
    '"user":{"id":22,"screen_name":"乙"}}]}}';

/// 合法 JSON 但 `statuses` 为空。
const String _emptyPage = '{"ok":1,"data":{"statuses":[]}}';

void main() {
  // ---------------------------------------------------------- extractStatuses

  group('WeiboParser.extractStatuses：读 data.statuses[]', () {
    test('正常形态：每条直接是 mblog，取出 2 条', () {
      final List<Object?> out = WeiboParser.extractStatuses(_twoStatuses);
      expect(out, hasLength(2));
      expect((out.first! as Map)['mid'], '2001');
    });

    test('解好的结构（Map）也能吃，不只是 JSON 字符串', () {
      final Object? decoded = jsonDecode(_twoStatuses);
      expect(WeiboParser.extractStatuses(decoded), hasLength(2));
    });

    test('空 body / 非法 JSON / HTML 抗风控页 → 空列表，不崩', () {
      for (final Object? body in <Object?>[
        '',
        'not json',
        '<html>blocked</html>',
        null,
        '{"ok":1}',
        '{"ok":1,"data":{"cards":[]}}',
        '{"ok":1,"data":{"statuses":"oops"}}',
      ]) {
        expect(
          WeiboParser.extractStatuses(body),
          isEmpty,
          reason: 'body=$body 必须安全返回空列表',
        );
      }
    });

    test('列表里混进非对象元素 → 只丢那一条', () {
      const String body = '{"ok":1,"data":{"statuses":['
          '{"id":"1","mid":"1","text":"好的"},42,null,"str"]}}';
      final List<Object?> out = WeiboParser.extractStatuses(body);
      expect(out, hasLength(1));
    });

    test('路径确实是 data.statuses，不是 data.cards[].mblog', () {
      // 同样的 mblog 放在 cards 外壳里时，extractStatuses 必须**取不到**
      // （否则说明两个入口被混成了一处，回归到「假阴性」的老路）。
      const String wrapped = '{"ok":1,"data":{"cards":'
          '[{"card_type":9,"mblog":{"id":"1","mid":"1","text":"x"}}]}}';
      expect(WeiboParser.extractStatuses(wrapped), isEmpty);

      const String bare = '{"ok":1,"data":{"statuses":'
          '[{"id":"1","mid":"1","text":"x"}]}}';
      expect(WeiboParser.extractMblogs(bare), isEmpty);
    });
  });

  // ------------------------------------------------------ fetchFriendsFeed

  group('fetchFriendsFeed：登录检查', () {
    test('cookie 为空 → auth 错误，且一个请求都不发、不写缓存', () async {
      final _FakeClient client = _FakeClient(body: _twoStatuses);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies(''),
      );

      final Object? thrown = await _capture(() => source.fetchFriendsFeed());
      expect(thrown, isA<AppError>());
      final AppError e = thrown! as AppError;
      expect(e.kind, AppErrorKind.auth);
      expect(e.message, contains('未登录'));
      expect(e.retryable, isFalse);
      expect(client.callCount, 0, reason: '没有凭据就不该发请求（必然 432）');
      expect(cache.writeCount, 0);
    });

    test('cookie 只有空白也算未登录', () async {
      final _FakeClient client = _FakeClient(body: _twoStatuses);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('   '),
      );
      final Object? thrown = await _capture(() => source.fetchFriendsFeed());
      expect((thrown! as AppError).kind, AppErrorKind.auth);
      expect(client.callCount, 0);
    });
  });

  group('fetchFriendsFeed：正常拉取', () {
    test('items 非空、sourceId == friendsSourceId、platform 是微博', () async {
      final _FakeClient client = _FakeClient(body: _twoStatuses);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc; SUBP=def'),
      );

      final WeiboFriendsFeedPage page = await source.fetchFriendsFeed();

      expect(client.callCount, 1);
      expect(page.items, hasLength(2));
      for (final ContentItem item in page.items) {
        expect(item.sourceId, WeiboTimelineSource.friendsSourceId);
        expect(item.sourceId, 'weibo:friends');
        expect(item.platform, Platform.weibo);
        expect(item.link, startsWith('https://m.weibo.cn/status/'));
      }
      expect(
        page.items.map((ContentItem i) => i.title),
        containsAll(<String>['关注流第一条', '关注流第二条']),
      );
      // 一页里作者是**多个**（这正是「关注流」与「单博主时间线」的区别）。
      expect(page.items.map((ContentItem i) => i.authorName).toSet(),
          <String>{'甲', '乙'});
      expect(client.receivedCookies.single, 'SUB=abc; SUBP=def');
    });

    test('sourceId 与页码/游标无关：两页产出的 sourceId 完全一致', () async {
      final _FakeClient client = _FakeClient(body: _twoStatuses);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFriendsFeedPage first = await source.fetchFriendsFeed();
      final WeiboFriendsFeedPage second =
          await source.fetchFriendsFeed(maxId: '2002');

      // 已读标记按 sourceId 分组存：这个值一变，满屏都会是新角标。
      expect(
        <String>{
          ...first.items.map((ContentItem i) => i.sourceId),
          ...second.items.map((ContentItem i) => i.sourceId),
        },
        <String>{WeiboTimelineSource.friendsSourceId},
      );
      // 虚拟订阅的 id 也必须正好等于那个常量（解析层拿它当 sourceId）。
      expect(
        WeiboTimelineSource.friendsSubscription.id,
        WeiboTimelineSource.friendsSourceId,
      );
    });

    test('游标：首屏不带，给了 maxId 就原样传下去，并透出下一页游标', () async {
      final _FakeClient client = _FakeClient(body: _twoStatuses);
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFriendsFeedPage first = await source.fetchFriendsFeed();
      expect(client.requestedMaxIds.single, isNull, reason: '首屏不带游标');
      expect(first.nextMaxId, '2002');
      expect(first.hasMore, isTrue);
      expect(first.isEnd, isFalse);

      await source.fetchFriendsFeed(
        maxId: '2002',
        forceRefresh: true,
      );
      expect(client.requestedMaxIds.last, '2002');
    });

    test('缓存键含游标：weibo-api://friends/max=<游标或空>', () async {
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _twoStatuses),
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      await source.fetchFriendsFeed();
      await source.fetchFriendsFeed(
        maxId: '2002',
        forceRefresh: true,
      );

      expect(
        cache.writtenKeys,
        <String>[
          'weibo-api://friends/max=',
          // 第二页请求带了 maxId=2002，缓存键就用它（游标必须进键，
          // 否则第 2 页会读到第 1 页的内容）。
          'weibo-api://friends/max=2002',
        ],
      );
    });

    test('缓存里存原始 status + 游标（不是解析后的模型）', () async {
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _twoStatuses),
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      await source.fetchFriendsFeed();

      final Map<String, dynamic> map =
          jsonDecode(cache.store.values.single.body)! as Map<String, dynamic>;
      expect((map['statuses']! as List<Object?>), hasLength(2));
      expect(map['maxId'], '2002');
    });

    test('空页：items 为空、不崩、没有下一页游标', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _emptyPage),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFriendsFeedPage page = await source.fetchFriendsFeed();
      expect(page.items, isEmpty);
      expect(page.nextMaxId, isNull);
      expect(page.hasMore, isFalse);
      expect(page.isEnd, isTrue);
    });

    test('一条畸形 status 只丢那一条', () async {
      const String body = '{"ok":1,"data":{"since_id":7,"statuses":['
          '{"id":"1","mid":"1","text":"好的"},'
          '{"text":"没有 id 的畸形条目"}]}}';
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: body),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFriendsFeedPage page = await source.fetchFriendsFeed();
      expect(page.items, hasLength(1));
      expect(page.items.single.summary, contains('好的'));
    });
  });

  group('fetchFriendsFeed：缓存命中', () {
    test('第二次（未 force）命中缓存：fromCache=true、**不再发请求**、游标不丢', () async {
      final _FakeClient client = _FakeClient(body: _twoStatuses);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final WeiboFriendsFeedPage first = await source.fetchFriendsFeed();
      final WeiboFriendsFeedPage second = await source.fetchFriendsFeed();

      expect(first.fromCache, isFalse);
      expect(second.fromCache, isTrue);
      expect(client.callCount, 1, reason: 'TTL 内不该再发请求');
      expect(second.items.length, first.items.length);
      expect(second.nextMaxId, '2002', reason: '游标不能因缓存丢失');
    });

    test('forceRefresh=true → 跳过缓存重新请求', () async {
      final _FakeClient client = _FakeClient(body: _twoStatuses);
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: client,
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      await source.fetchFriendsFeed();
      final WeiboFriendsFeedPage forced =
          await source.fetchFriendsFeed(forceRefresh: true);

      expect(forced.fromCache, isFalse);
      expect(client.callCount, 2);
    });

    test('缓存损坏 → 按空结果处理，不崩', () async {
      final _FakeCache cache = _FakeCache();
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: _twoStatuses),
        cache: cache,
        cookies: _cookies('SUB=abc'),
      );

      cache.store['weibo-api://friends/max='] = CachedBody(
        url: 'weibo-api://friends/max=',
        body: '这不是 JSON',
        fetchedAt: DateTime.now(),
      );

      final WeiboFriendsFeedPage page = await source.fetchFriendsFeed();
      expect(page.fromCache, isTrue);
      expect(page.items, isEmpty);
    });
  });

  group('fetchFriendsFeed：错误透传', () {
    test('客户端报登录失效 → 原样透出 auth 类 AppError', () async {
      final WeiboTimelineSource source = WeiboTimelineSource(
        client: _FakeClient(body: '{"ok":-100}'),
        cache: _FakeCache(),
        cookies: _cookies('SUB=abc'),
      );

      final Object? thrown = await _capture(() => source.fetchFriendsFeed());
      expect((thrown! as AppError).kind, AppErrorKind.auth);
    });
  });

  // ---------------------------------------------------------- URL 拼装（纯函数）

  group('WeiboApiClient.buildFriendsUrl：游标原样拼', () {
    test('首屏不带 query', () {
      expect(
        WeiboApiClient.buildFriendsUrl(),
        'https://m.weibo.cn/feed/friends',
      );
    });

    test('空白游标被忽略', () {
      expect(
        WeiboApiClient.buildFriendsUrl(maxId: '   '),
        'https://m.weibo.cn/feed/friends',
      );
    });

    test('游标原样追加为 max_id（不数值化、不编码）', () {
      // ⚠️ 曾经是 `since_id` —— 语义错误，见 buildFriendsUrl 的注释：
      // `since_id` 指向「更新的方向」，传回去第 2 页恒为 0 条。
      expect(
        WeiboApiClient.buildFriendsUrl(maxId: '4912345678901234567'),
        'https://m.weibo.cn/feed/friends?max_id=4912345678901234567',
      );
    });
  });

  group('WeiboApiClient.parseFriendsPage', () {
    test('抽 data.statuses，翻页游标取 max_id（不是 since_id）', () {
      final WeiboFriendsPage page = WeiboApiClient.parseFriendsPage(
        status: 200,
        body: _twoStatuses,
      );
      expect(page.statuses, hasLength(2));
      // `_twoStatuses` 只给了 since_id（4912345678901234），没给 max_id。
      // 正确行为：游标**落在本页最旧那条的 id（2002）**，而不是 since_id
      // —— 后者代表「更新的方向」，拿它翻页会得到 0 条。
      expect(
        page.maxId,
        '2002',
        reason: 'since_id 是「更新的方向」，翻页游标必须来自本页内容',
      );
      expect(page.httpStatus, 200);
    });

    test('优先用 data.max_id', () {
      const String byMax = '{"ok":1,"data":{"max_id":77,'
          '"statuses":[{"id":"9","mid":"9","text":"x"}]}}';
      final WeiboFriendsPage page = WeiboApiClient.parseFriendsPage(
        status: 200,
        body: byMax,
      );
      expect(page.maxId, '77');
    });

    test('没有 max_id 时回退到本页最后一条 status 的 id', () {
      const String noCursor = '{"ok":1,"data":{"statuses":['
          '{"id":"300","mid":"300","text":"new"},'
          '{"id":"200","mid":"200","text":"old"}]}}';
      final WeiboFriendsPage page = WeiboApiClient.parseFriendsPage(
        status: 200,
        body: noCursor,
      );
      // 最后一条 = 本页最旧的一条，正好是「从这里往更早翻」的下界。
      expect(page.maxId, '200');
    });

    test('空 statuses 且无 max_id → 游标为 null（视为到底）', () {
      const String empty = '{"ok":1,"data":{"since_id":999,"statuses":[]}}';
      final WeiboFriendsPage page = WeiboApiClient.parseFriendsPage(
        status: 200,
        body: empty,
      );
      expect(page.maxId, isNull);
    });

    test('非法 JSON → 空结果而不是抛异常', () {
      final WeiboFriendsPage page = WeiboApiClient.parseFriendsPage(
        status: 200,
        body: '<html>risk control</html>',
      );
      expect(page.statuses, isEmpty);
      expect(page.maxId, isNull);
    });
  });

  // ---------------------------------------------------------- 虚拟源常量

  group('friendsSourceId / friendsSubscription 契约', () {
    test('id 与 uid 与路由都固定（与游标、页码无关）', () {
      expect(WeiboTimelineSource.friendsSourceId, 'weibo:friends');
      final Subscription sub = WeiboTimelineSource.friendsSubscription;
      expect(sub.platform, Platform.weibo);
      expect(sub.uid, 'friends');
      expect(sub.id, WeiboTimelineSource.friendsSourceId);
      expect(sub.activeRoutes, <FeedRoute>[FeedRoute.weiboUser]);
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
