import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/cache_store.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/models/timeline_mode.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/data/weibo/weibo_api_client.dart';
import 'package:rrha/data/weibo/weibo_timeline_source.dart';
import 'package:rrha/features/timeline/timeline_page.dart';
import 'package:rrha/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 微博订阅在数据层的验收（接线后）。
///
/// 两条硬约束，配合着看：
/// 1. **微博订阅不许再打 RSSHub** —— 一旦有人把 RSSHub 分支顺手加回来，用户
///    就会开始看到 432 / 「实例未配置微博 Cookie」这类他根本无能为力的错误。
///    所以假客户端一旦被调用就抛异常 + 计数，用 `calls == 0` 把它钉死。
/// 2. **微博现在真的产出条目** —— 走 `WeiboTimelineSource`，产物必须带
///    `sourceId == sub.id`（已读标记与去重都靠它）。
///
/// 全部离线：假 client（不发请求）、假 cache（内存 Map）、假 cookie source
/// （直接给字符串）。**一个字节都不上网。**

// ---------------------------------------------------------------- 假实现


/// 假微博客户端：返回预设的响应体，不碰网络。
class _FakeWeiboClient extends WeiboApiClient {
  _FakeWeiboClient({required this.body, this.bodyForUid});

  /// 空字符串 = 让 `WeiboApiClient.parsePage` 判定为「拿不到可用数据」。
  final String body;

  /// 按 uid 生成响应体（用于「两个博主各有一份内容」这种场景）。
  final String Function(String uid)? bodyForUid;

  int callCount = 0;
  final List<String> requestedUids = <String>[];

  /// 只用于断言「凭据确实传到了请求头那一层」，测试之外不打印、不外传。
  final List<String> receivedCookies = <String>[];

  @override
  Future<WeiboPage> userTimeline({
    required String uid,
    required String cookie,
    String? sinceId,
  }) async {
    callCount += 1;
    requestedUids.add(uid);
    receivedCookies.add(cookie);
    return WeiboApiClient.parsePage(
      status: 200,
      body: bodyForUid == null ? body : bodyForUid!(uid),
    );
  }
}

/// 假缓存：内存 Map，行为与 [CacheStore] 的读写语义一致。
class _FakeCache extends CacheStore {
  final Map<String, CachedBody> store = <String, CachedBody>{};
  int writeCount = 0;

  @override
  Future<CachedBody?> read(String url, {bool ignoreTtl = false}) async =>
      store[url];

  @override
  Future<void> write(String url, String body, {int statusCode = 200}) async {
    writeCount += 1;
    store[url] = CachedBody(
      url: url,
      body: body,
      fetchedAt: DateTime.now(),
      statusCode: statusCode,
    );
  }
}

/// 假 cookie source：直接返回给定字符串，不碰任何 MethodChannel。
WeiboCookieSource _cookies(String value) =>
    WeiboCookieSource(loader: () async => value);

/// 两条 mblog 的最小合法形态（字段名全部来自真机采样）。
const String _twoMblogs = '{"ok":1,"data":{"cardlistInfo":{"total":99,'
    '"since_id":"4888888888888888"},"cards":['
    '{"card_type":9,"mblog":{"id":"1001","mid":"1001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"第一条",'
    '"user":{"id":1782488734,"screen_name":"张三"}}},'
    '{"card_type":9,"mblog":{"id":"1002","mid":"1002",'
    '"created_at":"Mon Aug 07 19:00:00 +0800 2023","text":"第二条",'
    '"user":{"id":1782488734,"screen_name":"张三"}}}]}}';

/// 一页 0 条（合法 JSON，但 cards 里没有博文卡）。
const String _emptyPage = '{"ok":1,"data":{"cards":[]}}';

Subscription _weiboSub({String uid = '1782488734', String? alias}) =>
    Subscription(
      platform: Platform.weibo,
      uid: uid,
      routes: <FeedRoute>{FeedRoute.weiboUser},
      alias: alias,
      addedAt: DateTime.utc(2026, 10, 15),
    );

Subscription _biliSub({String uid = '2267573'}) => Subscription(
      platform: Platform.bilibili,
      uid: uid,
      routes: <FeedRoute>{FeedRoute.bilibiliVideo},
      addedAt: DateTime.utc(2026, 10, 15),
    );

