import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/config/diagnostics_config.dart';
import 'package:rrha/features/weibo/weibo_webview_page.dart';

/// 微博诊断入口的**编译期开关**验收。
///
/// 这条测试的价值在于：同一份断言跑两遍，`--dart-define=RRHA_WEIBO_DIAG`
/// 写 true / false 时结论必须相反。所以它断言的不是「一定有菜单」或
/// 「一定没有」，而是「页面呈现必须与 [kWeiboDiagnosticsEnabled] 一致」。
///
///   flutter test --no-pub test/features/weibo_diagnostics_switch_test.dart
///   flutter test --no-pub --dart-define=RRHA_WEIBO_DIAG=false <同上>
///
/// 正式包的默认行为（profile / release 下默认关闭）由真机验收覆盖。
void main() {
  testWidgets('⋮ 诊断菜单只在 kWeiboDiagnosticsEnabled 为 true 时渲染', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: WeiboWebViewPage(url: 'https://m.weibo.cn/'),
      ),
    );
    await tester.pump();

    // 刷新按钮任何时候都在：页面骨架不受开关影响。
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);

    final Finder menu = find.byType(PopupMenuButton<String>);
    final Finder moreIcon = find.byIcon(Icons.more_vert_rounded);

    if (kWeiboDiagnosticsEnabled) {
      expect(menu, findsOneWidget);
      expect(moreIcon, findsOneWidget);
    } else {
      // 开关关闭：**连 PopupMenuButton 都不渲染**，不只是隐藏菜单项。
      expect(menu, findsNothing);
      expect(moreIcon, findsNothing);
    }
  });

  testWidgets('开关打开时菜单里是 8 个诊断项', (WidgetTester tester) async {
    if (!kWeiboDiagnosticsEnabled) {
      // 关闭态下不验证菜单内容（另一条测试已覆盖「不渲染」）。
      return;
    }
    await tester.pumpWidget(
      const MaterialApp(
        home: WeiboWebViewPage(url: 'https://m.weibo.cn/'),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    for (final String label in const <String>[
      '接口自检',
      '分页测试',
      '字段结构 dump',
      '深度采样（3 页）',
      '评论探针',
      '关注列表探针',
      '评论图片探针',
      '多图探针',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺少菜单项：$label');
    }
  });
}
