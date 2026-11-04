import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/theme/app_colors.dart';
import 'package:rrha/data/weibo/weibo_backend.dart';
import 'package:rrha/features/timeline/weibo_facade_card.dart';

/// 微博占位卡的离线 widget 测试。
///
/// 这张卡存在的唯一目的是「别让用户以为 App 坏了，明确告诉他去浏览器看」，
/// 所以断言集中在三件事：博主名看得见、解释文字看得见、点一下真的回调。
///
/// 注意：卡里**没有任何图片**（不加载网络图），这也是它能被 widget 测试的
/// 前提 —— 往测试树里塞会真正解码的 Image 会让 flutter_test 卡死。
void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    required VoidCallback onOpen,
    String displayName = '测试博主',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeiboFacadeCard(
            displayName: displayName,
            uid: '1782488734',
            onOpen: onOpen,
          ),
        ),
      ),
    );
  }

  testWidgets('渲染出博主名与解释文案，且不抛异常', (WidgetTester tester) async {
    var tapped = false;
    await pumpCard(tester, onOpen: () => tapped = true);

    // 标题是 WeiboCopy.facadeTitle(displayName)（「在浏览器里打开 测试博主」），
    // 所以用 textContaining 找博主名，而不是精确匹配整句。
    expect(find.textContaining('测试博主'), findsOneWidget);
    expect(find.text(WeiboCopy.facadeTitle('测试博主')), findsOneWidget);
    expect(find.textContaining(WeiboCopy.facadeSubtitle), findsOneWidget);

    expect(tapped, isFalse, reason: '还没点，不应触发回调');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点整张卡会触发 onOpen（交给内置浏览器）', (WidgetTester tester) async {
    var tapped = false;
    await pumpCard(tester, onOpen: () => tapped = true);

    await tester.tap(find.byType(InkWell).first);
    await tester.pump();

    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点标题文字同样能命中整卡手势', (WidgetTester tester) async {
    var tapped = false;
    await pumpCard(tester, onOpen: () => tapped = true);

    await tester.tap(find.textContaining('测试博主'));
    await tester.pump();

    expect(tapped, isTrue, reason: '手指落在文字上也要能打开，不能只有边缘可点');
    expect(tester.takeException(), isNull);
  });

  testWidgets('不往树里塞图片（Widget 测试里解码图片会挂死进程）',
      (WidgetTester tester) async {
    await pumpCard(tester, onOpen: () {});

    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展示名用的是传入值（订阅别名优先，标题跟着变）',
      (WidgetTester tester) async {
    await pumpCard(tester, onOpen: () {}, displayName: '老婆的微博');

    expect(find.textContaining('老婆的微博'), findsOneWidget);
    expect(find.textContaining('测试博主'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底色由 Material 提供，水波纹才不会被不透明 Container 遮住',
      (WidgetTester tester) async {
    await pumpCard(tester, onOpen: () {});

    // 这条断言是为了防止有人把底色改回不透明 Container，那样点击会再没有
    // 水波纹：splash 画在 Material 层，被不透明子节点盖住就完全看不见了。
    // 所以卡里必须有一层装饰用的 Ink，且底色挂在 InkWell 的 Material 上。
    expect(find.byType(Ink), findsWidgets);

    final Material cardMaterial = tester.widget<Material>(
      find
          .ancestor(
            of: find.byType(InkWell),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      cardMaterial.color,
      AppColors.card,
      reason: '底色必须在 Material 上，放在不透明子节点会把水波纹遮掉',
    );

    expect(tester.takeException(), isNull);
  });
}
