import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/models/timeline_mode.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 时间线「方案 C」的离线验收：
/// 1. 一页 20 条 + offset 游标翻页，滚到底追加（不是重新拉全量）；
/// 2. 到底之后不再请求；
/// 3. 模式切换会**重置列表**（两种模式的 sourceId 不同，混在一起已读标记会失效）。

ContentItem _item(String id) => ContentItem(
      id: id,
      platform: Platform.bilibili,
      kind: ContentKind.dynamic,
      sourceId: BiliTimelineSource.followingSourceId,
      authorName: 'up',
      title: '标题 $id',
      summary: '',
      link: 'https://t.bilibili.com/$id',
      fetchedAt: DateTime.utc(2026, 10, 15),
      publishedAt: DateTime.utc(2026, 10, 15),
    );

class _FakeTimelineRepo extends TimelineRepository {
  _FakeTimelineRepo({required super.prefs});

  int followingCalls = 0;
  int subscriptionCalls = 0;

  /// 每次调用 loadFollowing 时传进来的 offset（第 0 项是首屏，应为 null）。
  final List<String?> requestedOffsets = <String?>[];

  /// 每次调用 loadFollowing 时传进来的微博游标（同样首屏为 null）。
  final List<String?> requestedMaxIds = <String?>[];

  /// 记录「请求发起那一刻界面上的条目数」，用来证明切模式时列表被重置过。
  List<int> itemsAtRequest = <int>[];
  List<ContentItem> Function()? snapshot;

  /// 第二页故意带回一条与第一页重复的条目（服务端偶发）。
  bool duplicateSecondPage = false;

  /// 上一次 `load`（逐源聚合）收到的 `forceRefresh`，用来验证
  /// 「切模式走缓存」而不是强制刷新。
  bool? lastSubscriptionForceRefresh;

  /// 精选订阅模式返回的条目数。
  int subscriptionItems = 2;

  /// 微博侧是否还有下一页（模拟「两侧游标各自到底」的场景）。
  ///
  /// 默认 false：既有用例只关心 B 站游标，微博侧「到底」不该改变它们的结论。
  bool weiboSideHasMore = false;

  /// 只让微博侧有游标、B 站侧到底（验证「一侧到底不整页停住」）。
  bool biliSideEndsImmediately = false;

  void _capture() =>
      itemsAtRequest.add(snapshot == null ? -1 : snapshot!().length);

