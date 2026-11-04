import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/theme/app_colors.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/video_ref.dart';
import 'package:rrha/features/player/inline_video_player.dart';
import 'package:rrha/features/timeline/bili_dynamic_body.dart';
import 'package:rrha/features/timeline/content_detail_page.dart';

/// 纯文字动态详情页：**内容只出现一次**。
///
/// ## 这次修的真机缺陷
///
/// 用户截图：一条纯文字动态，正文在页面上**出现了两次**
/// （一次当大标题、一次当正文），并明确指出
/// 「纯文字动态你还是没有按照提供的 html 文件来做」。
///
/// 根因不在排版，而在**兜底标题**：
/// `BiliContentParser._fromDynamic` 在动态没有标题时把 `title` 兜底成
/// 「正文首行截 60 字」（`effectiveTitle`）。老 `ContentDetailPage` 无条件把
/// `item.displayTitle` 当大标题画一遍，又把 `summary` 整段画一遍 ——
/// 同一句话于是占了两个位置。
///
/// 这一组测试钉住三件事：
/// 1. 兜底标题**不**作为标题渲染（正文只出现一次）；
/// 2. 真正的独立标题仍然渲染（专栏/抽奖这类不能因为修 bug 而丢标题）；
/// 3. 纯文字动态按参考稿 `page-detail-text` 的字号/配色来（16px / 非粉色昵称），
///    带图动态按 `page-detail-image`（15px / 粉色昵称）。
ContentItem _dynamic({
  String title = '',
  String summary = '今日は今から配信する！\n\n昨日も告知したけど3日早朝から用事がある',
  List<String> images = const <String>[],
  ContentKind kind = ContentKind.dynamic,
  int? commentCount,
  int? likeCount,
  int? repostCount,
}) =>
    ContentItem(
      id: 'd1',
      platform: Platform.bilibili,
      kind: kind,
      sourceId: 'bilibili:1',
      authorName: '火羽ひのめ',
      title: title,
      summary: summary,
      images: images,
      link: 'https://t.bilibili.com/1',
      publishedAt: DateTime.utc(2026, 11, 2, 10, 8),
      fetchedAt: DateTime.utc(2026, 11, 2, 10, 8),
      commentCount: commentCount,
      likeCount: likeCount,
      repostCount: repostCount,
    );

/// 解析层真实的兜底标题形态：正文首行截 60 字。
ContentItem _withFallbackTitle() {
  const String body = '今日は今から配信する！\n\n昨日も告知したけど3日早朝から用事がある';
  return _dynamic(
    title: '今日は今から配信する！', // = 正文首行
    summary: body,
  );
}

