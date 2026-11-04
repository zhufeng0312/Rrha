import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/cache/cache_store.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/bili/bili_client.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/data/weibo/weibo_api_client.dart';
import 'package:rrha/data/weibo/weibo_timeline_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「全部关注」= B 站 + 微博混合信息流的离线验收。
///
/// 三件事必须被钉死（它们正是这条需求最容易出错的地方）：
/// 1. **合并纯函数** `mergeFollowing`：按 id 去重 + 按 sortKey 倒序；
/// 2. **微博失败不拖垮 B 站**：微博抛错时 B 站内容照常返回，失败只记进状态表；
/// 3. **两个游标互不干扰**：传给微博的是 `maxId`、传给 B 站的是 `offset`。

// ---------------------------------------------------------------- 假实现


/// 假微博客户端（关注流）。
class _FakeWeiboClient extends WeiboApiClient {
  _FakeWeiboClient({required this.body}) : super(dio: Dio());

  final String Function(String? maxId) body;

  int callCount = 0;
  final List<String?> requestedMaxIds = <String?>[];

  @override
  Future<WeiboFriendsPage> friendsFeed({
    required String cookie,
    String? maxId,
  }) async {
    callCount += 1;
    requestedMaxIds.add(maxId);
    return WeiboApiClient.parseFriendsPage(status: 200, body: body(maxId));
  }
}

/// 会抛错的微博客户端：用来验证「微博失败不拖垮 B 站」。
class _ThrowingWeiboClient extends WeiboApiClient {
  _ThrowingWeiboClient() : super(dio: Dio());

  int callCount = 0;

  @override
  Future<WeiboFriendsPage> friendsFeed({
    required String cookie,
    String? maxId,
  }) async {
    callCount += 1;
    throw const AppError(
      AppErrorKind.network,
      '微博炸了',
      retryable: true,
    );
  }
}

/// 假缓存：内存 Map。
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

/// 一页关注流（指定 mid 与作者，便于断言顺序与去重）。
///
/// [maxId] 为上一页游标（首屏为 null）；这里固定回一个游标值，模拟
/// 「服务端说还能往下翻」。
String _friendsBody(String? maxId) => '{"ok":1,"data":{"since_id":4912,'
    '"statuses":['
    '{"id":"w1","mid":"w1","created_at":"Mon Aug 07 20:15:27 +0800 2023",'
    '"text":"微博一","user":{"id":11,"screen_name":"甲"}},'
    '{"id":"w2","mid":"w2","created_at":"Mon Aug 07 19:00:00 +0800 2023",'
    '"text":"微博二","user":{"id":22,"screen_name":"乙"}}]}}';

/// 真实数据源（假 client / 假 cache / 假 cookie）—— 不子类化数据源本身，
/// 因为它自己的行为（登录检查 / 缓存 / 解析）正是要被接线验证的东西。
WeiboTimelineSource _weiboSource({
  String cookie = 'SUB=abc',
  _FakeCache? cache,
  WeiboApiClient? client,
  String Function(String? maxId)? body,
}) =>
    WeiboTimelineSource(
      client: client ??
          _FakeWeiboClient(
            body: body ?? (_friendsBody),
          ),
      cache: cache ?? _FakeCache(),
      cookies: _cookies(cookie),
    );