  @override
  Future<TimelineFollowingResult> loadFollowing({
    String? offset,
    String? maxId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    followingCalls++;
    requestedOffsets.add(offset);
    requestedMaxIds.add(maxId);
    _capture();

    final items = <ContentItem>[
      for (var i = 0; i < 20; i++) _item('p$page-$i'),
    ];
    if (page >= 2 && duplicateSecondPage) items.insert(0, _item('p1-0'));

    final String? nextOffset =
        (!biliSideEndsImmediately && page < 2) ? 'CURSOR-$page' : null;
    final String? nextMaxId = weiboSideHasMore ? 'SINCE-$page' : null;
    final bool more =
        nextOffset != null || nextMaxId != null;

    return TimelineFollowingResult(
      items: items,
      status: SourceStatus(
        subscriptionId: BiliTimelineSource.followingSourceId,
        route: FeedRoute.bilibiliDynamic,
        lastSuccessAt: DateTime.utc(2026, 10, 15),
        itemCount: items.length,
      ),
      nextOffset: nextOffset,
      nextMaxId: nextMaxId,
      hasMore: more,
      lastUpdated: DateTime.utc(2026, 10, 15),
    );
  }

  @override
  Future<TimelineResult> load({
    required List<Subscription> subscriptions,
    bool forceRefresh = false,
  }) async {
    subscriptionCalls++;
    lastSubscriptionForceRefresh = forceRefresh;
    _capture();
    return TimelineResult(
      items: <ContentItem>[
        for (var i = 0; i < subscriptionItems; i++)
          ContentItem(
            id: 'sub-$i',
            platform: Platform.bilibili,
            kind: ContentKind.video,
            sourceId: 'bilibili:2267573',
            authorName: 'up',
            title: '订阅条目 $i',
            summary: '',
            link: 'https://www.bilibili.com/video/BV$i',
            fetchedAt: DateTime.utc(2026, 10, 15),
          ),
      ],
      statuses: <String, SourceStatus>{
        'bilibili:2267573#bilibiliVideo': const SourceStatus(
          subscriptionId: 'bilibili:2267573',
          itemCount: 2,
        ),
      },
      lastUpdated: DateTime.utc(2026, 10, 15),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  late _FakeTimelineRepo repo;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
    repo = _FakeTimelineRepo(
      prefs: prefs,
    );

    container = ProviderContainer(
      overrides: <Override>[
        prefsProvider.overrideWithValue(prefs),
        timelineRepoProvider.overrideWithValue(repo),
      ],
    );
    repo.snapshot = () => container.read(timelineProvider).items;
    addTearDown(container.dispose);
  });

  group('「全部关注」分页', () {
    test('默认就是全部关注模式，首屏一页 20 条并拿到游标', () async {
      final notifier = container.read(timelineProvider.notifier);
      expect(container.read(timelineProvider).mode, TimelineMode.allFollowing);

      await notifier.refresh();

      final state = container.read(timelineProvider);
      expect(state.items.length, 20);
      expect(state.followingPage, 1);
      expect(state.followingOffset, 'CURSOR-1');
      expect(state.followingHasMore, isTrue);
      expect(state.canLoadMore, isTrue);
      expect(repo.followingCalls, 1);
      expect(repo.requestedOffsets.single, isNull, reason: '首屏不带游标');
    });

    test('滚到底：用上一页的游标追加下一页，而不是重新拉全部', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      await notifier.loadMore();

      final state = container.read(timelineProvider);
      expect(state.items.length, 40, reason: '20 + 20 追加');
      expect(repo.requestedOffsets, <String?>[null, 'CURSOR-1']);
      expect(repo.followingCalls, 2);
      expect(state.followingPage, 2);
      expect(state.followingOffset, isNull);
      expect(state.canLoadMore, isFalse, reason: '服务端说没有下一页了');
    });

    test('到底之后不再发请求（滚动回调可以放心重复调用）', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      await notifier.loadMore();
      await notifier.loadMore();
      await notifier.loadMore();

      expect(repo.followingCalls, 2);
      expect(container.read(timelineProvider).items.length, 40);
    });

    test('分页之间重复的条目会被去重（不会出现两张一样的卡片）', () async {
      repo.duplicateSecondPage = true;
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      await notifier.loadMore();

      final items = container.read(timelineProvider).items;
      expect(items.length, 40, reason: '第二页 20 条里 1 条重复 → 合并后 40 而不是 41');
      expect(items.map((e) => e.id).toSet().length, items.length);
    });

    test('精选订阅模式下不会误触发关注流分页', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.setMode(TimelineMode.selectedSubscriptions);
      final before = repo.followingCalls;

      await notifier.loadMore();
      expect(repo.followingCalls, before, reason: '非分页模式直接返回');
    });

    // ---- 两个游标独立维护（B 站 offset / 微博 since_id）----

    test('微博游标：首屏为 null，翻页时把上一页的 nextMaxId 传回去', () async {
      repo.weiboSideHasMore = true;
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();

      expect(
        container.read(timelineProvider).followingMaxId,
        'SINCE-1',
        reason: '微博侧游标要存回来',
      );

      await notifier.loadMore();

      expect(repo.requestedMaxIds, <String?>[null, 'SINCE-1']);
      expect(
        repo.requestedOffsets,
        <String?>[null, 'CURSOR-1'],
        reason: 'B 站游标与微博游标各走各的，不能串用',
      );
      expect(container.read(timelineProvider).followingMaxId, 'SINCE-2');
    });

    test('微博到底、B 站还有 → 继续用 B 站游标翻（微博侧传 null，不整页停住）', () async {
      // 微博侧首屏之后就没有下一页了。
      repo.weiboSideHasMore = false;
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();

      final afterFirst = container.read(timelineProvider);
      expect(afterFirst.followingMaxId, isNull);
      expect(afterFirst.followingHasMore, isTrue, reason: 'B 站还能翻');
      expect(afterFirst.canLoadMore, isTrue);

      await notifier.loadMore();

      expect(repo.followingCalls, 2);
      expect(repo.requestedOffsets.last, 'CURSOR-1');
      expect(repo.requestedMaxIds.last, isNull, reason: '微博侧已到底，不传游标');
      expect(container.read(timelineProvider).items.length, 40);
    });

