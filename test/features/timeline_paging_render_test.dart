import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/features/timeline/content_card.dart';
import 'package:rrha/features/timeline/timeline_page.dart';
import 'package:rrha/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 【时间线翻页渲染 BUG】的回归测试（真机 2026-10-26）。
///
/// 现象：
/// 1. 向下滚动一段时间后，列表「断层」—— **只剩微博内容，B 站内容消失**；
/// 2. 继续滚 N 条（一直是纯微博）；
/// 3. 界面**闪一下**，然后恢复，显示出刚跨过的 N 条混合内容。
///
/// 根因（已用测例复现，见 `_pruneKeys` 那段历史）：
/// 每张卡挂了 `GlobalKey`，又用 `_pruneKeys` 在长度超阈值时删掉
/// `currentContext == null` 的 key。`_keyFor(id)` 随后会为**同一个 id**
/// 再造一个新 `GlobalKey` —— 旧 Element 还在树上，新旧 key 争用同一条目，
/// 旧 Element 被整体丢弃重建。重建期间该条目短暂「消失」（断层），
/// 等下一帧布局完成又回来（闪烁）。
///
/// 这组测试从两个层面锁死：
/// - **数据层**：翻页合并后 B 站与微博都必须在，且严格倒序、无重复；
/// - **渲染层**：卡片 key 必须是 `ValueKey`（`GlobalKey` 会引发上述重建）。
class _PagingRepo extends TimelineRepository {
  _PagingRepo({required super.prefs});

  /// 第 1 页：2 条 B 站（较新）+ 2 条微博（较旧）。
  /// 第 2 页：2 条 B 站（比第 1 页的微博**新**、比第 1 页的 B 站旧）。
  ///
  /// 这正是真机的时间跨度错位：B 站每页跨度小、微博每页跨度大，
  /// 所以第 2 页的 B 站内容会「插到」第 1 页微博的**上面**。
  ContentItem _item(String id, Platform platform, int hour) => ContentItem(
        id: id,
        platform: platform,
        kind: ContentKind.dynamic,
        sourceId: platform == Platform.bilibili
            ? BiliTimelineSource.followingSourceId
            : 'weibo:friends',
        authorName: platform == Platform.bilibili ? 'up-$id' : '博主-$id',
        title: '标题 $id',
        summary: '正文 $id',
        link: 'https://example.com/$id',
        fetchedAt: DateTime.utc(2026, 10, 20),
        publishedAt: DateTime.utc(2026, 10, 20, hour),
      );

