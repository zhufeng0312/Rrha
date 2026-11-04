import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

/// 播放页的「一排统计数字」：播放 / 弹幕 / 点赞 / 投币 / 收藏 / 分享 / 评论。
///
/// ## 为什么单独一个文件
///
/// 这是 `docs/BILI_HANDOFF.md` §3.1 的 P0 项：`BiliVideoInfo` **早就解析了**
/// `likeCount / coinCount / favoriteCount / shareCount / replyCount / view /
/// danmakuCount`，但播放页只拼了其中两个（播放数与弹幕数），其余六个字段
/// 一直躺在模型里没人读。
///
/// 抽成独立组件的两个理由：
/// 1. 它是纯展示、零依赖，可以直接写 widget 测试把「哪个字段显示在哪个图标后面」
///    钉死（数字错位是这类组件最常见的回归，而真机上肉眼很难发现「投币」位置
///    其实是收藏数）；
/// 2. 播放页那个文件同时被多个会话盯着（`lib/features/player/player_page.dart`），
///    能少改它就少改。
///
/// ## 展示规则
///
/// - **0 也显示**：播放量 / 点赞这些「确实是 0」和「接口没给」在
///   [BiliVideoInfo] 里已经合流成 `int`（接口缺字段就是 0），因此这里统一按
///   「0 显示 0」处理，不做「>0 才显示」的特殊分支 —— 空一排图标比显示
///   0 更让人困惑。
/// - 大数字按 B 站习惯折算（`12.3万` / `1.2亿`），折算逻辑在 [formatCount]。
/// - 评论数可点：点击回调由调用方决定（通常是滚到评论区），图标下面那条
///   数字会跟着变成链接色，明确「这里能点」。
class VideoStatsRow extends StatelessWidget {
  const VideoStatsRow({
    super.key,
    required this.view,
    required this.danmaku,
    required this.like,
    required this.coin,
    required this.favorite,
    required this.share,
    required this.reply,
    this.onTapReply,
  });

  final int view;
  final int danmaku;
  final int like;
  final int coin;
  final int favorite;
  final int share;
  final int reply;

  /// 点「评论」时的回调。为 null 时评论数不可点（不画可点样式）。
  final VoidCallback? onTapReply;

  /// B 站口径的大数字折算。
  ///
  /// 保留一位小数：`1.2万` 比 `12345` 好读，但 `1万` 会丢掉一个数量级的精度。
  /// 负数（理论上不会出现）原样输出，不做特殊处理。
  static String formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return '$value';
  }

  @override
  Widget build(BuildContext context) {
    final entries = <Widget>[
      _item(Icons.play_circle_outline_rounded, '播放', view),
      _item(Icons.subtitles_outlined, '弹幕', danmaku),
      _item(Icons.thumb_up_outlined, '点赞', like),
      _item(Icons.paid_outlined, '投币', coin),
      _item(Icons.star_border_rounded, '收藏', favorite),
      _item(Icons.share_outlined, '分享', share),
      _item(
        Icons.chat_bubble_outline_rounded,
        '评论',
        reply,
        onTap: onTapReply,
      ),
    ];

    return Wrap(
      spacing: 18,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: entries,
    );
  }

  Widget _item(
    IconData icon,
    String? tooltip,
    int value, {
    VoidCallback? onTap,
  }) {
    final tappable = onTap != null;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 15,
          color: tappable ? AppColors.link : AppColors.textSecondary,
        ),
        const SizedBox(width: 4),
        Text(
          formatCount(value),
          style: TextStyle(
            fontSize: 12,
            color: tappable ? AppColors.link : AppColors.textSecondary,
          ),
        ),
      ],
    );

    final body = tooltip == null
        ? row
        : Tooltip(message: tooltip, child: row);

    if (!tappable) return body;
    // 可点项必须自带足够大的命中区：12 号字 + 15px 图标本身只有约 40×18，
    // 手指点不准。上下各扩 8px 把命中区做到 32px 以上（Material 的最小
    // 可点尺寸是 48，但在这一排统计里撑到 48 会让行高翻倍，32 是折中值）。
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: body,
      ),
    );
  }
}
