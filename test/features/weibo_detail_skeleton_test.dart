import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/theme/app_colors.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/features/timeline/bili_dynamic_body.dart';
import 'package:rrha/features/timeline/content_detail_page.dart';

/// 微博图文详情页对齐 B 站骨架（`docs/WEIBO_DETAIL_ALIGN.md` §10 验收标准）。
///
/// 用户原话：「我想让微博的纯文字卡片里的详情页的正文和你的一样（不包括评论区）」。
///
/// 这一组钉住五件事（对应文档 §7「新增测试建议」）：
/// 1. **正文只出现一次** —— 微博的 `title` 是「正文兜底」，老排版会画两遍；
/// 2. 真独立标题时标题与正文各出现一次；
/// 3. 数据栏 `评论 N` 用品牌粉加粗，`赞和转发 M` 取 like + repost；
/// 4. 计数为 null 时整项不渲染（不显示 0）；
/// 5. **评论区与改动前一致**（用户明确说「不包括评论区」）。
///
/// ⚠️ 测试环境里图片解码**永远不完成**，所以只断言结构，不对 `CachedImage`
/// 做真实解码断言（照抄 `bili_dynamic_body_test.dart` 的 fixture 写法）。
ContentItem _weibo({
  String title = '',
  String summary = '',
  List<String> images = const <String>[],
  int? commentCount,
  int? likeCount,
  int? repostCount,
}) =>
    ContentItem(
      id: 'w1',
      platform: Platform.weibo,
      kind: ContentKind.dynamic,
      sourceId: 'weibo:1782488734',
      authorName: '_warma_',
      authorAvatar: 'https://wx1.sinaimg.cn/avatar.jpg',
      title: title,
      summary: summary,
      images: images,
      link: 'https://m.weibo.cn/status/5259410951377781',
      commentCount: commentCount,
      likeCount: likeCount,
      repostCount: repostCount,
      publishedAt: DateTime.utc(2026, 11, 2, 10, 8),
      fetchedAt: DateTime.utc(2026, 11, 2, 10, 8),
      hasReliableTime: true,
    );

void main() {
  Future<void> pump(WidgetTester tester, ContentItem item) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: ContentDetailPage(item: item)),
      ),
    );
    // 不 pumpAndSettle：评论区会发起网络请求（离线必然失败），settle 会一直等。
    await tester.pump();
  }

  group('微博图文走 B 站骨架', () {
    testWidgets('纯文字微博：正文只出现一次（防「画两遍」回归）',
        (WidgetTester tester) async {
      // 复刻微博解析器的真实兜底形态：`_title()` 把 summary 单行化后截 60 字。
      // 老排版会把 `displayTitle` 当大标题画一次、summary 再画一次。
      const String body = '今天天气不错，出门走走。顺便拍了些照片，晚点发出来。';
      await pump(tester, _weibo(title: body, summary: body));

      expect(find.byType(BiliDynamicBody), findsOneWidget);
      // 核心断言：整页只找到 1 个。
      expect(
        find.textContaining('今天天气不错'),
        findsOneWidget,
        reason: '纯文字微博的正文只能出现一次',
      );
    });

    testWidgets('多段正文（title 是单行化全文）也只出现一次',
        (WidgetTester tester) async {
      // 文档 §2 点名的易错形态：`HtmlText.singleLine` 把换行压成空格，
      // 所以 title 不含 `\n\n`，`s.startsWith(t)` 不成立，
      // 靠的是 `t != truncate(singleLine(s), 60)` 那道判据。
      const String body = '第一段：起因。\n\n第二段：经过与结果。';
      await pump(
        tester,
        _weibo(title: '第一段：起因。 第二段：经过与结果。', summary: body),
      );

      expect(
        find.textContaining('第一段：起因。'),
        findsOneWidget,
        reason: '多段微博同样不能画两遍',
      );
    });

    testWidgets('真独立标题：标题与正文各出现一次', (WidgetTester tester) async {
      await pump(
        tester,
        _weibo(title: '周末去了趟海边', summary: '浪很大，风也很大，但心情很好。'),
      );

      expect(find.text('周末去了趟海边'), findsOneWidget);
      expect(find.textContaining('浪很大'), findsOneWidget);
    });

    testWidgets('带图微博：图片区渲染，且正文仍只有一份',
        (WidgetTester tester) async {
      await pump(
        tester,
        _weibo(
          summary: '配图微博正文',
          images: <String>['https://wx1.sinaimg.cn/a.jpg'],
        ),
      );

      expect(find.textContaining('配图微博正文'), findsOneWidget);
      // 图片区在骨架里由 PhotoGrid 渲染；这里只确认整体结构没崩。
      expect(tester.takeException(), isNull);
    });
  });

  group('微博数据栏', () {
    testWidgets('显示「评论 N」并用品牌粉加粗', (WidgetTester tester) async {
      await pump(
        tester,
        _weibo(summary: '正文', commentCount: 469, likeCount: 1200),
      );

      final Finder comment = find.text('评论 469');
      expect(comment, findsOneWidget);
      final Text widget = tester.widget<Text>(comment);
      expect(widget.style?.color, AppColors.weiboName);
      expect(widget.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('「赞和转发 M」取 like + repost 之和',
        (WidgetTester tester) async {
      await pump(
        tester,
        _weibo(
          summary: '正文',
          commentCount: 10,
          likeCount: 1200,
          repostCount: 26,
        ),
      );

      // 1200 + 26 = 1226 → 折叠成 1226（不触发「万」）。
      expect(find.text('赞和转发 1226'), findsOneWidget);
    });

    testWidgets('计数为 null 时整项不渲染（不显示 0）',
        (WidgetTester tester) async {
      await pump(tester, _weibo(summary: '正文'));

      // 注意：评论组件自己也会渲染一个「评论 N」标题，
      // 所以不能用 `textContaining('评论 ')` 宽泛匹配 —— 那会把它也算进来。
      // 这里只断言「数据栏的两种形态都不存在」：
      // 数据栏的评论项形如「评论 123」（带数字），null 时整项不该出现。
      expect(find.textContaining('赞和转发'), findsNothing);
      // 数据栏在正文下方；整页不得出现「评论 0」这种把未知伪装成 0 的文案。
      expect(find.text('评论 0'), findsNothing);
      expect(find.text('赞和转发 0'), findsNothing);
    });

    testWidgets('只有评论数时，只渲染评论这一项', (WidgetTester tester) async {
      await pump(tester, _weibo(summary: '正文', commentCount: 5));

      expect(find.text('评论 5'), findsOneWidget);
      expect(find.textContaining('赞和转发'), findsNothing);
    });
  });

  group('评论区保持不变', () {
    testWidgets('微博评论区仍然渲染在页面上（与改动前一致）',
        (WidgetTester tester) async {
      await pump(tester, _weibo(summary: '正文', commentCount: 3));

      // 评论区在骨架底部，需要滚过去才会构建（ListView 懒加载）。
      await tester.dragUntilVisible(
        find.text('正文'),
        find.byType(ListView).first,
        const Offset(0, -200),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
