import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/time_parse.dart';
import '../../data/models/content_item.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/content_media.dart';
import '../../widgets/quoted_origin.dart';
import '../gallery/image_gallery_page.dart';
import 'content_opener.dart';

/// 时间线条目卡片（B 站动态页式布局，见 `docs/UI_HANDOFF.md` §1.2 / §1.4）。
///
/// 结构与取舍：
/// - 44×44 头像 + 昵称（按平台着色）+ 时间 + 右上 `•••`；
/// - 正文 15sp / 行高 1.5 / 最多 4 行，真的超长才在右下角给可点的「全文」；
/// - 媒体区交给 [ContentMedia]（无图**不渲染**、单图 16:9、双列、三列九宫格）；
/// - 1px 分割线 + 三列操作栏。
///
/// **评论预览框本轮不做**（决策 D1）：B 站动态流与微博 `getIndex` 的响应里都没有
/// 评论内容，要拿就得每张卡再发一次请求 —— 既违反「不发额外网络请求」的硬约束，
/// 也必然触发风控。所以卡片是「媒体区 → 分割线 → 操作栏」，中间不插东西。
///
/// 卡片保持 `StatelessWidget` 且**不订阅 provider**：它只靠 [item] 渲染，
/// 任何状态变化都由外层列表驱动。
class ContentCard extends StatelessWidget {
  const ContentCard({
    super.key,
    required this.item,
    required this.onTap,
    this.repostCount,
    this.commentCount,
    this.likeCount,
  });

  final ContentItem item;
  final VoidCallback onTap;

  /// 操作栏的三个计数（决策 D5）。
  ///
  /// **刻意做成卡片的入参而不是读 [ContentItem] 的字段**：
  /// 计数字段由总设计会话往 `ContentItem` 里补（那是三方共用文件），
  /// 卡片先按「有值就显示、null 就不显示」两态留好位置 ——
  /// 字段落地后，调用方把 `item.repostCount` 之类的值传进来即可，
  /// 本文件不用再动（也就不用担心和别人抢同一个文件）。
  final int? repostCount;
  final int? commentCount;
  final int? likeCount;

  /// 正文最大行数。
  static const int bodyMaxLines = 4;

  /// 正文样式（15sp / 行高 1.5）。
  static const TextStyle bodyStyle = TextStyle(
    fontSize: 15,
    height: 1.5,
    color: AppColors.textPrimary,
  );

