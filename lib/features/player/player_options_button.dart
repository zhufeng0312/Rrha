import 'package:flutter/material.dart';

import '../../data/bili/bili_models.dart';
import 'player_controls_overlay.dart';

/// 播放页右上角的「更多」入口：清晰度 / 倍速 / 分 P。
///
/// ## 为什么是独立组件，而不是加进 [PlayerControlsOverlay]
///
/// `player_controls_overlay.dart` 归**界面会话**维护（见 `docs/COLLAB_PLAN.md`
/// §3.1 的领地表），而清晰度/倍速/分P 是**本会话（B 站）**的能力。
/// 把它做成播放页自己的一层 `Positioned`，满足三件事：
/// 1. 不动别人的文件，天然不冲突；
/// 2. 普通态与**全屏态**共用同一份实现 —— `_playerStack()` 在两个分支里都被渲染，
///    §3.6 要求的「全屏也能选清晰度/倍速/分P」因此自动成立；
/// 3. 可以单独写 widget 测试（弹出菜单的条目、禁用态）。
///
/// ## 命中测试的注意事项（继承 §7.10 的教训）
///
/// 这里是**有界**的按钮，不是铺满全屏的装饰容器。整层必须包
/// `IgnorePointer` 之外不加任何背景色 —— 一旦给它铺满的 `Container(color:)`，
/// 它就会像当初的控制栏渐变那样把下层手势（单击显隐 / 双击暂停）全吃掉。
class PlayerOptionsButton extends StatelessWidget {
  const PlayerOptionsButton({
    super.key,
    required this.qualities,
    required this.currentQuality,
    required this.speed,
    required this.pages,
    required this.currentPage,
    this.onSelectQuality,
    this.onSelectSpeed,
    this.onSelectPage,
    this.onOpenPlaybackInfo,
  });

  /// 可选清晰度（来自 `PlayUrlResult.qualities`）。空列表 = 接口没给，菜单项置灰。
  final List<QualityOption> qualities;

  /// 当前实际生效的 qn。
  final int currentQuality;

  final double speed;

  /// 分 P 列表。只有 1 个时不渲染该分组。
  final List<BiliPage> pages;

  final int currentPage;

  /// 选中清晰度。必填项由页面判断（选中当前项时不调用）。
  final ValueChanged<int>? onSelectQuality;

  /// 选中倍速。
  final ValueChanged<double>? onSelectSpeed;

  /// 切换到指定分 P。
  final ValueChanged<int>? onSelectPage;

  /// 打开「播放信息」（通道 / qn / 编解码）诊断弹窗。
  final VoidCallback? onOpenPlaybackInfo;

  /// 倍速档位。与 B 站 App 一致（额外留了 0.5 慢放）。
  static const List<double> speedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  /// 倍速文案：`1.0x` / `1.25x` / `0.5x`。
  ///
  /// 不能无脑 `toStringAsFixed(1)`（1.25 会变成 1.3），也不能固定两位
  /// （1.0x 会显示成 1.00x，与 B 站 App 的观感差一截）。规则是：
  /// 先固定两位，再**去掉末尾多余的 0**，但至少保留一位小数。
  static String formatSpeed(double v) {
    var s = v.toStringAsFixed(2);
    if (s.endsWith('0')) s = s.substring(0, s.length - 1);
    return '${s}x';
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_Action>(
      tooltip: '更多设置',
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
      // 弹出菜单本身用主题色（浅色面板），只有触发按钮是白色（它叠在视频上）。
      onSelected: (action) {
        switch (action.kind) {
          case _Kind.quality:
            onSelectQuality?.call(action.value);
          case _Kind.page:
            onSelectPage?.call(action.value);
          case _Kind.info:
            onOpenPlaybackInfo?.call();
        }
      },
      itemBuilder: (context) => _buildItems(context),
    );
  }

  List<PopupMenuEntry<_Action>> _buildItems(BuildContext context) {
    final items = <PopupMenuEntry<_Action>>[];

    // ---- 清晰度 ----
    if (qualities.isNotEmpty) {
      items.add(const PopupMenuItem<_Action>(
        enabled: false,
        height: 32,
        child: Text('清晰度', style: TextStyle(fontSize: 11)),
      ));
      for (final q in qualities) {
        final selected = q.qn == currentQuality;
        items.add(
          PopupMenuItem<_Action>(
            value: _Action.quality(q.qn),
            height: 40,
            child: _tile(
              label: q.label.isEmpty ? 'qn=${q.qn}' : q.label,
              selected: selected,
            ),
          ),
        );
      }
      items.add(const PopupMenuDivider());
    }

    // ---- 倍速 ----
    //
    // 倍速刻意用**一行 chip** 而不是 6 个菜单项：竖排 6 项会把整个菜单推到
    // 超出屏幕（清晰度 3~7 项 + 分P 若干 + 诊断项，手机上就要滚动了）。
    //
    // chip 的 `onSelected` 不会自动关闭菜单，所以在回调里手动 `pop` ——
    // 少了这一步，用户点完 chip 菜单还杵在那儿，很像「点了没生效」。
    items.add(const PopupMenuItem<_Action>(
      enabled: false,
      height: 32,
      child: Text('倍速', style: TextStyle(fontSize: 11)),
    ));
    items.add(
      PopupMenuItem<_Action>(
        enabled: false,
        height: 48,
        // 关掉这个条目的命中，否则点在 chip 之间的空白处会被当成「选中菜单项」。
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: <Widget>[
            for (final v in speedOptions)
              ChoiceChip(
                label: Text(
                  formatSpeed(v),
                  style: const TextStyle(fontSize: 11),
                ),
                selected: (v - speed).abs() < 0.001,
                onSelected: (_) {
                  onSelectSpeed?.call(v);
                  Navigator.of(context).pop();
                },
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
              ),
          ],
        ),
      ),
    );

    // ---- 分 P ----
    if (pages.length > 1) {
      items.add(const PopupMenuDivider());
      items.add(const PopupMenuItem<_Action>(
        enabled: false,
        height: 32,
        child: Text('分 P', style: TextStyle(fontSize: 11)),
      ));
      for (final p in pages) {
        items.add(
          PopupMenuItem<_Action>(
            value: _Action.page(p.page),
            height: 40,
            child: _tile(label: p.label, selected: p.page == currentPage),
          ),
        );
      }
    }

    // ---- 播放信息（开发者诊断）----
    if (onOpenPlaybackInfo != null) {
      items.add(const PopupMenuDivider());
      items.add(
        const PopupMenuItem<_Action>(
          value: _Action.info(),
          height: 40,
          child: Text('播放信息', style: TextStyle(fontSize: 13)),
        ),
      );
    }

    return items;
  }

  Widget _tile({required String label, required bool selected}) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        if (selected)
          const Icon(Icons.check_rounded, size: 16, color: Colors.black87),
      ],
    );
  }
}

enum _Kind { quality, page, info }

/// 弹出菜单的载荷。用一个小类而不是裸 `int`：
/// 清晰度与分 P 都是 int，混在一个 `PopupMenuButton<int>` 里无法区分。
class _Action {
  const _Action._(this.kind, this.value);

  const _Action.quality(int qn) : this._(_Kind.quality, qn);
  const _Action.page(int p) : this._(_Kind.page, p);
  const _Action.info() : this._(_Kind.info, 0);

  final _Kind kind;
  final int value;
}
