import 'package:flutter/material.dart';

/// 弹幕字号的一个档位。
class DanmakuFontScaleStep {
  const DanmakuFontScaleStep(this.scale, this.label);

  /// 倍率（引擎按 `item.fontSize * fontScale` 计算实际字号）。
  final double scale;

  /// 按钮文案。
  final String label;

  /// 一句话说明，用于无障碍与紧凑布局下的提示。
  String get description => '$label（$scale×）';
}

/// 四档弹幕字号选择器。
///
/// 为什么是**四档按钮**而不是滑块：字号是主观偏好，分成离散档位既好选也好记，
/// 而且不会出现「1.137 倍」这种无从复现的值；滑块那套留给透明度和同屏上限。
///
/// ⚠️ 兼容历史值：`fontScale` 早期是滑块写的，存量数据里可能是 1.1 这类
/// **不在任何档位上**的值。此时组件把**最近的档位**画成选中态，
/// 并在下方如实标出「当前 1.10（不在档位上）」——
/// 既不出现「一个都没选中」的坏状态，也不谎报用户选的是哪一档。
class DanmakuFontScaleSelector extends StatelessWidget {
  const DanmakuFontScaleSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  /// 当前倍率（可能不在档位上）。
  final double value;

  /// 选中某档时回调，传的是**该档的精确倍率**。
  final ValueChanged<double> onChanged;

  /// 紧凑模式：播放器内的面板空间有限，去掉说明文字、缩小按钮。
  final bool compact;

  /// 四个档位。改这里就等于改 UI 与「最近档位」判定的全部依据。
  static const List<DanmakuFontScaleStep> steps = <DanmakuFontScaleStep>[
    DanmakuFontScaleStep(0.75, '小'),
    DanmakuFontScaleStep(1.0, '中'),
    DanmakuFontScaleStep(1.25, '大'),
    DanmakuFontScaleStep(1.5, '特大'),
  ];

  /// 当前值是否正好落在某个档位上。
  static bool isOnStep(double v) =>
      steps.any((s) => (s.scale - v).abs() < 1e-9);

  /// 找出离 [v] 最近的档位。
  ///
  /// 相等距离时取**较小**的那档（避免把用户的字号偷偷放大）。
  static DanmakuFontScaleStep nearestStep(double v) {
    var best = steps.first;
    var bestDelta = (best.scale - v).abs();
    for (final s in steps.skip(1)) {
      final delta = (s.scale - v).abs();
      if (delta < bestDelta) {
        best = s;
        bestDelta = delta;
      }
    }
    return best;
  }

  /// 给紧凑 UI 用的一行摘要，例如 `字号 中（1.0×）`。
  static String summary(double v) {
    final s = nearestStep(v);
    return isOnStep(v)
        ? '字号 ${s.label}（${s.scale}×）'
        : '字号 ${s.label}？（当前 ${v.toStringAsFixed(2)}×）';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = nearestStep(value);
    final offStep = !isOnStep(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '弹幕字号',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: compact ? 12 : 13,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final step in steps)
              _stepButton(
                context,
                step: step,
                selected: step.scale == selected.scale,
              ),
          ],
        ),
        if (offStep) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '当前 ${value.toStringAsFixed(2)}× 不在档位上（旧版本滑块遗留），'
            '点上面任意一档即可修正',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.orangeAccent,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }

  Widget _stepButton(
    BuildContext context, {
    required DanmakuFontScaleStep step,
    required bool selected,
  }) {
    // 选中态用实心主色，未选中用描边 —— 在深色播放器背景上也足够清楚。
    return ChoiceChip(
      label: Text(
        compact ? step.label : '${step.label} ${step.scale}×',
        style: TextStyle(fontSize: compact ? 12 : 13),
      ),
      selected: selected,
      onSelected: (_) => onChanged(step.scale),
      tooltip: step.description,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
