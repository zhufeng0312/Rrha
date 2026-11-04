import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/widgets/photo_grid.dart';

/// 九宫格缩略图的离线验收。
///
/// 这一组测试**不联网**：`Image.network` 在 `flutter_test` 里拿不到真实图片，
/// 会直接走 `errorBuilder`，所以断言的是「渲染了几张图 / 点到了第几张」，
/// 而不是像素。图片加载失败时组件必须回落到灰底占位 —— 那也正是这里要保的底线：
/// 一旦 errorBuilder 缺失，测试会因为未捕获异常直接失败。
void main() {
  /// 从 provider 里取出真实 URL（会剥掉 [ResizeImage] 包装）。
  String? urlOfImage(ImageProvider provider) {
    if (provider is NetworkImage) return provider.url;
    if (provider is ResizeImage) return urlOfImage(provider.imageProvider);
    return null;
  }

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

  Future<void> pumpGrid(
    WidgetTester tester,
    List<String> images, {
    void Function(int)? onTap,
    double width = 360,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: PhotoGrid(images: images, onTap: onTap ?? (_) {}),
            ),
          ),
        ),
      ),
    );
  }

  /// 定位第 [index] 张缩略图上的可点区域。
  ///
  /// 刻意**不用** `find.byType(GestureDetector).at(index)`：Material 自己会在
  /// 树里塞进 InkWell 之类的手势识别器，按下标取值很容易点到框架内部那个。
  /// 这里改成「先按图片 URL 找到那张缩略图，再取包围它的 GestureDetector」，
  /// 语义上就是「用户点这张图」。
  ///
  /// ⚠️ 必须剥掉 [ResizeImage]：缩略图带了 `cacheWidth`，于是 provider 是
  /// `ResizeImage(NetworkImage(...))` 而不是裸的 `NetworkImage` ——
  /// 直接判 `is NetworkImage` 会一张都找不到。
  Finder tapsFinderAt(int index) {
    final image = find.byWidgetPredicate((w) {
      if (w is! Image) return false;
      return urlOfImage(w.image) == nineImages[index];
    });
    return find.ancestor(of: image, matching: find.byType(GestureDetector));
  }

  group('PhotoGrid 列数规则', () {
    test('1 张单列、2 张两列、4 张两列、其余三列', () {
      expect(PhotoGrid.columnsFor(0), 1);
      expect(PhotoGrid.columnsFor(1), 1);
      expect(PhotoGrid.columnsFor(2), 2);
      expect(PhotoGrid.columnsFor(3), 3);
      expect(PhotoGrid.columnsFor(4), 2);
      expect(PhotoGrid.columnsFor(5), 3);
      expect(PhotoGrid.columnsFor(6), 3);
      expect(PhotoGrid.columnsFor(7), 3);
      expect(PhotoGrid.columnsFor(8), 3);
      expect(PhotoGrid.columnsFor(9), 3);
    });
  });

  group('PhotoGrid 渲染', () {
    testWidgets('1 张图独占一行，且高度被限住（不撑满屏幕）', (tester) async {
      await pumpGrid(tester, const <String>['https://i0.hdslb.com/1.jpg']);
      expect(find.byType(Image), findsOneWidget);
      final size = tester.getSize(find.byType(Image).first);
      expect(size.height, lessThanOrEqualTo(260));
      await tester.pumpAndSettle();
    });

    testWidgets('2 张图渲染 2 个缩略图，左右并排（y 相同、x 不同）', (tester) async {
      await pumpGrid(tester, nineImages.sublist(0, 2));
      expect(find.byType(Image), findsNWidgets(2));
      final a = tester.getTopLeft(find.byType(Image).at(0));
      final b = tester.getTopLeft(find.byType(Image).at(1));
      expect(a.dy, b.dy);
      expect(b.dx, greaterThan(a.dx));
      await tester.pumpAndSettle();
    });

    testWidgets('4 张图是两列两行', (tester) async {
      await pumpGrid(tester, nineImages.sublist(0, 4));
      expect(find.byType(Image), findsNWidgets(4));
      final positions = <Offset>[
        for (int i = 0; i < 4; i++) tester.getTopLeft(find.byType(Image).at(i)),
      ];
      // 前两张同一行、后两张同一行；第 1 与第 3 张同一列。
      expect(positions[0].dy, positions[1].dy);
      expect(positions[2].dy, positions[3].dy);
      expect(positions[2].dy, greaterThan(positions[0].dy));
      expect(positions[0].dx, positions[2].dx);
      await tester.pumpAndSettle();
    });

    testWidgets('9 张图全部渲染（三列三行）', (tester) async {
      await pumpGrid(tester, nineImages);
      expect(find.byType(Image), findsNWidgets(9));
      final first = tester.getTopLeft(find.byType(Image).at(0));
      final third = tester.getTopLeft(find.byType(Image).at(2));
      final fourth = tester.getTopLeft(find.byType(Image).at(3));
      expect(third.dy, first.dy, reason: '第 3 张应与第 1 张同一行');
      expect(fourth.dy, greaterThan(first.dy), reason: '第 4 张应换行');
      await tester.pumpAndSettle();
    });

    testWidgets('空列表不渲染任何图片，也不占位', (tester) async {
      await pumpGrid(tester, const <String>[]);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('图片加载失败走灰底占位，不抛异常、不留白', (tester) async {
      await pumpGrid(tester, const <String>['https://i0.hdslb.com/nope.jpg']);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('PhotoGrid 点击回调', () {
    testWidgets('点第 1 张回传 index=0', (tester) async {
      final taps = <int>[];
      await pumpGrid(tester, nineImages, onTap: taps.add);
      await tester.tap(tapsFinderAt(0).first);
      expect(taps, <int>[0]);
      await tester.pumpAndSettle();
    });

    testWidgets('点第 5 张回传 index=4（九宫格里定位到对应图的关键）', (tester) async {
      final taps = <int>[];
      await pumpGrid(tester, nineImages, onTap: taps.add);
      await tester.tap(tapsFinderAt(4));
      expect(taps, <int>[4]);
      await tester.pumpAndSettle();
    });

    testWidgets('点最后一张回传 index=8', (tester) async {
      final taps = <int>[];
      await pumpGrid(tester, nineImages, onTap: taps.add);
      await tester.tap(tapsFinderAt(8));
      expect(taps, <int>[8]);
      await tester.pumpAndSettle();
    });
  });
}
