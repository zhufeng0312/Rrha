import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import 'cached_image.dart';

/// 动态图片的九宫格缩略图。
///
/// 为什么需要它：详情页早先只渲染一张 16:9 封面，而实测一条动态最多有 **9 张**
/// 图（`major.opus.pics[]`，见 `.env/probe_media_repost2.py` 的 121 条样本），
/// 结果「多图动态只显示第一张」。
///
/// 列数规则（用户已选定）：
/// - 1 张 → 单张大图（**限高**，不撑满屏幕，否则一张竖图会把详情页顶穿）；
/// - 2 张 / 4 张 → 两列；
/// - 其余（3、5、6、7、8、9）→ 三列。
///
/// 尺寸刻意用 [LayoutBuilder] 按可用宽度算，而不是写死像素：
/// 华为 P40 Pro 是 1200x2640 的高密度屏，写死宽高在不同 DPR 上会歪。
class PhotoGrid extends StatelessWidget {
  const PhotoGrid({
    super.key,
    required this.images,
    required this.onTap,
    this.spacing = 4,
    this.radius = 8,
    this.maxSingleHeight = 260,
    this.aspectRatios,
    this.singleFit = BoxFit.cover,
  });

  /// 全部图片地址（已归一化为 https）。为空时本组件不渲染任何东西。
  final List<String> images;

  /// 点击第 [index] 张图（0 起）。由调用方负责 push 全屏预览页。
  final void Function(int index) onTap;

  /// 格子间距（用户选定 4）。
  final double spacing;

  /// 圆角（用户选定 8）。
  final double radius;

  /// 单张图模式的高度上限。
  final double maxSingleHeight;

  /// 每张图的**真实宽高比**（`宽 / 高`），可为 null。
  ///
  /// 为什么需要它：B 站评论里的图经常是手机截图或超长竖图
  /// （探针实测有 `1080×9109`，宽高比 0.12）。默认的「单图按 4:3 取高 +
  /// `BoxFit.cover`」会把这种图裁到只剩中间一小条，用户根本看不出截的是什么。
  ///
  /// 给了比例后：单图按真实比例算高（仍受 [maxSingleHeight] 夹住），
  /// 并用 [singleFit]（评论侧传 `BoxFit.contain`）完整显示 —— 宁可上下留白，
  /// 也不要把内容裁掉。
  ///
  /// 数组长度不足 / 元素为 null / 比例异常时，回落默认策略。
  final List<double?>? aspectRatios;

  /// 单图模式的填充方式。多图九宫格恒为 `cover`（正方格必须裁）。
  final BoxFit singleFit;

