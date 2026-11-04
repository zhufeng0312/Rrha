import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/models/timeline_mode.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/features/timeline/content_card.dart';
import 'package:rrha/features/timeline/timeline_page.dart';
import 'package:rrha/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 每个模式给的条目数：必须能填满并**超出**一屏，否则列表根本滚不动，
/// 「滚动位置互不影响」就无从验证。
const int _perPage = 20;

ContentItem _item(String id) => ContentItem(
      id: id,
      platform: Platform.bilibili,
      kind: ContentKind.dynamic,
      sourceId: BiliTimelineSource.followingSourceId,
      authorName: 'up-$id',
      title: '标题 $id',
      summary: '正文 $id',
      link: 'https://t.bilibili.com/$id',
      fetchedAt: DateTime.utc(2026, 10, 15),
      publishedAt: DateTime.utc(2026, 10, 15),
    );

/// 两个模式都返回足够多的条目，并且**都没有下一页**（滚到底不会触发 loadMore，
/// 避免把「滚动」和「翻页」两个变量混在一起）。
class _FakeRepo extends TimelineRepository {
  _FakeRepo({required super.prefs});

  @override
  Future<TimelineFollowingResult> loadFollowing({
    String? offset,
    String? maxId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    final List<ContentItem> items = <ContentItem>[
      for (int i = 0; i < _perPage; i++) _item('f$page-$i'),
    ];
    return TimelineFollowingResult(
      items: items,
      status: SourceStatus(
        subscriptionId: BiliTimelineSource.followingSourceId,
        route: FeedRoute.bilibiliDynamic,
        lastSuccessAt: DateTime.utc(2026, 10, 15),
        itemCount: items.length,
      ),
      nextOffset: null,
      hasMore: false,
      lastUpdated: DateTime.utc(2026, 10, 15),
    );
  }

  @override
  Future<TimelineResult> load({
    required List<Subscription> subscriptions,
    bool forceRefresh = false,
  }) async {
    final List<ContentItem> items = <ContentItem>[
      for (int i = 0; i < _perPage; i++) _item('s$i'),
    ];
    return TimelineResult(
      items: items,
      statuses: <String, SourceStatus>{
        'bilibili:2267573#bilibiliVideo': SourceStatus(
          subscriptionId: 'bilibili:2267573',
          itemCount: items.length,
        ),
      },
      lastUpdated: DateTime.utc(2026, 10, 15),
    );
  }
}

/// 时间线**滚动位置隔离**的离线验收。
///
/// 缺陷现象（真机）：「全部关注」翻到一半切「精选订阅」，新列表直接停在
/// 同样的位置；反过来也一样 —— 两个模式的滚动**互相影响**。
///
/// 根因：`ListView` 竖直方向默认 `primary: true`，会去认领所在 Route 的
/// `PrimaryScrollController`；两种模式共用同一个 `ScrollPosition`，
/// 新列表一挂上去就继承了旧偏移。
///
/// 这组测试的价值：它是**唯一**能自动发现「controller 被删掉/改成 primary」
/// 的地方 —— 页面本身不渲染任何可断言的文字差异，只有滚动偏移能暴露问题。
void main() {
  late Prefs prefs;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
    container = ProviderContainer(
      overrides: <Override>[
        prefsProvider.overrideWithValue(prefs),
        timelineRepoProvider.overrideWithValue(
          _FakeRepo(
                  prefs: prefs,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 屏幕给高一点，让 20 张卡确实超出可视区。
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TimelinePage()),
      ),
    );

    // `TimelinePage` 自己不发起首次刷新（那是 `HomeShell.initState` 的活），
    // 所以这里必须手动刷一次，否则页面一直是空态、列表根本不存在。
    await container.read(timelineProvider.notifier).refresh();
    await tester.pumpAndSettle();
  }

  /// 当前列表的滚动偏移。
  double offsetOf(WidgetTester tester) {
    final Scrollable scrollable = tester.widget<Scrollable>(
      find.byType(Scrollable).last,
    );
    return scrollable.controller!.offset;
  }

  group('两种模式的滚动位置互不影响', () {
    testWidgets('全部关注滚下去后切精选订阅，新列表从顶部开始', (WidgetTester tester) async {
      await pumpPage(tester);

      // 1) 全部关注：滚到明显不是 0 的位置。
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -600));
      await tester.pumpAndSettle();
      final double followingOffset = offsetOf(tester);
      expect(
        followingOffset,
        greaterThan(100),
        reason: '前提：列表真的滚动了，否则这条测试证明不了什么',
      );

      // 2) 切到精选订阅。
      await container
          .read(timelineProvider.notifier)
          .setMode(TimelineMode.selectedSubscriptions);
      await tester.pumpAndSettle();

      expect(
        container.read(timelineProvider).mode,
        TimelineMode.selectedSubscriptions,
      );
      expect(
        offsetOf(tester),
        0,
        reason: '精选订阅是首次进入，必须从顶部开始，不能继承全部关注的偏移',
      );
    });

    testWidgets('精选订阅滚下去后切回全部关注，各自恢复自己的位置', (WidgetTester tester) async {
      await pumpPage(tester);

      // 全部关注：滚到某个位置并记住它。
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -500));
      await tester.pumpAndSettle();
      final double followingPos = offsetOf(tester);
      expect(followingPos, greaterThan(50));

      // 切到精选订阅并滚到另一个位置。
      await container
          .read(timelineProvider.notifier)
          .setMode(TimelineMode.selectedSubscriptions);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
      await tester.pumpAndSettle();
      final double selectedPos = offsetOf(tester);
      expect(
        selectedPos,
        greaterThan(0),
        reason: '前提：精选订阅也真的滚动了',
      );
      expect(
        selectedPos,
        isNot(closeTo(followingPos, 1)),
        reason: '两个位置必须不同，否则后面的断言没有区分力',
      );

      // 切回全部关注：应回到它自己记住的位置，而不是精选订阅那个。
      await container
          .read(timelineProvider.notifier)
          .setMode(TimelineMode.allFollowing);
      await tester.pumpAndSettle();

      expect(
        offsetOf(tester),
        closeTo(followingPos, 1),
        reason: '切回来要回到全部关注自己的位置，不受精选订阅滚动影响',
      );
    });

    testWidgets('列表自带 controller，且 key 随模式变化', (WidgetTester tester) async {
      await pumpPage(tester);

      // 这条断言直击根因：一旦有人把 `controller:` 删掉，列表就会重新挂到
      // 共享的 PrimaryScrollController 上，两个模式又会互相影响。
      final Scrollable list = tester.widget<Scrollable>(
        find.byType(Scrollable).last,
      );
      expect(
        list.controller,
        isNotNull,
        reason: '时间线列表必须自带 controller（不能依赖 primary 的共享实例）',
      );

      // key 也必须随模式变：只给 controller 而让 Element 复用，
      // 旧 position 仍会残留到新列表上（尤其是 offset 以外的状态）。
      final String followingKey = _listKeyOf(tester);
      await container
          .read(timelineProvider.notifier)
          .setMode(TimelineMode.selectedSubscriptions);
      await tester.pumpAndSettle();
      expect(
        _listKeyOf(tester),
        isNot(followingKey),
        reason: '切换模式时列表的 key 必须变化，强制重建 Scrollable',
      );
    });

    testWidgets('卡片只能用 ValueKey，不能用 GlobalKey（翻页断层/闪烁的根因）',
        (WidgetTester tester) async {
      await pumpPage(tester);

      // 真机缺陷（2026-10-26）：向下滚动时列表「断层」、只剩微博内容，
      // 继续滚 N 条后闪一下才恢复。
      //
      // 根因：早先给每张卡挂 `GlobalKey`（id → key）并用 `_pruneKeys` 清理。
      // 清理后 `_keyFor(id)` 会为同一 id **再造一个新 GlobalKey**，而旧 Element
      // 还在树上 —— 新旧 key 争用同一条目，旧 Element 被整个丢弃重建，
      // 表现为断层 + 闪烁。
      //
      // 所以这条测试锁死：卡片 key 必须是 ValueKey（不参与 Element 搬家）。
      final Finder card = find.byType(ContentCard).first;
      final ContentCard widget = tester.widget<ContentCard>(card);
      expect(widget.key, isNotNull, reason: '卡片仍要带 key（锚点/复用都要靠它）');
      expect(
        widget.key,
        isA<ValueKey<String>>(),
        reason: '❌ 绝不能用 GlobalKey：key 实例被替换会导致 Element 重建 → 断层闪烁',
      );
      expect(
        (widget.key! as ValueKey<String>).value,
        widget.item.id,
        reason: 'key 必须是条目 id（跨页稳定），用下标会在插入后失效',
      );
    });

    testWidgets('列表不再依赖 findChildIndexCallback（它不补偿偏移）',
        (WidgetTester tester) async {
      await pumpPage(tester);

      // 上一轮曾加过这个回调想修「翻页跳回」，实测无效（插入 5 条后 offset
      // 停在原值）。它还逼着卡片挂 GlobalKey，间接造成了断层缺陷。
      // 视口锚定改由 `_captureAnchor`/`_restoreAnchor` 从 sliver 读几何完成，
      // 这里锁死「回调已移除」，防止它被误加回来。
      final ListView list = tester.widget<ListView>(find.byType(ListView).last);
      final SliverChildBuilderDelegate delegate =
          list.childrenDelegate as SliverChildBuilderDelegate;
      expect(
        delegate.findChildIndexCallback,
        isNull,
        reason: '这个回调不修视口跳动，却会逼出 GlobalKey，别再启用',
      );
    });
  });
}

/// 取出时间线列表的 key（用来验证它随模式变化）。
String _listKeyOf(WidgetTester tester) {
  // `ListView.separated` 返回的是 `ListView` 本身，key 挂在它上面。
  final ListView list = tester.widget<ListView>(find.byType(ListView).last);
  return '${list.key}';
}
