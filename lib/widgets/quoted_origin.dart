import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../data/models/content_item.dart';
import 'cached_image.dart';
import 'content_media.dart';

/// 时间线卡片里的「被转发的原动态」嵌套区块。
///
/// 视觉与结构对齐原型 `转发动态卡片.html` 的 `bg-nested` 块：
///
/// ```
/// ┌────────────────────────────────┐  底色 #F6F7F8 / 圆角 8 / 内边距 12
/// │ @原博主昵称                     │  14sp，微博蓝 #507DAF
/// │ 原动态正文，最多 3 行……          │  15sp / 行高 1.5
/// │ ┌──┬──┬──┐                     │  图文：1 图全宽 16:9
/// │ │  │  │  │                     │        2 图两列
/// │ └──┴──┴──┘                     │        ≥3 图三列九宫格
/// │ ┌─────────────────┐ ▶          │  视频：16:9 封面 + 右下角播放角标
/// │ └─────────────────┘            │
/// └────────────────────────────────┘
/// ```
///
/// ## 为什么整块是一个点击区
///
/// 需求写得很明确：「整个内嵌的灰色区域是一个 GestureDetector，点击后把当前展示的
/// UI 数据源从『转发者』切换为『原动态对象』，并压入一个新的详情页路由」。
/// 所以媒体区**也**归到同一个动作上（九宫格每一格同样打开原动态页），
/// 而不是让点图去看大图 —— 否则同一块灰色区域里一半点开详情、一半点开相册，
/// 用户没法预期。`ContentMedia` 的 `onTap` 因此被接成 `onOpen`。
///
/// ## 刻意省略的两个原型元素
///
/// - **`+ 关注`**：本 App 没有关注写能力，放一个点了没反应的按钮比不放更糟
///   （与 `_ActionItem` 同一条纪律）。
/// - **话题高亮**（`#明日方舟#` 渲染成微博蓝）：[ContentItem.summary] 是
///   `HtmlText.toPlainText` 清洗后的**纯文本**，标签信息已经丢了。
///   要还原就得回头改解析层保留富文本，那是数据层的接口变更，不归本轮。
///
/// ## 为什么不用 [ContentMedia] 画视频
///
/// `ContentMedia` 的视频角标是**居中**大按钮；原型与需求都要求「右下角盖一个
/// 播放按钮角标」。两套规则没法用一个参数兼容，所以视频这边单独画，
/// 图文那边继续复用 [ContentMedia]（它的「1 图全宽 / 2 图两列 / 多图九宫格」
/// 规则正好就是需求要的那条）。
class QuotedOrigin extends StatelessWidget {
  const QuotedOrigin({
    super.key,
    required this.origin,
    required this.onOpen,
    this.maxLines = 3,
  });

  /// 被转发的原动态（`ContentItem.origin`，解析层保证最多一层）。
  final ContentItem origin;

  /// 点击整块时执行：调用方负责 push 原动态详情页。
  final VoidCallback onOpen;

  /// 正文最多几行。卡片里给 3 行，详情页里可以给更多。
  final int maxLines;

  /// 区块圆角（原型 `rounded-lg`）。
  static const double radius = 8;

  /// 区块内边距（原型 `p-3`）。
  static const double inset = 12;

  /// 媒体区与正文之间的间距。
  static const double mediaGap = 8;

  /// 是不是视频形态。
  ///
  /// 只看 [ContentKind]：解析层已经把 B 站的 `major.archive` 与微博的
  /// `page_info.media_info` 都归成 [ContentKind.video]，再叠加 `videoRef`
  /// 判断会把「视频但没取到直链」错判成图文（那恰好是最需要显示播放角标的
  /// 情况 —— 点了才知道能不能播）。
  bool get isVideo => origin.kind == ContentKind.video;

  /// 正文：优先 `summary`（原话），为空退回 `title`。
  ///
  /// 与 [ContentCard] 同一套取法：`displayTitle` 会优先返回 `title`，
  /// 而这里要的是「原博主说了什么」。
  String get text {
    final String summary = origin.summary.trim();
    if (summary.isNotEmpty) return summary;
    return origin.title.trim();
  }

  /// 视频封面：优先图的序列，其次 `videoRef.coverUrl`。
  String? get _cover {
    if (origin.images.isNotEmpty) return origin.images.first;
    final String? fromRef = origin.videoRef?.coverUrl;
    if (fromRef == null || fromRef.isEmpty) return null;
    return fromRef;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      // 底色走 Material 而不是包一层 Container：水波纹要画在**底色之上**，
      // 外面再盖一个不透明 Container 会把 ripple 全遮住。
      color: AppColors.nested,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _authorLine(),
              if (text.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                _text(),
              ],
              if (isVideo) ...<Widget>[
                const SizedBox(height: mediaGap),
                _video(),
              ] else if (origin.images.isNotEmpty) ...<Widget>[
                const SizedBox(height: mediaGap),
                // 图文九宫格：规则与卡片媒体区完全一致，直接复用。
                // `onTap` 接 `onOpen` —— 整块灰色区域是**同一个**动作。
                ContentMedia(
                  images: origin.images,
                  onTap: (_) => onOpen(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// `@原博主`。原型这一行右侧还有 `+ 关注`，本 App 没有关注能力，省略。
  Widget _authorLine() {
    final String name =
        origin.authorName.isEmpty ? '原动态作者' : origin.authorName;
    return Text(
      '@$name',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 14,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: AppColors.weiboMention,
      ),
    );
  }

  Widget _text() {
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 15,
        height: 1.5,
        color: AppColors.textPrimary,
      ),
    );
  }

  /// 视频：16:9 封面 + 右下角播放角标（需求指定位置）。
  Widget _video() {
    final String? cover = _cover;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // 没有封面也要占住 16:9：那块位置本身就是「这里是个视频」的
                // 视觉信号，塌成 0 高度会让人以为是纯文字转发。
                if (cover == null)
                  _videoPlaceholder()
                else
                  CachedImage(
                    url: cover,
                    width: double.infinity,
                    height: double.infinity,
                    // 16:9 全宽：屏宽 ~311dp 时 ≈ 933px，覆盖 3x DPR。
                    cacheWidth: (width * 3).round(),
                    fit: BoxFit.cover,
                    placeholder: _videoPlaceholder(),
                    errorWidget: _videoPlaceholder(),
                  ),
                const Positioned(right: 8, bottom: 8, child: _PlayBadge()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _videoPlaceholder() => const ColoredBox(
        color: AppColors.placeholder,
        child: Center(
          child: Icon(
            Icons.videocam_outlined,
            size: 22,
            color: AppColors.textSecondary,
          ),
        ),
      );
}

/// 视频封面右下角的播放角标。
///
/// 用纯色圆底 + 图标，不叠 `BackdropFilter`：毛玻璃在长列表里会显著掉帧
/// （项目硬约束：列表条目内禁止 Opacity / BackdropFilter / ShaderMask）。
class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: const BoxDecoration(
        color: Colors.black45,
        shape: BoxShape.circle,
      ),
      child: const Center(
        child: Icon(
          Icons.play_arrow_rounded,
          size: 22,
          color: Colors.white,
        ),
      ),
    );
  }
}
