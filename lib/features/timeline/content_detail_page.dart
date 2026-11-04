import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/time_parse.dart';
import '../../data/models/content_item.dart';
import '../../data/weibo/weibo_web_urls.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/photo_grid.dart';
import '../../widgets/source_badge.dart';
import '../comments/comment_section.dart';
import '../gallery/image_gallery_page.dart';
import '../player/inline_video_player.dart';
import '../player/player_page.dart';
import '../weibo/weibo_webview_page.dart';
import 'bili_dynamic_body.dart';
import 'content_opener.dart';

/// 非 B 站视频内容的详情页：B 站动态、微博内容。
///
/// 微博部分的处理**刻意诚实**：
/// - 能提取到视频直链 → 提供「尝试播放」，并说明成功率不保证；
/// - 提取不到 → 明确显示「视频解析失败」，不伪造播放能力；
/// - 评论 → 占位 UI，文案写明「待后续实现」。
///
/// 同一个页面也用来渲染**转发的原动态**（`ContentDetailPage(item: item.origin!)`）：
/// 单独做一个「原动态页」只会复制一遍正文 / 图片 / 评论逻辑，
/// 而且原动态本来就没有评论入口（见下），复用是最省事的正确解。
///
/// ## B 站动态走 [BiliDynamicBody]（2026-11-02 第三轮修订）
///
/// 用户给了参考稿（`桌面/动态内部.html`）并指出「纯文字动态没有按 html 做」。
/// 实测那条路径根本没经过 `OpusDetailPage` —— 从时间线卡片点进来（以及
/// 「原动态」入口）都落在本页，于是同一类内容有两个长得不一样的详情页。
///
/// 现在本页对 B 站动态（图文 / 纯文字 / 转发）直接把正文交给
/// [BiliDynamicBody]，与 `OpusDetailPage` 用**同一套骨架**；AppBar、
/// 加载态、评论入口的解析仍留在本页（微博分支完全不动）。
class ContentDetailPage extends ConsumerWidget {
  const ContentDetailPage({super.key, required this.item, this.headerLabel});

  final ContentItem item;

  /// 标题前缀。原动态独立页传「原动态」，让用户知道自己在看被转发的那条，
  /// 而不是转发者自己发的。默认 null = 保持原有标题。
  final String? headerLabel;

  /// 是否走参考稿那套「动态详情」骨架。
  ///
  /// ## 判据：**非视频**就套骨架，不分平台（2026-11-02 第四轮修订）
  ///
  /// 用户原话：「我想让微博的纯文字卡片里的详情页的正文和你的一样
  /// （不包括评论区）」，并且明确「**视频动态不要动**」。
  ///
  /// 所以平台判断去掉了：微博的图文 / 纯文字 / 转发都和 B 站共用同一副骨架。
  /// 这消灭了最后一种分叉 —— 同是微博内容，以前图文一个样、B 站内容另一个样。
  ///
  /// **视频仍然不走这里**（两个平台都是）：
  /// - 微博视频要在页内自动播放（`InlineVideoPlayer`），骨架的媒体区只认
  ///   `PhotoGrid`，塞进去会被渲染成一张静态封面；
  /// - B 站视频本来就该进 `PlayerPage`（弹幕 / 清晰度 / 进度记忆整套）。
  ///
  /// **转发动态也走骨架**：老排版同样会「标题 = 正文首行 + 正文 = 整段」
  /// 地画两遍，那是同一个缺陷。原动态块通过 `originBlock` 参数插进骨架。
  bool get _usesDynamicLayout => item.kind != ContentKind.video;

