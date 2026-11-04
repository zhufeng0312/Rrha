import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/widgets/photo_grid.dart';

/// 单图**按真实宽高比**渲染（2026-11-02 为 B 站评论图新增）。
///
/// ## 为什么需要这条能力
///
/// 原实现里单图恒按 `宽度 × 3/4` 取高并 `BoxFit.cover`。B 站评论图恰恰
/// 以**手机截图 / 超长竖图**为主 —— 探针实测样本 `BV1RXx169Emu` 里有一张
/// `1080×9109`（宽高比 0.12）。按 4:3 裁掉上下，用户只能看到中间一小条，
/// 完全看不出这条评论截的是什么。
///
/// 这里断言的是**高度计算**与**填充方式**，不涉及像素：
/// `flutter_test` 里 `Image.network` 必然走 errorBuilder，图片内容测不了。
void main() {
  /// 把测试窗口放大到 1600 高。
  ///
  /// ⚠️ 这一步是必须的：`flutter_test` 默认窗口只有 800×600，而「普通高图
  /// 完整展示」算出来的高度可以到 650+（`360 / 0.55 ≈ 653`）。窗口不够高时
  /// 父级会把 SizedBox **压扁**成 600 —— 断言会得到一个「看起来像实现写错了」
  /// 的假失败（排查了半小时才发现是测试环境限制了高度，不是代码问题）。
  ///
  /// 生产环境里这个组件永远在 `ListView` 里（无界高度），不会遇到这种压缩。
  setUp(() {
    // 每个用例前重置，避免相互影响。
  });

  Future<void> pump(
    WidgetTester tester, {
    required List<String> images,
    List<double?>? aspectRatios,
    BoxFit singleFit = BoxFit.cover,
    double width = 360,
    double maxSingleHeight = 400,
  }) async {
    // 用 setSurfaceSize 而不是改 physicalSize：后者要同时换算 DPR，
    // 一旦 DPR 不是 1，所有断言里的像素值都得跟着除，很容易算错。
    // setSurfaceSize 直接以**逻辑像素**指定测试表面大小。
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 用 ListView 而不是 Center：生产里这个组件就在列表里（高度无界），
          // 用 Center 会给它一个有限的垂直约束，把高图压扁。
          body: ListView(
            children: <Widget>[
              // 用 Row + 固定宽 SizedBox 把宽度**钉死**：
              // ListView 会把孩子横向拉伸到表面宽度，`SizedBox(width:)`
              // 独自放在里面是无效的（会被父约束覆盖）。
              Row(
                children: <Widget>[
                  SizedBox(
                    width: width,
                    child: PhotoGrid(
                      images: images,
                      onTap: (_) {},
                      aspectRatios: aspectRatios,
                      singleFit: singleFit,
                      maxSingleHeight: maxSingleHeight,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 取第一张图对应的 `CachedImage` 的 fit。
  BoxFit fitOfSingle(WidgetTester tester) {
    final img = tester.widget<Image>(find.byType(Image).first);
    expect(img.fit, isNotNull);
    return img.fit!;
  }

  double heightOfSingle(WidgetTester tester) {
    return tester.getSize(find.byType(ClipRRect).first).height;
  }

  group('默认行为不变（没有比例时退回 4:3）', () {
    testWidgets('单图无比例 → 高度 = 宽 × 3/4', (tester) async {
      await pump(tester, images: const <String>['https://i0.hdslb.com/a.jpg']);
      expect(heightOfSingle(tester), closeTo(360 * 3 / 4, 0.5));
    });

    testWidgets('单图默认 fit 仍是 cover（时间线详情页那条路径）', (tester) async {
      await pump(tester, images: const <String>['https://i0.hdslb.com/a.jpg']);
      expect(fitOfSingle(tester), BoxFit.cover);
    });

    testWidgets('比例列表为 null 时行为完全不变', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/a.jpg'],
        aspectRatios: null,
      );
      expect(heightOfSingle(tester), closeTo(360 * 3 / 4, 0.5));
    });
  });

  group('给了真实比例时按比例算高', () {
    testWidgets('横图 16:9（比例 1.778）→ 高度 = 宽 / 1.778', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/wide.jpg'],
        aspectRatios: const <double?>[16 / 9],
      );
      expect(heightOfSingle(tester), closeTo(360 / (16 / 9), 0.5));
    });

    testWidgets('方图 1:1 → 高度 = 宽', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/sq.jpg'],
        aspectRatios: const <double?>[1.0],
      );
      expect(heightOfSingle(tester), closeTo(360, 0.5));
    });

    testWidgets('⚠️ 普通竖图（1080×1959，比例 0.55）**完整显示**，不被裁',
        (tester) async {
      // 这正是用户说的「有些并不是很长的图片不需要只显示一部分」。
      // 手机截图比例约 0.55，按 360 宽铺满需要 654px 高 —— 旧实现会被
      // maxSingleHeight=260 夹住并裁掉一大半。
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/shot.jpg'],
        aspectRatios: const <double?>[1080 / 1959],
        maxSingleHeight: 260,
      );

      expect(
        heightOfSingle(tester),
        closeTo(360 / (1080 / 1959), 0.5),
        reason: '普通图按真实比例完整展示，上限只服务长截图',
      );
    });

    testWidgets('超长竖图（1080×9109）被 maxSingleHeight 夹住，不会撑穿页面',
        (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/tall.jpg'],
        aspectRatios: const <double?>[1080 / 9109],
        maxSingleHeight: 260,
      );
      expect(
        heightOfSingle(tester),
        260,
        reason: '按比例算出来会是 360/0.1186 ≈ 3035px，必须夹到上限',
      );
    });

    testWidgets('长图判据是「高 > 2×宽」（比例 < 0.5），不是「超过上限」',
        (tester) async {
      // 比例 0.6（高 1.67×宽）：普通图，即使超过上限也完整显示。
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/a.jpg'],
        aspectRatios: const <double?>[0.6],
        maxSingleHeight: 200,
      );
      expect(heightOfSingle(tester), closeTo(360 / 0.6, 0.5));

      // 比例 0.45（高 2.2×宽）：算长图，夹到上限。
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/b.jpg'],
        aspectRatios: const <double?>[0.45],
        maxSingleHeight: 200,
      );
      expect(heightOfSingle(tester), 200);
    });

    testWidgets('极宽图有 120px 下限（不会被压成一条缝）', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/flat.jpg'],
        aspectRatios: const <double?>[8.0],
        maxSingleHeight: 400,
      );
      expect(heightOfSingle(tester), 120);
    });

    testWidgets('比例是 0 / 负数 / NaN 时退回 4:3（当坏数据处理）', (tester) async {
      for (final bad in <double?>[0, -1.5, double.nan]) {
        await pump(
          tester,
          images: const <String>['https://i0.hdslb.com/a.jpg'],
          aspectRatios: <double?>[bad],
        );
        expect(
          heightOfSingle(tester),
          closeTo(360 * 3 / 4, 0.5),
          reason: '比例 $bad 不是有效宽高比',
        );
      }
    });
  });

  group('填充方式', () {
    testWidgets('评论侧传 contain → 普通竖图不裁切', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/tall.jpg'],
        aspectRatios: const <double?>[1.0],
        singleFit: BoxFit.contain,
        maxSingleHeight: 400,
      );
      expect(fitOfSingle(tester), BoxFit.contain);
    });

    testWidgets('⚠️ 超长截图：外面只露一段（cover），不缩成一条缝', (tester) async {
      // 真机上撞到的场景：整页长截图，按比例 contain 后宽度只剩十几像素，
      // 屏幕上就是一条黑细线（tools/shots/c11.png 实证）。
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/longscreen.jpg'],
        aspectRatios: const <double?>[0.05],
        singleFit: BoxFit.contain,
        maxSingleHeight: 200,
      );

      expect(heightOfSingle(tester), 200, reason: '高度仍被上限夹住');
      expect(
        fitOfSingle(tester),
        BoxFit.cover,
        reason: '按比例缩完宽度只有 200×0.05=10px，contain 会变成一条细线',
      );
    });

    testWidgets('被裁的长图**从顶部**开始露（默认居中会裁掉标题）', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/longscreen.jpg'],
        aspectRatios: const <double?>[0.05],
        singleFit: BoxFit.contain,
        maxSingleHeight: 200,
      );

      final img = tester.widget<Image>(find.byType(Image).first);
      expect(img.alignment, Alignment.topCenter);
    });

    testWidgets('没被裁的图仍然居中', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/a.jpg'],
        aspectRatios: const <double?>[1.0],
        maxSingleHeight: 400,
      );

      final img = tester.widget<Image>(find.byType(Image).first);
      expect(img.alignment, Alignment.center);
    });

    testWidgets('⚠️ 被裁时**不再**贴角标（用户 2026-11-02 要求去掉）',
        (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/longscreen.jpg'],
        aspectRatios: const <double?>[0.05],
        maxSingleHeight: 200,
      );

      // 去掉的是提示，不是裁切：高度仍被夹住（见上一组测试）。
      expect(find.text('长图 · 点击查看'), findsNothing);
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);
    });

    testWidgets('是否裁切取决于实际布局，不是硬编码比例阈值', (tester) async {
      // 同一比例 0.2：宽容器下会被裁，窄容器下不会。
      // 这条防止把判据写成 `ratio < 0.15` 这种与布局无关的死阈值。
      const ratio = 0.2;

      // 宽 360、上限 260：需要高 360/0.2=1800 > 260 → 裁
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/a.jpg'],
        aspectRatios: const <double?>[ratio],
        singleFit: BoxFit.contain,
        width: 360,
        maxSingleHeight: 260,
      );
      expect(fitOfSingle(tester), BoxFit.cover);

      // 宽 40、上限 260：需要高 40/0.2=200 <= 260 → 不裁
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/a.jpg'],
        aspectRatios: const <double?>[ratio],
        singleFit: BoxFit.contain,
        width: 40,
        maxSingleHeight: 260,
      );
      expect(fitOfSingle(tester), BoxFit.contain);
    });

    testWidgets('没有比例时永远用调用方给的 fit（不猜）', (tester) async {
      await pump(
        tester,
        images: const <String>['https://i0.hdslb.com/a.jpg'],
        aspectRatios: null,
        singleFit: BoxFit.contain,
      );
      expect(fitOfSingle(tester), BoxFit.contain);
    });

    testWidgets('多图时 singleFit 不生效（正方格必须 cover）', (tester) async {
      await pump(
        tester,
        images: const <String>[
          'https://i0.hdslb.com/1.jpg',
          'https://i0.hdslb.com/2.jpg',
          'https://i0.hdslb.com/3.jpg',
        ],
        aspectRatios: const <double?>[0.5, 0.5, 0.5],
        singleFit: BoxFit.contain,
      );

      // 三张图 → 三列正方格，且每张都是 cover。
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, hasLength(3));
      for (final img in images) {
        expect(img.fit, BoxFit.cover, reason: '多图格子里必须是 cover，否则会歪');
      }

      // 格子是正方形。
      final size = tester.getSize(find.byType(ClipRRect).first);
      expect(size.width, closeTo(size.height, 0.5));
    });
  });

  group('列数规则不受影响（既有契约）', () {
    test('columnsFor 保持原样', () {
      expect(PhotoGrid.columnsFor(1), 1);
      expect(PhotoGrid.columnsFor(2), 2);
      expect(PhotoGrid.columnsFor(3), 3);
      expect(PhotoGrid.columnsFor(4), 2);
      expect(PhotoGrid.columnsFor(9), 3);
    });
  });
}
