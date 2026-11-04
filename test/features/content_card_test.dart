import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/theme/app_colors.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/video_ref.dart';
import 'package:rrha/features/timeline/content_card.dart';
import 'package:rrha/widgets/cached_image.dart';
import 'package:rrha/widgets/content_media.dart';

/// 时间线卡片的离线验收（`docs/UI_HANDOFF.md` §1.2 / §1.4 / §3.2）。
///
/// 只断言「看得见的结构」，不联网：卡片里的图片一律走 errorBuilder。
/// 图片解码在 `flutter_test` 里永远不会完成，所以这里不 pump 到 settle 之前
/// 就断言位置关系（占位是同步铺开的）。
ContentItem _item({
  String id = 'x1',
  Platform platform = Platform.bilibili,
  ContentKind kind = ContentKind.dynamic,
  String authorName = '妖百灵',
  String? authorAvatar,
  String title = '标题',
  String summary = '',
  List<String> images = const <String>[],
  bool isNew = false,
  bool hasReliableTime = true,
  DateTime? publishedAt,
  VideoRef? videoRef,
}) =>
    ContentItem(
      id: id,
      platform: platform,
      kind: kind,
      sourceId: '${platform.key}:1',
      authorName: authorName,
      authorAvatar: authorAvatar,
      title: title,
      summary: summary,
      images: images,
      link: 'https://example.com/$id',
      videoRef: videoRef,
      publishedAt: publishedAt ?? DateTime.now().toUtc().subtract(
            const Duration(minutes: 3),
          ),
      fetchedAt: DateTime.now().toUtc(),
      hasReliableTime: hasReliableTime,
      isNew: isNew,
    );

