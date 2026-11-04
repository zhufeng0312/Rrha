import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/models/timeline_mode.dart';
import 'package:rrha/data/repo/timeline_repo.dart';
import 'package:rrha/features/timeline/timeline_page.dart';
import 'package:rrha/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 时间线页面「外框」（除卡片内容之外的那几条小字）的回归测试。
///
/// 用户要求删掉的两句话（2026-10-22）：
/// 1. 列表上方「更新于 刚刚 · 117 条 · 6 个订阅源」—— 由 `_UpdatedBar` 渲染；
/// 2. 列表底部「B 站与微博内容均来自官方接口（需登录）」—— 由 `_DisclaimerBar`
///    渲染 `AppConfig.dataSourceDisclaimer`。
///
/// 为什么值得单独立测试而不是「删掉就完了」：
/// 这两条都不是「偶然出现」的文案，它们**各自背后有一段历史**——
/// 更新条曾是「分页到底了没」的用户可见证据，免责声明曾被一条防腐单测
/// 钉死「必须提到官方接口和登录」。所以将来任何一次「补回一点信息给用户」
/// 的改动，都很容易顺手把它们加回来，而且加了不会被任何测试发现。
/// 这组断言就是那道闸门：**时间线主界面上不许再出现这两类文字**。
class _FakeRepo extends TimelineRepository {
  _FakeRepo({required super.prefs});

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

  @override
  Future<TimelineFollowingResult> loadFollowing({
    String? offset,
    String? maxId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    final List<ContentItem> items = <ContentItem>[_item('f1'), _item('f2')];
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
      // 刻意给一个非 null 的时间：旧代码只有它非 null 才渲染「更新于 …」，
      // 若将来有人恢复那一行，这条测试会立刻失败。
      lastUpdated: DateTime.utc(2026, 10, 15),
    );
  }

  @override
  Future<TimelineResult> load({
    required List<Subscription> subscriptions,
    bool forceRefresh = false,
  }) async {
    final List<ContentItem> items = <ContentItem>[_item('s1'), _item('s2')];
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

void main() {
  late Prefs prefs;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await Prefs.create();
    container = ProviderContainer(
      overrides: <Override>[
        prefsProvider.overrideWithValue(prefs),
        timelineRepoProvider.overrideWithValue(_FakeRepo(prefs: prefs)),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TimelinePage()),
      ),
    );
    // `TimelinePage` 自己不发起首刷（那是 `HomeShell.initState` 的活）。
    await container.read(timelineProvider.notifier).refresh();
    await tester.pumpAndSettle();
  }

  group('时间线主界面不再显示这两条小字', () {
    testWidgets('不显示「更新于 …」条', (WidgetTester tester) async {
      await pumpPage(tester);

      // 前提：内容确实渲染出来了，否则「找不到更新条」也可能只是页面没内容。
      expect(find.textContaining('正文 f1'), findsOneWidget);

      // 旧实现的整行格式是 `更新于 {时间} · {N} 条 · …`，用前缀匹配覆盖全部变体
      // （humanize 会随时间变成「刚刚 / 5 分钟前 / 昨天」，不能写死时间）。
      expect(
        find.textContaining('更新于'),
        findsNothing,
        reason: '「更新于 刚刚 · N 条 · N 个订阅源」已按要求删除，不许再出现',
      );
      expect(find.textContaining('个订阅源'), findsNothing);
    });

    testWidgets('不显示底部数据来源声明', (WidgetTester tester) async {
      await pumpPage(tester);

      expect(find.textContaining('正文 f1'), findsOneWidget);

      expect(
        find.textContaining('官方接口'),
        findsNothing,
        reason: '「B 站与微博内容均来自官方接口（需登录）」已按要求删除',
      );
      expect(find.textContaining('需登录'), findsNothing);
    });

    testWidgets('模式切换条与列表仍然存在（删的只是小字，不是功能）',
        (WidgetTester tester) async {
      await pumpPage(tester);

      // 切换条是「全部关注 / 精选订阅」的入口，必须留着。
      expect(find.byType(SegmentedButton<TimelineMode>), findsOneWidget);
      expect(find.text('全部关注'), findsOneWidget);
      expect(find.text('精选订阅'), findsOneWidget);

      // 列表本身也在。
      expect(find.byType(ListView), findsOneWidget);
    });
  });
}
