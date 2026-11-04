import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/html_text.dart';
import '../../core/utils/time_parse.dart';
import '../../data/models/content_item.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/photo_grid.dart';
import '../gallery/image_gallery_page.dart';

/// B 站动态详情页的**正文骨架**（纯文字 / 带图两种形态）。
///
/// ## 参考稿里有两个页面，对应两种形态
///
/// 用户给的参考稿（`桌面/动态内部.html`）并不是一个页面，而是**并列的两屏**：
///
/// | 参考稿 | id | 昵称色 | 正文字号 | 图片区 |
/// | --- | --- | --- | --- | --- |
/// | 带图动态 | `page-detail-image` | `text-pink`（品牌粉） | `text-[15px]` | 全宽大图 |
/// | 纯文字动态 | `page-detail-text` | `text-primary`（正文深色） | `text-[16px]` | **无** |
///
/// 这看起来像「参考稿自己不一致」，其实是 B 站真实的样子：纯文字动态没有
/// 媒体区抢视觉，字号和配色都更「正文」。用户明确要求
/// 「严格按照 html 里纯文字动态的样子来做」，所以这里按 `images.isEmpty`
/// 分档，而不是统一成一种。
///
/// 两档共用的骨架（顺序与参考稿一致）：
///
/// ```
/// ◯48  作者昵称                     ← 作者行
///      2026-11-02 18:08
/// [独立标题]                        ← 仅当动态真的有标题（见 hasOwnTitle）
/// 正文（15px 或 16px，行高 1.6）
/// [原动态区块 / 图片区]
/// 评论 N    赞和转发 M               ← 数据栏（评论数品牌粉加粗）
/// ─────────────────────────
/// 评论列表
/// ```
///
/// ## 为什么单独抽出来
///
/// 页面有**两个入口**，过去各写一套，结果同一条动态从两条路点进去长得不一样：
/// - 「按 BV 号 / 动态链接打开」→ `OpusDetailPage`
/// - 时间线卡片点开 → `ContentDetailPage`
///
/// 两个页面现在都只负责 AppBar / 加载态 / 评论入口，正文一律走这里，
/// 视觉不可能再分叉。
///
/// ## 与参考稿刻意不一致的两处
///
/// 1. **不放 SourceBadge / KindBadge**：参考稿没有，且两个页面的 AppBar 标题
///    已经写着「Bilibili · 动态」——「每条内容必须显示来源」这条需求仍然满足，
///    不需要在正文里再贴一次标签。
/// 2. **不做 IP 属地、点赞/投币按钮**：参考稿明确去掉了 IP 属地；写操作本 App
///    没有能力，画出来只会点了没反应。
class BiliDynamicBody extends StatelessWidget {
  const BiliDynamicBody({
    super.key,
    required this.item,
    required this.commentSection,
    this.originBlock,
  });

  final ContentItem item;

  /// 评论区。**由调用方提供**：两个页面的评论入口来源不同
  /// （`ContentDetailPage` 用 `ContentItem.commentOid`，
  /// `OpusDetailPage` 用 detail 接口的 `basic.comment_id_str`）。
  final Widget commentSection;

  /// 转发动态的原动态区块（插在正文之后、图片之前）。
  ///
  /// 参考稿没有转发态样例，这里沿用既有 `_OriginBlock` 的视觉，
  /// 不自己发明一套。
  final Widget? originBlock;