ContentItem _item({
  required String id,
  required Platform platform,
  required String sourceId,
  required DateTime at,
}) =>
    ContentItem(
      id: id,
      platform: platform,
      kind: ContentKind.dynamic,
      sourceId: sourceId,
      authorName: '作者',
      title: '标题 $id',
      summary: '',
      link: 'https://example.com/$id',
      fetchedAt: at,
      publishedAt: at,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
  });

  // ------------------------------------------------------------ 合并纯函数

  group('mergeFollowing：去重 + 倒序（纯函数）', () {
    DateTime at(int h) => DateTime.utc(2026, 10, 19, h);

    test('同 id 只留一条（B 站侧重复也不出两张卡）', () {
      final List<ContentItem> bili = <ContentItem>[
        _item(id: 'dup', platform: Platform.bilibili, sourceId: 'b', at: at(3)),
        _item(id: 'dup', platform: Platform.bilibili, sourceId: 'b', at: at(1)),
      ];
      final List<ContentItem> weibo = <ContentItem>[
        _item(id: 'dup', platform: Platform.weibo, sourceId: 'w', at: at(2)),
      ];

      final List<ContentItem> out = TimelineRepository.mergeFollowing(bili, weibo);
      expect(out, hasLength(1));
      expect(out.single.id, 'dup');
      // 第一条胜出（先到先得，与 TimelineRepository.load 的 putIfAbsent 一致）。
      expect(out.single.publishedAt, at(3));
    });

    test('按时间倒序交错（B 站与微博真的混在一起）', () {
      final List<ContentItem> bili = <ContentItem>[
        _item(id: 'b1', platform: Platform.bilibili, sourceId: 'b', at: at(5)),
        _item(id: 'b2', platform: Platform.bilibili, sourceId: 'b', at: at(1)),
      ];
      final List<ContentItem> weibo = <ContentItem>[
        _item(id: 'w1', platform: Platform.weibo, sourceId: 'w', at: at(4)),
        _item(id: 'w2', platform: Platform.weibo, sourceId: 'w', at: at(2)),
      ];

      final List<ContentItem> out = TimelineRepository.mergeFollowing(bili, weibo);
      expect(out.map((ContentItem i) => i.id), <String>['b1', 'w1', 'w2', 'b2']);
      for (var i = 1; i < out.length; i++) {
        expect(
          out[i - 1].sortKey.isAfter(out[i].sortKey),
          isTrue,
          reason: '必须严格倒序',
        );
      }
    });

    test('publishedAt 缺失时用 fetchedAt 参与排序（不排到最后）', () {
      final ContentItem noPub = ContentItem(
        id: 'np',
        platform: Platform.weibo,
        kind: ContentKind.dynamic,
        sourceId: 'w',
        authorName: '甲',
        title: '',
        summary: '',
        link: 'https://example.com/np',
        fetchedAt: at(3),
      );
      final List<ContentItem> out = TimelineRepository.mergeFollowing(
        <ContentItem>[
          _item(id: 'b', platform: Platform.bilibili, sourceId: 'b', at: at(2)),
        ],
        <ContentItem>[noPub],
      );
      expect(out.map((ContentItem i) => i.id), <String>['np', 'b']);
    });

    test('一边为空：原样返回另一边（仍倒序）', () {
      final List<ContentItem> bili = <ContentItem>[
        _item(id: 'b1', platform: Platform.bilibili, sourceId: 'b', at: at(1)),
        _item(id: 'b2', platform: Platform.bilibili, sourceId: 'b', at: at(9)),
      ];

      final List<ContentItem> onlyBili =
          TimelineRepository.mergeFollowing(bili, const <ContentItem>[]);
      expect(onlyBili.map((ContentItem i) => i.id), <String>['b2', 'b1']);

      final List<ContentItem> onlyWeibo =
          TimelineRepository.mergeFollowing(const <ContentItem>[], bili);
      expect(onlyWeibo.map((ContentItem i) => i.id), <String>['b2', 'b1']);
    });

    test('两边都空 → 空列表，不抛', () {
      expect(
        TimelineRepository.mergeFollowing(
          const <ContentItem>[],
          const <ContentItem>[],
        ),
        isEmpty,
      );
    });

    test('纯函数：不改动入参列表', () {
      final List<ContentItem> bili = <ContentItem>[
        _item(id: 'b1', platform: Platform.bilibili, sourceId: 'b', at: at(1)),
      ];
      final List<ContentItem> weibo = <ContentItem>[
        _item(id: 'w1', platform: Platform.weibo, sourceId: 'w', at: at(5)),
      ];
      final List<ContentItem> biliCopy = List<ContentItem>.of(bili);
      final List<ContentItem> weiboCopy = List<ContentItem>.of(weibo);

      TimelineRepository.mergeFollowing(bili, weibo);

      expect(bili.map((ContentItem i) => i.id), biliCopy.map((ContentItem i) => i.id));
      expect(weibo.map((ContentItem i) => i.id),
          weiboCopy.map((ContentItem i) => i.id));
    });
  });

  // ------------------------------------------------------------ 翻页续接
  //
  // 这一组盯的是一个**真机缺陷（2026-10-25）**：
  // 「B 站 9 小时前的动态与 9 小时前的视频之间，夹着微博近一个月的全部内容」。
  //
  // 根因不在排序函数（`mergeFollowing` 一直是对的），而在**翻页时的合并方式**：
  // `loadMore()` 早先把新一页直接 append 到已展示列表末尾，注释理由是
  // 「追加的页天然更旧」。这句话只在「两侧每页的时间跨度一致」时成立 ——
  // 而现实是 B 站一页 20 条只覆盖约 9 小时，微博一页 20 条能覆盖近一个月。
  // 第一页排完序，末尾已经是一堆「一个月前」的微博；第二页带回「9 小时前」
  // 的 B 站动态，append 上去就落在最后 → 时间线整体乱序。
  //
  // 所以这里断言的重点是：**翻页合并后，整条列表仍严格倒序**。

  group('mergeContinuing：翻页合并后仍严格倒序', () {
    DateTime at(int d, int h) => DateTime.utc(2026, 10, d, h);

    /// 断言整条列表按 sortKey 严格不增（允许相等：同一秒发布的几条）。
    void expectDescending(List<ContentItem> items) {
      for (var i = 1; i < items.length; i++) {
        expect(
          items[i - 1].sortKey.isBefore(items[i].sortKey),
          isFalse,
          reason: '第 $i 条比前一条更新 → 时间线乱序：'
              '${items[i - 1].id}(${items[i - 1].sortKey}) 在 '
              '${items[i].id}(${items[i].sortKey}) 之前',
        );
      }
    }

    test('复现真机场景：第二页的 B 站动态不该被 append 到一个月前的微博之后', () {
      // 第一页：B 站最近 9 小时 + 微博近一个月（微博每页跨度大得多）。
      final List<ContentItem> page1 = <ContentItem>[
        _item(id: 'bili-new', platform: Platform.bilibili, sourceId: 'b', at: at(19, 12)),
        // 微博一页就跨到一个月前。
        _item(id: 'weibo-old', platform: Platform.weibo, sourceId: 'w', at: at(19, 1)),
        _item(id: 'weibo-older', platform: Platform.weibo, sourceId: 'w', at: DateTime.utc(2026, 9, 20)),
      ];
      // 第二页：B 站继续往「更早」翻，但仍是当天早些时候 —— 比第一页的微博新。
      final List<ContentItem> page2 = <ContentItem>[
        _item(id: 'bili-9h', platform: Platform.bilibili, sourceId: 'b', at: at(19, 3)),
      ];

      final List<ContentItem> merged =
          TimelineRepository.mergeContinuing(page1, page2);

      // 正确顺序：bili-new > bili-9h > weibo-old > weibo-older
      expect(
        merged.map((ContentItem i) => i.id),
        <String>['bili-new', 'bili-9h', 'weibo-old', 'weibo-older'],
      );
      expectDescending(merged);
    });

    test('旧实现（纯 append）会失败 —— 证明这条测试有区分力', () {
      final List<ContentItem> page1 = <ContentItem>[
        _item(id: 'weibo-old', platform: Platform.weibo, sourceId: 'w', at: DateTime.utc(2026, 9, 20)),
      ];
      final List<ContentItem> page2 = <ContentItem>[
        _item(id: 'bili-9h', platform: Platform.bilibili, sourceId: 'b', at: at(19, 3)),
      ];

      // 旧写法：直接 [...loaded, ...next]。
      final List<ContentItem> appended = <ContentItem>[...page1, ...page2];
      expect(
        () => expectDescending(appended),
        throwsA(isA<TestFailure>()),
        reason: 'append 的结果必须是乱序的，否则这条缺陷根本复现不了',
      );

      // 新写法修好它。
      expectDescending(TimelineRepository.mergeContinuing(page1, page2));
    });

    test('跨页重复的条目只留一条（先到先得）', () {
      final List<ContentItem> loaded = <ContentItem>[
        _item(id: 'dup', platform: Platform.bilibili, sourceId: 'b', at: at(20, 5)),
        _item(id: 'b2', platform: Platform.bilibili, sourceId: 'b', at: at(19, 5)),
      ];
      final List<ContentItem> next = <ContentItem>[
        _item(id: 'dup', platform: Platform.bilibili, sourceId: 'b', at: at(20, 5)),
        _item(id: 'w1', platform: Platform.weibo, sourceId: 'w', at: at(19, 1)),
      ];

      final List<ContentItem> merged =
          TimelineRepository.mergeContinuing(loaded, next);
      expect(merged.map((ContentItem i) => i.id), <String>['dup', 'b2', 'w1']);
    });

    test('同一时间戳的条目保持原有相对顺序（稳定排序，卡片不会跳）', () {
      // 同一秒发布的三条：排序后必须还是 b1, b2, w1 这个相对次序。
      final DateTime same = at(19, 12);
      final List<ContentItem> loaded = <ContentItem>[
        _item(id: 'b1', platform: Platform.bilibili, sourceId: 'b', at: same),
        _item(id: 'b2', platform: Platform.bilibili, sourceId: 'b', at: same),
      ];
      final List<ContentItem> next = <ContentItem>[
        _item(id: 'w1', platform: Platform.weibo, sourceId: 'w', at: same),
      ];

      final List<ContentItem> merged =
          TimelineRepository.mergeContinuing(loaded, next);
      expect(
        merged.map((ContentItem i) => i.id),
        <String>['b1', 'b2', 'w1'],
        reason: 'sortKey 相同时必须按到达顺序，否则每次翻页同秒条目互相换位',
      );
    });

    test('空的下一页 / 空的已加载列表都不炸', () {
      final List<ContentItem> some = <ContentItem>[
        _item(id: 'a', platform: Platform.bilibili, sourceId: 'b', at: at(19, 1)),
      ];
      expect(
        TimelineRepository.mergeContinuing(some, const <ContentItem>[])
            .map((ContentItem i) => i.id),
        <String>['a'],
      );
      expect(
        TimelineRepository.mergeContinuing(const <ContentItem>[], some)
            .map((ContentItem i) => i.id),
        <String>['a'],
      );
      expect(
        TimelineRepository.mergeContinuing(
            const <ContentItem>[], const <ContentItem>[]),
        isEmpty,
      );
    });

    test('纯函数：不改动入参列表', () {
      final List<ContentItem> loaded = <ContentItem>[
        _item(id: 'b1', platform: Platform.bilibili, sourceId: 'b', at: at(19, 1)),
      ];
      final List<ContentItem> next = <ContentItem>[
        _item(id: 'w1', platform: Platform.weibo, sourceId: 'w', at: at(19, 9)),
      ];
      final List<ContentItem> loadedCopy = List<ContentItem>.of(loaded);
      final List<ContentItem> nextCopy = List<ContentItem>.of(next);

      TimelineRepository.mergeContinuing(loaded, next);

      expect(loaded.map((ContentItem i) => i.id),
          loadedCopy.map((ContentItem i) => i.id));
      expect(next.map((ContentItem i) => i.id), nextCopy.map((ContentItem i) => i.id));
    });
  });

  // -------------------------------------------------------- loadFollowing

  group('loadFollowing：微博失败不拖垮 B 站', () {
    test('微博抛错 → B 站内容仍然返回，失败只记进 statuses', () async {
      final client = _ThrowingWeiboClient();
      final repo = TimelineRepository(
        prefs: prefs,
        weibo: _weiboSource(client: client),
        // B 站侧刻意不注入（= 未登录）是不行的：那样没法验证「B 站有内容」。
        // 这里用一个真实 BiliTimelineSource + 不存在的登录态会抛 auth；
        // 所以改用无 B 站数据源 + 只断言「不整页变红」这一半，另一半见
        // 下面用 mergeFollowing 覆盖的「B 站有内容 + 微博失败」。
      );

      final TimelineFollowingResult result = await repo.loadFollowing(page: 1);

      // 微博失败 → 整页 error 不该被置成微博那条（那是 B 站侧的字段）。
      expect(result.error?.message, isNot(contains('微博')));
      final SourceStatus w =
          result.statuses['${WeiboTimelineSource.friendsSourceId}#weiboUser']!;
      expect(w.hasError, isTrue);
      expect(w.error, contains('微博炸了'));
      expect(w.itemCount, 0);
      expect(client.callCount, 1);
      // 有可读提示，但**不是**把整页判成致命。
      expect(result.items, isEmpty);
      expect(result.emptyHint, isNotNull);
      expect(result.emptyHint, contains('微博'));
    });

    test('B 站成功 + 微博失败 → 合并结果里是 B 站那些条目（关键用例）', () async {
      final repo = TimelineRepository(
        prefs: prefs,
        bili: _StubBiliFollowingSource(
          pages: <BiliFollowingFeedPage>[
            BiliFollowingFeedPage(
              items: <ContentItem>[
                _item(
                  id: 'b1',
                  platform: Platform.bilibili,
                  sourceId: BiliTimelineSource.followingSourceId,
                  at: DateTime.utc(2026, 10, 19, 3),
                ),
              ],
              fetchedAt: DateTime.utc(2026, 10, 19, 3),
              nextOffset: '999',
              hasMore: true,
            ),
          ],
        ),
        weibo: _weiboSource(client: _ThrowingWeiboClient()),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();

      expect(result.items, hasLength(1), reason: '微博失败不能吞掉 B 站内容');
      expect(result.items.single.id, 'b1');
      // B 站侧状态干净、微博侧有错：UI 因此只提示微博，不整页变红。
      expect(result.status.hasError, isFalse);
      expect(result.weiboStatus!.hasError, isTrue);
      expect(result.error, isNull, reason: 'B 站成功时整页不该有致命错误');
      expect(result.emptyHint, isNull, reason: '有内容时不给空态文案');
      expect(result.nextOffset, '999', reason: 'B 站游标照常透出');
      expect(result.nextMaxId, isNull);
      expect(result.hasMore, isTrue);
    });

    test('微博未登录（空 cookie）→ B 站照常返回，微博状态是 auth 类', () async {
      final repo = TimelineRepository(
        prefs: prefs,
        bili: _StubBiliFollowingSource(
          pages: <BiliFollowingFeedPage>[
            BiliFollowingFeedPage(
              items: <ContentItem>[
                _item(
                  id: 'b1',
                  platform: Platform.bilibili,
                  sourceId: BiliTimelineSource.followingSourceId,
                  at: DateTime.utc(2026, 10, 19, 3),
                ),
              ],
              fetchedAt: DateTime.utc(2026, 10, 19, 3),
              hasMore: true,
              nextOffset: '7',
            ),
          ],
        ),
        weibo: _weiboSource(cookie: ''),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();

      expect(result.items.single.id, 'b1');
      expect(result.weiboStatus!.isAuthError, isTrue);
      expect(result.weiboStatus!.error, contains('登录'));
      expect(result.status.hasError, isFalse);
    });

    test('微博数据源未注入（接线缺失）→ 只影响微博侧，B 站照常', () async {
      final repo = TimelineRepository(
        prefs: prefs,
        bili: _StubBiliFollowingSource(
          pages: <BiliFollowingFeedPage>[
            BiliFollowingFeedPage(
              items: <ContentItem>[
                _item(
                  id: 'b1',
                  platform: Platform.bilibili,
                  sourceId: BiliTimelineSource.followingSourceId,
                  at: DateTime.utc(2026, 10, 19, 3),
                ),
              ],
              fetchedAt: DateTime.utc(2026, 10, 19, 3),
            ),
          ],
        ),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();
      expect(result.items.single.id, 'b1');
      expect(result.weiboStatus!.hasError, isTrue);
      expect(result.weiboStatus!.error, contains('未配置'));
    });
  });

  group('loadFollowing：合并与排序', () {
    test('两边都有内容 → 合并后按时间倒序（B 站与微博交错）', () async {
      final repo = TimelineRepository(
        prefs: prefs,
        bili: _StubBiliFollowingSource(
          pages: <BiliFollowingFeedPage>[
            BiliFollowingFeedPage(
              items: <ContentItem>[
                _item(
                  id: 'b-new',
                  platform: Platform.bilibili,
                  sourceId: BiliTimelineSource.followingSourceId,
                  at: DateTime.utc(2026, 10, 19, 8),
                ),
                _item(
                  id: 'b-old',
                  platform: Platform.bilibili,
                  sourceId: BiliTimelineSource.followingSourceId,
                  at: DateTime.utc(2026, 10, 19, 1),
                ),
              ],
              fetchedAt: DateTime.utc(2026, 10, 19, 8),
              hasMore: true,
              nextOffset: 'off-1',
            ),
          ],
        ),
        weibo: _weiboSource(body: (String? maxId) {
          return '{"ok":1,"data":{"since_id":123,"statuses":['
              '{"id":"w-new","mid":"w-new",'
              '"created_at":"Mon Aug 07 20:15:27 +0800 2023",'
              '"text":"微博新","user":{"id":11,"screen_name":"甲"}}]}}';
        }),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();

      expect(result.items, hasLength(3));
      // 微博那条的 created_at 是 2023，必然排在两条 B 站（2026）之后。
      expect(result.items.last.id, startsWith('w'));
      expect(result.items.first.id, 'b-new');
      // 一条来自微博、两条来自 B 站 —— 混合流的核心断言。
      expect(
        result.items.map((ContentItem i) => i.platform).toSet(),
        <Platform>{Platform.bilibili, Platform.weibo},
      );
      for (var i = 1; i < result.items.length; i++) {
        expect(
          result.items[i - 1].sortKey.isAfter(result.items[i].sortKey),
          isTrue,
        );
      }
    });

    test('微博条目的 sourceId 恒为虚拟源 weibo:friends（已读标记依赖它）',
        () async {
      final repo = TimelineRepository(
        prefs: prefs,
        weibo: _weiboSource(),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();
      expect(result.items, isNotEmpty);
      expect(
        result.items.map((ContentItem i) => i.sourceId).toSet(),
        <String>{WeiboTimelineSource.friendsSourceId},
      );
    });
  });

  group('loadFollowing：两个游标互不干扰', () {
    test('传给 B 站的是 offset、传给微博的是 maxId（不串用）', () async {
      final biliStub = _StubBiliFollowingSource(
        pages: <BiliFollowingFeedPage>[
          BiliFollowingFeedPage(
            items: const <ContentItem>[],
            fetchedAt: _fixedTime,
          )
        ],
      );
      final weiboClient = _FakeWeiboClient(body: _friendsBody);
      final repo = TimelineRepository(
        prefs: prefs,
        bili: biliStub,
        weibo: _weiboSource(client: weiboClient),
      );

      const String biliOffset = '1198765432109876543';
      const String weiboSince = '4912345678901234';
      await repo.loadFollowing(offset: biliOffset, maxId: weiboSince, page: 2);

      expect(biliStub.requestedOffsets.single, biliOffset);
      expect(weiboClient.requestedMaxIds.single, weiboSince);
      // 反向确认：微博侧绝不能收到 B 站那个 19 位 offset。
      expect(weiboClient.requestedMaxIds, isNot(contains(biliOffset)));
    });

    test('nextOffset / nextMaxId 各自回传上一页的游标', () async {
      final biliStub = _StubBiliFollowingSource(
        pages: <BiliFollowingFeedPage>[
          BiliFollowingFeedPage(
            items: const <ContentItem>[],
            fetchedAt: _fixedTime,
            nextOffset: 'BILI-NEXT',
            hasMore: true,
          ),
        ],
      );
      final repo = TimelineRepository(
        prefs: prefs,
        bili: biliStub,
        weibo: _weiboSource(
          // 刻意只给 `since_id`（777），不给 `max_id`：这是修复后的关键行为 ——
          // 翻页游标必须来自**本页内容**（最后一条 w1），不能是 since_id。
          body: (String? maxId) => '{"ok":1,"data":{"since_id":777,'
              '"statuses":[{"id":"w1","mid":"w1","text":"x",'
              '"user":{"id":1,"screen_name":"甲"}}]}}',
        ),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();

      expect(result.nextOffset, 'BILI-NEXT');
      expect(
        result.nextMaxId,
        'w1',
        reason: '微博翻页游标取本页最旧那条的 id，而不是 since_id（那个方向相反）',
      );
      expect(result.hasMore, isTrue);
      expect(result.isEnd, isFalse);
    });

    test('微博到底、B 站还有 → hasMore 仍为 true（不能整页停住）', () async {
      final repo = TimelineRepository(
        prefs: prefs,
        bili: _StubBiliFollowingSource(
          pages: <BiliFollowingFeedPage>[
            BiliFollowingFeedPage(
              items: const <ContentItem>[],
              fetchedAt: _fixedTime,
              nextOffset: 'BILI-NEXT',
              hasMore: true,
            ),
          ],
        ),
        // 服务端没给 since_id → 微博侧到底。
        weibo: _weiboSource(
          body: (String? maxId) => '{"ok":1,"data":{"statuses":[]}}',
        ),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();

      expect(result.nextMaxId, isNull);
      expect(result.nextOffset, 'BILI-NEXT');
      expect(result.hasMore, isTrue, reason: 'B 站还能翻，就不能整页停住');
      expect(result.isEnd, isFalse);
    });

    test('B 站到底、微博还有 → hasMore 仍为 true', () async {
      final repo = TimelineRepository(
        prefs: prefs,
        bili: _StubBiliFollowingSource(
          pages: <BiliFollowingFeedPage>[
            BiliFollowingFeedPage(
              items: const <ContentItem>[],
              fetchedAt: _fixedTime,
              hasMore: false,
            ),
          ],
        ),
        weibo: _weiboSource(),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();

      expect(result.nextOffset, isNull);
      expect(result.nextMaxId, isNotNull);
      expect(result.hasMore, isTrue, reason: '微博还能翻，就不能整页停住');
    });

    test('两边都到底 → isEnd', () async {
      final repo = TimelineRepository(
        prefs: prefs,
        bili: _StubBiliFollowingSource(
          pages: <BiliFollowingFeedPage>[
            BiliFollowingFeedPage(
              items: const <ContentItem>[],
              fetchedAt: _fixedTime,
              hasMore: false,
            ),
          ],
        ),
        weibo: _weiboSource(
          body: (String? maxId) => '{"ok":1,"data":{"statuses":[]}}',
        ),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();
      expect(result.hasMore, isFalse);
      expect(result.isEnd, isTrue);
    });
  });

  group('loadFollowing：B 站未登录分支保持原行为', () {
    test('未注入 B 站数据源 → 整页 auth 错误（微博侧仍会被尝试）', () async {
      final weiboClient = _FakeWeiboClient(body: _friendsBody);
      final repo = TimelineRepository(
        prefs: prefs,
        weibo: _weiboSource(client: weiboClient),
      );

      final TimelineFollowingResult result = await repo.loadFollowing();

      expect(result.error, isNotNull);
      expect(result.error!.kind, AppErrorKind.auth);
      expect(
        result.status.subscriptionId,
        BiliTimelineSource.followingSourceId,
      );
      expect(result.status.hasError, isTrue);
      // 微博侧照样拉了一次：用户可能只登录了微博。
      expect(weiboClient.callCount, 1);
      expect(result.weiboStatus, isNotNull);
      expect(result.weiboStatus!.hasError, isFalse);
    });
  });
}

final DateTime _fixedTime = DateTime.utc(2026, 10, 19);

/// B 站关注流的桩数据源：按顺序吐出预设页，记录 offset。
///
/// 刻意只是**桩**：`fetchFollowing` 本身的行为已由
/// `test/bili/following_feed_test.dart` 覆盖，这里验证的是「外面套的合并」。
class _StubBiliFollowingSource extends BiliTimelineSource {
  _StubBiliFollowingSource({required this.pages})
      : super(client: BiliClient(dio: Dio()), cache: _FakeCache());

  final List<BiliFollowingFeedPage> pages;
  final List<String?> requestedOffsets = <String?>[];
  final List<int> requestedPages = <int>[];

  @override
  Future<BiliFollowingFeedPage> fetchFollowing({
    String? offset,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    requestedOffsets.add(offset);
    requestedPages.add(page);
    final int index = pages.length >= page ? page - 1 : pages.length - 1;
    return pages[index < 0 ? 0 : index];
  }
}
