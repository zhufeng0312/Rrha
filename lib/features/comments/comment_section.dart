import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/time_parse.dart';
import '../../data/models/comment.dart';
import '../../data/models/content_item.dart';
import '../gallery/image_gallery_page.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/error_view.dart';
import '../../widgets/photo_grid.dart';
import 'comment_controller.dart';

/// 评论区（B 站视频 / 动态与微博共用）。
///
/// 需求验收：每页 20 条、支持排序、下拉加载更多、楼中楼展开、
/// 接口失败时显示错误和重试按钮。
///
/// [platform] 决定数据源与展示差异，**[oid] / [type] 由内容自己声明**：
/// - B 站：视频 `(aid, 1)`、图文动态 `(图片 id, 11)`、转发动态 `(动态 id, 17)`；
/// - 微博：`(mid, 0)`，mid 即 `m.weibo.cn/status/<mid>` 里的那段纯数字。
///
/// 微博侧的差异只有两处（**不复制一份 B 站实现**）：
/// 1. 排序按钮隐藏：hotflow 只有一种顺序，`CommentSort` 对微博不适用；
/// 2. 空态文案不同（「没有可见评论」比「没有评论」更诚实）。
class CommentSection extends ConsumerStatefulWidget {
  const CommentSection({
    super.key,
    required this.oid,
    this.platform = Platform.bilibili,
    this.type = 1,
    this.upMid = 0,
    this.embedded = false,
  });

  final String oid;
  final Platform platform;
  final int type;
  final int upMid;

  /// 内嵌模式：用在「详情页的 ListView 里」这种外层已有滚动的场景。
  ///
  /// 此时本组件不再自带滚动（也就没有「滚到底自动翻页」），
  /// 翻页交给底部的「加载更多」按钮。
  final bool embedded;

  @override
  ConsumerState<CommentSection> createState() => _CommentSectionState();
}

class _CommentSectionState extends ConsumerState<CommentSection> {
  final ScrollController _scrollController = ScrollController();

  CommentArgs get _args => CommentArgs(
        oid: widget.oid,
        platform: widget.platform,
        type: widget.type,
        upMid: widget.upMid,
      );