    test('B 站到底、微博还有 → 仍能继续翻（只传微博游标）', () async {
      repo.biliSideEndsImmediately = true;
      repo.weiboSideHasMore = true;
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();

      final afterFirst = container.read(timelineProvider);
      expect(afterFirst.followingOffset, isNull);
      expect(afterFirst.followingMaxId, 'SINCE-1');
      expect(afterFirst.canLoadMore, isTrue, reason: '微博还能翻就不能停');

      await notifier.loadMore();

      expect(repo.followingCalls, 2);
      expect(repo.requestedOffsets.last, isNull, reason: 'B 站已到底，不传游标');
      expect(repo.requestedMaxIds.last, 'SINCE-1');
    });

    test('两侧都到底 → canLoadMore 为 false', () async {
      repo.weiboSideHasMore = false;
      repo.biliSideEndsImmediately = true;
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();

      final state = container.read(timelineProvider);
      expect(state.followingHasMore, isFalse);
      expect(state.canLoadMore, isFalse);
      expect(state.followingOffset, isNull);
      expect(state.followingMaxId, isNull);
    });
  });

  group('模式切换', () {
    test('首次切到精选订阅：还没有快照，列表只能重置', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      expect(container.read(timelineProvider).items.length, 20);

      await notifier.setMode(TimelineMode.selectedSubscriptions);

      final state = container.read(timelineProvider);
      expect(state.mode, TimelineMode.selectedSubscriptions);
      expect(state.items.length, repo.subscriptionItems);
      expect(state.followingOffset, isNull, reason: '游标必须清掉，否则会串页');
      expect(state.canLoadMore, isFalse);
      expect(repo.subscriptionCalls, 1);
      // 首次进入该模式没有任何可复用内容 → 请求发起那一刻列表确实是空的。
      expect(repo.itemsAtRequest.last, 0);
    });

    test('切回「全部关注」：用上一轮的快照秒回，不再闪空列表', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh(); // 全部关注：20 条，写进快照
      await notifier.setMode(TimelineMode.selectedSubscriptions);

      await notifier.setMode(TimelineMode.allFollowing);

      final state = container.read(timelineProvider);
      expect(state.mode, TimelineMode.allFollowing);
      expect(state.items.length, 20);
      expect(state.followingPage, 1);
      expect(repo.requestedOffsets.last, isNull, reason: '游标从零开始');
      // 「旧画面」修复的核心断言：切回去时**请求发起那一刻界面上已经有内容**
      // （来自该模式自己的快照），而不是「占位卡 + 迷你转圈」。
      expect(
        repo.itemsAtRequest.last,
        20,
        reason: '有快照时必须立刻有内容，不能再清空列表',
      );
    });

    test('切模式走缓存而不是强制刷新（force=false，否则又变成几秒空窗）', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      await notifier.setMode(TimelineMode.selectedSubscriptions);

      // 逐源聚合那次请求必须是「允许走缓存」的，否则切过去必然要真拉所有源。
      expect(repo.lastSubscriptionForceRefresh, isFalse);
    });

    test('精选订阅也记快照：第二次切回来立刻有内容', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      await notifier.setMode(TimelineMode.selectedSubscriptions); // 先拉一次，写快照
      await notifier.setMode(TimelineMode.allFollowing);

      repo.itemsAtRequest.clear();
      await notifier.setMode(TimelineMode.selectedSubscriptions);

      expect(
        repo.itemsAtRequest.last,
        repo.subscriptionItems,
        reason: '精选订阅自己的快照要能秒回',
      );
    });

    test('模式选择写入 Prefs（下次启动直接生效）', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.setMode(TimelineMode.selectedSubscriptions);
      expect(prefs.timelineMode, TimelineMode.selectedSubscriptions);

      await notifier.setMode(TimelineMode.allFollowing);
      expect(prefs.timelineMode, TimelineMode.allFollowing);
    });

    test('重复切到当前模式不重复请求', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      final before = repo.followingCalls;

      await notifier.setMode(TimelineMode.allFollowing);
      expect(repo.followingCalls, before);
    });
  });

  group('模式枚举', () {
    test('默认与解析', () {
      expect(TimelineMode.fromKey(null), TimelineMode.allFollowing);
      expect(TimelineMode.fromKey('oops'), TimelineMode.allFollowing);
      expect(
        TimelineMode.fromKey('selectedSubscriptions'),
        TimelineMode.selectedSubscriptions,
      );
    });

    test('只有全部关注是分页模式', () {
      expect(TimelineMode.allFollowing.isPaged, isTrue);
      expect(TimelineMode.selectedSubscriptions.isPaged, isFalse);
    });
  });
}
