import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/theme/app_colors.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/video_ref.dart';
import 'package:rrha/features/timeline/content_card.dart';
import 'package:rrha/widgets/cached_image.dart';
import 'package:rrha/widgets/content_media.dart';
import 'package:rrha/widgets/quoted_origin.dart';

/// 转发动态卡片里的「原动态嵌套区块」离线验收。
///
/// 需求（用户给的 `转发动态卡片.html`）：
/// - 被转发的原动态画在卡片内部一个**灰色嵌套块**里；
/// - 图文 → 按 1 图全宽 / 2 图两列 / 多图九宫格渲染；
/// - 视频 → 16:9 缩略图 + 右下角播放按钮角标；
/// - **整块**可点 → 把数据源换成原动态、压一个新路由。
///
/// 这里只断言可离线验证的结构，不联网：图片一律走 `errorBuilder`。
ContentItem _item({
  String id = 'fwd1',
  Platform platform = Platform.bilibili,
  ContentKind kind = ContentKind.repost,
  String authorName = '转发者',
  String title = '转发者的标题',
  String summary = '转发者的话',
  List<String> images = const <String>[],
  ContentItem? origin,
}) =>
    ContentItem(
      id: id,
      platform: platform,
      kind: kind,
      sourceId: '${platform.key}:1',
      authorName: authorName,
      title: title,
      summary: summary,
      images: images,
      link: 'https://example.com/$id',
      origin: origin,
      publishedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
      fetchedAt: DateTime.now().toUtc(),
    );

/// 被转发的原动态。
ContentItem _origin({
  String id = 'orig1',
  Platform platform = Platform.bilibili,
  ContentKind kind = ContentKind.dynamic,
  String authorName = '原博主',
  String title = '',
  String summary = '原动态的正文',
  List<String> images = const <String>[],
  VideoRef? videoRef,
}) =>
    ContentItem(
      id: id,
      platform: platform,
      kind: kind,
      sourceId: '${platform.key}:1',
      authorName: authorName,
      title: title,
      summary: summary,
      images: images,
      link: 'https://example.com/$id',
      videoRef: videoRef,
      publishedAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      fetchedAt: DateTime.now().toUtc(),
    );