  bool get _isWeibo => widget.platform == Platform.weibo;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(commentListProvider(_args).notifier).load();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 需求里的「下拉加载更多」：滚动接近底部时自动取下一页。
  ///
  /// `loadMore()` 自带 `loadingMore` / `isEnd` 守卫，所以这里可以放心地
  /// 在每次滚动回调里调用。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      ref.read(commentListProvider(_args).notifier).loadMore();
    }
  }

  @override
  void didUpdateWidget(covariant CommentSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.oid != widget.oid ||
        oldWidget.type != widget.type ||
        oldWidget.platform != widget.platform) {
      ref.read(commentListProvider(_args).notifier).load(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(commentListProvider(_args));
    final notifier = ref.read(commentListProvider(_args).notifier);
    final theme = Theme.of(context);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          Text(
            '评论 ${state.displayCount > 0 ? state.displayCount : ''}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _sortButton(state, notifier),
        ],
      ),
    );

    final body = _body(context, state, notifier);

    // 内嵌时不能给 Expanded：外层（详情页的 ListView）高度是无界的，
    // 这里必须是「按内容撑开」的列。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: widget.embedded ? MainAxisSize.min : MainAxisSize.max,
      children: <Widget>[
        header,
        if (widget.embedded) body else Expanded(child: body),
      ],
    );
  }

  Widget _sortButton(CommentListState state, CommentListNotifier notifier) {
    // 微博 hotflow 只有「热门」一种顺序：留一个点了没反应的排序按钮比不显示
    // 更糟（用户会以为排序坏了）。所以微博侧直接不渲染。
    if (_isWeibo) return const SizedBox.shrink();

    return SegmentedButton<CommentSort>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: const WidgetStatePropertyAll<TextStyle?>(
          TextStyle(fontSize: 12),
        ),
      ),
      segments: CommentSort.values
          .map(
            (s) => ButtonSegment<CommentSort>(
              value: s,
              label: Text(s.label),
            ),
          )
          .toList(),
      selected: <CommentSort>{state.sort},
      onSelectionChanged: (selection) => notifier.changeSort(selection.first),
    );
  }

  /// 空态文案：按平台区分。
  ///
  /// 微博接口可能过滤掉「不可见评论」，所以不能断言「一条评论都没有」。
  String get _emptyMessage {
    if (_isWeibo) return '这条微博还没有评论，或接口没有返回可见评论';
    return widget.type == 1
        ? '这个视频还没有评论，或者接口没有返回可见评论'
        : '这条动态还没有评论，或者接口没有返回可见评论';
  }

  Widget _body(
    BuildContext context,
    CommentListState state,
    CommentListNotifier notifier,
  ) {
    if (state.loading && !state.initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && state.isEmpty) {
      return ErrorView(
        error: state.error!,
        onRetry: () => notifier.load(force: true),
      );
    }

    if (state.isEmpty) {
      return EmptyView(
        message: _emptyMessage,
        icon: Icons.forum_outlined,
      );
    }

    final items = <BiliComment>[...state.top, ...state.items];

    // 内嵌模式：外层已经能滚，这里只把内容按真实高度摊开，
    // 否则两层滚动会互相抢手势，而且 shrinkWrap 缺了就直接撑不满。
    final list = ListView.separated(
      controller: widget.embedded ? null : _scrollController,
      shrinkWrap: widget.embedded,
      physics: widget.embedded
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 4, 16, widget.embedded ? 8 : 24),
      itemCount: items.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 20),
      itemBuilder: (context, index) {
        if (index == items.length) {
          return _footer(state, notifier);
        }
        final comment = items[index];
        return _CommentTile(
          comment: comment,
          loadingReplies: state.loadingReplies.contains(comment.id),
          repliesError: state.repliesError[comment.id],
          onToggleReplies: () => notifier.toggleReplies(comment),
          resolvingPics: state.resolvingPics.contains(comment.id),
          picsError: state.picsError[comment.id],
          onExpandPics: () => notifier.expandCommentPics(comment),
          // 微博走「默认 2 条 + …… 共 N 条回复 >」的两段式；
          // B 站恒 false → 仍是「查看 N 条回复 / 收起回复」的老交互。
          weiboSubComments: _isWeibo,
          subRepliesExpanded: state.expandedReplies.contains(comment.id),
          subRepliesAllLoaded: state.repliesAllLoaded.contains(comment.id),
        );
      },
    );

    if (widget.embedded) return list;

    return RefreshIndicator(
      onRefresh: () => notifier.load(force: true),
      child: list,
    );
  }

  Widget _footer(CommentListState state, CommentListNotifier notifier) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // 分页失败：给明确错误 + 重试按钮（需求验收项）。
    if (state.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ErrorView(
          error: state.error!,
          compact: true,
          onRetry: () => notifier.loadMore(),
        ),
      );
    }

    if (state.isEnd) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '没有更多评论了',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: OutlinedButton(
          onPressed: () => notifier.loadMore(),
          child: const Text('加载更多'),
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.loadingReplies,
    required this.repliesError,
    required this.onToggleReplies,
    this.resolvingPics = false,
    this.picsError,
    this.onExpandPics,
    this.weiboSubComments = false,
    this.subRepliesExpanded = false,
    this.subRepliesAllLoaded = false,
  });

  final BiliComment comment;
  final bool loadingReplies;
  final String? repliesError;
  final VoidCallback onToggleReplies;

  /// 该评论的多图短链正在解析中（点过一次、还没回来）。
  final bool resolvingPics;

  /// 多图解析失败的可读提示（失败只降级到单图，不整页崩）。
  final String? picsError;

  /// 点「共 N 张 · 点此加载全部」时回调。为 null = 不提供该能力
  /// （B 站评论恒为 null，路径完全不变）。
  final VoidCallback? onExpandPics;

  /// 微博的子评论区走**两段式**（默认只显示前 2 条 + 「…… 共 N 条回复 >」）。
  ///
  /// 为 false（B 站）时整段逻辑与历史完全一致：一行「查看 N 条回复」+ 展开后
  /// 直接列全部。**不要**把 B 站也改成两段式 —— 它的 `replies` 本来就是
  /// 一次请求的全部，没有「内嵌只有 2 条」的问题。
  final bool weiboSubComments;

  /// 子评论是否**被用户点开过**（微博侧）。
  ///
  /// ⚠️ 不能用 `comment.repliesLoaded` 代替：微博内嵌的 2 条让那个标记
  /// 在解析阶段就是 true，拿它当展开开关会让楼层一进页面就显示「收起 ^」，
  /// `...... 共 N 条回复 >` 那行**根本不会出现**（真机复现过）。
  final bool subRepliesExpanded;

  /// 子评论是否已经拉到到底（微博侧）。
  ///
  /// 用途只有一个：当「声称 N 条 > 实拉到 M 条」时，如实补一行
  /// 「已显示全部 M 条」。**绝不能**拿 `totalReplies` 当分母做进度。
  final bool subRepliesAllLoaded;

  /// 未展开时展示的子评论条数（参考设计：前 2 条）。
  static const int collapsedReplyCount = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Avatar(url: comment.avatar),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          comment.uname,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (comment.isUp) ...<Widget>[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00A1D6).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            'UP',
                            style: TextStyle(
                              fontSize: 9,
                              color: Color(0xFF00A1D6),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    comment.message,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                  // 评论配图：渲染在正文下方、时间行之前。
                  // B 站评论 images 恒为空 → 这里整段不渲染，B 站路径零变化。
                  if (comment.images.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    _CommentImages(
                      comment: comment,
                      maxSingleHeight: 200,
                    ),
                  ],
                  if (comment.imageCount > comment.images.length) ...<Widget>[
                    const SizedBox(height: 4),
                    _PicCountHint(
                      count: comment.imageCount,
                      loaded: comment.images.length,
                      // 有短链线索才给「加载全部」；没有就如实说接口只给了这些。
                      canExpand: comment.mixMediaIds.isNotEmpty &&
                          onExpandPics != null,
                      resolving: resolvingPics,
                      onExpand: onExpandPics,
                      error: picsError,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Text(
                        TimeParse.humanize(comment.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${comment.like}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        // 子评论区：两个平台是**两套交互**，刻意不合并。
        //
        // - B 站：一行「查看 N 条回复」+ 展开后列全部回复（历史行为，零变化）；
        // - 微博：默认只显示前 2 条 + 「…… 共 N 条回复 >」，点开显示全部
        //   已加载的（完整内容由 `comments/hotflowChild` 在后台补全）。
        if (weiboSubComments)
          ..._weiboReplies(context, theme)
        else
          ..._biliReplies(theme),
      ],
    );
  }

  // ------------------------------------------------------------ B 站（不变）

  /// B 站子评论区：与历史实现逐行一致（一行切换 + 展开后列全部）。
  List<Widget> _biliReplies(ThemeData theme) {
    if (comment.replyCount <= 0) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(left: 40),
        child: InkWell(
          onTap: loadingReplies ? null : onToggleReplies,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                if (loadingReplies)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.subdirectory_arrow_right_rounded, size: 14),
                const SizedBox(width: 6),
                Text(
                  comment.repliesLoaded
                      ? '收起回复'
                      : '查看 ${comment.replyCount} 条回复',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF00A1D6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (repliesError != null)
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 4),
          child: Text(
            repliesError!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      if (comment.replies.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: comment.replies.map((sub) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    RichText(
                      text: TextSpan(
                        style:
                            theme.textTheme.bodySmall?.copyWith(height: 1.45),
                        children: <TextSpan>[
                          TextSpan(
                            text: '${sub.uname}：',
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(text: sub.message),
                        ],
                      ),
                    ),
                    // 楼中楼也显示配图，但用更小的尺寸：这里的可用宽度
                    // 已经比一级评论窄 40px，再用一级的限高会显得头重脚轻。
                    if (sub.images.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      _CommentImages(
                        comment: sub,
                        maxSingleHeight: 120,
                      ),
                    ],
                    if (sub.imageCount > sub.images.length) ...<Widget>[
                      const SizedBox(height: 2),
                      _PicCountHint(
                        count: sub.imageCount,
                        loaded: sub.images.length,
                        canExpand: false,
                        resolving: false,
                        onExpand: null,
                        error: null,
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
        ),
    ];
  }

  // ------------------------------------------------------------ 微博（两段式）

  /// 微博子评论区（照参考设计）：
  ///
  /// - **未展开**：只显示前 [collapsedReplyCount] 条 + 一行可点的
  ///   「…… 共 N 条回复 >」；
  /// - **展开后**：显示全部已加载的 + 那一行变成「收起 ^」；
  /// - 若已拉到底但条数仍少于声称总数，在那行**上方**补一行
  ///   「已显示全部 M 条」（如实告知，不假装拉全了）。
  ///
  /// N 取 `totalReplies`（微博 `total_number`）—— 它**只是文案**，
  /// 绝不参与进度计算：实测声称 68、接口只给 12，拿它当分母会永远卡住。
  List<Widget> _weiboReplies(BuildContext context, ThemeData theme) {
    final bool hasEmbedded = comment.replies.isNotEmpty;
    final int claimed =
        comment.totalReplies > 0 ? comment.totalReplies : comment.replies.length;
    // 一条回复都没有、也没声称有回复 → 整段不渲染（与历史一致）。
    if (!hasEmbedded && claimed <= 0) return const <Widget>[];

    final bool expanded = subRepliesExpanded;
    final List<BiliComment> shown = expanded
        ? comment.replies
        : comment.replies.take(collapsedReplyCount).toList(growable: false);

    final bool showAllHint = expanded &&
        subRepliesAllLoaded &&
        comment.replies.length < claimed;

    return <Widget>[
      if (shown.isNotEmpty) ...<Widget>[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: shown
                .map((sub) => _SubCommentTile(comment: sub))
                .toList(growable: false),
          ),
        ),
      ],
      if (showAllHint)
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 2),
          child: Text(
            // 如实告知：接口能给的只有这么多。
            '已显示全部 ${comment.replies.length} 条',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(left: 40, top: 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            onTap: loadingReplies ? null : onToggleReplies,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    expanded
                        // 参考设计里这三个点与箭头都是文本，不是图标。
                        ? '收起 ^'
                        : '...... 共 $claimed 条回复 >',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (loadingReplies) ...<Widget>[
                    const SizedBox(width: 6),
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      if (repliesError != null)
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 2),
          child: Text(
            repliesError!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
    ];
  }
}

/// 微博子评论（二级回复）单条，照参考设计：
///
/// 小头像 24px · 昵称 13px 次要色 · 正文 15px · 底部时间 12px + 点赞数。
///
/// 图片复用 [_CommentImages]（限高比一级评论小）。
class _SubCommentTile extends StatelessWidget {
  const _SubCommentTile({required this.comment});

  final BiliComment comment;

  static const double _avatarSize = 24;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final DateTime? at = comment.createdAt;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Avatar(url: comment.avatar, size: _avatarSize),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  comment.uname,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  comment.message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                if (comment.images.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  _CommentImages(comment: comment, maxSingleHeight: 120),
                ],
                if (comment.imageCount > comment.images.length) ...<Widget>[
                  const SizedBox(height: 2),
                  _PicCountHint(
                    count: comment.imageCount,
                    loaded: comment.images.length,
                    canExpand: false,
                    resolving: false,
                    onExpand: null,
                    error: null,
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Text(
                      TimeParse.humanize(at),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (comment.like > 0) ...<Widget>[
                      const SizedBox(width: 12),
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${comment.like}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「共 N 张」这行。
///
/// 两种形态：
/// - `canExpand = true`（微博、且评论带 `mix_media_ids` 短链）→
///   **可点击**的「共 N 张 · 点此加载全部」；
/// - `canExpand = false`（B 站 / 没有短链线索 / 楼中楼）→ 保持原来的
///   只读文案「共 N 张（接口仅提供 M 张）」。
///
/// 点击**只**触发 [onExpand]，组件本身不发任何请求：短链解析在仓库层，
/// 由 controller 的 `expandCommentPics` 驱动（懒加载，绝不进列表构建路径）。
class _PicCountHint extends StatelessWidget {
  const _PicCountHint({
    required this.count,
    required this.loaded,
    required this.canExpand,
    required this.resolving,
    required this.onExpand,
    required this.error,
  });

  /// 接口声明的总张数（`pic_num`）。
  final int count;

  /// 已经拿到的张数。
  final int loaded;

  final bool canExpand;

  /// 正在解析（点过、还没回来）→ 行尾显示小 spinner。
  final bool resolving;

  final VoidCallback? onExpand;

  /// 解析失败的可读提示。
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String? err = error;

    if (!canExpand) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            // 如实告知：接口只给了这么多，不是我们只显示一张。
            '共 $count 张（接口仅提供 $loaded 张）',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (err != null)
            Text(
              err,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        InkWell(
          // 解析中禁用重复点击（controller 侧还有一层防重复）。
          onTap: resolving ? null : onExpand,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (resolving) ...<Widget>[
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  resolving ? '正在加载全部图片…' : '共 $count 张 · 点此加载全部',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (err != null)
          Text(
            err,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
      ],
    );
  }
}

/// 评论配图（微博 hotflow 一条评论最多给 1 张，见 `WeiboCommentParser`）。
///
/// 刻意**复用** [PhotoGrid] 与 [ImageGalleryPage]，不自己画格子：
/// 动态九宫格那套已经处理了限高、圆角、`cacheWidth` 解码压缩。
///
/// 不做宫格/轮播的「多图」假象：接口只回 1 张，写多图 UI 只会永远空着
/// 后面的格子。张数差异由正文下方的「共 N 张」小字如实说明。
class _CommentImages extends StatelessWidget {
  const _CommentImages({
    required this.comment,
    required this.maxSingleHeight,
  });

  final BiliComment comment;

  /// 单图高度上限：一级评论宽松、楼中楼收紧。
  final double maxSingleHeight;

  @override
  Widget build(BuildContext context) {
    final List<String> images = comment.images;
    if (images.isEmpty) return const SizedBox.shrink();

    return PhotoGrid(
      images: images,
      maxSingleHeight: maxSingleHeight,
      // 单图按真实比例显示并 `contain`（不裁）：
      // B 站评论图常是超长手机截图（实测 1080×9109），按 4:3 裁会只剩一条。
      // 多图仍是正方格 `cover`（PhotoGrid 内部对 >1 张不读这个 fit）。
      aspectRatios: comment.imageAspectRatios,
      singleFit: BoxFit.contain,
      onTap: (index) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImageGalleryPage(
            images: images,
            initialIndex: index,
            // 标题用评论者昵称：全屏预览顶部有标题位，留空会显得没上下文。
            title: comment.uname,
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.url, this.size = 30});

  final String? url;

  /// 头像边长。一级评论 30；子评论按参考设计用 24。
  final double size;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: AppColors.placeholder,
          shape: BoxShape.circle,
        ),
      );
    }
    return ClipOval(
      child: CachedImage(
        url: url,
        width: size,
        height: size,
        cacheWidth: (size * 3).round(),
        errorWidget: Container(
          width: size,
          height: size,
          color: AppColors.placeholder,
        ),
      ),
    );
  }
}