  /// 列数：1 张单独处理，2/4 张两列，其余三列。
  static int columnsFor(int count) {
    if (count <= 1) return 1;
    if (count == 2 || count == 4) return 2;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (images.length == 1) return _single(context, width);

        final cols = columnsFor(images.length);
        final tile = (width - spacing * (cols - 1)) / cols;
        // 九宫格一律正方格：不等高会导致最后一行残缺时看起来像「图没加载完」。
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (int i = 0; i < images.length; i++)
              SizedBox(
                width: tile,
                height: tile,
                child: _tile(context, i, (tile * 3).round()),
              ),
          ],
        );
      },
    );
  }

  /// 单张图的高度：有真实比例按比例算（再夹住上限），否则退回 4:3。
  ///
  /// 下限 120 是防「极端宽幅图」把容器压成一条缝（例如 1771×1080 的横图
  /// 在窄屏上按比例只有几十像素高，图就看不清了）。
  ///
  /// ## 只有**真正的长截图**才裁，普通图按原样完整展示
  ///
  /// 用户 2026-11-02 的明确要求：「有些并不是很长的图片不需要只显示一部分，
  /// 正常展示即可。」所以判据不是「有没有超过上限」，而是跨度更大的两档：
  ///
  /// | 情况 | 高度 | 显示 |
  /// | --- | --- | --- |
  /// | 普通图（比例 ≥ [tallRatio]，即高 ≤ 2×宽） | 按比例 | **完整**（不裁） |
  /// | 长截图（比例 < [tallRatio]） | 夹到 [maxSingleHeight] | 只露顶部一段 + 角标 |
  ///
  /// 为什么用「高 > 2×宽」而不是「超过 maxSingleHeight」：一张 1080×1959 的
  /// 手机截图（比例 0.55）按宽度铺满就是 2 倍宽高，它**应该完整显示**；
  /// 而 1080×9109 的整页截图（比例 0.12）才是真该裁的。用上限当判据会把
  /// 前者也裁掉一截 —— 那正是用户说的「并不是很长的图片」。
  static const double tallRatio = 0.5;

  double _singleHeight(double width) {
    final ratio = aspectRatios?.firstOrNull;
    if (ratio == null || ratio <= 0 || !ratio.isFinite) {
      final h = width * 3 / 4;
      final cap = math.max(minSingleHeight, maxSingleHeight);
      return h.clamp(minSingleHeight, cap);
    }
    final needed = width / ratio;
    // 普通图：完整显示，**不受 maxSingleHeight 限制**（上限只为长截图服务）。
    if (!_isTallImage(ratio)) {
      return needed < minSingleHeight ? minSingleHeight : needed;
    }
    final cap = math.max(minSingleHeight, maxSingleHeight);
    return needed.clamp(minSingleHeight, cap);
  }

  /// 单图最小高度：防「极端宽幅图」（如 1771×1080 的横图）在窄屏上
  /// 按比例算出几十像素，缩成一条缝。
  static const double minSingleHeight = 120;

  /// 是否属于「长截图」（需要裁切显示）。
  static bool _isTallImage(double? ratio) =>
      ratio != null && ratio > 0 && ratio.isFinite && ratio < tallRatio;

  /// 这张图在**当前格子**里是否被裁掉了（只显示了原图的一部分）。
  ///
  /// 判据是「长截图 **且** 按宽度算出来的高度超过格子高」——
  /// 两个条件缺一不可：普通图即使被夹高也不算「裁」（那种情况不会发生，
  /// 因为 [_singleHeight] 对普通图不限高）。
  bool isCropped({
    required double containerWidth,
    required double containerHeight,
    int index = 0,
  }) {
    final ratio = index < (aspectRatios?.length ?? 0)
        ? aspectRatios![index]
        : null;
    if (!_isTallImage(ratio)) return false;
    if (containerWidth <= 0 || containerHeight <= 0) return false;
    final neededHeight = containerWidth / ratio!;
    // 留 1px 容差，避免浮点误差导致角标在「刚好放得下」时闪一下。
    return neededHeight > containerHeight + 1;
  }

  /// 单图最终的 fit：被裁时用 `cover`（铺满格子），否则用调用方给的值。
  BoxFit singleFitForHeight({
    required double containerWidth,
    required double height,
  }) {
    if (isCropped(containerWidth: containerWidth, containerHeight: height)) {
      return BoxFit.cover;
    }
    return singleFit;
  }

  /// 单张图：按真实比例（拿不到比例时 4:3）并限高，避免竖图把详情页撑穿。
  ///
  /// ## 为什么没有「长图 · 点击查看」角标（2026-11-02 第四轮）
  ///
  /// 早先这里在右下角贴了一个黑色角标，用来提示「这张图被裁了，点开能看全」。
  /// 用户看过真机效果后要求**去掉**：长图本身已经能从画面判断出是截屏，
  /// 角标反而压在图上挡住了内容。所以只保留「裁切 + 从顶部露」这两个行为，
  /// 不再有任何视觉提示。
  ///
  /// 注意：角标去掉**不影响** [isCropped] / [singleFitForHeight] ——
  /// 它们决定的是「怎么显示」，与「显不显示提示」是两件事。
  Widget _single(BuildContext context, double width) {
    final double height = _singleHeight(width);
    final bool cropped = isCropped(
      containerWidth: width,
      containerHeight: height,
    );
    return SizedBox(
      width: width,
      height: height,
      child: _tile(
        context,
        0,
        (width * 3).round(),
        fit: singleFitForHeight(containerWidth: width, height: height),
        // 被裁的图从**顶部**开始露：长截图的开头（标题/页头）才是
        // 「这是什么图」的关键。默认居中会把最有信息的那段裁掉。
        alignment: cropped ? Alignment.topCenter : Alignment.center,
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    int index,
    int cacheWidth, {
    BoxFit? fit,
    Alignment? alignment,
  }) {
    return GestureDetector(
      // 用 opaque 让整格可点（图片加载失败时的灰底占位也要能点开预览）。
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap(index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: _thumb(index, cacheWidth, fit: fit, alignment: alignment),
      ),
    );
  }

  /// 缩略图。
  ///
  /// `cacheWidth` 是**硬要求**：9 张 1080p 原图按原尺寸解码会直接吃掉
  /// 9 × ~4MB 的内存，滚动时必被系统杀。这里按「显示宽度 × 3（覆盖 3x DPR）」
  /// 做解码压缩，实测 3 列格子 ≈ 120 × 3 = 360px，足够清晰。
  ///
  /// ⚠️ B 站评论图单张可达 **3.5MB**（探针实测，另有一张 GIF 4MB），
  /// 不压缩解码就是「滚两条评论吃光内存」。
  ///
  /// 图片走 [CachedImage]：缩略图在磁盘上留一份，九宫格整块滚走再滚回时
  /// 不会重新联网（内存缓存根本装不下 9 张原图）。
  Widget _thumb(int index, int cacheWidth, {BoxFit? fit, Alignment? alignment}) {
    return CachedImage(
      url: images[index],
      width: double.infinity,
      height: double.infinity,
      cacheWidth: cacheWidth,
      fit: fit ?? BoxFit.cover,
      // 被裁的长图从顶部露：长截图的开头（标题/页头）才是「这是什么图」的关键。
      alignment: alignment ?? Alignment.center,
      placeholder: _placeholder(),
      errorWidget: _placeholder(),
    );
  }

  /// 灰底占位：与 [CoverImage] 同风格，不留白、不抛异常。
  ///
  /// 尺寸交给父级约束（网格是正方形、单图是限高矩形），
  /// 所以这里刻意不写死宽高 —— 写死会让占位块与外框对不上、看起来像没加载完。
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
