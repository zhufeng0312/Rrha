import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import 'cached_image.dart';

/// 卡片媒体区：B 站动态页式布局（见 `docs/UI_HANDOFF.md` §1.3 / §3.3）。
///
/// 渲染规则：
/// - **0 张 → 什么都不渲染**（不留空、不留占位）。无图不渲染媒体区是硬性要求；
/// - **1 张 → 全宽 `AspectRatio(16/9)`**，圆角 8，`BoxFit.cover`；视频再叠播放图标；
/// - **2 张 → 两列**正方形；
/// - **≥3 张 → 三列九宫格**正方形，最多 9 张，超出部分在最后一格叠 `+N`。
///
/// ## 为什么不复用 [PhotoGrid]
///
/// 详情页那边是「1 张 4:3 限高 260 / 4 张两列」，那是详情页的用户决策
/// （竖图会把整页顶穿）；卡片规范要「1 张 16:9 全宽 / 3 张以上三列」。
/// 两者规则不同，改 [PhotoGrid] 的默认值会牵动详情页，所以卡片走这个独立组件
/// （决策 D2 / D3）。新建文件也不碰任何现有文件，天然不与别的会话冲突。
///
/// 组件保持 `StatelessWidget` 且不订阅 provider：它和 [ContentCard] 一样是
/// 纯展示组件，只靠入参渲染。
class ContentMedia extends StatelessWidget {
  const ContentMedia({
    super.key,
    required this.images,
    required this.onTap,
    this.isVideo = false,
    this.spacing = 4,
    this.radius = 8,
    this.videoDuration,
    this.videoIsVertical,
  });

  /// 全部图片地址（已归一化为 https）。为空时本组件不渲染任何东西。
  final List<String> images;

  /// 点击第 [index] 张图（0 起）。调用方负责 push 全屏预览页。
  final void Function(int index) onTap;

  /// 是否是视频内容：单图时在中央叠一个播放图标，并在右下角显示时长。
  final bool isVideo;

  /// 视频时长；为 null 时**不显示**时长角标（接口没给就不编）。
  final Duration? videoDuration;

  /// 视频是否竖屏。竖屏时封面改为「居中留边」而不是 `cover` 硬裁 —
  /// 实测竖屏视频封面是 480×853，裁成 16:9 会把主体切掉一大半。
  final bool? videoIsVertical;

  /// 格子间距（规范 4）。
  final double spacing;

  /// 圆角（规范 8）。
  final double radius;

  /// 最多渲染几张（第 10 张起折进 `+N`）。
  static const int maxTiles = 9;

  /// 列数：2 张两列，其余（≥3）三列。
  ///
  /// **刻意与 [PhotoGrid.columnsFor] 不同**：那边把 4 张判成两列（详情页决策），
  /// 卡片规范是「3 张以上 → 三列」。别直接抄。
  static int columnsFor(int count) {
    if (count <= 1) return 1;
    if (count == 2) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    if (images.length == 1) return _single();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        // 列数按**实际显示的张数**算：10 张时折成 9 格，仍是三列。
        final int shown = images.length > maxTiles ? maxTiles : images.length;
        final int cols = columnsFor(shown);
        final double tile = (width - spacing * (cols - 1)) / cols;
        final int hidden = images.length - shown;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (int i = 0; i < shown; i++)
              SizedBox(
                width: tile,
                height: tile,
                child: _tile(
                  index: i,
                  // 最后一格且还有更多图 → 叠 +N。
                  extraBadge: (hidden > 0 && i == shown - 1) ? hidden : null,
                  cacheWidth: (tile * 3).round(),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 单图：全宽 16:9（不复用 `PhotoGrid` 的 4:3 限高分支）。
  ///
  /// 视频时按 B 站视频卡片排版：
  /// - 封面 16:9 圆角 8；
  /// - **中央**一个大播放按钮（`_CenterPlayButton`）；
  /// - **右下角**时长角标（有 `videoDuration` 才显示）。
  Widget _single() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        // 竖屏视频用 contain 居中留边：硬 cover 会把竖构图主体裁掉。
        final bool vertical = isVideo && (videoIsVertical ?? false);
        return AspectRatio(
          aspectRatio: 16 / 9,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // 竖屏视频铺一层深色底，留边处不至于露出卡片白底显得突兀。
                  if (vertical) const ColoredBox(color: Colors.black),
                  CachedImage(
                    url: images.first,
                    width: double.infinity,
                    height: double.infinity,
                    // 16:9 全宽：屏幕宽 ~311dp 时 ≈ 933px，覆盖 3x DPR 足够。
                    cacheWidth: (width * 3).round(),
                    fit: vertical ? BoxFit.contain : BoxFit.cover,
                    placeholder: _placeholder(),
                    errorWidget: _placeholder(),
                  ),
                  if (isVideo) ...<Widget>[
                    const Center(child: _CenterPlayButton()),
                    if (videoDuration != null)
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: _DurationBadge(duration: videoDuration!),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tile({
    required int index,
    required int cacheWidth,
    int? extraBadge,
  }) {
    return GestureDetector(
      // 用 opaque 让整格可点（图片加载失败时的灰底占位也要能点开预览）。
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // `cacheWidth` 是**硬要求**：9 张 1080p 原图按原尺寸解码会直接
            // 吃掉 9 × ~4MB 内存，滚动时必被系统杀（详见 photo_grid.dart 的注释）。
            CachedImage(
              url: images[index],
              width: double.infinity,
              height: double.infinity,
              cacheWidth: cacheWidth,
              fit: BoxFit.cover,
              placeholder: _placeholder(),
              errorWidget: _placeholder(),
            ),
            if (extraBadge != null)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Text(
                      '+$extraBadge',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 灰底占位：亮色规范下用浅灰，不留白、不抛异常。
  Widget _placeholder() => const ColoredBox(
        color: AppColors.placeholder,
        child: Center(
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 18,
            color: AppColors.textSecondary,
          ),
        ),
      );
}

/// 视频卡中央的播放按钮（B 站视频卡片同位置）。
///
/// 刻意**不用** `BackdropFilter` 做毛玻璃：列表内禁止该用法（会显著掉帧，
/// 项目硬约束），所以是「半透明黑圆 + 白三角」的纯色方案。
class _CenterPlayButton extends StatelessWidget {
  const _CenterPlayButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        // 比旧角标的 black45 更深一档：封面常是浅色（白发角色等），
        // 太淡会让播放按钮糊在画面里看不见。
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        size: 34,
        color: Colors.white,
      ),
    );
  }
}

/// 右下角时长角标：`mm:ss` 或 `h:mm:ss`。
///
/// 底色用黑色半透明 + 圆角，保证在亮/暗封面上都能读。
class _DurationBadge extends StatelessWidget {
  const _DurationBadge({required this.duration});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        formatDuration(duration),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 时长格式化：`1:05` / `1:02:03`。
///
/// 抽成顶层函数是为了能被单测直接调用（widget 私有类测不到）。
/// 负数与 0 都输出 `0:00`：宁可显示 0:00，也不显示 `-1:-1` 这种脏数据。
String formatDuration(Duration duration) {
  final int total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final int s = total % 60;
  final String ss = s.toString().padLeft(2, '0');
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:$ss';
  }
  return '$m:$ss';
}
