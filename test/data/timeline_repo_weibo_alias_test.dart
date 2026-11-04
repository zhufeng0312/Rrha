import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/cache_store.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/data/weibo/weibo_api_client.dart';
import 'package:rrha/data/weibo/weibo_timeline_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 微博昵称回填（`TimelineRepository._fetchWeibo` → `Prefs` 别名）的离线验收。
///
/// 三条硬约束，属于「比显示 UID 更糟」的错误方向，所以逐条钉死：
/// 1. **不覆盖用户已有别名**（手动设的永远优先）；
/// 2. **不新增任何请求**（昵称来自刚拉到的那一页）；
/// 3. **回填失败不影响内容展示**。
///
/// 全部离线：假 client（不发请求）、假 cache（内存 Map）、假 cookie source。

// ---------------------------------------------------------------- 假实现


class _FakeWeiboClient extends WeiboApiClient {
  _FakeWeiboClient({required this.body});

  final String body;
  int callCount = 0;
  final List<String> requestedUids = <String>[];

  @override
  Future<WeiboPage> userTimeline({
    required String uid,
    required String cookie,
    String? sinceId,
  }) async {
    callCount += 1;
    requestedUids.add(uid);
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

const String _body = '{"ok":1,"data":{"cards":['
    '{"card_type":9,"mblog":{"id":"1001","mid":"1001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"第一条",'
    '"user":{"id":1782488734,"screen_name":"_warma_"}}}]}}';

const String _empty = '{"ok":1,"data":{"cards":[]}}';

const String _noScreenName = '{"ok":1,"data":{"cards":['
    '{"card_type":9,"mblog":{"id":"3001","mid":"3001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"没有昵称",'
    '"user":{"id":1782488734}}}]}}';

Subscription _sub({String uid = '1782488734', String? alias}) => Subscription(
      platform: Platform.weibo,
      uid: uid,
      routes: const <FeedRoute>{FeedRoute.weiboUser},
      alias: alias,
      addedAt: DateTime.utc(2026, 1, 1),
    );

WeiboTimelineSource _source({
  String cookie = 'SUB=abc; SUBP=xyz',
  String body = _body,
  _FakeWeiboClient? client,
}) =>
    WeiboTimelineSource(
      client: client ?? _FakeWeiboClient(body: body),
      cache: _FakeCache(),
      cookies: _cookies(cookie),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
  });

  Future<void> seed(Subscription sub) async {
    await prefs.setSubscriptions(<Subscription>[sub]);
  }