void main() {
  Future<void> pumpCard(WidgetTester tester, ContentItem item) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: AppColors.page,
          body: SingleChildScrollView(
            child: SizedBox(
              width: 359,
              child: ContentCard(item: item, onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('嵌套区块的存在与结构', () {
    testWidgets('转发动态有 origin 时渲染 QuotedOrigin', (WidgetTester tester) async {
      await pumpCard(tester, _item(origin: _origin()));
      expect(find.byType(QuotedOrigin), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('普通动态（无 origin）不渲染嵌套区块', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(kind: ContentKind.dynamic, summary: '普通动态', origin: null),
      );
      expect(find.byType(QuotedOrigin), findsNothing);
    });

    testWidgets('微博「转发了一条视频」——kind 是 video 但带 origin，也必须渲染',
        (WidgetTester tester) async {
      // 微博解析层的形态优先级是「视频 > 转发」，所以这种条目 kind==video。
      // 只按 kind==repost 判会把它漏掉。
      await pumpCard(
        tester,
        _item(
          platform: Platform.weibo,
          kind: ContentKind.video,
          origin: _origin(platform: Platform.weibo),
        ),
      );
      expect(
        find.byType(QuotedOrigin),
        findsOneWidget,
        reason: 'kind 不是 repost 但带 origin，仍需渲染原动态块',
      );
    });

    testWidgets('灰底是 AppColors.nested（和卡片白底、页面底色都区分得开）',
        (WidgetTester tester) async {
      await pumpCard(tester, _item(origin: _origin()));
      final Material nested = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(QuotedOrigin),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(nested.color, AppColors.nested);
      expect(nested.color, isNot(AppColors.card));
      expect(nested.color, isNot(AppColors.page));
      expect(nested.borderRadius, BorderRadius.circular(QuotedOrigin.radius));
    });

    testWidgets('显示原博主昵称，且用 @ 前缀', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(origin: _origin(authorName: '朝陇山播报站')),
      );
      expect(find.text('@朝陇山播报站'), findsOneWidget);
      // 转发者与原博主是两个不同的名字，不能互相覆盖。
      expect(find.text('转发者'), findsOneWidget);
    });

    testWidgets('原动态没有昵称时不画一个空的 @', (WidgetTester tester) async {
      await pumpCard(tester, _item(origin: _origin(authorName: '')));
      expect(find.text('@'), findsNothing);
      expect(find.textContaining('原动态作者'), findsOneWidget);
    });

    testWidgets('原动态正文优先 summary，为空退回 title', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(title: '只有标题的原动态', summary: ''),
        ),
      );
      expect(find.text('只有标题的原动态'), findsOneWidget);
    });

    testWidgets('原动态正文最多 3 行 + 省略号（不能把卡片顶穿）',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(origin: _origin(summary: '很长的原动态正文' * 30)),
      );
      final Text body = tester.widget<Text>(
        find.text('很长的原动态正文' * 30),
      );
      expect(body.maxLines, 3);
      expect(body.overflow, TextOverflow.ellipsis);
    });
  });

  group('图文：九宫格规则与卡片媒体区一致', () {
    testWidgets('1 张图 → 全宽 16:9', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(images: <String>['https://i0.hdslb.com/a.jpg']),
        ),
      );
      final Finder ratio = find.descendant(
        of: find.byType(QuotedOrigin),
        matching: find.byType(AspectRatio),
      );
      expect(ratio, findsOneWidget);
      final Size size = tester.getSize(ratio);
      expect(
        size.width / size.height,
        moreOrLessEquals(16 / 9, epsilon: 0.01),
      );
    });

    testWidgets('2 张图 → 两列同一行', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(images: <String>[
            'https://i0.hdslb.com/a.jpg',
            'https://i0.hdslb.com/b.jpg',
          ]),
        ),
      );
      final Finder imgs = find.descendant(
        of: find.byType(QuotedOrigin),
        matching: find.byType(Image),
      );
      expect(imgs, findsNWidgets(2));
      final Offset p0 = tester.getTopLeft(imgs.at(0));
      final Offset p1 = tester.getTopLeft(imgs.at(1));
      expect(p1.dy, p0.dy, reason: '两张同一行 → 两列');
      expect(p1.dx, greaterThan(p0.dx));
    });

    testWidgets('4 张图 → 三列（3 + 1 换行），复用 ContentMedia',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(images: <String>[
            for (int i = 0; i < 4; i++) 'https://i0.hdslb.com/$i.jpg',
          ]),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(QuotedOrigin),
          matching: find.byType(ContentMedia),
        ),
        findsOneWidget,
        reason: '图文分支必须复用 ContentMedia，不要另写一套列数规则',
      );

      final Finder imgs = find.descendant(
        of: find.byType(QuotedOrigin),
        matching: find.byType(Image),
      );
      final List<Offset> pos = <Offset>[
        for (int i = 0; i < 4; i++) tester.getTopLeft(imgs.at(i)),
      ];
      expect(pos[1].dy, pos[0].dy);
      expect(pos[2].dy, pos[0].dy, reason: '前三张同一行 → 三列');
      expect(pos[3].dy, greaterThan(pos[0].dy), reason: '第 4 张换行');
    });

    testWidgets('原动态无图时不渲染媒体区（不留空）', (WidgetTester tester) async {
      await pumpCard(tester, _item(origin: _origin(images: const <String>[])));
      expect(
        find.descendant(
          of: find.byType(QuotedOrigin),
          matching: find.byType(ContentMedia),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(QuotedOrigin),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
    });
  });

  group('视频：16:9 封面 + 右下角播放角标', () {
    testWidgets('视频原动态渲染 16:9，不渲染九宫格', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(
            kind: ContentKind.video,
            images: <String>['https://i0.hdslb.com/cover.jpg'],
          ),
        ),
      );

      final Finder ratio = find.descendant(
        of: find.byType(QuotedOrigin),
        matching: find.byType(AspectRatio),
      );
      expect(ratio, findsOneWidget);
      final Size size = tester.getSize(ratio);
      expect(
        size.width / size.height,
        moreOrLessEquals(16 / 9, epsilon: 0.01),
      );

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      expect(
        find.descendant(
          of: find.byType(QuotedOrigin),
          matching: find.byType(ContentMedia),
        ),
        findsNothing,
        reason: '视频分支不能走九宫格',
      );
    });

    testWidgets('播放角标在右下角，不是居中', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(
            kind: ContentKind.video,
            images: <String>['https://i0.hdslb.com/cover.jpg'],
          ),
        ),
      );

      final Rect cover = tester.getRect(
        find.descendant(
          of: find.byType(QuotedOrigin),
          matching: find.byType(AspectRatio),
        ),
      );
      final Offset badge =
          tester.getCenter(find.byIcon(Icons.play_arrow_rounded));

      expect(badge.dx, greaterThan(cover.center.dx), reason: '偏右');
      expect(badge.dy, greaterThan(cover.center.dy), reason: '偏下');
      expect(badge.dx, lessThan(cover.right));
      expect(badge.dy, lessThan(cover.bottom));
    });

    testWidgets('视频没有封面时仍然占住 16:9（不塌成 0 高度）',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(
            kind: ContentKind.video,
            images: const <String>[],
          ),
        ),
      );
      final Size size = tester.getSize(
        find.descendant(
          of: find.byType(QuotedOrigin),
          matching: find.byType(AspectRatio),
        ),
      );
      expect(size.height, greaterThan(50));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('视频封面缺失时回落到 videoRef.coverUrl', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(
            kind: ContentKind.video,
            images: const <String>[],
            videoRef: const VideoRef(
              bvid: 'BV1xx411c7mD',
              coverUrl: 'https://i0.hdslb.com/ref-cover.jpg',
            ),
          ),
        ),
      );
      final Finder cached = find.descendant(
        of: find.byType(QuotedOrigin),
        matching: find.byType(CachedImage),
      );
      expect(cached, findsWidgets);
      expect(tester.widget<CachedImage>(cached.first).url,
          'https://i0.hdslb.com/ref-cover.jpg');
    });
  });

  group('点击：整块换数据源并压新路由', () {
    testWidgets('点正文区域 → 打开原动态详情页（标题带「原动态」）',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(origin: _origin(authorName: '原博主')),
      );

      await tester.tap(find.text('原动态的正文'));
      await tester.pumpAndSettle();

      // 新路由压栈：原动态的作者出现在详情页里。
      expect(find.text('原博主'), findsWidgets);
      expect(find.textContaining('原动态'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点九宫格里的图 → 也是打开原动态页（不是看大图）',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          origin: _origin(images: <String>[
            'https://i0.hdslb.com/a.jpg',
            'https://i0.hdslb.com/b.jpg',
          ]),
        ),
      );

      final Finder cell = find.descendant(
        of: find.byType(QuotedOrigin),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(cell.first);
      await tester.pumpAndSettle();

      // 相册页有 close 按钮；详情页没有。据此区分走了哪条分支。
      expect(find.byIcon(Icons.close_rounded), findsNothing,
          reason: '整块灰区是同一个动作，不该弹相册');
      expect(find.textContaining('原动态'), findsWidgets);
    });

    testWidgets('点嵌套块不会触发整卡的 onTap（两个动作不能互相串）',
        (WidgetTester tester) async {
      var cardTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 359,
                child: ContentCard(
                  item: _item(origin: _origin()),
                  onTap: () => cardTapped = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('原动态的正文'));
      await tester.pumpAndSettle();

      expect(
        cardTapped,
        isFalse,
        reason: '点原动态块要开原动态页，不是开转发者自己的详情页',
      );
    });
  });
}
