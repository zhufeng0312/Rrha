import 'package:flutter/material.dart';

import '../data/models/content_item.dart';
import 'cached_image.dart';

/// 来源标签：每条内容必须显示 Bilibili 或 微博（需求硬性要求）。
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.platform, this.compact = false});

  final Platform platform;
  final bool compact;

  static Color colorOf(Platform platform) => switch (platform) {
        Platform.bilibili => const Color(0xFF00A1D6),
        Platform.weibo => const Color(0xFFE6162D),
      };

  @override
  Widget build(BuildContext context) {
    final color = colorOf(platform);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 7,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        platform.label,
        style: TextStyle(
          color: color,
          fontSize: compact ? 10 : 11,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 内容形态标签（视频 / 动态 / 转发）。
class KindBadge extends StatelessWidget {
  const KindBadge({super.key, required this.kind});

  final ContentKind kind;

  String get _label => switch (kind) {
        ContentKind.video => '视频',
        ContentKind.dynamic => '动态',
        ContentKind.article => '文章',
        ContentKind.repost => '转发',
        ContentKind.unknown => '内容',
      };

  IconData get _icon => switch (kind) {
        ContentKind.video => Icons.play_circle_outline_rounded,
        ContentKind.dynamic => Icons.chat_bubble_outline_rounded,
        ContentKind.article => Icons.article_outlined,
        ContentKind.repost => Icons.repeat_rounded,
        ContentKind.unknown => Icons.help_outline_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(_icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(
          _label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 「新内容」角标（App 内标记，不做系统推送）。
class NewBadge extends StatelessWidget {
  const NewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFFF6699),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'NEW',
        style: TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
      ),
    );
  }
}

/// 封面容错组件：加载失败或为空时显示灰底图标，不留白。
///
/// 图片走 [CachedImage]（内存 + **磁盘**双层）：时间线卡片是最热的滚动路径，
/// 只有内存缓存时一屏 9 图动态就能把 Flutter 的 ImageCache 挤爆，
/// 逐出后滚回来只能重新联网 —— 那就是「滚走再滚回封面重新加载」的根因。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.width = 120,
    this.height = 76,
    this.borderRadius = 8,
  });

  final String? url;
  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return CachedImage(
      url: url,
      width: width,
      height: height,
      borderRadius: borderRadius,
      // 卡片封面尺寸固定且不大，按显示宽度 ×3 解码（覆盖 3x DPR）。
      cacheWidth: (width * 3).round(),
    );
  }
}