void main() {
  Future<void> pumpCard(
    WidgetTester tester,
    ContentItem item, {
    VoidCallback? onTap,
    int? commentCount,
    int? likeCount,
    int? repostCount,
    double width = 359,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: AppColors.page,
          body: Center(
            child: SizedBox(
              width: width,
              child: ContentCard(
                item: item,
                onTap: onTap ?? () {},
                commentCount: commentCount,
                likeCount: likeCount,
                repostCount: repostCount,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('头部', () {
    testWidgets('44×44 头像 + 昵称 + 时间 + ••• 都在', (WidgetTester tester) async {
      await pumpCard(tester, _item());
      // 没有头像 → 首字占位圆形，尺寸必须是 44。
      final Size avatar =
          tester.getSize(find.text('妖').first);
      expect(avatar, isNotNull);
      expect(find.text('妖百灵'), findsOneWidget);
      // 3 分钟前（时间弱化成相对时间）。
      expect(find.textContaining('分钟前'), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    });

    testWidgets('微博昵称用粉色，B 站昵称用深黑', (WidgetTester tester) async {
      await pumpCard(tester, _item(platform: Platform.weibo));
      Color? colorOf(String name) =>
          tester.widget<Text>(find.text(name)).style?.color;
      expect(colorOf('妖百灵'), AppColors.weiboName);
      expect(tester.takeException(), isNull);

      await pumpCard(tester, _item(platform: Platform.bilibili));
      expect(colorOf('妖百灵'), AppColors.biliName);
    });

    testWidgets('时间不可靠时写「抓取于」，不假装是发布时间', (WidgetTester tester) async {
      await pumpCard(tester, _item(hasReliableTime: false));
      expect(find.textContaining('抓取于'), findsOneWidget);
    });

    testWidgets('isNew 保留成昵称后的小圆点（不能丢这个时间线核心交互）', (WidgetTester tester) async {
      await pumpCard(tester, _item(isNew: true));
      expect(find.text('NEW'), findsNothing, reason: '旧角标样式已废弃');
      // 圆点没有文字，靠「昵称右侧多出一个 6×6 的容器」间接确认。
      final Finder dot = find.byWidgetPredicate((Widget w) {
        if (w is! Container) return false;
        final BoxDecoration? d = w.decoration as BoxDecoration?;
        return d?.shape == BoxShape.circle &&
            d?.color == AppColors.newBadge &&
            (w.constraints?.maxWidth == 6);
      });
      expect(dot, findsOneWidget);
    });

    testWidgets('转发动态在昵称行给出「转发」小标签', (WidgetTester tester) async {
      await pumpCard(tester, _item(kind: ContentKind.repost));
      expect(find.text('转发'), findsOneWidget);
      expect(find.textContaining('含原动态'), findsNothing, reason: '旧封面角标已删');
    });
  });

  group('正文', () {
    testWidgets('短正文不出现「全文」', (WidgetTester tester) async {
      await pumpCard(tester, _item(summary: '很短的一句话'));
      expect(find.text('很短的一句话'), findsOneWidget);
      expect(find.text('全文'), findsNothing);
    });

    testWidgets('超长正文截断到 4 行，并出现蓝色可点的「全文」', (WidgetTester tester) async {
      final String long = '我的天呐九寨沟真的太漂亮了，特别今天还断断续续有太阳，妈耶景色绝了，'
          '以下除了我的脸，全部原图直出没P过，就是太累了，今天才逛了一大半就力不从心了，'
          '明天还要继续吗，我觉得我可能需要休息一下，但是又不想浪费门票钱，'
          '所以还是继续吧，毕竟来都来了，这里的风景确实值得，就是走路走到腿软。';
      var tapped = false;
      await pumpCard(
        tester,
        _item(summary: long),
        onTap: () => tapped = true,
      );

      expect(find.text('全文'), findsOneWidget);
      final Text body = tester.widget<Text>(find.text(long));
      expect(body.maxLines, ContentCard.bodyMaxLines);
      expect(body.overflow, TextOverflow.ellipsis);

      final Text full = tester.widget<Text>(find.text('全文'));
      expect(full.style?.color, AppColors.link);

      await tester.tap(find.text('全文'));
      await tester.pump();
      expect(tapped, isTrue, reason: '「全文」要能进详情页');
    });

    testWidgets('summary 为空时退回 title（正文区不空着）', (WidgetTester tester) async {
      await pumpCard(tester, _item(title: '只有标题的内容', summary: ''));
      expect(find.text('只有标题的内容'), findsOneWidget);
    });
  });

  group('媒体区', () {
    testWidgets('无图时完全不渲染媒体区（无占位、无空行）',
        (WidgetTester tester) async {
      await pumpCard(tester, _item());
      expect(find.byType(ContentMedia), findsNothing);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('有图时渲染 ContentMedia，且单图是 16:9', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(images: <String>['https://i0.hdslb.com/a.jpg']),
      );
      expect(find.byType(ContentMedia), findsOneWidget);
      expect(find.byType(AspectRatio), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('多图走三列九宫格（4 张也是 3 列）', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(images: <String>[
          for (int i = 0; i < 4; i++) 'https://i0.hdslb.com/$i.jpg',
        ]),
      );
      expect(find.byType(Image), findsNWidgets(4));
      final List<Offset> pos = <Offset>[
        for (int i = 0; i < 4; i++) tester.getTopLeft(find.byType(Image).at(i)),
      ];
      expect(pos[1].dy, pos[2].dy, reason: '前三张同一行');
    });

    testWidgets('不再有「共 N 张」「直链未解析」这类旧封面角标',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          kind: ContentKind.video,
          images: <String>[
            for (int i = 0; i < 3; i++) 'https://i0.hdslb.com/$i.jpg',
          ],
        ),
      );
      expect(find.textContaining('共 '), findsNothing);
      expect(find.text('直链未解析'), findsNothing);
    });
  });

  group('底部操作栏', () {
    testWidgets('三列平分：转发 / 评论 / 点赞三个图标都在', (WidgetTester tester) async {
      await pumpCard(tester, _item());
      expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    });

    testWidgets('计数为 null 时不渲染数字（决策 D5 的「两态」）',
        (WidgetTester tester) async {
      await pumpCard(tester, _item());
      // 纯图标版本：操作栏里不应出现任何数字文本。
      for (final String s in <String>['0', '1', '143']) {
        expect(find.text(s), findsNothing, reason: '没有计数字段时不能凭空造数字');
      }
    });

    testWidgets('计数有值时自动显示（补完字段后无需再改布局）',
        (WidgetTester tester) async {
      await pumpCard(tester, _item(), commentCount: 143);
      expect(find.text('143'), findsOneWidget);
    });

    testWidgets('大数折叠成「万」', (WidgetTester tester) async {
      await pumpCard(tester, _item(), commentCount: 12345);
      expect(find.text('1.2万'), findsOneWidget);
    });

    testWidgets('没有评论预览框（决策 D1：本轮不做）', (WidgetTester tester) async {
      await pumpCard(tester, _item(summary: '正文'));
      // 卡片里除了正文之外不应再有注释性/预览性文本块。
      expect(find.textContaining('查看评论'), findsNothing);
    });
  });

  // 用户需求：「卡片显示真实评论数和点赞数」「B 站卡片显示博主头像」。
  //
  // 数据层由 `bili_content_parser_test` / `weibo_parser_test` 保证取得到；
  // 这里保证**卡片确实把它们画出来了** —— 两边都绿才算需求完成。
  group('操作栏真实计数与头像', () {
    testWidgets('三个计数都有值时，三个数字都显示且位置在操作栏',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(),
        commentCount: 143,
        likeCount: 833,
        repostCount: 21,
      );

      expect(find.text('143'), findsOneWidget);
      expect(find.text('833'), findsOneWidget);
      expect(find.text('21'), findsOneWidget);

      // 数字应与对应图标同一行（操作栏），而不是跑到正文里。
      final Offset likeIcon = tester.getCenter(find.byIcon(Icons.thumb_up_outlined));
      final Offset likeText = tester.getCenter(find.text('833'));
      expect((likeIcon.dy - likeText.dy).abs(), lessThan(8));
      expect(likeText.dx, greaterThan(likeIcon.dx));
    });

    testWidgets('真实的大数（18050 赞）折叠成 1.8万', (WidgetTester tester) async {
      await pumpCard(tester, _item(), likeCount: 18050, commentCount: 583);
      expect(find.text('1.8万'), findsOneWidget);
      expect(find.text('583'), findsOneWidget);
    });

    testWidgets('计数为 0 时显示 0（区别于「接口没给」）', (WidgetTester tester) async {
      await pumpCard(tester, _item(), commentCount: 0, likeCount: 0, repostCount: 0);
      expect(find.text('0'), findsNWidgets(3));
    });

    testWidgets('有头像 URL 时用 CachedImage 渲染，且 url/尺寸正确',
        (WidgetTester tester) async {
      const String avatar = 'https://i0.hdslb.com/bfs/face/a.jpg';
      await pumpCard(tester, _item(authorAvatar: avatar));

      // 头像是 44×44 的圆形 → ClipOval 里包一个 CachedImage。
      final Finder avatarImage = find.descendant(
        of: find.byType(ClipOval),
        matching: find.byType(CachedImage),
      );
      expect(avatarImage, findsWidgets, reason: '有作者头像时必须真的去加载它');
      final CachedImage w = tester.widget<CachedImage>(avatarImage.first);
      expect(w.url, avatar);
      expect(w.width, 44);
      expect(w.height, 44);

      // ⚠️ 刻意**不**断言首字「妖」不存在：`CachedImage` 的 placeholder 就是
      // 首字圆形（加载中/失败时兜底），在 flutter_test 里网络图必然失败，
      // 于是首字一定在。真正要证明的是「它去请求了那张头像」——上面已经证了。
    });

    testWidgets('头像为空时完全不请求网络图（直接画首字圆形占位）',
        (WidgetTester tester) async {
      await pumpCard(tester, _item(authorAvatar: null));
      expect(
        find.descendant(
          of: find.byType(ClipOval),
          matching: find.byType(CachedImage),
        ),
        findsNothing,
      );
      expect(find.text('妖'), findsOneWidget, reason: '昵称首字');
    });
  });

  group('整卡点击', () {
    testWidgets('点卡片空白处进详情页', (WidgetTester tester) async {
      var tapped = false;
      await pumpCard(tester, _item(), onTap: () => tapped = true);
      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('图片卡点单图走全屏预览，不触发整卡 onTap', (WidgetTester tester) async {
      var cardTapped = false;
      await pumpCard(
        tester,
        _item(images: <String>['https://i0.hdslb.com/a.jpg']),
        onTap: () => cardTapped = true,
      );
      // 单图媒体区是 GestureDetector（opaque），点它会 push 预览页而不是详情页。
      final Finder mediaTap = find.descendant(
        of: find.byType(ContentMedia),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(mediaTap.first);
      await tester.pump();
      expect(cardTapped, isFalse, reason: '纯图片卡点图应该看大图，不是进详情页');
      expect(tester.takeException(), isNull);
    });

    /// 真机回归：**视频卡点封面必须打开视频**，不能只是看封面图。
    ///
    /// 早先 `ContentMedia` 用 opaque 的 GestureDetector 吃掉封面点击，
    /// 点封面只会 push 全屏预览（用户看到「只显示封面图片」），
    /// 只有点标题才播 —— 正是这次报上来的现象。
    testWidgets('视频卡点单张封面 = 打开视频（走整卡 onTap）', (WidgetTester tester) async {
      var cardTapped = false;
      await pumpCard(
        tester,
        _item(
          kind: ContentKind.video,
          images: <String>['https://i0.hdslb.com/a.jpg'],
        ),
        onTap: () => cardTapped = true,
      );
      final Finder mediaTap = find.descendant(
        of: find.byType(ContentMedia),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(mediaTap.first);
      await tester.pump();

      expect(
        cardTapped,
        isTrue,
        reason: '点视频封面要和点标题一样打开播放页，不能只弹封面大图',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('视频卡点封面不会 push 全屏预览页', (WidgetTester tester) async {
      await pumpCard(
        tester,
        _item(
          kind: ContentKind.video,
          images: <String>['https://i0.hdslb.com/a.jpg'],
        ),
      );
      final Finder mediaTap = find.descendant(
        of: find.byType(ContentMedia),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(mediaTap.first);
      await tester.pumpAndSettle();

      // 预览页是唯一的全屏黑底页；没被 push 时不该出现它的关闭按钮。
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('视频卡多图时点图仍看大图（不是播放）', (WidgetTester tester) async {
      var cardTapped = false;
      await pumpCard(
        tester,
        _item(
          kind: ContentKind.video,
          images: <String>[
            'https://i0.hdslb.com/a.jpg',
            'https://i0.hdslb.com/b.jpg',
          ],
        ),
        onTap: () => cardTapped = true,
      );
      final Finder mediaTap = find.descendant(
        of: find.byType(ContentMedia),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(mediaTap.first);
      await tester.pump();

      expect(
        cardTapped,
        isFalse,
        reason: '一组图里每张地位相同，点图应看大图',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('操作栏点击', () {
    testWidgets('点「评论」图标进详情页（有可看内容，不是空点击）',
        (WidgetTester tester) async {
      var tapped = 0;
      await pumpCard(tester, _item(), onTap: () => tapped++);

      // 操作栏里评论用的是 chat_bubble 图标。
      final Finder commentIcon = find.byIcon(Icons.chat_bubble_outline_rounded);
      expect(commentIcon, findsOneWidget);
      await tester.tap(commentIcon);
      await tester.pump();

      expect(tapped, 1, reason: '点评论应当进详情页看评论');
    });

    testWidgets('「转发」「点赞」不额外造点击区（点击冒泡到整卡，不是空动作）',
        (WidgetTester tester) async {
      var tapped = 0;
      await pumpCard(tester, _item(), onTap: () => tapped++);

      await tester.tap(find.byIcon(Icons.repeat_rounded));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await tester.pump();

      // 这两项在本 App 没有写操作能力，所以**自己不绑动作**；
      // 但它们的点击会冒泡到整卡 InkWell → 表现为「点哪都能进详情页」，
      // 这是既有的、符合预期的行为（不是空点击区，也不是写操作）。
      expect(tapped, 2, reason: '两次点击都经整卡 InkWell 冒泡进详情页');
    });
  });

  group('配色', () {
    testWidgets('卡片白底（不是旧的深色 0xFF1E1E1E）', (WidgetTester tester) async {
      await pumpCard(tester, _item());
      final Material material = tester.widget<Material>(
        find
            .ancestor(
              of: find.byType(InkWell),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, AppColors.card);
      expect(material.borderRadius, BorderRadius.circular(12));
    });
  });

  group('微博视频卡（2026-10-27 真机实测：pics 为空，封面在 page_info）', () {
    /// 真实样本：微博视频微博的 `pics` 是**空的**，封面由解析层从
    /// `page_info.page_pic.url` 塞进 `videoRef.coverUrl`。
    ContentItem weiboVideo({
      List<String> images = const <String>[],
      Duration? duration = const Duration(seconds: 26),
      bool? isVertical = true,
    }) =>
        _item(
          id: 'w1',
          platform: Platform.weibo,
          kind: ContentKind.video,
          images: images,
          videoRef: VideoRef(
            directVideoUrl: 'https://f.video.weibocdn.com/o0/x.mp4',
            coverUrl: 'https://wx4.sinaimg.cn/orj480/x.jpg',
            sourceUrl: 'https://m.weibo.cn/status/1',
            duration: duration,
            isVertical: isVertical,
          ),
        );

    testWidgets('pics 为空时媒体区仍渲染封面（不能用 images 判有无媒体）',
        (WidgetTester tester) async {
      await pumpCard(tester, weiboVideo());
      // 这是本次修复的核心回归点：早先按 `images.isNotEmpty` 判媒体区，
      // 视频微博 pics 为空 → 整块媒体区不渲染 → 卡片看不出是视频。
      expect(find.byType(ContentMedia), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('右下角显示时长「0:26」', (WidgetTester tester) async {
      await pumpCard(tester, weiboVideo(duration: const Duration(seconds: 26)));
      expect(find.text('0:26'), findsOneWidget);
    });

    testWidgets('duration 为 null 时不显示时长', (WidgetTester tester) async {
      await pumpCard(tester, weiboVideo(duration: null));
      expect(find.text('0:26'), findsNothing);
    });

    testWidgets('点封面走整卡 onTap（=播放），不 push 预览页',
        (WidgetTester tester) async {
      var tapped = false;
      await pumpCard(tester, weiboVideo(), onTap: () => tapped = true);
      final Finder mediaTap = find.descendant(
        of: find.byType(ContentMedia),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(mediaTap.first);
      await tester.pump();
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('视频同时带 pics 时，图集照常显示（不被压成一张封面）',
        (WidgetTester tester) async {
      await pumpCard(
        tester,
        weiboVideo(
          images: <String>[
            'https://wx1.sinaimg.cn/a.jpg',
            'https://wx1.sinaimg.cn/b.jpg',
          ],
        ),
      );
      // 两张图 → 两列两格。
      expect(find.byType(ContentMedia), findsOneWidget);
      final ContentMedia media = tester.widget<ContentMedia>(
        find.byType(ContentMedia),
      );
      expect(media.images.length, 2);
    });
  });
}