  /// B 站动态分支的 AppBar：与 `OpusDetailPage` 一致（复制链接 + 重新加载）。
  ///
  /// 不放「重新加载」以外的操作：本页数据是外面传进来的 `ContentItem`，
  /// 没有自己的请求，所以只保留「复制链接」。
  AppBar _appBar(String baseTitle, String? label) {
    return AppBar(
      backgroundColor: AppColors.card,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      title: Text(
        label == null ? baseTitle : '$label · $baseTitle',
        style: const TextStyle(fontSize: 15),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isWeibo = item.platform == Platform.weibo;
    final directUrl = item.videoRef?.directVideoUrl;

    final baseTitle =
        '${item.platform.label} · ${item.kind == ContentKind.video ? '视频' : '动态'}';
    final label = headerLabel;

    // B 站动态（图文 / 纯文字 / 转发）走参考稿那套骨架，**不再**用下面这套
    // 「标题 + 来源徽章 + 正文」的通用排版。
    //
    // 真机反馈的「动态内容出现两次」就出在下面那套里：它先把
    // `item.displayTitle` 当大标题画一次，再画整段 `summary`；而 B 站动态
    // 常常没有标题，解析层会把 `displayTitle` 兜底成「正文首行截 60 字」——
    // 于是同一句话被画了两遍。
    //
    // 视频动态（带 bvid）不走这里：它们本来就该进 `PlayerPage`，
    // `ContentOpener.opensInPlayer` 已把这条路分走了，剩下的只是兜底。
    if (_usesDynamicLayout) {
      return Scaffold(
        backgroundColor: AppColors.card,
        appBar: _appBar(baseTitle, label),
        body: BiliDynamicBody(
          item: item,
          originBlock: item.origin == null
              ? null
              : OriginBlock(
                  origin: item.origin!,
                  onOpen: () => ContentOpener.open(
                    context,
                    item.origin!,
                    headerLabel: '原动态',
                  ),
                ),
          commentSection: _CommentSection(item: item),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(label == null ? baseTitle : '$label · $baseTitle'),
        actions: <Widget>[
          IconButton(
            tooltip: '复制原文链接',
            icon: const Icon(Icons.link_rounded),
            onPressed: item.link.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: item.link));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('链接已复制')),
                      );
                    }
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          // 媒体区。
          //
          // ⚠️ 视频**不再铺 PhotoGrid**：早先无脑走 `PhotoGrid`，而视频条目
          // 的 `images` 只有一张封面 → 单图分支渲染成一张封面大图，
          // 页面上没有任何「这是视频」的信号，也没有播放入口。
          // 真机反馈「点视频封面只显示一张照片」就是指这里。
          //
          // ## 微博视频：**在详情页内直接播**（2026-10-27 第二轮修订）
          //
          // 用户原话：「我需要点击视频的时候进的是视频详情页，能看到评论的那种」。
          // 上一轮把微博视频改成「点卡片直接进全屏播放页」，结果评论区被甩在后面，
          // 想看评论还得返回 —— 一次操作被拆成三次。现在改成：**进详情页、就地自动播放、
          // 评论就在下面**。
          //
          // B 站视频仍走 `_VideoCover` + 去播放页：那边有弹幕/清晰度/进度记忆
          // 一整套（`PlayerPage`），塞进详情页反而会丢功能。
          if (isWeibo && item.kind == ContentKind.video && directUrl != null)
            InlineVideoPlayer(
              url: directUrl,
              // 实测必须带，否则微博 CDN 返回 403。
              referer: 'https://weibo.com/',
              posterUrl: item.videoRef?.coverUrl,
              hintDuration: item.videoRef?.duration,
              isVertical: item.videoRef?.isVertical,
            )
          else if (item.kind == ContentKind.video)
            _VideoCover(item: item)
          else if (item.images.isNotEmpty)
            PhotoGrid(
              images: item.images,
              onTap: (i) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ImageGalleryPage(
                    images: item.images,
                    initialIndex: i,
                    // 用**这条内容自己**的标题：直接拿 item.displayTitle 会在
                    // 「原动态独立页」里显示转发者的话（真机上撞见过）。
                    title: item.displayTitle,
                  ),
                ),
              ),
            ),
          // 微博视频但**没有可播直链**：明确说清，别让用户对着封面反复点。
          if (isWeibo && item.kind == ContentKind.video && directUrl == null) ...<
              Widget>[
            const SizedBox(height: 10),
            const _WeiboNoUrlHint(),
          ],
          const SizedBox(height: 14),
          Text(
            item.displayTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              SourceBadge(platform: item.platform),
              const SizedBox(width: 8),
              KindBadge(kind: item.kind),
              const Spacer(),
              Text(
                item.hasReliableTime
                    ? TimeParse.absolute(item.publishedAt)
                    : '抓取于 ${TimeParse.absolute(item.fetchedAt)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            item.authorName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 28),

          // 视频区块：B 站走「去播放页」。
          //
          // **微博视频不在这里**：它已经在顶部媒体区用 `InlineVideoPlayer`
          // 就地播放了，再挂一个「尝试播放」按钮就是重复入口（真机截图上
          // 会同时看到封面区和「尝试播放」按钮，用户不知道该点哪个）。
          if (!isWeibo && ContentOpener.opensInPlayer(item)) ...<Widget>[
            _BiliVideoSection(item: item),
            const SizedBox(height: 20),
          ],

          SelectableText(
            item.summary.isEmpty ? '（正文为空，可能该条内容只有图片或视频）' : item.summary,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),

          // 转发动态：下方给出**原动态预览区块**。
          //
          // 点击走 [ContentOpener]：B 站视频会进播放页（能播、有评论区），
          // 其余进详情页。早先这里硬编码 `ContentDetailPage`，
          // 与卡片里的同名入口行为不一致。
          // 判定只看 `origin != null`，不额外要求 kind == repost：
          // 微博「转发了一条视频」的 kind 是 video（见 weibo_parser 的优先级）。
          if (item.origin != null) ...<Widget>[
            const SizedBox(height: 18),
            OriginBlock(
              origin: item.origin!,
              onOpen: () =>
                  ContentOpener.open(context, item.origin!, headerLabel: '原动态'),
            ),
          ],

          const SizedBox(height: 24),
          _CommentSection(item: item),

          if (item.link.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            SelectableText(
              item.link,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 转发动态里的「原动态」预览区块。
///
/// 为什么单独抽一个带边框的容器、而不是直接把原动态正文接在转发文字下面：
/// 实测一条转发动态里**两段正文会连在一起**（转发者的话 + 原博的话），
/// 视觉上分不清谁说的 —— 而「分不清谁在说话」正是这次要修的缺陷现象之一。
/// 所以这里给了三重视觉区隔：外框 + 更深的底色 + 左上角「原动态」小标签。
///
/// 内容取舍：只放**首图缩略 + 共 N 张**，不在这里铺九宫格 ——
/// 用户已选定「点击查看原动态按钮跳独立页」的交互（见 §7.8）。
///
/// 为什么是**公开**类（原 `_OriginBlock`）：B 站动态现在有两个详情页入口
/// （`ContentDetailPage` 与 `OpusDetailPage`），两者都通过
/// `BiliDynamicBody.originBlock` 插这个区块，不能再私有在一个文件里。
class OriginBlock extends StatelessWidget {
  const OriginBlock({super.key, required this.origin, required this.onOpen});

  final ContentItem origin;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bvid = origin.videoRef?.bvid;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // 比页面底色（0xFFF4F5F7）再浅一档的纯白：一眼能看出是「另一条内容」。
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.placeholder,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '原动态',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _avatar(origin),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      origin.authorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      origin.hasReliableTime
                          ? TimeParse.absolute(origin.publishedAt)
                          : '抓取于 ${TimeParse.absolute(origin.fetchedAt)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ⚠️ 这两个 `Text` 必须用 `SizedBox(width: double.infinity)` 包住，
          // 或依赖 `Column` 的 `crossAxisAlignment: stretch`。
          //
          // 真机缺陷（2026-11-02）：原动态块里的长段落**右侧被硬裁切**
          // （「我会崩」「更久更久更」被切掉、且没有省略号）。原因是
          // `Column(crossAxisAlignment: start)` 下的 `Text` 拿到的宽度约束
          // 是「无约束 + 父级最大宽度」，而 `TextOverflow.ellipsis` 只在
          // **有确定宽度**时才画省略号；宽度不收敛时它按单行无限延伸，
          // 被外层 `ClipRect`/圆角容器裁掉。
          //
          // 修法：显式给满宽约束（`stretch` 等价），让文本在容器内正常换行，
          // `maxLines` + `ellipsis` 才会真正生效。
          if (origin.summary.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: Text(
                origin.summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: Text(
                origin.displayTitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            ),
          if (origin.images.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                CoverImage(
                  url: origin.images.first,
                  width: 96,
                  height: 96,
                  borderRadius: 8,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '共 ${origin.images.length} 张图片',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '点下方按钮进入原动态页可看全部大图',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('查看原动态'),
                ),
              ),
              if (bvid != null) ...<Widget>[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlayerPage(
                          bvid: bvid,
                          aid: origin.videoRef?.aid,
                          fallbackTitle: origin.displayTitle,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('播放原视频'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 原动态作者头像：加载失败时退回首字母圆形占位，不留白。
  Widget _avatar(ContentItem origin) {
    final url = origin.authorAvatar;
    if (url == null || url.isEmpty) return _avatarPlaceholder(origin);
    return ClipOval(
      child: CachedImage(
        url: url,
        width: 32,
        height: 32,
        cacheWidth: 96,
        errorWidget: _avatarPlaceholder(origin),
      ),
    );
  }

  Widget _avatarPlaceholder(ContentItem origin) {
    final first = origin.authorName.isEmpty ? '?' : origin.authorName[0];
    return Container(
      width: 32,
      height: 32,
      decoration: const BoxDecoration(
        color: AppColors.placeholder,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          first,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ),
    );
  }
}

/// 视频封面：16:9 + 居中播放按钮，点击进入播放（或尝试播放）。
///
/// 刻意**不复用** `PhotoGrid`：那套规则是给图文的（单图 4:3 限高 / 4 张两列），
/// 视频只有一张封面，铺进去就变成「一张普通照片」。
///
/// ## 什么时候还会用到它
///
/// 微博视频（有直链）已经改走 [InlineVideoPlayer]（页内直接播），所以这里只剩两种：
/// 1. **B 站视频** —— 点封面进 `PlayerPage`（弹幕/清晰度/评论区一整套）；
/// 2. **微博视频但没有可播直链** —— 点封面**不能再跳详情页**。
///
/// 第 2 种是必须显式挡住的：`ContentOpener.open` 对微博视频现在返回
/// `ContentDetailPage`，而本组件就长在详情页里 —— 不挡就会
/// **一层套一层地压新详情页**（用户点一下封面，栈深 +1，返回键要按很多次）。
class _VideoCover extends StatelessWidget {
  const _VideoCover({required this.item});

  final ContentItem item;

  /// 封面候选：`images.first` → `videoRef.coverUrl`。
  String? get _cover {
    if (item.images.isNotEmpty) return item.images.first;
    final String? fromRef = item.videoRef?.coverUrl;
    if (fromRef == null || fromRef.isEmpty) return null;
    return fromRef;
  }

  /// 点封面是否有地方可去。
  ///
  /// 只有 B 站会被 [ContentOpener.open] 分去播放页；微博在这里点等于
  /// 「再打开一次当前页」，所以直接不给点击。
  bool get _canOpen => item.platform == Platform.bilibili;

  @override
  Widget build(BuildContext context) {
    final String? cover = _cover;
    // 没有封面也要占住 16:9：那块位置本身就是「这里是个视频」的信号。
    final Widget body = AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (cover == null)
              const ColoredBox(
                color: AppColors.placeholder,
                child: Center(
                  child: Icon(Icons.videocam_outlined,
                      size: 28, color: AppColors.textSecondary),
                ),
              )
            else
              CachedImage(
                url: cover,
                width: double.infinity,
                height: double.infinity,
                // 16:9 全宽：屏宽 ~359dp 时 ≈ 1077px，覆盖 3x DPR。
                cacheWidth: (MediaQuery.sizeOf(context).width * 3).round(),
                fit: BoxFit.cover,
              ),
            const Center(
              child: SizedBox(
                width: 56,
                height: 56,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 38,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // 微博（无直链）：不给点击 —— 点它只会把当前详情页再压一层。
    if (!_canOpen) return body;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ContentOpener.open(context, item),
      child: body,
    );
  }
}

/// B 站视频区块：一个「播放」按钮，点了进播放页（带 aid 评论区）。
///
/// 为什么详情页不自己播：视频播放 + 弹幕 + 评论区是一整套（`PlayerPage`），
/// 在详情页里再实现一遍必然走偏。这里只做**入口**。
class _BiliVideoSection extends StatelessWidget {
  const _BiliVideoSection({required this.item});

  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.page,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.play_circle_outline_rounded,
                  size: 20, color: AppColors.biliBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '这是一条 B 站视频',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '点下面的按钮进播放页，可以看弹幕和这条视频的评论。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => ContentOpener.open(context, item),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放视频'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 微博视频**拿不到直链**时的提示条。
///
/// 取代了旧的 `_WeiboVideoSection`「尝试播放」区块 —— 那个区块在有直链时
/// 会额外渲染一个「尝试播放」按钮，而视频现在已经在顶部媒体区就地自动播放，
/// 于是页面会出现两个播放入口（真机截图上正是如此）。这里只保留
/// 「确实没有直链」这一种情况的说明。
class _WeiboNoUrlHint extends StatelessWidget {
  const _WeiboNoUrlHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warningTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.videocam_off_outlined,
              color: Colors.orangeAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '视频解析失败',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '这条微博是视频，但接口没有给出可播放的直链。'
                  '可以点下面的「在应用内查看这条微博」去内置浏览器里看。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 评论区。
///
/// B 站动态**有**评论区：接口与视频评论同一个（`/x/v2/reply/wbi/main`），
/// 只是 `oid` / `type` 不同 —— 动态 JSON 的 `basic.comment_id_str` 与
/// `basic.comment_type` 直接声明了正确取值（图文动态 11、转发动态 17、
/// 视频投稿动态 1），解析时已经带进 [ContentItem.commentOid] / `commentType`。
///
/// 微博评论**已在 App 内实现**：走 `m.weibo.cn/comments/hotflow`（实测
/// 不要求登录），楼中楼内嵌在同一份响应里。这里渲染真实评论区，
/// 同时保留下方「在应用内查看这条微博」按钮 —— 有些人就是要用网页看，
/// 而且它是评论接口出问题时的兜底入口。
class _CommentSection extends StatelessWidget {
  const _CommentSection({required this.item});

  final ContentItem item;

  /// 从微博链接里抠单条微博的 mid：
  /// - `weibo.com/<uid>/<mid>`（PC 站，mid 是 6 位以上字母数字）
  /// - `m.weibo.cn/status/<mid>`（移动站，纯数字）
  static final RegExp _midRe = RegExp(
    r'(?:weibo\.com/\d+/|m\.weibo\.cn/status/)([0-9A-Za-z]{6,})',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (item.platform == Platform.weibo) {
      final mid = _resolveMid();
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          // 与正文区同色（正文走 `BiliDynamicBody`，其底色是 `AppColors.card`）。
          // 早先这里是 `AppColors.page`（浅灰），在详情页上表现为
          // 「正文白色、评论区灰色」的一道色差。
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 真实评论区（内嵌模式：外层详情页已有滚动，翻页走「加载更多」）。
            //
            // mid 解析不出来时不硬编一个 oid 去请求（那必然拿到别的微博的
            // 评论或者干脆 404），只留网页入口。
            if (mid != null)
              CommentSection(
                oid: mid,
                platform: Platform.weibo,
                // 微博侧 type 固定 0：hotflow 只认 id/mid，没有 B 站那套 type。
                type: 0,
                embedded: true,
              )
            else
              Text(
                '没能从这条微博的链接里解析出 mid，暂时无法在应用内加载评论。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            const SizedBox(height: 16),
            // 兜底入口：评论接口失败 / 想看原网页排版时用。
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _openInBrowser(context),
                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: const Text('在应用内查看这条微博'),
              ),
            ),
          ],
        ),
      );
    }

    // B 站动态：接真实评论区（内嵌模式，翻页走底部「加载更多」按钮）。
    final oid = item.commentOid;
    final type = item.commentType;
    if (oid != null && oid.isNotEmpty && type != null && type > 0) {
      return CommentSection(
        oid: oid,
        type: type,
        embedded: true,
        // upMid 留 0：动态作者未必是评论区的「UP」，宁可不标也不误标。
      );
    }

    // ⚠️ 回退：B 站**视频**的评论入口本来就是 `(aid, 1)`，不依赖
    // `basic.comment_id_str`。而「转发的原动态」实测 `comment_id_str` 是**空串**、
    // `comment_type` 是 0（见 BiliContentParser._parseOrigin 的注释），
    // 于是它必然落到下面那句「没有评论入口」—— 真机反馈的「还不显示评论」
    // 就是指这条路径。只要拿到 aid 就能正常查评论，不必有 commentOid。
    final int? aid = item.videoRef?.aid;
    if (aid != null && aid > 0) {
      return CommentSection(
        oid: '$aid',
        // 视频评论固定 type=1（与 PlayerPage 里用的同一组参数）。
        type: 1,
        embedded: true,
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.page,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '接口没有给出这条内容的评论入口（comment_id_str 缺失），暂时看不到评论。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 这条微博的 mid（评论接口的 `id` / `mid` 参数）。
  ///
  /// 复用「打开网页」那套取值顺序的前两档：`commentOid` → 从 [item.link]
  /// 抠出的 mid（`m.weibo.cn/status/<mid>`）。**刻意不回落作者 uid**：
  /// 拿 uid 当 oid 去查评论会查到「用户主页」而不是这条微博，比不加载更糟。
  ///
  /// 只接受纯数字（hotflow 的 id 就是纯数字）；解析不出来返回 null，
  /// 调用方据此不渲染评论区，而不是硬编一个 id 去请求。
  String? _resolveMid() {
    final RegExp digits = RegExp(r'^\d+$');
    for (final String? candidate in <String?>[
      item.commentOid,
      _midRe.firstMatch(item.link)?.group(1),
    ]) {
      if (candidate == null) continue;
      final String trimmed = candidate.trim();
      if (digits.hasMatch(trimmed)) return trimmed;
    }
    return null;
  }

  /// 这条微博在内置浏览器里的地址。
  ///
  /// 优先级：单条微博（commentOid）→ 从 link 抠出的 mid → 博主主页 → 微博首页。
  /// [WeiboWebUrls] 对非纯数字一律抛 [AppError]，所以每一档都单独兜住：
  /// 某一档数据脏不该block住后面能用的档。
  String _resolveWebUrl() {
    final fromOid = _tryStatus(item.commentOid);
    if (fromOid != null) return fromOid;

    final fromLink = _tryStatus(_midRe.firstMatch(item.link)?.group(1));
    if (fromLink != null) return fromLink;

    final fromAuthor = _tryProfile(item.authorId);
    if (fromAuthor != null) return fromAuthor;

    return WeiboWebUrls.mbBase;
  }

  static String? _tryStatus(String? mid) {
    if (mid == null || mid.isEmpty) return null;
    try {
      return WeiboWebUrls.status(mid);
    } catch (_) {
      return null;
    }
  }

  static String? _tryProfile(String? uid) {
    if (uid == null || uid.isEmpty) return null;
    try {
      return WeiboWebUrls.profile(uid);
    } catch (_) {
      return null;
    }
  }

  /// 打开内置浏览器。解析或跳转出任何异常都只弹提示，不让 App 崩。
  void _openInBrowser(BuildContext context) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);

    final String url;
    try {
      url = _resolveWebUrl();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('这条微博的链接不合法，无法打开')),
      );
      return;
    }

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => WeiboWebViewPage(url: url, title: item.authorName),
      ),
    );
  }
}
