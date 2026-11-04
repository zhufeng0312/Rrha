import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/theme/app_colors.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/features/timeline/content_card.dart';
import 'package:rrha/features/timeline/weibo_facade_card.dart';

/// 亮色卡片方案的**离线视觉自检**（不是回归测试，不进 `flutter test` 默认套件）。
///
/// 为什么要有它：真机 USB 通道不可用时（Windows 侧 ADB 接口缺 DeviceInterfaceGUIDs，
/// 修它需要管理员权限），`docs/UI_HANDOFF.md` §7 的 6 张截图没法直接从手机上截。
/// 这个文件用 flutter_test 的软件光栅器把同样的卡面渲染成 PNG，至少能在提交前
/// 人眼确认「白底 / 深字 / 无白底白字 / 16:9 / 三列九宫格 / 4 行截断」这些硬指标。
///
/// 用法（会把 PNG 写到 tools/preview/shots/）：
/// ```powershell
/// . .\tools\flutter-env.ps1
/// flutter test tools/preview/ui_preview_test.dart --update-goldens
/// ```
///
/// 注意：`flutter_test` 默认字体是 Ahem（所有字符都是方块），所以这里显式加载
/// Windows 自带的黑体，否则截图里全是方块、看不出排版对不对。
/// 加载一个字体文件并注册成 [family]。文件不存在时静默跳过（别人机器上可能没有）。
Future<void> _loadFont(String family, String path) async {
  if (!File(path).existsSync()) return;
  final FontLoader loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(
      File(path).readAsBytesSync(),
    )));
  await loader.load();
}

void main() {
  setUpAll(() async {
    // 用系统黑体替换默认字体，让中文真的能渲染出来。
    await _loadFont('SimHei', r'C:\Windows\Fonts\simhei.ttf');
    // Material 图标字体（默认在 flutter_test 里不会加载，不加载的话图标全是方块）。
    await _loadFont(
      'MaterialIcons',
      r'C:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    );
  });

  ContentItem item({
    String id = 'x',
    Platform platform = Platform.bilibili,
    ContentKind kind = ContentKind.dynamic,
    String author = '妖百灵',
    String title = '',
    String summary = '',
    List<String> images = const <String>[],
    bool isNew = false,
  }) =>
      ContentItem(
        id: id,
        platform: platform,
        kind: kind,
        sourceId: '${platform.key}:1',
        authorName: author,
        title: title,
        summary: summary,
        images: images,
        link: 'https://example.com/$id',
        publishedAt: DateTime.utc(2026, 10, 17, 8, 9),
        fetchedAt: DateTime.utc(2026, 10, 17, 8, 9),
        isNew: isNew,
      );

  /// 把一整列卡片渲染到 359dp 宽的手机画布上并存成 PNG。
  Future<void> shoot(
    WidgetTester tester,
    String name,
    List<Widget> cards,
  ) async {
    // 359dp 逻辑宽（荣耀 Magic8 Pro：1256 物理 / dpr 3.5）。
    tester.view.physicalSize = const Size(359 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: AppColors.biliBlue),
          scaffoldBackgroundColor: AppColors.page,
          fontFamily: 'SimHei',
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              // golden 只截这块：整屏截图会带上一大片空白底色，看图很费劲。
              key: const Key('preview-content'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final Widget c in cards) ...<Widget>[
                  c,
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await expectLater(
      find.byKey(const Key('preview-content')),
      matchesGoldenFile('shots/$name.png'),
    );
  }

  testWidgets('01 视频卡：单图 16:9 + 播放图标', (WidgetTester tester) async {
    await shoot(tester, 'ui-light-01-video', <Widget>[
      ContentCard(
        item: item(
          kind: ContentKind.video,
          author: '妖百灵',
          title: '律澪互踢一首花之塔的时间',
          summary: '律澪互踢一首花之塔的时间',
          images: const <String>['https://i0.hdslb.com/a.jpg'],
        ),
        onTap: () {},
      ),
    ]);
  });

  testWidgets('02 微博纯文字卡：完全没有媒体占位', (WidgetTester tester) async {
    await shoot(tester, 'ui-light-02-weibo-text', <Widget>[
      ContentCard(
        item: item(
          platform: Platform.weibo,
          author: '楚天明c',
          summary: '今天的天气真的很好啊，适合出门散步。',
        ),
        onTap: () {},
      ),
    ]);
  });

  testWidgets('03 微博双图：两列正方形', (WidgetTester tester) async {
    await shoot(tester, 'ui-light-03-two-images', <Widget>[
      ContentCard(
        item: item(
          platform: Platform.weibo,
          author: '楚天明c',
          summary: '旅游第一天的我：晚上强撑着给脸p一下，给风景找好看的模板搭配一下。',
          images: const <String>[
            'https://i0.hdslb.com/a.jpg',
            'https://i0.hdslb.com/b.jpg',
          ],
        ),
        onTap: () {},
      ),
    ]);
  });

  testWidgets('04 微博九图：三列九宫格', (WidgetTester tester) async {
    await shoot(tester, 'ui-light-04-nine-images', <Widget>[
      ContentCard(
        item: item(
          platform: Platform.weibo,
          author: '楚天明c',
          summary: '我的天呐九寨沟真的太漂亮了，特别今天还断断续续有太阳，妈耶景色绝了，'
              '以下除了我的脸，全部原图直出没P过，就是太累了，今天才逛了一大半就力不从心了，'
              '明天还要继续吗，我觉得我可能需要休息一下，但是又不想浪费门票钱。',
          images: <String>[for (int i = 0; i < 9; i++) 'https://i0.hdslb.com/$i.jpg'],
        ),
        onTap: () {},
      ),
    ]);
  });

  testWidgets('05 长文卡：4 行截断 + 蓝色「全文」', (WidgetTester tester) async {
    await shoot(tester, 'ui-light-05-long-text', <Widget>[
      ContentCard(
        item: item(
          author: '某个 UP 主',
          summary: '这是一段很长的正文，用来验证卡片正文区在第 4 行末尾被截断，'
              '并且在右下角出现一个蓝色的「全文」文本按钮。'
              '注意这里刻意不是「省略号 + 拼一段文字」，因为那样会变成两个省略号连在一起，'
              '很难看也很难点。真正超长的时候才出现「全文」，短正文不应该出现。'
              '所以这一条必须足够长，长到 TextPainter 判定它超过了 4 行。',
          images: const <String>['https://i0.hdslb.com/a.jpg'],
        ),
        onTap: () {},
      ),
    ]);
  });

  testWidgets('06 转发 + NEW + 计数有值（D5 补齐后的样子）', (WidgetTester tester) async {
    await shoot(tester, 'ui-light-06-repost-counts', <Widget>[
      ContentCard(
        item: item(
          id: 'r',
          kind: ContentKind.repost,
          author: '转发的人',
          summary: '转发了一条动态。',
          isNew: true,
        ),
        onTap: () {},
        repostCount: 1,
        commentCount: 143,
        likeCount: 833,
      ),
      ContentCard(
        item: item(
          id: 'w',
          platform: Platform.weibo,
          author: '某个微博博主',
          summary: '纯文字微博，没有图片，所以不该有媒体区。',
        ),
        onTap: () {},
        repostCount: 1,
        commentCount: 105,
        likeCount: 774,
      ),
    ]);
  });

  testWidgets('07 微博占位卡（亮色）', (WidgetTester tester) async {
    await shoot(tester, 'ui-light-07-weibo-facade', <Widget>[
      WeiboFacadeCard(
        displayName: '测试博主',
        uid: '1782488734',
        onOpen: () {},
      ),
    ]);
  });
}
