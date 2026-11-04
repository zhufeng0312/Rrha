import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 真机缺陷的离线回归（2026-10-26）：
///
/// > 向下滚动时突然「断层」，只剩微博内容；继续滚 N 条后界面闪一下，
/// > 然后恢复正常，显示出刚刚跨过的 N 条混合内容。
///
/// 根因不是排序、也不是渲染，而是**把还没拉全的时间段先显示了**：
/// B 站一页只覆盖几小时，微博一页覆盖十几天，于是微博水位飞快走到一个月前，
/// 中间那一大段在内存里只有微博数据。
///
/// 修法是「显示下界」（见 `TimelineFloor`）：只显示**两侧都已完整**的区间。
/// 这组测试把它钉成三条可断言的性质：
/// 1. 任何时刻可见列表都严格按时间倒序；
/// 2. 任何时刻都不存在「同一时间窗内另一侧明明还有内容、却没被显示」；
/// 3. 翻页只追加在末尾 —— 已显示条目的相对位置不变（这就是「不闪」）。
class _PagingRepo extends TimelineRepository {
  _PagingRepo({required super.prefs});

  /// B 站一页 20 条、条间隔 1 小时 → 覆盖 19 小时。
  static const int biliHoursPerPage = 20;

  /// 微博一页 20 条、条间隔 13 小时 → 覆盖约 10 天。
  static const int weiboHoursPerItem = 13;

  /// 记录每次请求的页号。
  final List<int> pages = <int>[];