/// 用假依赖造一个**真实**的 [WeiboTimelineSource]。
///
/// 不子类化数据源本身：它的行为（登录检查 / 缓存 / 解析）正是要被接线验证的
/// 东西，把整段替换成返回固定 List 的桩，等于把「接线是否真的接通了」也一起
/// 绕过去了。
WeiboTimelineSource _source({
  String cookie = 'SUB=abc; SUBP=xyz',
  String body = _twoMblogs,
  _FakeCache? cache,
  _FakeWeiboClient? client,
}) =>
    WeiboTimelineSource(
      client: client ?? _FakeWeiboClient(body: body),
      cache: cache ?? _FakeCache(),
      cookies: _cookies(cookie),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
  });

  group('微博订阅不再请求 RSSHub，但真的产出条目', () {
    test('注入数据源后：RSSHub 零调用，items 非空且 sourceId 正确', () async {
      final sub = _weiboSub();
      final client = _FakeWeiboClient(body: _twoMblogs);
      final repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(client: client),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );


      expect(result.items, hasLength(2), reason: '微博现在有真实内容，不再是占位空结果');
      for (final ContentItem item in result.items) {
        expect(item.platform, Platform.weibo);
        // sourceId 必须是订阅 id：已读标记、按源过滤、去重全都依赖它。
        expect(item.sourceId, sub.id);
        expect(item.link, startsWith('https://m.weibo.cn/status/'));
      }
      expect(
        result.items.map((i) => i.title),
        containsAll(<String>['第一条', '第二条']),
      );

      final key = '${sub.id}#${FeedRoute.weiboUser.key}';
      final SourceStatus status = result.statuses[key]!;
      expect(status.hasError, isFalse);
      expect(status.itemCount, 2);
      expect(status.route, FeedRoute.weiboUser);
      expect(status.fromCache, isFalse);
      expect(status.lastSuccessAt, isNotNull);

      // 有内容 → 不判致命、不给「没有内容」的口径。
      expect(result.fatalError, isNull);
      expect(client.callCount, 1);
      expect(client.requestedUids, <String>[sub.uid]);
      // 凭据只用于断言「确实带上了」，不落盘不打日志。
      expect(client.receivedCookies.single, isNotEmpty);
    });

    test('多个微博订阅：各自独立请求，零 RSSHub 调用，条目都带自己的 sourceId',
        () async {
      final a = _weiboSub(uid: '1111');
      final b = _weiboSub(uid: '2222', alias: '小号');
      final repo = TimelineRepository(
        prefs: prefs,
        // 两个博主各给一份 mid 不同的内容：mid 相同会被去重合并（真实世界里
        // mid 全局唯一，这里故意造不同，才能断言「两边的条目都在」）。
        weibo: _source(
          client: _FakeWeiboClient(
            body: _twoMblogs,
            bodyForUid: (String uid) => '{"ok":1,"data":{"cards":['
                '{"card_type":9,"mblog":{"id":"${uid}01","mid":"${uid}01",'
                '"created_at":"Mon Aug 07 20:15:27 +0800 2023",'
                '"text":"$uid 的第一条","user":{"id":$uid,"screen_name":"博主$uid"}}}]}}',
          ),
        ),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[a, b],
      );

      expect(result.statuses.length, 2);
      for (final Subscription sub in <Subscription>[a, b]) {
        final SourceStatus status =
            result.statuses['${sub.id}#${FeedRoute.weiboUser.key}']!;
        expect(status.itemCount, 1);
        expect(status.hasError, isFalse);
      }
      // 两个源的 sourceId 必须泾渭分明，不能串。
      final Set<String> sourceIds =
          result.items.map((i) => i.sourceId).toSet();
      expect(sourceIds, <String>{a.id, b.id});
      expect(result.fatalError, isNull);
    });

    test('数据源返回 0 条：不算失败，但 itemCount 为 0 且给出解释', () async {
      final sub = _weiboSub();
      final repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(body: _emptyPage),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      expect(result.items, isEmpty);
      final status = result.statuses['${sub.id}#${FeedRoute.weiboUser.key}']!;
      expect(status.itemCount, 0);
      expect(status.hasError, isFalse, reason: '「最近没发微博」不是错误');
      expect(result.emptyHint, isNotNull);
      expect(result.fatalError, isNull);
    });

    test('未注入微博数据源：给一条可读错误，**不静默返回空**，且不碰 RSSHub',
        () async {
      // 保留原有用例的意图：微博绝不回落到 RSSHub。
      // 差异：现在未注入属于「接线缺失」，必须报出来（静默空会表现成
      // 「这个博主没有微博」，把接线 bug 伪装成正常状态）。
      final sub = _weiboSub();
      final repo = TimelineRepository(prefs: prefs);

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );


      final status = result.statuses['${sub.id}#${FeedRoute.weiboUser.key}']!;
      expect(status.error, isNotNull);
      expect(status.error, contains('未配置'));
      expect(status.itemCount, 0);

      expect(result.items, isEmpty);
      expect(result.fatalError, isNotNull);
    });
  });

  group('微博源报错时的状态与致命判定', () {
    test('cookie 为空（未登录）→ 状态 error 非空且是 auth 类', () async {
      final sub = _weiboSub();
      final client = _FakeWeiboClient(body: _twoMblogs);
      final repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(cookie: '', client: client),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      expect(result.items, isEmpty);

      final status = result.statuses['${sub.id}#${FeedRoute.weiboUser.key}']!;
      expect(status.error, isNotNull);
      expect(status.hasError, isTrue);
      // 分类必须带上来：UI 靠它区分「去登录」和「换浏览器打开主页」。
      expect(status.isAuthError, isTrue);
      expect(status.errorKind, AppErrorKind.auth);
      expect(status.error, contains('登录'));

      // 没有凭据就不该发请求（必然 432）。
      expect(client.callCount, 0);
    });

    test('只有微博源且它失败 → fatalError 就是那条 auth 错误', () async {
      final sub = _weiboSub();
      final repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(cookie: ''),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      // 以实际行为为准：本轮唯一的源失败了、且没有任何条目，所以
      // `fatalError` 会被置上（既有语义，本轮不改）。这里钉住它的**分类**，
      // 让空态能显示成「去登录」而不是「App 坏了」。
      expect(result.fatalError, isNotNull);
      expect(result.fatalError!.kind, AppErrorKind.auth);
      expect(result.items, isEmpty);
    });
  });

  group('对照：B 站订阅也不走 RSSHub', () {
    test('未登录时 B 站订阅只报「先去登录」，RSSHub 零调用', () async {
      final sub = _biliSub();
      final repo = TimelineRepository(prefs: prefs);

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      // 新架构下 B 站订阅走官方接口；_bili 为 null（未登录）时直接给

      final key = '${sub.id}#${FeedRoute.bilibiliVideo.key}';
      final status = result.statuses[key]!;
      expect(status.error, isNotNull);
      expect(status.itemCount, 0);
      expect(result.items, isEmpty);

      // 以实际行为为准：这一轮唯一的源就失败了，且没有任何条目，
      // 所以 fatalError 会被置上（这是既有语义，本轮不改）。
      expect(result.fatalError, isNotNull);
      expect(result.fatalError!.kind, AppErrorKind.auth);
    });

    test('B 站与微博混订：微博有内容时 timeline 不致命，B 站那段照常报错', () async {
      final bili = _biliSub();
      final weibo = _weiboSub();
      final repo = TimelineRepository(
        prefs: prefs,
        // 刻意不注入 BiliTimelineSource（等价于未登录），只给微博源。
        weibo: _source(),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[bili, weibo],
      );

      expect(
        result.statuses['${bili.id}#${FeedRoute.bilibiliVideo.key}']!.error,
        isNotNull,
      );
      expect(
        result.statuses['${weibo.id}#${FeedRoute.weiboUser.key}']!.itemCount,
        2,
      );
      // 两个源里有一个成功、有内容 → 不是全员失败。
      expect(result.fatalError, isNull, reason: '不是全员失败，不能判成致命');
      expect(result.items, hasLength(2));
    });
  });

  // ================================================================ 占位卡判定
  //
  // 占位卡从「只要有微博订阅就显示」改成「该源本轮没拉到内容才显示」。
  // 判定逻辑抽成了静态纯函数（`TimelinePage.facadeSubsFor`），所以这里不需要
  // pump 整个页面 + Riverpod，直接喂状态即可。
  group('占位卡判定：facadeSubsFor', () {
    TimelineState stateWith({
      required List<Subscription> subs,
      Map<String, SourceStatus> statuses = const <String, SourceStatus>{},
      List<ContentItem> items = const <ContentItem>[],
      TimelineMode mode = TimelineMode.selectedSubscriptions,
    }) =>
        TimelineState(
          mode: mode,
          subscriptions: subs,
          statuses: statuses,
          items: items,
        );

    ContentItem weiboItem(String sourceId, String id) => ContentItem(
          id: id,
          platform: Platform.weibo,
          kind: ContentKind.dynamic,
          sourceId: sourceId,
          authorName: '张三',
          title: '第一条',
          summary: '第一条',
          link: 'https://m.weibo.cn/status/1001',
          fetchedAt: DateTime.utc(2026, 10, 15),
        );

    test('有内容（itemCount > 0）→ 不显示占位卡', () {
      final sub = _weiboSub();
      final key = '${sub.id}#${FeedRoute.weiboUser.key}';
      final state = stateWith(
        subs: <Subscription>[sub],
        statuses: <String, SourceStatus>{
          key: SourceStatus(
            subscriptionId: sub.id,
            route: FeedRoute.weiboUser,
            itemCount: 2,
          ),
        },
        items: <ContentItem>[weiboItem(sub.id, 'a'), weiboItem(sub.id, 'b')],
      );

      expect(TimelinePage.facadeSubsFor(state), isEmpty);
    });

    test('0 条 → 显示占位卡（作为「去登录 / 换浏览器」入口）', () {
      final sub = _weiboSub();
      final key = '${sub.id}#${FeedRoute.weiboUser.key}';
      final state = stateWith(
        subs: <Subscription>[sub],
        statuses: <String, SourceStatus>{
          key: SourceStatus(
            subscriptionId: sub.id,
            route: FeedRoute.weiboUser,
            itemCount: 0,
          ),
        },
      );

      final facade = TimelinePage.facadeSubsFor(state);
      expect(facade, hasLength(1));
      expect(facade.single.id, sub.id);
    });

    test('没有 status（本轮还没拉）→ 显示占位卡', () {
      final sub = _weiboSub();
      final state = stateWith(subs: <Subscription>[sub]);

      expect(TimelinePage.facadeSubsFor(state), hasLength(1));
    });

    test('登录类错误 → 占位卡副标题引导「去登录」；其它空结果 → 引导「打开主页」',
        () {
      final sub = _weiboSub();
      final key = '${sub.id}#${FeedRoute.weiboUser.key}';

      final authState = stateWith(
        subs: <Subscription>[sub],
        statuses: <String, SourceStatus>{
          key: SourceStatus(
            subscriptionId: sub.id,
            route: FeedRoute.weiboUser,
            error: '微博未登录：请打开「微博」页面登录一次',
            errorKind: AppErrorKind.auth,
          ),
        },
      );
      expect(
        TimelinePage.facadeSubtitleFor(authState, sub),
        contains('未登录'),
        reason: 'auth 类必须明确指向「去登录」，否则用户只会去浏览器里瞎逛',
      );

      final emptyState = stateWith(
        subs: <Subscription>[sub],
        statuses: <String, SourceStatus>{
          key: SourceStatus(
            subscriptionId: sub.id,
            route: FeedRoute.weiboUser,
            itemCount: 0,
          ),
        },
      );
      expect(
        TimelinePage.facadeSubtitleFor(emptyState, sub),
        contains('内置浏览器'),
      );
    });

    test('B 站订阅永远不出占位卡（占位卡是微博专用引导）', () {
      final bili = _biliSub();
      final state = stateWith(subs: <Subscription>[bili]);

      expect(TimelinePage.facadeSubsFor(state), isEmpty);
    });

    test('「全部关注」模式（分页流，不含微博）不出占位卡', () {
      final sub = _weiboSub();
      final state = stateWith(
        subs: <Subscription>[sub],
        mode: TimelineMode.allFollowing,
      );

      // 该模式本轮根本没拉微博；出卡会让人以为「微博未登录」，而实际只是
      // 选了个不含微博的模式（引导由那一行小字承担）。
      expect(TimelinePage.facadeSubsFor(state), isEmpty);
    });
  });
}