void main() {
  Future<void> pumpBody(WidgetTester tester, ContentItem item) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: AppColors.card,
          body: BiliDynamicBody(
            item: item,
            commentSection: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('兜底标题不再重复渲染（真机缺陷回归）', () {
    test('hasOwnTitle：标题是正文首行 → 判为「不是独立标题」', () {
      expect(BiliDynamicStyle.hasOwnTitle(_withFallbackTitle()), isFalse);
    });

    test('hasOwnTitle：标题被正文包含 → 不是独立标题', () {
      expect(
        BiliDynamicStyle.hasOwnTitle(
          _dynamic(title: '今日は今から配信する！', summary: '今日は今から配信する！ 全文'),
        ),
        isFalse,
      );
    });

    test('hasOwnTitle：标题与正文无关 → 是独立标题', () {
      expect(
        BiliDynamicStyle.hasOwnTitle(
          _dynamic(title: '十一月舰长礼物', summary: '面包捏捏乐钥匙扣，可以捏哦'),
        ),
        isTrue,
      );
    });

    test('hasOwnTitle：只有标题没有正文 → 仍然显示标题', () {
      // 专栏、抽奖这类动态正文为空，标题是唯一信息，不能因为修 bug 就吞掉。
      expect(
        BiliDynamicStyle.hasOwnTitle(_dynamic(title: '抽奖结果公布', summary: '')),
        isTrue,
      );
    });

    testWidgets('兜底标题的纯文字动态：整段文字在页面上只出现一次',
        (WidgetTester tester) async {
      final ContentItem item = _withFallbackTitle();
      await pumpBody(tester, item);

      // 核心断言：首行（= 兜底标题的内容）只出现 1 次。
      // 修之前会出现 2 次（标题 + 正文里那一行）。
      expect(
        find.textContaining('今日は今から配信する！'),
        findsOneWidget,
        reason: '兜底标题不能既当标题又当正文，否则内容重复',
      );
      // 正文整段仍然在（不能把内容一起删了）。
      expect(find.textContaining('昨日も告知したけど'), findsOneWidget);
    });

    testWidgets('真独立标题：标题 + 正文各出现一次（都保留）',
        (WidgetTester tester) async {
      await pumpBody(
        tester,
        _dynamic(title: '十一月舰长礼物', summary: '面包捏捏乐钥匙扣，可以捏哦'),
      );

      expect(find.text('十一月舰长礼物'), findsOneWidget);
      expect(find.textContaining('面包捏捏乐钥匙扣'), findsOneWidget);
    });

    testWidgets('纯图动态的「[图片]」占位不能当标题画出来',
        (WidgetTester tester) async {
      // 解析层对纯图片动态兜底成 title='[图片]'、summary=''。
      await pumpBody(
        tester,
        _dynamic(
          title: '[图片]',
          summary: '',
          images: <String>['https://i0.hdslb.com/a.jpg'],
        ),
      );
      expect(
        find.text('[图片]'),
        findsNothing,
        reason: '占位标题不是内容，画出来就是假的正文',
      );
    });
  });

  group('参考稿两档形态的字号与配色', () {
    test('纯文字动态：正文 16px、昵称用正文深色（page-detail-text）', () {
      final ContentItem item = _dynamic();
      expect(BiliDynamicStyle.bodySizeFor(item), 16);
      expect(BiliDynamicStyle.nameColorFor(item), AppColors.textPrimary);
    });

    test('带图动态：正文 15px、昵称用品牌粉（page-detail-image）', () {
      final ContentItem item = _dynamic(images: <String>['https://i0.hdslb.com/a.jpg']);
      expect(BiliDynamicStyle.bodySizeFor(item), 15);
      expect(BiliDynamicStyle.nameColorFor(item), AppColors.weiboName);
    });

    testWidgets('纯文字动态的正文 Text 用 16px / 行高 1.6',
        (WidgetTester tester) async {
      await pumpBody(tester, _dynamic(title: '', summary: '纯文字正文'));

      final Text body = tester.widget<Text>(find.text('纯文字正文'));
      expect(body.style?.fontSize, 16);
      expect(body.style?.height, 1.6);
    });

    testWidgets('带图动态的正文 Text 用 15px', (WidgetTester tester) async {
      await pumpBody(
        tester,
        _dynamic(
          title: '',
          summary: '带图正文',
          images: <String>['https://i0.hdslb.com/a.jpg'],
        ),
      );

      final Text body = tester.widget<Text>(find.text('带图正文'));
      expect(body.style?.fontSize, 15);
    });

    testWidgets('作者行：48px 头像 + 昵称 + 时间', (WidgetTester tester) async {
      await pumpBody(tester, _dynamic(title: '', summary: '正文'));

      expect(find.byType(BiliAuthorRow), findsOneWidget);
      expect(find.text('火羽ひのめ'), findsOneWidget);
      expect(find.textContaining('2026-11-02'), findsOneWidget);
    });
  });

  group('数据栏按参考稿', () {
    testWidgets('「评论 N」品牌粉加粗 + 「赞和转发 M」次要色',
        (WidgetTester tester) async {
      await pumpBody(
        tester,
        _dynamic(title: '', summary: '正文', commentCount: 1007, likeCount: 2000, repostCount: 651),
      );

      expect(find.text('评论 1007'), findsOneWidget);
      expect(find.text('赞和转发 2651'), findsOneWidget);

      final Text comment = tester.widget<Text>(find.text('评论 1007'));
      expect(comment.style?.color, AppColors.weiboName);
      expect(comment.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('接口没给计数时整项不渲染（不是显示 0）',
        (WidgetTester tester) async {
      await pumpBody(tester, _dynamic(title: '', summary: '正文'));

      expect(find.textContaining('评论 '), findsNothing);
      expect(find.textContaining('赞和转发'), findsNothing);
    });

    testWidgets('只有 like 没有 repost 也能算出「赞和转发」',
        (WidgetTester tester) async {
      await pumpBody(
        tester,
        _dynamic(title: '', summary: '正文', likeCount: 12),
      );
      expect(find.text('赞和转发 12'), findsOneWidget);
    });
  });

  group('时间展示诚实', () {
    test('有可靠发布时间 → 绝对时间', () {
      final ContentItem item = _dynamic();
      expect(BiliDynamicStyle.timeText(item), contains('2026-11-02'));
      expect(BiliDynamicStyle.timeText(item), isNot(contains('抓取于')));
    });

    test('时间不可靠 → 明说「抓取于」，不冒充发布时间', () {
      final ContentItem item = ContentItem(
        id: 'x',
        platform: Platform.bilibili,
        kind: ContentKind.dynamic,
        sourceId: 'bilibili:1',
        authorName: 'a',
        title: '',
        summary: '正文',
        link: 'https://t.bilibili.com/1',
        fetchedAt: DateTime.utc(2026, 11, 2, 10, 8),
        hasReliableTime: false,
      );
      expect(BiliDynamicStyle.timeText(item), startsWith('抓取于'));
    });
  });

  group('ContentDetailPage 也走同一套骨架', () {
    testWidgets('B 站纯文字动态：不再渲染「Bilibili / 动态」徽章行与大标题',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ContentDetailPage(item: _withFallbackTitle()),
          ),
        ),
      );
      await tester.pump();

      // 走的是新骨架。
      expect(find.byType(BiliDynamicBody), findsOneWidget);
      // 内容只出现一次（这就是用户截图里的缺陷）。
      expect(find.textContaining('今日は今から配信する！'), findsOneWidget);
    });

    testWidgets('微博图文也走同一套骨架（2026-11-02 第四轮修订）',
        (WidgetTester tester) async {
      // 用户原话：「我想让微博的纯文字卡片里的详情页的正文和你的一样」。
      // 旧契约是「微博不走骨架」，本条按新需求改为「也走」——
      // 这是**需求变更**，不是放宽断言。
      final ContentItem weibo = ContentItem(
        id: 'w1',
        platform: Platform.weibo,
        kind: ContentKind.dynamic,
        sourceId: 'weibo:1',
        authorName: '博主',
        title: '微博标题',
        summary: '微博正文',
        link: 'https://m.weibo.cn/status/5259410951377781',
        publishedAt: DateTime.utc(2026, 11, 2),
        fetchedAt: DateTime.utc(2026, 11, 2),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: ContentDetailPage(item: weibo)),
        ),
      );
      await tester.pump();

      expect(find.byType(BiliDynamicBody), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('微博**视频**仍然不走骨架（用户明确要求「视频动态不要动」）',
        (WidgetTester tester) async {
      final ContentItem weiboVideo = ContentItem(
        id: 'w2',
        platform: Platform.weibo,
        kind: ContentKind.video,
        sourceId: 'weibo:2',
        authorName: '博主',
        title: '视频标题',
        summary: '视频正文',
        link: 'https://m.weibo.cn/status/5259410951377782',
        videoRef: VideoRef(
          directVideoUrl: 'https://f.video.weibocdn.com/x.mp4',
          coverUrl: 'https://wx4.sinaimg.cn/c.jpg',
        ),
        publishedAt: DateTime.utc(2026, 11, 2),
        fetchedAt: DateTime.utc(2026, 11, 2),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: ContentDetailPage(item: weiboVideo)),
        ),
      );
      await tester.pump();

      // 视频走老排版：页内有 InlineVideoPlayer，不套骨架。
      expect(find.byType(BiliDynamicBody), findsNothing);
      expect(find.byType(InlineVideoPlayer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
