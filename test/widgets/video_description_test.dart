import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/widgets/video_description.dart';

/// 视频简介（`docs/BILI_HANDOFF.md` §3.2）的防回归测试。
///
/// 这块最容易被「顺手重排」破坏的是三件看起来很小、但在小屏播放页上很要紧的事：
/// 1. 空简介**不能占位**（头部是固定高度，空占位会挤掉评论区的可见行数）；
/// 2. 短简介**不能挂一个「展开」按钮**（点了没反应，真机上像坏了）；
/// 3. 换视频/切分 P 后，上次的「展开」状态**不能带过去**。
void main() {
  Widget wrap(Widget child, {double width = 320}) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      );

  /// 一段足够长的简介：在 320 宽、12 号字下必然超过两行。
  const long = '这是一段很长的视频简介，用来验证折叠与展开的行为。'
      '它需要足够长，才能在三百二十像素宽的容器里超过两行，'
      '从而让组件显示「展开」按钮。否则测试会退化成「短简介不应该有按钮」，'
      '测不到真正关心的分支。';

  /// 一段足够短的简介：一行就能放下。
  const short = '一句话简介';

  testWidgets('空简介不占位（渲染成零尺寸）', (tester) async {
    await tester.pumpWidget(wrap(const VideoDescription(text: '')));

    // 完全空白 + 只有空格 + 换行，都视为空。
    expect(find.byType(Text), findsNothing);
    final size = tester.getSize(find.byType(VideoDescription));
    expect(size.height, 0);
  });

  testWidgets('只有空白的简介同样不占位', (tester) async {
    await tester.pumpWidget(wrap(const VideoDescription(text: '   \n\n  ')));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('短简介不显示「展开」按钮', (tester) async {
    await tester.pumpWidget(wrap(const VideoDescription(text: short)));

    expect(find.text(short), findsOneWidget);
    expect(find.text('展开'), findsNothing, reason: '一行就够长的简介不该有展开按钮');
    expect(find.text('收起'), findsNothing);
  });

  testWidgets('长简介默认折叠成两行并显示「展开」', (tester) async {
    await tester.pumpWidget(wrap(const VideoDescription(text: long)));

    final text = tester.widget<Text>(find.text(long));
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(find.text('展开'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
  });

  testWidgets('点「展开」后不再限制行数，按钮变成「收起」', (tester) async {
    await tester.pumpWidget(wrap(const VideoDescription(text: long)));

    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text(long));
    expect(text.maxLines, isNull, reason: '展开后必须真的放开行数');
    expect(text.overflow, isNull);
    expect(find.text('收起'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
  });

  testWidgets('再点「收起」回到折叠态', (tester) async {
    await tester.pumpWidget(wrap(const VideoDescription(text: long)));

    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.text(long)).maxLines, 2);
    expect(find.text('展开'), findsOneWidget);
  });

  testWidgets('换成另一个视频的简介时，「展开」状态被重置', (tester) async {
    await tester.pumpWidget(wrap(const VideoDescription(text: long)));
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);

    // 模拟切分 P：文本换了一份同样长但内容不同的简介。
    const other = '另一段同样很长很长的简介，用来模拟切换到另一个分 P 之后的场景。'
        '它也需要超过两行，否则组件会走「短简介」分支，测不到状态重置。';
    await tester.pumpWidget(wrap(const VideoDescription(text: other)));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.text(other)).maxLines,
      2,
      reason: '换了内容之后不能还处于展开态（否则新简介直接铺满整块）',
    );
    expect(find.text('展开'), findsOneWidget);
  });

  testWidgets('简介里的换行被保留（B 站 desc 常是时间轴排版）', (tester) async {
    const withBreaks = '00:00 开场\n01:20 第一部分\n02:40 第二部分';
    await tester.pumpWidget(wrap(const VideoDescription(text: withBreaks)));

    // 文本原样交给 Text，不做任何单行化 —— 抹平换行会把时间轴挤成一句话。
    expect(find.text(withBreaks), findsOneWidget);
  });

  testWidgets('窄容器下更短的简介也会折行，同样能展开', (tester) async {
    // 160 宽时 short 也会超过两行吗？不会。这里用中等长度验证
    // 「是否折行取决于宽度」而不是写死某段文本。
    const medium = '这是一段中等长度的简介，在很窄的容器里会超过两行。';
    await tester.pumpWidget(wrap(const VideoDescription(text: medium), width: 120));

    expect(find.text('展开'), findsOneWidget);
  });
}
