import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/features/gallery/image_gallery_page.dart';

/// 全屏预览页的离线验收。
///
/// 这里**不联网**（`Image.network` 在测试里必定失败并走 errorBuilder），
/// 所以能验的是「结构对不对」：页码、初始定位、翻页、关闭、放大后禁止翻页、
/// 单图不崩。真实图片与保存到相册只能在真机上验（见 docs/HANDOVER.md §7.8）。
void main() {
  const nineImages = <String>[
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

  Future<void> pumpGallery(
    WidgetTester tester, {
    required List<String> images,
    int initialIndex = 0,
    String? title,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ImageGalleryPage(
            images: images,
            initialIndex: initialIndex,
            title: title,
          ),
        ),
      ),
    );
  }

  group('ImageGalleryPage 页码与初始定位', () {
    testWidgets('initialIndex=4 时首屏页码就是 5 / 9（不能先显示第 1 张再跳）', (tester) async {
      await pumpGallery(tester, images: nineImages, initialIndex: 4);
      expect(find.text('5 / 9'), findsOneWidget);
      expect(find.text('1 / 9'), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('initialIndex=0 时页码是 1 / 9', (tester) async {
      await pumpGallery(tester, images: nineImages);
      expect(find.text('1 / 9'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('initialIndex 越界（过大）夹到最后一张', (tester) async {
      await pumpGallery(tester, images: nineImages, initialIndex: 99);
      expect(find.text('9 / 9'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('initialIndex 越界（负数）夹到第一张', (tester) async {
      await pumpGallery(tester, images: nineImages, initialIndex: -3);
      expect(find.text('1 / 9'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('单张图也能打开，页码 1 / 1', (tester) async {
      await pumpGallery(
        tester,
        images: const <String>['https://i0.hdslb.com/only.jpg'],
      );
      expect(find.text('1 / 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('空列表：给出明确文案而不是崩', (tester) async {
      await pumpGallery(tester, images: const <String>[]);
      expect(find.text('没有可预览的图片'), findsOneWidget);
      expect(find.text('0 / 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ImageGalleryPage 交互', () {
    testWidgets('左右滑动切换到下一张，页码随之变化', (tester) async {
      await pumpGallery(tester, images: nineImages, initialIndex: 0);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 9'), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(find.text('1 / 9'), findsOneWidget);
    });

    testWidgets('一页一个 InteractiveViewer（双指缩放与拖动都靠它）', (tester) async {
      await pumpGallery(tester, images: nineImages, initialIndex: 0);
      // PageView 只保留相邻页，所以至少有一个、最多三个。
      expect(find.byType(InteractiveViewer), findsWidgets);
      await tester.pumpAndSettle();
    });

    testWidgets('关闭按钮能返回上一页', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ImageGalleryPage(
                          images: nineImages,
                          initialIndex: 3,
                        ),
                      ),
                    ),
                    child: const Text('打开预览'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开预览'));
      await tester.pumpAndSettle();
      expect(find.text('4 / 9'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('打开预览'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('连续进出预览页 5 次不抛异常（真机回归项的单测版本）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ImageGalleryPage(
                          images: nineImages,
                          initialIndex: 4,
                        ),
                      ),
                    ),
                    child: const Text('打开预览'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      for (int i = 0; i < 5; i++) {
        await tester.tap(find.text('打开预览'));
        await tester.pumpAndSettle();
        expect(find.text('5 / 9'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.close_rounded));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('ImageGalleryPage 手势协调', () {
    testWidgets('放大到 2.5x 后 PageView 不再响应翻页（拖图不会变成翻页）', (tester) async {
      await pumpGallery(tester, images: nineImages, initialIndex: 0);
      await tester.pumpAndSettle();

      // 双击 = 放大到 doubleTapScale。
      final center = tester.getCenter(find.byType(PageView));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(
        pageView.physics,
        isA<NeverScrollableScrollPhysics>(),
        reason: '放大后必须把翻页关掉，否则「放大后想拖图」会变成翻页',
      );
      // 页码没有变化（没有误翻页）。
      expect(find.text('1 / 9'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('再双击缩回 1x 后翻页能力恢复', (tester) async {
      await pumpGallery(tester, images: nineImages, initialIndex: 0);
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(PageView));

      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );

      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );

      // 恢复后能正常翻页。
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 9'), findsOneWidget);
    });

    testWidgets('缩放阈值取 1.01 而不是 1.0（躲开捏合回弹的浮点抖动）', (tester) async {
      expect(ImageGalleryPage.zoomThreshold, greaterThan(1.0));
      expect(ImageGalleryPage.doubleTapScale, greaterThan(ImageGalleryPage.zoomThreshold));
    });
  });
}