  @override
  Future<TimelineFollowingResult> loadFollowing({
    String? offset,
    String? maxId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    final List<ContentItem> items = page == 1
        ? <ContentItem>[
            _item('b1', Platform.bilibili, 20),
            _item('b2', Platform.bilibili, 18),
            _item('w1', Platform.weibo, 2),
            _item('w2', Platform.weibo, 1),
          ]
        : <ContentItem>[
            // 比 w1(2 点) 新，比 b2(18 点) 旧 → 必须插到中间。
            _item('b3', Platform.bilibili, 10),
            _item('b4', Platform.bilibili, 8),
          ];

    return TimelineFollowingResult(
      items: items,
      status: SourceStatus(
        subscriptionId: BiliTimelineSource.followingSourceId,
        route: FeedRoute.bilibiliDynamic,
        lastSuccessAt: DateTime.utc(2026, 10, 20),
        itemCount: items.length,
      ),
      nextOffset: page == 1 ? 'CURSOR-1' : null,
      nextMaxId: null,
      hasMore: page == 1,
      lastUpdated: DateTime.utc(2026, 10, 20),
    );
  }

  @override
  Future<TimelineResult> load({
    required List<Subscription> subscriptions,
    bool forceRefresh = false,
  }) async =>
      const TimelineResult(
        items: <ContentItem>[],
        statuses: <String, SourceStatus>{},
      );
}

void main() {
  late Prefs prefs;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
    container = ProviderContainer(
      overrides: <Override>[
        prefsProvider.overrideWithValue(prefs),
        timelineRepoProvider.overrideWithValue(_PagingRepo(prefs: prefs)),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TimelinePage()),
      ),
    );
    await container.read(timelineProvider.notifier).refresh();
    await tester.pumpAndSettle();
  }

  group('翻页后两个平台的内容都必须还在', () {
    test('翻页合并：B 站没有被微博「挤掉」，且插到了正确的时间位置', () async {
      final notifier = container.read(timelineProvider.notifier);
      await notifier.refresh();
      await notifier.loadMore();

      final List<ContentItem> items = container.read(timelineProvider).items;

      // 关键断言：4 条（2 B 站 + 2 微博）一条都不能少 —— 真机缺陷里
      // 「只剩微博」意味着这里的 B 站条目丢了。
      expect(items.map((ContentItem i) => i.id), <String>[
        'b1', 'b2', // 20 点、18 点
        'b3', 'b4', // 10 点、8 点  ← 第 2 页的 B 站，插在微博之前
        'w1', 'w2', // 2 点、1 点
      ]);

      final int biliCount =
          items.where((ContentItem i) => i.platform == Platform.bilibili).length;
      final int weiboCount =
          items.where((ContentItem i) => i.platform == Platform.weibo).length;
      expect(biliCount, 4, reason: 'B 站内容不许在翻页后消失');
      expect(weiboCount, 2);

      // 严格倒序。
      for (var i = 1; i < items.length; i++) {
        expect(
          items[i - 1].sortKey.isBefore(items[i].sortKey),
          isFalse,
          reason: '第 $i 条比前一条更新 → 时间线乱序',
        );
      }
    });

    testWidgets('翻页后两个平台的卡片都渲染出来（不是只剩微博）',
        (WidgetTester tester) async {
      await pumpPage(tester);
      await container.read(timelineProvider.notifier).loadMore();
      await tester.pumpAndSettle();

      // 滚动到能覆盖全部 6 条的位置，逐条确认都渲染了。
      final List<ContentItem> items = container.read(timelineProvider).items;
      expect(items, hasLength(6));

      final Set<String> rendered = <String>{};
      for (final ContentCard card in tester
          .widgetList<ContentCard>(find.byType(ContentCard))) {
        rendered.add(card.item.id);
      }
      // 首屏可能有条目在屏幕外未构建，这里只断言「至少 B 站与微博都有」。
      expect(
        rendered.any((String id) => id.startsWith('b')),
        isTrue,
        reason: 'B 站卡片必须出现（真机缺陷里它们消失了）',
      );
      expect(
        rendered.any((String id) => id.startsWith('w')),
        isTrue,
        reason: '微博卡片也要在',
      );
    });

    testWidgets('卡片 key 全是 ValueKey（无 GlobalKey 就不会触发重建断层）',
        (WidgetTester tester) async {
      await pumpPage(tester);
      await container.read(timelineProvider.notifier).loadMore();
      await tester.pumpAndSettle();

      for (final ContentCard card
          in tester.widgetList<ContentCard>(find.byType(ContentCard))) {
        expect(
          card.key,
          isA<ValueKey<String>>(),
          reason: '❌ GlobalKey 会在 key 实例被替换时重建 Element → 断层 + 闪烁',
        );
      }
    });

    testWidgets('连续翻两页不产生重复卡片（去重生效）',
        (WidgetTester tester) async {
      await pumpPage(tester);
      final notifier = container.read(timelineProvider.notifier);
      await notifier.loadMore();
      await notifier.loadMore(); // 第 2 页之后已无游标，这次是空操作
      await tester.pumpAndSettle();

      final List<ContentItem> items = container.read(timelineProvider).items;
      expect(items.map((ContentItem i) => i.id).toSet().length, items.length);
    });
  });
}