  @override
  Widget build(BuildContext context) {
    final String body = item.summary.trim();
    final String title = BiliDynamicStyle.hasOwnTitle(item) ? item.title.trim() : '';

    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              BiliAuthorRow(item: item),
              const SizedBox(height: 12),
              // 真标题只在这里出现一次。动态没有标题时解析层把 title 兜底成
              // 「正文首行截 60 字」，那种情况 hasOwnTitle 返回 false ——
              // 这正是「同一条动态内容出现两次」的根因。
              if (title.isNotEmpty) ...<Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (body.isNotEmpty) ...<Widget>[
                _BodyText(item: item, text: body),
                const SizedBox(height: 12),
              ],
              if (originBlock != null) ...<Widget>[
                originBlock!,
                const SizedBox(height: 12),
              ],
              if (item.images.isNotEmpty) ...<Widget>[
                _media(context),
                const SizedBox(height: 12),
              ],
              BiliStatRow(item: item),
            ],
          ),
        ),
        const Divider(height: 1),
        // 评论区**不加左右 padding**：`CommentSection` 自己已经内建 16，
        // 外面再加一层就会让头像/文案比正文多缩进 16（参考稿是一致的）。
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: commentSection,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// 图片区：**与微博板块同一套规则**（[PhotoGrid]）。
  ///
  /// 用户要求「图片展示方法参考微博板块」，所以这里不是另写一份：
  /// 单图按真实比例完整展示、多图九宫格、长截图只露顶部一段 + 角标、
  /// 点开走全屏预览。参数与 `OpusDetailPage` 保持完全一致。
  Widget _media(BuildContext context) {
    return PhotoGrid(
      images: item.images,
      maxSingleHeight: 420,
      singleFit: BoxFit.cover,
      onTap: (int i) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImageGalleryPage(
            images: item.images,
            initialIndex: i,
            title: item.displayTitle,
          ),
        ),
      ),
    );
  }
}

/// 两档形态的字号 / 配色，集中一处。
class BiliDynamicStyle {
  BiliDynamicStyle._();

  /// 头像直径（参考稿 `w-12 h-12`）。
  static const double avatarSize = 48;

  /// 头像解码宽（3x DPR）。
  static const int avatarCacheWidth = 144;

  /// 昵称字号（参考稿 `text-[16px]`）。
  static const double nameSize = 16;

  /// 时间字号（参考稿 `text-[12px]`）。
  static const double timeSize = 12;

  /// 带图动态正文字号（参考稿 `text-[15px]`）。
  static const double bodySizeWithMedia = 15;

  /// 纯文字动态正文字号（参考稿 `text-[16px]`）。
  static const double bodySizeTextOnly = 16;

  /// 正文行高（参考稿 `leading-relaxed`）。
  static const double bodyHeight = 1.6;

  /// 数据栏字号（参考稿 `text-[14px]`）。
  static const double statSize = 14;

  /// 昵称色：纯文字动态用正文深色，带图动态用品牌粉。
  static Color nameColorFor(ContentItem item) =>
      item.images.isEmpty ? AppColors.textPrimary : AppColors.weiboName;

  /// 正文字号：同上分档。
  static double bodySizeFor(ContentItem item) =>
      item.images.isEmpty ? bodySizeTextOnly : bodySizeWithMedia;

  /// 这条动态是不是有**独立标题**（与正文不同的那种）。
  ///
  /// 为什么必须判：解析层在没有标题时把 `title` 兜底成
  /// 「正文首行截 60 字」（见 `BiliContentParser._fromDynamic` 的
  /// `effectiveTitle`）。若把 `title` 无条件当标题渲染，纯文字动态就会
  /// **标题 = 正文首行、下面再整段正文** —— 真机上看到的「动态内容出现两次」。
  ///
  /// 兜底标题共三种形态，都要挡：
  /// 1. **正文首行**（截 60 字）—— 最普遍；
  /// 2. **`[图片]`**（纯图片动态，正文为空）—— 它是占位符不是文案；
  /// 3. **`（无标题）`**（`ContentItem.displayTitle` 的最终兜底）。
  static bool hasOwnTitle(ContentItem item) {
    final String t = item.title.trim();
    if (t.isEmpty) return false;
    if (_placeholderTitles.contains(t)) return false;
    final String s = item.summary.trim();
    // 只有标题没有正文（专栏 / 抽奖这类）：标题当然要显示。
    if (s.isEmpty) return true;
    // 正文以标题开头：那是兜底标题，不是独立标题。
    if (s.startsWith(t)) return false;
    return t != HtmlText.truncate(HtmlText.singleLine(s), 60);
  }

