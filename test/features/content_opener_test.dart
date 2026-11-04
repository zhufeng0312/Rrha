import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/video_ref.dart';
import 'package:rrha/features/timeline/content_detail_page.dart';
import 'package:rrha/features/timeline/content_opener.dart';
import 'package:rrha/features/player/player_page.dart';
import 'package:rrha/features/player/simple_video_page.dart';

/// 「点开一条内容」的分发规则（真机缺陷回归）。
///
/// 用户原话：「转发的视频无法打开，点击视频封面只显示一张照片，还不显示评论」。
///
/// 根因是分发逻辑写了**两份且规则不一致**：
/// - 时间线整卡点击 → B 站 + bvid → `PlayerPage`（能播、有 aid 评论区）；
/// - 卡片里的原动态块 → **一律** `ContentDetailPage`（只渲染封面大图，
///   原动态又拿不到 `commentOid`，于是落进「没有评论入口」兜底）。
///
/// 修法是把规则收敛到 [ContentOpener]，这里钉住它的判定。
ContentItem _item({
  Platform platform = Platform.bilibili,
  ContentKind kind = ContentKind.video,
  String? bvid,
  int? aid,
  String? directVideoUrl,
  List<String> images = const <String>[],
}) =>
    ContentItem(
      id: 'x1',
      platform: platform,
      kind: kind,
      sourceId: '${platform.key}:1',
      authorName: '作者',
      title: '标题',
      summary: '',
      images: images,
      link: 'https://example.com/x1',
      videoRef: (bvid == null && aid == null && directVideoUrl == null)
          ? null
          : VideoRef(bvid: bvid, aid: aid, directVideoUrl: directVideoUrl),
      publishedAt: DateTime.now().toUtc(),
      fetchedAt: DateTime.now().toUtc(),
    );

void main() {
  group('opensInPlayer 判定', () {
    test('B 站 + 有 bvid → 进播放页', () {
      expect(
        ContentOpener.opensInPlayer(_item(bvid: 'BV1xx411c7mD', aid: 1)),
        isTrue,
      );
    });

    test('B 站 + 只有 aid 没有 bvid → 详情页', () {
      // PlayerPage 的构造要求 bvid 非空，只有 aid 进不去。
      expect(ContentOpener.opensInPlayer(_item(aid: 170001)), isFalse);
    });

    test('B 站图文动态（无 videoRef）→ 详情页', () {
      expect(
        ContentOpener.opensInPlayer(_item(kind: ContentKind.dynamic)),
        isFalse,
      );
    });

    test('微博视频即使有直链也不进 PlayerPage', () {
      // PlayerPage 只认 bvid/aid，微博直链进不去。
      // 微博走 ContentDetailPage 的「尝试播放」分支才是诚实的降级。
      expect(
        ContentOpener.opensInPlayer(
          _item(
            platform: Platform.weibo,
            directVideoUrl: 'https://f.video.weibocdn.com/x.mp4',
          ),
        ),
        isFalse,
      );
    });

    test('bvid 是空串也当没有（脏数据不能骗过判定）', () {
      expect(ContentOpener.opensInPlayer(_item(bvid: '')), isFalse);
    });

    test('kind 是 repost 但带 bvid → 仍然进播放页', () {
      // 判定刻意不看 kind：解析层对「转发了一条视频」可能给 repost，
      // 但只要带着 bvid，播放页就是正确去处。
      expect(
        ContentOpener.opensInPlayer(
          _item(kind: ContentKind.repost, bvid: 'BV1xx411c7mD'),
        ),
        isTrue,
      );
    });
  });

  group('open 实际路由', () {
    Future<void> pumpWithButton(
      WidgetTester tester,
      ContentItem item,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () => ContentOpener.open(context, item),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // ⚠️ 刻意**不做**「B 站视频真的打开播放页」的 widget 断言：
    // `PlayerPage` 一挂载就去请求 playurl，离线必然抛异常，
    // 而 flutter_test 会把那个异常记到当前测试上（与「分发到哪」无关）。
    // 分发规则本身已经由上面 `opensInPlayer` 的 6 条纯逻辑测试钉死，
    // 而 `open()` 是「判定 → 二选一 push」的两行，没有第三条分支。

    testWidgets('B 站图文 → 压入详情页', (WidgetTester tester) async {
      await pumpWithButton(tester, _item(kind: ContentKind.dynamic));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(ContentDetailPage), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
    });

    testWidgets('微博视频（有直链）→ 详情页（视频页内自动播，评论在下面）',
        (WidgetTester tester) async {
      // 2026-10-27 第二轮修订：上一轮曾让微博视频直接进全屏 SimpleVideoPage，
      // 真机反馈「进去只有视频，看不到评论、也做不了操作」。现在回到详情页：
      // 视频在页内自动播放（InlineVideoPlayer），评论就在它下面。
      await pumpWithButton(
        tester,
        _item(
          platform: Platform.weibo,
          directVideoUrl: 'https://f.video.weibocdn.com/x.mp4',
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(ContentDetailPage), findsOneWidget);
      expect(find.byType(SimpleVideoPage), findsNothing);
      expect(find.byType(PlayerPage), findsNothing);
    });

    testWidgets('微博视频（无直链）→ 仍进详情页（那里有诚实的兜底文案）',
        (WidgetTester tester) async {
      await pumpWithButton(
        tester,
        _item(platform: Platform.weibo, kind: ContentKind.video),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(ContentDetailPage), findsOneWidget);
      expect(find.byType(SimpleVideoPage), findsNothing);
    });

    testWidgets('headerLabel 只在落到详情页时生效', (WidgetTester tester) async {
      await pumpWithButton(tester, _item(kind: ContentKind.dynamic));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 不带 headerLabel 时标题没有「原动态」前缀。
      expect(find.textContaining('原动态 ·'), findsNothing);
    });
  });
}
