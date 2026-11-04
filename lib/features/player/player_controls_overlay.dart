import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 播放器控制栏：顶部条 + 底部条，外加一层**不参与命中测试**的渐变装饰。
///
/// ## 为什么抽成独立的 public widget
///
/// 主要理由是**可测**。这个组件最容易犯的错误是「装饰层吃掉手势」，
/// 而那在真机上的表现是「控制栏根本点不掉」—— 正是 §7.10 修掉的缺陷。
/// 独立出来之后，widget 测试可以把它和一个模拟的手势层叠在一起、
/// 直接往画面空白处派发 tap，从而**确定性地**检出这类回归
/// （见 `test/features/player_controls_overlay_test.dart`）。
///
/// ## ⚠️ 渐变装饰为什么必须 IgnorePointer（这是最容易踩的一条）
///
/// - `Container(decoration: BoxDecoration(...))` 会构建 `RenderDecoratedBox`；
/// - `RenderDecoratedBox` **重写了 `hitTestSelf`**（`rendering/proxy_box.dart`），
///   内部直接调用 `decoration.hitTest(...)`；
/// - 而 `Decoration.hitTest` 的默认实现就是 **`=> true`**（`painting/decoration.dart`）。
///
/// 于是「铺满全屏的渐变容器」**自身就是命中目标**。它若挂在手势层之上，
/// `Stack` 的命中测试会在它这里立刻返回（`defaultHitTestChildren` 里
/// `if (isHit) return true;`），下层手势层**永远收不到事件**：
/// 控制栏隐藏时一切正常（那时它不渲染），一唤出来单击/双击就全部失效，
/// 只有它内部的 `IconButton` / `Slider` 还能点 —— 只能干等自动隐藏。
///
/// 所以本组件保证：
/// 1. 装饰层被 `IgnorePointer` 包住；
/// 2. 前景只有顶部条与底部条，**中间大片空白不铺任何参与命中测试的 widget**
///    （`Column` / `Row` / `Spacer` / `Text` 的 `hitTestSelf` 都是 false）。
class PlayerControlsOverlay extends StatelessWidget {
  const PlayerControlsOverlay({
    super.key,
    required this.title,
    required this.danmakuCount,
    required this.playing,
    required this.progressMs,
    required this.duration,
    required this.danmakuEnabled,
    required this.fullscreen,
    required this.progressBar,
    required this.onBack,
    required this.onTogglePlay,
    required this.onToggleDanmaku,
    required this.onOpenDanmakuSettings,
    required this.onToggleFullscreen,
  });

  /// 控制栏文字/图标颜色：**必须是白色**。
  ///
  /// 这层永远叠在**黑色视频画面**上，所以颜色不能跟随主题 ——
  /// 亮色主题下 `ThemeData` 的文字色是深色（`0xFF18191C`），
  /// 直接继承会让标题、时间、弹幕数在视频上几乎看不见（真机反馈）。
  static const Color foreground = Colors.white;

  /// 次要文字（时间 / 弹幕数）：白色半透明，比纯白弱一档但仍然清晰。
  static const Color foregroundSecondary = Color(0xE6FFFFFF);

  /// 标题（通常取视频标题，缺失时用兜底标题）。
  final String title;

  /// 弹幕总数；<= 0 时不显示角标。
  final int danmakuCount;

  final bool playing;

  /// 进度（毫秒）。刻意用 `ValueListenable` 而不是普通 double：
  /// 它每帧都在变，直接传值会让整个控制栏每帧重建。
  final ValueListenable<double> progressMs;

  final Duration duration;
  final bool danmakuEnabled;
  final bool fullscreen;

  /// 进度条本体（由调用方构建，便于复用既有的 seek 逻辑）。
  final Widget progressBar;

  final VoidCallback onBack;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleDanmaku;
  final VoidCallback onOpenDanmakuSettings;
  final VoidCallback onToggleFullscreen;

  /// 时间格式化（`mm:ss` / `h:mm:ss`）。
  ///
  /// 放在这里是为了让它成为**唯一实现**：播放页与播放列表都调它，
  /// 不会再出现两处格式化结果不一致的情况。
  ///
  /// 负时长（时长还没加载出来时的边界值）按 `00:00` 处理 ——
  /// 不做钳制的话 `Duration(seconds: -1)` 会算出 `59:59` 这种荒谬结果。
  static String formatDuration(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // 纯装饰渐变：撑满但不参与命中（见类注释）。
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Color(0xB3000000),
                    Color(0x00000000),
                    Color(0xB3000000),
                  ],
                  stops: <double>[0.0, 0.5, 1.0],
                ),
              ),
              child: SizedBox.expand(),
            ),
          ),
        ),

        // 前景：只有顶部条与底部条占据命中区域，中间留空让事件穿透。
        Column(
          children: <Widget>[
            _topBar(),
            const Spacer(),
            _bottomBar(),
          ],
        ),
      ],
    );
  }

  Widget _topBar() {
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: '返回',
          onPressed: onBack,
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: foreground,
          ),
        ),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 显式白色：这里在黑色视频上，跟随主题会变成深色（亮色主题的坑）。
            style: const TextStyle(fontSize: 13, color: foreground),
          ),
        ),
        if (danmakuCount > 0)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '弹幕 $danmakuCount',
              style: const TextStyle(
                fontSize: 11,
                color: foregroundSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: playing ? '暂停' : '播放',
            onPressed: onTogglePlay,
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: foreground,
            ),
          ),
          ValueListenableBuilder<double>(
            valueListenable: progressMs,
            builder: (context, ms, _) => Text(
              '${formatDuration(Duration(milliseconds: ms.round()))}'
              ' / ${formatDuration(duration)}',
              // 同样是「黑底白字」：时间文字在视频上必须显式白色。
              style: const TextStyle(fontSize: 11, color: foreground),
            ),
          ),
          Expanded(child: progressBar),
          IconButton(
            tooltip: '弹幕开关',
            onPressed: onToggleDanmaku,
            icon: Icon(
              danmakuEnabled
                  ? Icons.subtitles_rounded
                  : Icons.subtitles_off_rounded,
              color: foreground,
            ),
          ),
          IconButton(
            tooltip: '弹幕设置',
            onPressed: onOpenDanmakuSettings,
            icon: const Icon(Icons.tune_rounded, color: foreground),
          ),
          IconButton(
            tooltip: '全屏',
            onPressed: onToggleFullscreen,
            icon: Icon(
              fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