  /// 解析层 / UI 层会产生的**占位**标题，渲染出来就是假的正文。
  static const Set<String> _placeholderTitles = <String>{
    '[图片]',
    '[视频]',
    '[动态]',
    '（无标题）',
  };

  /// 发布时间。不可靠时如实说「抓取于」，不拿抓取时间冒充发布时间。
  static String timeText(ContentItem item) {
    final DateTime? t = item.publishedAt;
    if (t != null && item.hasReliableTime) return TimeParse.absolute(t);
    return '抓取于 ${TimeParse.absolute(item.fetchedAt)}';
  }

  /// 计数折算：`1042` → `1042`，`12345` → `1.2万`。
  static String count(int v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    return '$v';
  }
}

/// 作者行：48px 圆头像 + 昵称 + 发布时间。
class BiliAuthorRow extends StatelessWidget {
  const BiliAuthorRow({super.key, required this.item});

  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        ClipOval(
          child: CachedImage(
            url: item.authorAvatar,
            width: BiliDynamicStyle.avatarSize,
            height: BiliDynamicStyle.avatarSize,
            cacheWidth: BiliDynamicStyle.avatarCacheWidth,
            fit: BoxFit.cover,
            placeholder: _placeholder(),
            errorWidget: _placeholder(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.authorName.isEmpty ? '（未知作者）' : item.authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: BiliDynamicStyle.nameSize,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: BiliDynamicStyle.nameColorFor(item),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                BiliDynamicStyle.timeText(item),
                style: const TextStyle(
                  fontSize: BiliDynamicStyle.timeSize,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 头像兜底：首字母圆形占位，不留白、不抛异常。
  Widget _placeholder() {
    final String first =
        item.authorName.isEmpty ? '?' : item.authorName.characters.first;
    return Container(
      width: BiliDynamicStyle.avatarSize,
      height: BiliDynamicStyle.avatarSize,
      color: AppColors.placeholder,
      alignment: Alignment.center,
      child: Text(
        first,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// 正文段落。
class _BodyText extends StatelessWidget {
  const _BodyText({required this.item, required this.text});

  final ContentItem item;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: BiliDynamicStyle.bodySizeFor(item),
        height: BiliDynamicStyle.bodyHeight,
        color: AppColors.textPrimary,
      ),
    );
  }
}

/// 数据栏：`评论 N    赞和转发 M`（参考稿写法，评论数是品牌粉加粗）。
///
/// 接口没给计数时**整项不渲染**，而不是显示 0 ——「不知道」和「确实是 0」
/// 是两件事（`ContentItem` 的计数字段正是为此用 `int?`）。
class BiliStatRow extends StatelessWidget {
  const BiliStatRow({super.key, required this.item});

  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    final int? comment = item.commentCount;
    final int? like = item.likeCount;
    final int? repost = item.repostCount;

    final List<Widget> parts = <Widget>[];
    if (comment != null) {
      parts.add(Text(
        '评论 ${BiliDynamicStyle.count(comment)}',
        style: const TextStyle(
          fontSize: BiliDynamicStyle.statSize,
          fontWeight: FontWeight.w700,
          color: AppColors.weiboName,
        ),
      ));
    }
    if (like != null || repost != null) {
      final int sum = (like ?? 0) + (repost ?? 0);
      parts.add(Text(
        '赞和转发 ${BiliDynamicStyle.count(sum)}',
        style: const TextStyle(
          fontSize: BiliDynamicStyle.statSize,
          color: AppColors.textSecondary,
        ),
      ));
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < parts.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 24),
            parts[i],
          ],
        ],
      ),
    );
  }
}
