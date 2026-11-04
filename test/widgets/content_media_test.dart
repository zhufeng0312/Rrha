import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/widgets/content_media.dart';

/// 卡片媒体区的离线验收（`docs/UI_HANDOFF.md` §1.3 / §3.3）。
///
/// 这一组测试**不联网**：`Image.network` 在 `flutter_test` 里拿不到真实图片，
/// 会直接走 `errorBuilder`（组件必须自己兜住，否则测试会因为未捕获异常失败）。
/// 因此断言的是「渲染了几张 / 摆放成几列 / 点到了第几张」，而不是像素。
void main() {
  const List<String> nineImages = <String>[
    'https://i0.hdslb.com/1.jpg',
    'https://i0.hdslb.com/2.jpg',
    'https://i0.hdslb.com/3.jpg',
    'https://i0.hdslb.com/4.jpg',
    'https://i0.hdslb.com/5.jpg',
    'https://i0.hdslb.com/6.jpg',
    'https://i0.hdslb.com/7.jpg',
    'https://i0.hdslb.com/8.jpg',
    'https://i0.hdslb.com/9.jpg',
  ];

  Future<void> pumpMedia(
    WidgetTester tester,
    List<String> images, {
    void Function(int)? onTap,
    bool isVideo = false,
    double width = 311, // 359dp 屏宽 - 页面边距 24 - 卡片边距 24
    Duration? videoDuration,
    bool? videoIsVertical,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: ContentMedia(
                images: images,
                isVideo: isVideo,
                videoDuration: videoDuration,
                videoIsVertical: videoIsVertical,
                onTap: onTap ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    // 图片全部走 errorBuilder，settle 一次把占位铺开。
    await tester.pumpAndSettle();
  }

  group('列数规则（与 PhotoGrid 刻意不同）', () {
    test('2 张两列，其余 3 张以上三列（4 张也是三列）', () {
      expect(ContentMedia.columnsFor(0), 1);
      expect(ContentMedia.columnsFor(1), 1);
      expect(ContentMedia.columnsFor(2), 2);
      expect(ContentMedia.columnsFor(3), 3);
      expect(ContentMedia.columnsFor(4), 3, reason: '卡片规范：3 张以上一律三列');
      expect(ContentMedia.columnsFor(9), 3);
    });
  });

  group('渲染', () {
    testWidgets('0 张图不渲染任何东西（无图不留空、不留占位）', (WidgetTester tester) async {
      await pumpMedia(tester, const <String>[]);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('1 张图是全宽 16:9（不是 PhotoGrid 的 4:3 限高）', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages.sublist(0, 1), width: 320);
      final Size size = tester.getSize(find.byType(AspectRatio));
      expect(size.width, moreOrLessEquals(320, epsilon: 0.5));
      expect(size.height, moreOrLessEquals(320 * 9 / 16, epsilon: 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('2 张图左右并排，同一行（y 相同、x 递增）', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages.sublist(0, 2));
      final List<Offset> pos = <Offset>[
        for (int i = 0; i < 2; i++) tester.getTopLeft(find.byType(Image).at(i)),
      ];
      expect(pos[0].dy, pos[1].dy);
      expect(pos[1].dx, greaterThan(pos[0].dx));
    });

    testWidgets('4 张图是 3 列（3 + 1 换行），不是两列两行', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages.sublist(0, 4));
      final List<Offset> pos = <Offset>[
        for (int i = 0; i < 4; i++) tester.getTopLeft(find.byType(Image).at(i)),
      ];
      expect(pos[0].dy, pos[1].dy);
      expect(pos[1].dy, pos[2].dy, reason: '前三张同一行 → 3 列');
      expect(pos[3].dy, greaterThan(pos[0].dy), reason: '第 4 张换行');
      expect(pos[3].dx, pos[0].dx);
    });

    testWidgets('9 张图全部渲染（三列三行）', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages);
      expect(find.byType(Image), findsNWidgets(9));
      final Offset first = tester.getTopLeft(find.byType(Image).at(0));
      final Offset third = tester.getTopLeft(find.byType(Image).at(2));
      final Offset fourth = tester.getTopLeft(find.byType(Image).at(3));
      expect(third.dy, first.dy);
      expect(fourth.dy, greaterThan(first.dy));
    });

    testWidgets('超过 9 张只画 9 格，最后一格叠 +N', (WidgetTester tester) async {
      final List<String> twelve = <String>[
        for (int i = 0; i < 12; i++) 'https://i0.hdslb.com/$i.jpg',
      ];
      await pumpMedia(tester, twelve);
      expect(find.byType(Image), findsNWidgets(9), reason: '最多 9 张');
      expect(find.text('+3'), findsOneWidget);
    });

    testWidgets('不加 +N 时不出现任何角标文字', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('视频单图叠播放图标', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages.sublist(0, 1), isVideo: true);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('图片单图不叠播放图标', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages.sublist(0, 1));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('视频有 duration 时右下角显示时长角标', (WidgetTester tester) async {
      await pumpMedia(
        tester,
        nineImages.sublist(0, 1),
        isVideo: true,
        videoDuration: const Duration(seconds: 26, milliseconds: 331),
      );
      // 26.331 秒 → 向下取整成 26 秒 → "0:26"。
      expect(find.text('0:26'), findsOneWidget);
    });

    testWidgets('没有 duration 时不显示时长（接口没给就不编）', (WidgetTester tester) async {
      await pumpMedia(tester, nineImages.sublist(0, 1), isVideo: true);
      expect(find.textContaining(':'), findsNothing);
    });

    testWidgets('非视频即使传了 duration 也不显示时长角标', (WidgetTester tester) async {
      await pumpMedia(
        tester,
        nineImages.sublist(0, 1),
        videoDuration: const Duration(seconds: 26),
      );
      expect(find.text('0:26'), findsNothing);
    });
  });

  group('时长格式化（formatDuration）', () {
    test('秒级补零', () {
      expect(formatDuration(const Duration(seconds: 5)), '0:05');
      expect(formatDuration(const Duration(seconds: 65)), '1:05');
      expect(formatDuration(const Duration(minutes: 12, seconds: 3)), '12:03');
    });

    test('超过一小时带小时段', () {
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
      expect(formatDuration(const Duration(hours: 2)), '2:00:00');
    });

    test('零与负数都输出 0:00（不显示脏数据）', () {
      expect(formatDuration(Duration.zero), '0:00');
      expect(formatDuration(const Duration(seconds: -30)), '0:00');
    });

    test('毫秒向下取整（26.331 秒 → 0:26）', () {
      expect(
        formatDuration(const Duration(seconds: 26, milliseconds: 331)),
        '0:26',
      );
    });
  });

  group('点击回调', () {
    testWidgets('单图点一下回传 index=0', (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await pumpMedia(tester, nineImages.sublist(0, 1), onTap: taps.add);
      await tester.tap(find.byType(GestureDetector).first);
      expect(taps, <int>[0]);
    });

    testWidgets('九宫格点第 5 张回传 index=4（全屏预览要能直接定位）', (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await pumpMedia(tester, nineImages, onTap: taps.add);
      await tester.tap(find.byType(GestureDetector).at(4));
      expect(taps, <int>[4]);
    });

    testWidgets('点最后一格回传 index=8', (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await pumpMedia(tester, nineImages, onTap: taps.add);
      await tester.tap(find.byType(GestureDetector).at(8));
      expect(taps, <int>[8]);
    });
  });
}
