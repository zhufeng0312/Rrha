import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/widgets/danmaku_font_scale_selector.dart';

/// 弹幕字号选择器的离线验收。
///
/// 重点盯两件事：
/// 1. 四档的倍率**不能写错**（写错了弹幕字号会整体偏大/偏小，很难从现象反推）；
/// 2. 历史遗留的非档位值（例如滑块时代留下的 1.1）**不能出现「一个都没选中」
///    的坏状态** —— 那会让用户完全无从下手。
void main() {
  Future<void> pump(WidgetTester tester, double value,
      {ValueChanged<double>? onChanged, bool compact = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DanmakuFontScaleSelector(
            value: value,
            onChanged: onChanged ?? (_) {},
            compact: compact,
          ),
        ),
      ),
    );
  }

  group('档位定义', () {
    test('就是用户选定的四档：小 0.75 / 中 1.0 / 大 1.25 / 特大 1.5', () {
      expect(DanmakuFontScaleSelector.steps.length, 4);
      expect(
        DanmakuFontScaleSelector.steps.map((s) => s.scale).toList(),
        <double>[0.75, 1.0, 1.25, 1.5],
      );
      expect(
        DanmakuFontScaleSelector.steps.map((s) => s.label).toList(),
        <String>['小', '中', '大', '特大'],
      );
    });

    test('isOnStep 只认精确档位值', () {
      expect(DanmakuFontScaleSelector.isOnStep(0.75), isTrue);
      expect(DanmakuFontScaleSelector.isOnStep(1.0), isTrue);
      expect(DanmakuFontScaleSelector.isOnStep(1.25), isTrue);
      expect(DanmakuFontScaleSelector.isOnStep(1.5), isTrue);
      expect(DanmakuFontScaleSelector.isOnStep(1.1), isFalse);
      expect(DanmakuFontScaleSelector.isOnStep(0.5), isFalse);
      expect(DanmakuFontScaleSelector.isOnStep(2.0), isFalse);
    });
  });

  group('最近档位（历史脏数据的兜底）', () {
    test('滑块时代的常见遗留值都能落到最近的档', () {
      // 1.1 → 1.0（|0.1| < |0.15|）
      expect(DanmakuFontScaleSelector.nearestStep(1.1).scale, 1.0);
      // 1.2 → 1.25（|0.05| < |0.2|）
      expect(DanmakuFontScaleSelector.nearestStep(1.2).scale, 1.25);
      // 0.9 → 0.75 与 1.0 距离相同（0.15 vs 0.1）→ 取更近的 1.0
      expect(DanmakuFontScaleSelector.nearestStep(0.9).scale, 1.0);
      // 0.875 正好在 0.75 与 1.0 中间 → 相等距离取**较小**那档，不偷偷放大
      expect(DanmakuFontScaleSelector.nearestStep(0.875).scale, 0.75);
    });

    test('越界值不会崩，落到端点档位', () {
      expect(DanmakuFontScaleSelector.nearestStep(0.0).scale, 0.75);
      expect(DanmakuFontScaleSelector.nearestStep(-5).scale, 0.75);
      expect(DanmakuFontScaleSelector.nearestStep(99).scale, 1.5);
    });

    test('summary 在档位上与不在档位上给出不同文案', () {
      expect(DanmakuFontScaleSelector.summary(1.0), contains('中'));
      expect(DanmakuFontScaleSelector.summary(1.0), isNot(contains('当前')));

      final off = DanmakuFontScaleSelector.summary(1.1);
      expect(off, contains('当前'));
      expect(off, contains('1.10'));
    });
  });

  group('渲染与交互', () {
    testWidgets('四个档位按钮都在', (tester) async {
      await pump(tester, 1.0);
      expect(find.text('小 0.75×'), findsOneWidget);
      expect(find.text('中 1.0×'), findsOneWidget);
      expect(find.text('大 1.25×'), findsOneWidget);
      expect(find.text('特大 1.5×'), findsOneWidget);
    });

    testWidgets('紧凑模式只显示档位名（播放器面板空间有限）', (tester) async {
      await pump(tester, 1.0, compact: true);
      expect(find.text('小'), findsOneWidget);
      expect(find.text('中'), findsOneWidget);
      expect(find.text('大'), findsOneWidget);
      expect(find.text('特大'), findsOneWidget);
      expect(find.text('中 1.0×'), findsNothing);
    });

    testWidgets('点某档回调该档的精确倍率', (tester) async {
      final picked = <double>[];
      await pump(tester, 1.0, onChanged: picked.add);

      await tester.tap(find.text('特大 1.5×'));
      await tester.pumpAndSettle();
      expect(picked, <double>[1.5]);

      await tester.tap(find.text('小 0.75×'));
      await tester.pumpAndSettle();
      expect(picked, <double>[1.5, 0.75]);
    });

    testWidgets('当前值所在的档显示为选中态', (tester) async {
      await pump(tester, 1.25);
      // ChoiceChip 的 selected 状态：大档应被选中，其余不选中。
      final chips = tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .toList();
      expect(chips.length, 4);
      final selected = <String>[
        for (final c in chips)
          if (c.selected) '${(c.label as Text).data}',
      ];
      expect(selected, <String>['大 1.25×']);
    });

    testWidgets('非档位值：最近的档被选中 + 明确提示「不在档位上」，不出现无选中的坏状态', (tester) async {
      await pump(tester, 1.1);

      final chips = tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .toList();
      final selectedCount = chips.where((c) => c.selected).length;
      expect(selectedCount, 1, reason: '必须恰好有一个选中项，否则用户无从下手');
      expect((chips.firstWhere((c) => c.selected).label as Text).data, '中 1.0×');

      expect(find.textContaining('不在档位上'), findsOneWidget);
      expect(find.textContaining('1.10'), findsOneWidget);
    });

    testWidgets('点非档位值旁边的最近档能把它修正成精确值', (tester) async {
      final picked = <double>[];
      await pump(tester, 1.1, onChanged: picked.add);
      await tester.tap(find.text('中 1.0×'));
      await tester.pumpAndSettle();
      expect(picked, <double>[1.0], reason: '点它就等于把 1.1 修正成 1.0');
    });

    testWidgets('档位值不显示多余提示', (tester) async {
      await pump(tester, 0.75);
      expect(find.textContaining('不在档位上'), findsNothing);
    });
  });
}