  group('别名为空 → 写入博主真实昵称', () {
    test('拉取成功后别名被写成 screen_name，且零额外请求', () async {
      final Subscription sub = _sub();
      await seed(sub);
      final _FakeWeiboClient client = _FakeWeiboClient(body: _body);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(client: client),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      // 内容照常展示。
      expect(result.items, hasLength(1));
      expect(result.fatalError, isNull);
      // 回填生效。
      final Subscription stored = prefs.subscriptions.single;
      expect(stored.alias, '_warma_');
      expect(stored.displayName, '_warma_');
      expect(stored.displayName, isNot(contains('1782488734')));
      // 硬约束：内容拉取只发生一次，回填没有额外联网。
      expect(client.callCount, 1);
      expect(client.requestedUids, <String>[sub.uid]);
    });

    test('第二次拉取（命中缓存）时别名为空 → 同样回填', () async {
      final Subscription sub = _sub();
      await seed(sub);
      final _FakeWeiboClient client = _FakeWeiboClient(body: _body);
      final WeiboTimelineSource source = _source(client: client);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: source,
      );

      await repo.load(
        subscriptions: <Subscription>[sub],
      );
      // 模拟「用户清掉了别名」后再次刷新（走缓存路径）。
      await prefs.setSubscriptions(<Subscription>[_sub()]);

      await repo.load(
        subscriptions: <Subscription>[_sub()],
      );

      expect(prefs.subscriptions.single.alias, '_warma_');
      expect(client.callCount, 1, reason: '第二次应命中缓存，不发请求');
    });
  });

  group('不覆盖用户已有别名（关键）', () {
    test('已有别名 → 保持原样', () async {
      final Subscription sub = _sub(alias: '我自己起的名字');
      await seed(sub);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(),
      );

      await repo.load(
        subscriptions: <Subscription>[sub],
      );

      final Subscription stored = prefs.subscriptions.single;
      expect(stored.alias, '我自己起的名字',
          reason: '用户手动设置的别名永远优先，绝不能被昵称覆盖');
      expect(stored.displayName, '我自己起的名字');
    });

    test('已有别名（含首尾空白）也算「已设置」，不覆盖', () async {
      final Subscription sub = _sub(alias: '  我的别名  ');
      await seed(sub);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(),
      );

      await repo.load(
        subscriptions: <Subscription>[sub],
      );

      expect(prefs.subscriptions.single.alias, '  我的别名  ');
    });

    test('已有别名时完全不写 Prefs（不多一次落盘）', () async {
      final Subscription sub = _sub(alias: '我的别名');
      await seed(sub);
      SharedPreferences sp = await SharedPreferences.getInstance();
      final String before = sp.getString('subscriptions') ?? '';

      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(),
      );
      await repo.load(
        subscriptions: <Subscription>[sub],
      );

      sp = await SharedPreferences.getInstance();
      expect(sp.getString('subscriptions'), before);
      expect(prefs.subscriptions.single.alias, '我的别名');
    });

    test('两个订阅：只有别名为空的那个被回填', () async {
      final Subscription withAlias = _sub(uid: '1111', alias: '小号');
      final Subscription noAlias = _sub(uid: '2222');
      await prefs.setSubscriptions(<Subscription>[withAlias, noAlias]);

      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(),
      );
      await repo.load(
        subscriptions: <Subscription>[withAlias, noAlias],
      );

      final List<Subscription> stored = prefs.subscriptions;
      expect(stored.firstWhere((s) => s.uid == '1111').alias, '小号');
      expect(stored.firstWhere((s) => s.uid == '2222').alias, '_warma_');
    });
  });

  group('作者名拿不到 → 不写入、不报错', () {
    test('空页（authorName 为 null）→ 别名保持 null，刷新不失败', () async {
      final Subscription sub = _sub();
      await seed(sub);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(body: _empty),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      expect(result.items, isEmpty);
      expect(result.fatalError, isNull, reason: '「最近没发微博」不是错误');
      expect(prefs.subscriptions.single.alias, isNull);
      expect(prefs.subscriptions.single.displayName, '微博 1782488734');
    });

    test('缺 screen_name（作者名是「微博 <uid>」兜底）→ 不把占位值写进别名',
        () async {
      final Subscription sub = _sub();
      await seed(sub);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(body: _noScreenName),
      );

      await repo.load(
        subscriptions: <Subscription>[sub],
      );

      expect(prefs.subscriptions.single.alias, isNull,
          reason: '写进占位值等于永久占住别名位，界面却看不出变化');
    });

    test('拉取失败（未登录）→ 不写别名，也不抛异常给上层', () async {
      final Subscription sub = _sub();
      await seed(sub);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(cookie: ''),
      );

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      expect(prefs.subscriptions.single.alias, isNull);
      expect(result.fatalError, isNotNull);
      expect(result.items, isEmpty);
    });

    test('拉取期间订阅被删掉 → 回填静默跳过，内容照常返回', () async {
      final Subscription sub = _sub();
      await seed(sub);
      final _FakeWeiboClient client = _FakeWeiboClient(body: _body);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(client: client),
      );

      // 用「注入一个在 load 期间会清空订阅的仓库」不好做，这里直接验证
      // 订阅已不存在时 load 仍能正常返回内容、且不会把订阅复活。
      await prefs.setSubscriptions(const <Subscription>[]);

      final result = await repo.load(
        subscriptions: <Subscription>[sub],
      );

      expect(result.items, hasLength(1), reason: '回填失败不许影响内容展示');
      expect(prefs.subscriptions, isEmpty, reason: '不许把已删订阅写回去');
    });
  });

  group('B 站行为零变化', () {
    test('B 站订阅不会被回填任何别名', () async {
      final Subscription bili = Subscription(
        platform: Platform.bilibili,
        uid: '2267573',
        routes: const <FeedRoute>{FeedRoute.bilibiliVideo},
        addedAt: DateTime.utc(2026, 1, 1),
      );
      await prefs.setSubscriptions(<Subscription>[bili]);
      final TimelineRepository repo = TimelineRepository(
        prefs: prefs,
        weibo: _source(),
      );

      await repo.load(
        subscriptions: <Subscription>[bili],
      );

      expect(prefs.subscriptions.single.alias, isNull);
      expect(prefs.subscriptions.single.displayName, 'B 站 UP 2267573');
    });
  });
}
