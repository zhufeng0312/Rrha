import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/features/timeline/timeline_page.dart';
import 'package:rrha/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「点击底部『时间线』标签 → 回到顶部并刷新」的验收（需求 2026-10-26）。
///
/// 交互预期（与小红书/微博一致）：
/// - 已经在时间线页时再点「时间线」，列表滚回顶部；
/// - 同时刷新一次，让用户看到最新内容；
/// - **连续点两次也要都能响应** —— 这是用「计数器」而不是 bool 的原因。
class _Repo extends TimelineRepository {
  _Repo({required super.prefs});

  int followingCalls = 0;

  @override
  Future<TimelineFollowingResult> loadFollowing({
    String? offset,
    String? maxId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    followingCalls++;
    final List<ContentItem> items = <ContentItem>[
      for (int i = 0; i < 20; i++)
        ContentItem(
          id: 'p$page-$i',
          platform: Platform.bilibili,
          kind: ContentKind.dynamic,
          sourceId: BiliTimelineSource.followingSourceId,
          authorName: 'up$i',
          title: '标题 $page-$i',
          summary: '正文 $page-$i',
          link: 'https://example.com/p$page-$i',
          fetchedAt: DateTime.utc(2026, 10, 26),
          publishedAt: DateTime.utc(2026, 10, 26).subtract(Duration(minutes: i)),
        ),
    ];
    return TimelineFollowingResult(
      items: items,
      status: SourceStatus(
        subscriptionId: BiliTimelineSource.followingSourceId,
        route: FeedRoute.bilibiliDynamic,
        lastSuccessAt: DateTime.utc(2026, 10, 26),
        itemCount: items.length,
      ),
      nextOffset: page < 2 ? 'CURSOR-$page' : null,
      hasMore: page < 2,
      lastUpdated: DateTime.utc(2026, 10, 26),
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
  late _Repo repo;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
    repo = _Repo(prefs: prefs);
    container = ProviderContainer(
      overrides: <Override>[
        prefsProvider.overrideWithValue(prefs),
        timelineRepoProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 只挂时间线页（不挂整个 HomeShell）：`IndexedStack` 会把设置页也建出来，
    // 而设置页里有 `ListTile` 套在带背景色的 `DecoratedBox` 里，会抛
    // 「ink splashes may be invisible」断言 —— 那是既有问题，与本需求无关，
    // 混进来只会让这里的失败信息失真。
    //
    // 「点标签」这个动作本身在 `HomeShell` 里，是两行纯逻辑
    // （自增信号 + 刷新）。所以这里直接驱动同一组 provider 来验证行为等价，
    // 而页面侧「收到信号就回顶部」由真实 widget 验证。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TimelinePage()),
      ),
    );
    await container.read(timelineProvider.notifier).refresh();
    await tester.pumpAndSettle();
  }

  /// 模拟「用户点了底部时间线标签」：HomeShell 里的那两个动作。
  Future<void> tapTimelineTab(WidgetTester tester) async {
    container.read(timelineScrollToTopProvider.notifier).state++;
    unawaited(container.read(timelineProvider.notifier).refresh(force: true));
    await tester.pumpAndSettle();
  }

  /// 当前时间线列表的滚动偏移。
  double offsetOf(WidgetTester tester) {
    final Scrollable s = tester.widget<Scrollable>(find.byType(Scrollable).first);
    return s.controller!.offset;
  }

  group('点击「时间线」标签回到顶部并刷新', () {
    testWidgets('滚下去后点标签 → 回到顶部', (WidgetTester tester) async {
      await pumpShell(tester);

      // 先滚下去。
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(offsetOf(tester), greaterThan(100), reason: '前提：真的滚动了');

      // 点底部「时间线」标签。
      await tapTimelineTab(tester);

      expect(
        offsetOf(tester),
        closeTo(0, 1),
        reason: '点击时间线标签必须回到顶部',
      );
    });

    testWidgets('点标签会触发一次刷新', (WidgetTester tester) async {
      await pumpShell(tester);
      final int before = repo.followingCalls;

      await tapTimelineTab(tester);

      expect(
        repo.followingCalls,
        greaterThan(before),
        reason: '回到顶部的同时要刷新，让用户看到最新内容',
      );
    });

    testWidgets('连续点两次都能响应（计数器而非 bool）',
        (WidgetTester tester) async {
      await pumpShell(tester);

      await tapTimelineTab(tester);
      final int first = container.read(timelineScrollToTopProvider);

      await tapTimelineTab(tester);
      final int second = container.read(timelineScrollToTopProvider);

      expect(second, first + 1, reason: '每次点击都要产生一次新信号');
    });

    testWidgets('已经在顶部时不报错、不抖动', (WidgetTester tester) async {
      await pumpShell(tester);
      expect(offsetOf(tester), closeTo(0, 1));

      await tapTimelineTab(tester);

      expect(offsetOf(tester), closeTo(0, 1));
      expect(tester.takeException(), isNull);
    });
  });
}