  @override
  Widget build(BuildContext context) {
    final String body = _bodyText();
    final bool isVideo = item.kind == ContentKind.video;
    // 媒体区地址：**视频优先用封面**。
    //
    // 为什么不能只看 `item.images`：实测微博视频微博的 `pics` 是**空的**，
    // 封面在 `page_info.page_pic.url`，解析层已把它塞进
    // [VideoRef.coverUrl]（见 weibo_parser `_videoRefOf`）。
    // 早先这里只判 `images.isNotEmpty`，于是视频卡**整块媒体区都不渲染** ——
    // 用户看到的是一条没有任何视频痕迹的纯文字微博（真机反馈「视频看不了」）。
    final List<String> media = _mediaImages(isVideo: isVideo);
    final bool hasMedia = media.isNotEmpty;
    // 被转发的原动态：有 origin 就渲染嵌套区块（见 [QuotedOrigin]）。
    //
    // 判定**只看 `origin != null`，不额外要求 `kind == repost`**：
    // 微博解析层把「转发了一条视频」归成 [ContentKind.video]（视频优先于转发，
    // 见 weibo_parser 的形态判定注释），那种条目 kind 不是 repost，但它确实
    // 带着 origin —— 只按 kind 判会让这类转发在卡片上凭空丢掉原动态块，
    // 用户点进详情页却又能看到，前后矛盾。
    final ContentItem? origin = item.origin;
    final bool hasOrigin = origin != null;

    // 底色必须由 Material 提供而不是 Container：白底卡片再套一层不透明
    // Container 会把 InkWell 的水波纹盖住 —— 深色下不明显，亮色下很突兀。
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _header(context),
              if (body.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                _body(context, body),
              ],
              if (hasOrigin) ...<Widget>[
                const SizedBox(height: 8),
                QuotedOrigin(
                  origin: origin,
                  onOpen: () => _openOrigin(context, origin),
                ),
              ],
              if (hasMedia) ...<Widget>[
                const SizedBox(height: 8),
                ContentMedia(
                  images: media,
                  isVideo: isVideo,
                  videoDuration: item.videoRef?.duration,
                  videoIsVertical: item.videoRef?.isVertical,
                  onTap: (int i) =>
                      _onMediaTap(context, i, isVideo: isVideo, media: media),
                ),
              ],
              const SizedBox(height: 8),
              const _DividerLine(),
              _actionBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// 媒体区要渲染的地址列表。
  ///
  /// - 视频且**没有** `pics` → 用 `videoRef.coverUrl`（实测微博视频的封面在
  ///   `page_info.page_pic.url`，`pics` 是空的；不兜这一下媒体区整块消失）。
  /// - 其余（含视频但带 `pics`）→ 原样用 `images`：多图视频微博的图集
  ///   本身是内容，不能因为「它是视频」就被压成一张封面。
  List<String> _mediaImages({required bool isVideo}) {
    if (!isVideo) return item.images;
    if (item.images.isNotEmpty) return item.images;
    final String? cover = item.videoRef?.coverUrl;
    if (cover != null && cover.isNotEmpty) return <String>[cover];
    return const <String>[];
  }

  /// 打开被转发的原动态：**压一个新路由，数据源换成 [origin]**。
  ///
  /// 需求原话：「把当前展示的 UI 数据源从『转发者』切换为『原动态对象』，
  /// 并压入一个新的详情页路由」。
  ///
  /// ⚠️ 分发走 [ContentOpener]，**不要在这里写 `if (是视频) 开播放页`**。
  /// 早先这里直接 `push(ContentDetailPage(...))`，导致「转发的 B 站视频」
  /// 点开只看到封面大图、也没有评论（播放页才有 aid 评论区）——
  /// 而同样的视频从时间线整卡点进去却能播。两个入口两套行为就是这个 bug。
  void _openOrigin(BuildContext context, ContentItem origin) {
    ContentOpener.open(context, origin, headerLabel: '原动态');
  }

  /// 媒体区被点击。
  ///
  /// **视频卡的封面 → 走整卡点击（=播放），不是看大图。**
  ///
  /// 为什么必须特判：`ContentMedia` 用 `HitTestBehavior.opaque` 的
  /// [GestureDetector] 包住封面，点它**不会**冒泡到外层 `InkWell`。
  /// 早先（旧卡片）封面是裸 `Image`，点击自然冒泡成「打开条目」，
  /// 于是「点封面 = 播放」；换成九宫格媒体区后，点封面变成「全屏看封面图」，
  /// 用户感知就是「点封面打不开视频，只能点标题」（真机反馈）。
  ///
  /// 多图仍然走全屏预览：一组图里每一张的地位相同，此时「点图看大图」
  /// 才是符合预期的交互。
  ///
  /// [media] 是**实际渲染的地址列表**（视频时封面可能来自 `videoRef`，
  /// 与 `item.images` 不同源）—— 预览页必须用同一份，否则点开的是另一张图。
  void _onMediaTap(
    BuildContext context,
    int index, {
    required bool isVideo,
    required List<String> media,
  }) {
    // 只有「单张媒体」的视频卡才走播放。
    //
    // 为什么不能只判 `isVideo`：视频微博也可能**同时带多张图**（历史数据见过
    // `pics` + `page_info` 并存）。那种卡上媒体区渲染的是一组图，点任意一张
    // 都该看大图 —— 否则用户点第 2 张却发现进了播放页，会觉得点错了。
    // 单张时媒体区显示的就是视频封面，点它等于点视频，符合 B 站视频卡的习惯。
    if (isVideo && media.length == 1) {
      onTap();
      return;
    }
    _openGallery(context, index, media);
  }

  /// 正文：优先 `summary`，为空退回 `title`。
  ///
  /// 刻意不用 [ContentItem.displayTitle]：它优先返回 `title`，
  /// 而卡片正文区要的是「原话」。
  String _bodyText() {
    final summary = item.summary.trim();
    if (summary.isNotEmpty) return summary;
    return item.title.trim();
  }

  // ---------------------------------------------------------------- 头部

  Widget _header(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _avatar(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(child: _name()),
                  if (item.isNew) ...<Widget>[
                    const SizedBox(width: 5),
                    const _NewDot(),
                  ],
                  if (item.kind == ContentKind.repost) ...<Widget>[
                    const SizedBox(width: 5),
                    const _RepostTag(),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _timeLabel(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        _moreButton(),
      ],
    );
  }

  /// 昵称：颜色按平台（微博粉 / B 站黑）。
  Widget _name() {
    final Color color = item.platform == Platform.weibo
        ? AppColors.weiboName
        : AppColors.biliName;
    return Text(
      item.authorName.isEmpty ? '（未知作者）' : item.authorName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1.25,
      ),
    );
  }

  /// 44×44 圆形头像。没有头像时用「姓名首字圆形」兜底 ——
  /// 微博侧不是每个博主都有头像，但为了头像去改数据层不值得。
  Widget _avatar() {
    final String? url = item.authorAvatar;
    if (url == null || url.isEmpty) return _avatarPlaceholder();
    return ClipOval(
      child: CachedImage(
        url: url,
        width: 44,
        height: 44,
        cacheWidth: 132,
        fit: BoxFit.cover,
        errorWidget: _avatarPlaceholder(),
        placeholder: _avatarPlaceholder(),
      ),
    );
  }

  Widget _avatarPlaceholder() {
    final String first =
        item.authorName.isEmpty ? '?' : item.authorName.characters.first;
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: AppColors.placeholder,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        first,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  /// 右上角 `•••`。
  ///
  /// 原型里是纯文本 `•••`；这里必须包成 [PopupMenuButton] / IconButton 才能
  /// 保证点击区不小于 40×40（手指点不到等于没有）。
  ///
  /// 菜单只有「看详情」与「复制原文链接」两项：两者都是纯本地动作，
  /// 不发任何网络请求。转发/点赞这类写操作本 App 没有能力，不放进菜单。
  Widget _moreButton() {
    return PopupMenuButton<_CardMenu>(
      tooltip: '更多',
      icon: const Icon(
        Icons.more_horiz_rounded,
        size: 20,
        color: AppColors.textSecondary,
      ),
      padding: EdgeInsets.zero,
      // 点击区：IconButton 默认 48，这里显式收到 40（规范下限），
      // 免得把 44 的头像行撑高。
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_CardMenu>>[
        PopupMenuItem<_CardMenu>(
          value: _CardMenu.detail,
          child: const Text('查看详情', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem<_CardMenu>(
          value: _CardMenu.copyLink,
          enabled: item.link.isNotEmpty,
          child: const Text('复制原文链接', style: TextStyle(fontSize: 13)),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case _CardMenu.detail:
            onTap();
          case _CardMenu.copyLink:
            if (item.link.isEmpty) return;
            Clipboard.setData(ClipboardData(text: item.link));
        }
      },
    );
  }

  String _timeLabel() {
    if (item.hasReliableTime) {
      return TimeParse.humanize(item.publishedAt);
    }
    // 时间不可靠就如实说「抓取于」，不假装是发布时间。
    return '抓取于 ${TimeParse.humanize(item.fetchedAt)}';
  }

  // ---------------------------------------------------------------- 正文

  /// 正文 4 行截断 + 「全文」。
  ///
  /// 「全文」只在**真的**超长时出现：用 [TextPainter.didExceedMaxLines] 判断，
  /// 而不是 `body.length > N` 猜 —— 猜会在窄屏/宽屏上两头错。
  ///
  /// 刻意不做「省略号后直接拼『… 全文』」：`TextOverflow.ellipsis` 已经画了省略号，
  /// 再拼一段文字会变成「… … 全文」。所以「全文」是下方右对齐的独立文本按钮。
  Widget _body(BuildContext context, String text) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: text, style: bodyStyle),
          maxLines: bodyMaxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool overflowed = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              text,
              maxLines: bodyMaxLines,
              overflow: TextOverflow.ellipsis,
              style: bodyStyle,
            ),
            if (overflowed)
              Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Text(
                      '全文',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: AppColors.link,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 底部

  /// 操作栏：三列平分、图标居中。
  ///
  /// 数字由 [ContentItem] 的计数字段驱动（决策 D5，字段由总设计会话补）。
  /// 在那之前调用方不传，三个值都是 null → **不渲染数字**，只有图标。
  /// 字段补齐后外层把值传进来，这里自动多出数字，布局不用再改。
  ///
  /// ## 只有「评论」可点（2026-10-27 修订）
  ///
  /// 原先三项**全部**不绑点击，理由是「转发/点赞没有写操作能力，造一个点了
  /// 没反应的点击区比不给点击更糟」。这条理由对转发/点赞成立，对**评论不成立**：
  /// 本 App 能看评论（`CommentSection` 走官方接口）。用户真机反馈原话是
  /// 「点卡片上的评论都只能进入视频本身，还没办法对其进行操作」——
  /// 点评论却什么都不发生，比点了没反应更费解。
  ///
  /// 所以评论项接 [onTap]（=进详情页看评论），转发/点赞保持不可点。
  Widget _actionBar() {
    return Row(
      children: <Widget>[
        _ActionItem(
          icon: Icons.repeat_rounded,
          label: '转发',
          count: repostCount,
        ),
        _ActionItem(
          icon: Icons.chat_bubble_outline_rounded,
          label: '评论',
          count: commentCount,
          onTap: onTap,
        ),
        _ActionItem(
          icon: Icons.thumb_up_outlined,
          label: '点赞',
          count: likeCount,
        ),
      ],
    );
  }

  void _openGallery(BuildContext context, int index, List<String> images) {
    // 全屏预览页已有（滑动、双指缩放、双击 2.5x、页码），不重写。
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImageGalleryPage(
          images: images,
          initialIndex: index,
          title: item.displayTitle,
        ),
      ),
    );
  }
}

/// `•••` 菜单的动作。
enum _CardMenu { detail, copyLink }

/// 1px 分割线（规范 0xFFE3E5E7）。
class _DividerLine extends StatelessWidget {
  const _DividerLine();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, color: AppColors.divider);
}

