import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

/// 视频简介：默认折叠成两行，超出时才显示「展开 / 收起」。
///
/// `docs/BILI_HANDOFF.md` §3.2：`BiliVideoInfo.description` 早就解析了
/// （`/x/web-interface/view` 的 `desc`），但**从来没有渲染过** ——
/// 用户看得到标题、看得到播放量，唯独看不了 UP 主写的那段话，
/// 而这恰恰是「这视频讲什么」最有用的信息。
///
/// ## 三个刻意的取舍
///
/// 1. **空简介不占位**：直接 `SizedBox.shrink()`，而不是画一个空框。
///    播放页头部是固定高度，任何空占位都会从小屏上挤掉评论区的可见行数。
/// 2. **只在真的折行时才给「展开」**：靠 [LayoutBuilder] + [TextPainter]
///    预量两行高度来判断。不加这个判断的话，短简介下面会挂一个点了也没变化的
///    「展开」按钮（真机上显得很傻）。
/// 3. **B 站简介里的换行要保留**：`desc` 里常常是「时间轴 + 空行」的排版，
///    用纯文本 + `softWrap` 就是原意；转成单行会把这些结构全抹平。
class VideoDescription extends StatefulWidget {
  const VideoDescription({
    super.key,
    required this.text,
    this.maxLines = 2,
  });

  /// 简介原文。允许带 `\n`。
  final String text;

  /// 折叠时显示几行。
  final int maxLines;

  @override
  State<VideoDescription> createState() => _VideoDescriptionState();
}

class _VideoDescriptionState extends State<VideoDescription> {
  bool _expanded = false;

  static const TextStyle _style = TextStyle(
    fontSize: 12,
    height: 1.5,
    color: AppColors.textSecondary,
  );

  @override
  void didUpdateWidget(covariant VideoDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切分 P 或换视频后简介会变：不重置的话，「展开」状态会带到下一个视频上。
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // 预量：把同样的文本按同样的样式排一遍，看折叠高度放不放得下。
        final painter = TextPainter(
          text: TextSpan(text: text, style: _style),
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.topCenter,
              child: Text(
                text,
                maxLines: _expanded ? null : widget.maxLines,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: _style,
              ),
            ),
            if (overflows)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  // 只有文字本身在 12 号字下约 16px 高，手指很难点准；
                  // 上下补一点内边距把命中区做到 28px 左右。
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _expanded ? '收起' : '展开',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.link,
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 14,
                        color: AppColors.link,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