  @override
  Future<TimelineFollowingResult> loadFollowing({
    String? offset,
    String? maxId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    pages.add(page);

    final DateTime anchor = DateTime.utc(2026, 10, 26, 12);
    final List<ContentItem> bili = <ContentItem>[];
    final List<ContentItem> weibo = <ContentItem>[];

    // 首屏两个游标都是 null，但**两侧都要返回内容**（真实调用方在首页
    // 就是传 null null，由数据源自己从头拉第一页）。
    final bool wantBili = page == 1 || offset != null;
    final bool wantWeibo = page == 1 || maxId != null;

    if (wantBili) {
      // B 站：每页 20 条、逐页严格向更早推进（第 N 页整体比第 N-1 页更旧）。
      for (var i = 0; i < 20; i++) {
        final DateTime t = anchor.subtract(
          Duration(hours: (page - 1) * biliHoursPerPage + i),
        );
        bili.add(
          ContentItem(
            id: 'b$page-$i',
            platform: Platform.bilibili,
            kind: ContentKind.dynamic,
            sourceId: 'bilibili:1',
            authorName: 'up',
            title: 'b$page-$i',
            summary: '',
            link: 'https://t.bilibili.com/$i',
            fetchedAt: t,
            publishedAt: t,
          ),
        );
      }
    }

    if (wantWeibo) {
      // 微博：每页 20 条、逐页严格向更早推进，每页跨越约 10 天
      // （20 × 13h ≈ 10.8 天）—— 这正是「密度差一个数量级」的来源。
      for (var i = 0; i < 20; i++) {
        final DateTime t = anchor.subtract(
          Duration(
            hours: (page - 1) * 20 * weiboHoursPerItem + i * weiboHoursPerItem,
          ),
        );
        weibo.add(
          ContentItem(
            id: 'w$page-$i',
            platform: Platform.weibo,
            kind: ContentKind.dynamic,
            sourceId: 'weibo:1',
            authorName: 'wb',
            title: 'w$page-$i',
            summary: '',
            link: 'https://m.weibo.cn/detail/$i',
            fetchedAt: t,
            publishedAt: t,
          ),
        );
      }
    }

    final List<ContentItem> merged =
        TimelineRepository.mergeFollowing(bili, weibo);

    // 两侧各给 6 页，之后到底。
    const int maxPages = 6;
    final String? nextOffset = page < maxPages ? 'B-$page' : null;
    final String? nextMaxId = page < maxPages ? 'W-$page' : null;

    return TimelineFollowingResult(
      items: merged,
      status: SourceStatus(
        subscriptionId: 'bilibili:1',
        itemCount: bili.length,
      ),
      weiboStatus: SourceStatus(
        subscriptionId: 'weibo:1',
        itemCount: weibo.length,
      ),
      nextOffset: nextOffset,
      nextMaxId: nextMaxId,
      hasMore: nextOffset != null || nextMaxId != null,
      lastUpdated: DateTime.utc(2026, 10, 26, 12),
    );
  }

  @override
  Future<TimelineResult> load({
    required List<Subscription> subscriptions,
    bool forceRefresh = false,
  }) async =>
      const TimelineResult(items: <ContentItem>[], statuses: <String, SourceStatus>{});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  late _PagingRepo repo;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
    repo = _PagingRepo(prefs: prefs);
    container = ProviderContainer(
      overrides: <Override>[
        prefsProvider.overrideWithValue(prefs),
        timelineRepoProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
  });

  TimelineState readState() => container.read(timelineProvider);

  test('首屏就要扣住「另一侧还没拉全」的区间', () async {
    await container.read(timelineProvider.notifier).refresh();

    final s = readState();
    expect(s.displayFloor, isNotNull, reason: '首屏两侧覆盖期差异已经存在');
    expect(s.bufferedCount, greaterThan(0), reason: '微博那一页会超出 B 站覆盖期');

    // 关键：可见列表里最旧的一条，不能比 B 站水位更旧 ——
    // 否则就意味着「显示了 B 站还没拉到的时间段」。
    final DateTime oldestVisible = s.items.last.sortKey;
    expect(
      oldestVisible.isBefore(s.displayFloor!),
      isFalse,
      reason: '可见内容不得越过显示下界',
    );
  });

  test('可见列表任何时刻都严格按时间倒序（翻 5 页全程检查）', () async {
    final notifier = container.read(timelineProvider.notifier);
    await notifier.refresh();

    for (var i = 0; i < 5; i++) {
      final List<ContentItem> items = readState().items;
      for (var k = 1; k < items.length; k++) {
        expect(
          items[k - 1].sortKey.isBefore(items[k].sortKey),
          isFalse,
          reason: '第 $i 轮第 $k 条顺序错了：'
              '${items[k - 1].sortKey} 不该排在 ${items[k].sortKey} 前面',
        );
      }
      await notifier.loadMore();
    }
  });

  test('翻页只追加在末尾：已显示内容的相对位置永不改变（不会闪）', () async {
    final notifier = container.read(timelineProvider.notifier);
    await notifier.refresh();

    List<String> previous = readState().items.map((e) => e.id).toList();
    for (var round = 1; round <= 4; round++) {
      await notifier.loadMore();
      final List<String> current =
          readState().items.map((e) => e.id).toList();

      expect(
        current.length,
        greaterThanOrEqualTo(previous.length),
        reason: '第 $round 轮：可见条目不该变少（否则就是「凭空消失」）',
      );
      expect(
        current.sublist(0, previous.length),
        previous,
        reason: '第 $round 轮：已显示条目必须原样留在开头，'
            '只能往后追加 —— 这条成立就不会出现视口闪烁',
      );
      previous = current;
    }
  });

  test('不存在「另一侧还有内容却没显示」的区间', () async {
    final notifier = container.read(timelineProvider.notifier);
    await notifier.refresh();
    await notifier.loadMore();
    await notifier.loadMore();

    final s = readState();
    final List<ContentItem> visible = s.items;
    // 可见区间内的微博条目数：如果 floor 正确，这段区间里两侧数据都完整，
    // 微博该有就有（这里微博每 13 小时一条，区间内必然有若干条）。
    final int weiboVisible =
        visible.where((i) => i.platform == Platform.weibo).length;
    final int biliVisible =
        visible.where((i) => i.platform == Platform.bilibili).length;

    expect(biliVisible, greaterThan(0));
    expect(
      weiboVisible,
      greaterThan(0),
      reason: '可见区间两侧都完整，微博不该消失',
    );

    // 可见区间的最旧时间必须 >= floor，也就是两侧都已覆盖到那里。
    for (final ContentItem i in visible) {
      expect(
        i.sortKey.isBefore(s.displayFloor!),
        isFalse,
        reason: '${i.id} 越过了显示下界，它所在的时间窗另一侧还没拉全',
      );
    }
  });

  test('缓冲是预取：floor 推进后它们直接出现，不额外发请求', () async {
    final notifier = container.read(timelineProvider.notifier);
    await notifier.refresh();

    final int firstBuffered = readState().bufferedCount;
    expect(firstBuffered, greaterThan(0));

    final int callsAfterFirst = repo.pages.length;
    await notifier.loadMore();

    // 第二轮只多了一次请求（两侧各一页属于同一次 loadFollowing）。
    expect(
      repo.pages.length - callsAfterFirst,
      1,
      reason: '一次 loadMore 只发一次 loadFollowing',
    );
    // 缓冲里那些条目最终会进入可见列表（池只增不减）。
    expect(
      readState().allLoaded.length,
      greaterThanOrEqualTo(40),
      reason: '池里保存了所有已加载条目，包括被扣住的',
    );
  });

  test('可见条目永不重复（去重在池层面生效）', () async {
    final notifier = container.read(timelineProvider.notifier);
    await notifier.refresh();
    for (var i = 0; i < 4; i++) {
      await notifier.loadMore();
    }
    final List<String> ids = readState().items.map((e) => e.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}