/// 操作栏单项：图标 + 可选数字，三列平分居中。
///
/// **只有传了 [onTap] 才可点**。转发/点赞在本 App 没有写操作能力，
/// 不传 onTap → 纯展示，不造一个点了没反应的点击区。
class _ActionItem extends StatelessWidget {
  const _ActionItem({
    required this.icon,
    required this.label,
    this.count,
    this.onTap,
  });

  final IconData icon;

  /// 无障碍语义标签（同时是「图标 + 数字」缺数字时的唯一说明）。
  final String label;

  /// 计数值。为 null 时只画图标（决策 D5：字段未补）。
  final int? count;

  /// 点击动作。null = 不可点（转发 / 点赞）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final int? c = count;
    final Widget row = SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 16, color: AppColors.textSecondary),
          if (c != null) ...<Widget>[
            const SizedBox(width: 5),
            Text(
              _formatCount(c),
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );

    return Expanded(
      child: Semantics(
        label: label,
        button: onTap != null,
        child: onTap == null
            // 无动作：纯展示，不包 InkWell（点了没反应比不可点更糟）。
            ? row
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(6),
                child: row,
              ),
      ),
    );
  }

  /// 与播放页统计一致的量级折叠（1.2万 / 1.0亿）。
  static String _formatCount(int value) {
    if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return '$value';
  }
}

/// 「新内容」小圆点（原来左上角的 NEW 角标改到昵称后面）。
class _NewDot extends StatelessWidget {
  const _NewDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: AppColors.newBadge,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 转发标记：昵称行里的小标签。
///
/// 原来卡片封面右下角的「含原动态」角标已删 —— 媒体区现在是九宫格，
/// 角标会和图片本身抢注意力，而且「转发」标记放在作者行更符合动态页习惯。
class _RepostTag extends StatelessWidget {
  const _RepostTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.textSecondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '转发',
        style: TextStyle(
          fontSize: 10,
          height: 1.3,
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
