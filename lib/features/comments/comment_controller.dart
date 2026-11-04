import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/app_error.dart';
import '../../core/utils/logger.dart';
import '../../data/models/comment.dart';
import '../../data/models/content_item.dart';
import '../../data/repo/comment_repo.dart';
import '../../providers.dart';

/// 评论区的参数（一条内容的评论 = 一份评论状态）。
///
/// [platform] + [oid] + [type] 一起决定「看的是哪个评论区」：
/// B 站视频 `(bilibili, aid, 1)`、图文动态 `(bilibili, 图片 id, 11)`、
/// 转发动态 `(bilibili, 动态 id, 17)`；微博 `(weibo, mid, 0)`。
///
/// 三者一起进 [==] / [hashCode]，否则切到另一条内容时会复用错的状态。
class CommentArgs {
  const CommentArgs({
    required this.oid,
    this.platform = Platform.bilibili,
    this.type = 1,
    this.upMid = 0,
  });

  final String oid;
  final Platform platform;
  final int type;
  final int upMid;

  /// 转成平台无关的请求参数。
  CommentRequest get request => CommentRequest(
        platform: platform,
        oid: oid,
        type: type,
        upMid: upMid,
      );

  @override
  bool operator ==(Object other) =>
      other is CommentArgs &&
      other.oid == oid &&
      other.platform == platform &&
      other.type == type &&
      other.upMid == upMid;

  @override
  int get hashCode => Object.hash(oid, platform, type, upMid);
}

class CommentListState {
  const CommentListState({
    this.loading = false,
    this.loadingMore = false,
    this.initialized = false,
    this.top = const <BiliComment>[],
    this.items = const <BiliComment>[],
    this.isEnd = false,
    this.cursor,
    this.error,
    this.sort = CommentSort.hot,
    this.total = 0,
    this.loadingReplies = const <String>{},
    this.repliesError = const <String, String>{},
    this.collapsedReplies = const <String, List<BiliComment>>{},
    this.repliesCursor = const <String, String?>{},
    this.repliesAllLoaded = const <String>{},
    this.expandedReplies = const <String>{},
    this.resolvingPics = const <String>{},
    this.expandedPics = const <String>{},
    this.picsError = const <String, String>{},
  });

  final bool loading;
  final bool loadingMore;
  final bool initialized;

  /// 置顶评论。
  final List<BiliComment> top;

  final List<BiliComment> items;
  final bool isEnd;
  final String? cursor;
  final AppError? error;
  final CommentSort sort;
  final int total;

  /// 正在加载楼中楼的楼层 id（评论主键是 String，见 [BiliComment.id]）。
  final Set<String> loadingReplies;

  /// 楼中楼加载失败的原因（id -> 文案）。
  final Map<String, String> repliesError;

  /// 微博被**收起**的楼中楼（id -> 已加载的回复列表）。
  ///
  /// 为什么需要暂存：微博的楼中楼内嵌在首页响应里，`loadReplies` 返回空页
  /// （没有第二个接口）。若收起时直接丢弃列表，再展开就再也拿不回来了。
  /// 所以收起 = 「从 `BiliComment.replies` 搬到这个 Map 里」，
  /// 展开 = 「搬回去」，全程零请求。B 站不用这个字段（它走重新请求）。
  final Map<String, List<BiliComment>> collapsedReplies;

  /// 每条评论的**下一个**子评论游标（id -> 游标）。
  ///
  /// 只在展开时写入（来自 [BiliComment.replyCursor]）；`null` / 缺失 = 到底。
  /// 微博侧专用，B 站不写这个 Map。
  final Map<String, String?> repliesCursor;

  /// 子评论已经拉到到底的评论 id（微博侧专用）。
  ///
  /// 用途：展开后如果「已加载条数 < 声称总数」，UI 要如实补一行
  /// 「已显示全部 N 条」——否则用户会以为「说 68 条只给 12 条」是 bug。
  final Set<String> repliesAllLoaded;

  /// **用户点开过**子评论的楼层 id（微博侧专用，两段式交互的开关）。
  ///
  /// ⚠️ 刻意与 [BiliComment.repliesLoaded] 分开，这是本功能最关键的语义拆分：
  ///
  /// - `repliesLoaded` 表示「列表里已经有内容」（微博内嵌的 2 条也算有），
  ///   它是**数据状态**，解析层一进门就置 true；
  /// - `expandedReplies` 表示「用户点开过」，它是**交互状态**，初始为空。
  ///
  /// 早先拿 `repliesLoaded` 当展开开关，结果微博楼层一进页面就是
  /// 「收起 ^」+ 只有 2 条 —— `...... 共 N 条回复 >` 那行**根本不会出现**，
  /// 用户连点都点不到（真机已复现）。
  final Set<String> expandedReplies;

  /// 正在解析多图短链的评论 id（防重复触发）。
  ///
  /// 只有用户点「共 N 张 · 点此加载全部」时才会进这里 ——
  /// 列表构建路径**绝不**碰这个字段，也**绝不**发任何请求。
  final Set<String> resolvingPics;

  /// 已经成功展开过完整图集的评论 id。
  final Set<String> expandedPics;

  /// 图集解析失败的原因（id -> 文案）。失败只降级到单图，不整页崩。
  final Map<String, String> picsError;

  bool get isEmpty => top.isEmpty && items.isEmpty;

  int get displayCount => total > 0 ? total : items.length;
}

/// 把「多图短链」解析成图片直链的注入点（默认走 `weiboCommentPicResolverProvider`）。
///
/// 抽成函数类型而不是直接依赖具体类：这样 controller 的单测不需要构造 Dio，
/// 也钉死了「controller 只负责状态机，解析细节在仓库层」的分层。
typedef CommentPicResolver = Future<List<String>> Function(
  List<String> mixMediaIds, {
  String? commentId,
});

/// 拉一页**子评论**（微博二级回复）的注入点。
///
/// 默认接 `WeiboCommentRepository.loadChildReplies`。为 null = 本次没有注入
/// （B 站 / 纯状态机单测）→ 展开时只用内嵌内容，**绝不发请求**。
///
/// 抽成函数类型的原因同 [CommentPicResolver]：B 站仓库不该多出一个
/// 「拉微博子评论」的能力，也不该为了它去改 `CommentRepositoryLike`
/// 这个被十几个测试实现着的接口。
typedef ChildRepliesLoader = Future<({
  List<BiliComment> items,
  String? nextCursor,
})> Function({
  required String cid,
  String? maxId,

  /// 所属微博的 mid。子评论接口的 `Referer` 要用它拼详情页地址 ——
  /// 缺 Referer 时服务端返回的不是 JSON，真机表现为「内容解析失败」。
  String? mid,
});

/// 评论区分页控制器。
///
/// 需求要求的「排序 / 下拉加载更多 / 楼中楼展开 / 失败可重试」都体现在这里。
/// 注意：接口用**游标**分页（B 站 `pagination_str`、微博 `max_id`），不是
/// `pn` 递增，所以这里保存的是服务端返回的裸游标值 ——
/// 包装成请求参数的职责只在仓库层一处（不在这里、也不在解析层）。
class CommentListNotifier extends StateNotifier<CommentListState> {
  CommentListNotifier({
    required CommentRepositoryLike repo,
    required this.args,
    CommentPicResolver? resolvePics,
    ChildRepliesLoader? loadChildReplies,
  })  : _repo = repo,
        _resolvePics = resolvePics,
        _loadChildReplies = loadChildReplies,
        super(const CommentListState());

  final CommentRepositoryLike _repo;
  final CommentArgs args;

  /// 多图短链解析入口。为 null = 本次没有注入（B 站 / 单测），
  /// [expandCommentPics] 直接空转，**绝不**发请求。
  final CommentPicResolver? _resolvePics;

  /// 子评论拉取入口。为 null = 没有注入（B 站 / 单测），微博展开时
  /// 只用已内嵌的内容，**绝不**发请求。
  final ChildRepliesLoader? _loadChildReplies;

  /// 首屏加载。
  Future<void> load({bool force = false}) async {
    if (state.loading) return;
    if (state.initialized && !force) return;

    state = CommentListState(
      loading: true,
      initialized: state.initialized,
      sort: state.sort,
      items: state.items,
      top: state.top,
      cursor: state.cursor,
      total: state.total,
      isEnd: state.isEnd,
    );

    try {
      final page = await _repo.loadFirst(req: args.request);
      state = CommentListState(
        initialized: true,
        top: page.topComments,
        items: page.comments,
        isEnd: page.isEnd,
        cursor: page.nextCursor,
        sort: state.sort,
        total: page.total,
      );
    } on AppError catch (e) {
      state = CommentListState(
        initialized: true,
        sort: state.sort,
        error: e,
        total: state.total,
      );
    } catch (e) {
      state = CommentListState(
        initialized: true,
        sort: state.sort,
        error: AppError(AppErrorKind.unknown, '评论加载失败：$e'),
      );
    }
  }

  /// 加载下一页。
  Future<void> loadMore() async {
    if (state.loadingMore || state.isEnd) return;
    final cursor = state.cursor;
    if (cursor == null || cursor.isEmpty) return;

    state = _copy(loadingMore: true);

    try {
      final page = await _repo.loadMore(req: args.request, cursor: cursor);
      state = _copy(
        loadingMore: false,
        items: <BiliComment>[...state.items, ...page.comments],
        isEnd: page.isEnd,
        cursor: page.nextCursor,
        total: page.total > 0 ? page.total : state.total,
        clearError: true,
      );
    } on AppError catch (e) {
      state = _copy(loadingMore: false, error: e);
    } catch (e) {
      state = _copy(
        loadingMore: false,
        error: AppError(AppErrorKind.unknown, '加载更多失败：$e'),
      );
    }
  }

  /// 切换排序（重置游标重新拉取）。
  Future<void> changeSort(CommentSort sort) async {
    if (sort == state.sort) return;
    state = CommentListState(sort: sort, initialized: false);
    await load(force: true);
  }

  /// 展开/收起楼中楼。
  ///
  /// **两个平台走两条完全不同的路径**（微博的楼中楼内嵌 + 可续拉，
  /// B 站的楼中楼要单独请求）：
  ///
  /// - **B 站**：未加载 → `loadReplies` 拉一页；已加载 → 收起。行为与历史一致。
  /// - **微博**：默认只显示内嵌的前 2 条；点「…… 共 N 条回复 >」时
  ///   **先用已有内容立即展开**，再在后台补全（[childReplyPageLimit] 页封顶）。
  ///   详见 [_toggleEmbeddedReplies]。
  ///
  /// ## ⚠️ B 站收起时必须把「已展开」状态复位
  ///
  /// 早先收起只清空了 `replies`、却留着 `repliesLoaded = true`，于是：
  /// - UI 判据是 `comment.repliesLoaded` → 仍然显示「收起回复」（文字不变，
  ///   用户看到的就是「收回去了但字没变」）；
  /// - 再次点击又命中 `comment.repliesLoaded == true` 的收起分支，
  ///   只做一次「清空一个已经空的列表」—— 于是**永远无法重新展开**。
  Future<void> toggleReplies(BiliComment comment) async {
    if (_repliesAreEmbedded) {
      await _toggleEmbeddedReplies(comment);
      return;
    }

    final index = state.items.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;

    if (comment.repliesLoaded) {
      _collapseRemote(index, comment);
      return;
    }

    final loading = Set<String>.from(state.loadingReplies)..add(comment.id);
    final errors = Map<String, String>.from(state.repliesError)
      ..remove(comment.id);
    state = _copy(loadingReplies: loading, repliesError: errors);

    try {
      final page = await _repo.loadReplies(
        req: args.request,
        rootId: comment.id,
        page: 1,
      );
      final updated = List<BiliComment>.from(state.items);
      final idx = updated.indexWhere((c) => c.id == comment.id);
      if (idx >= 0) {
        updated[idx] = comment.copyWith(
          replies: page.comments,
          repliesLoaded: true,
          repliesHasMore: page.hasMore,
        );
      }
      final done = Set<String>.from(state.loadingReplies)..remove(comment.id);
      state = _copy(items: updated, loadingReplies: done);
    } on AppError catch (e) {
      final done = Set<String>.from(state.loadingReplies)..remove(comment.id);
      final errs = Map<String, String>.from(state.repliesError)
        ..[comment.id] = e.message;
      state = _copy(loadingReplies: done, repliesError: errs);
    } catch (e) {
      final done = Set<String>.from(state.loadingReplies)..remove(comment.id);
      final errs = Map<String, String>.from(state.repliesError)
        ..[comment.id] = '楼中楼加载失败：$e';
      state = _copy(loadingReplies: done, repliesError: errs);
    }
  }

  /// 微博的楼中楼内嵌在首页响应里 → 收起只切状态、**保留**列表。
  bool get _repliesAreEmbedded => args.platform == Platform.weibo;

  // ------------------------------------------------------- 微博子评论（两段式）

  /// 单次展开最多续拉几页子评论（防止「声称 68 条」把请求打爆）。
  static const int childReplyPageLimit = 3;

  /// 微博的子评论展开/收起。
  ///
  /// ## 为什么是两段式
  ///
  /// 一级评论接口内嵌的 `comments[]` **恒为前 2 条**（实测），所以：
  /// 1. **先显示**：立即用已有内容（内嵌 2 条，或上次已拉到的更多条）展开，
  ///    **不等网络** —— 点一下就要有反应；
  /// 2. **后台补全**：再拉 `comments/hotflowChild` 的第 1 页并续拉（≤3 页），
  ///    按 id 去重合并到同一条楼层上。
  ///
  /// 失败**不重试**（重试交给用户手上的再次点击）、保留已显示内容。
  Future<void> _toggleEmbeddedReplies(BiliComment comment) async {
    final String id = comment.id;
    final BiliComment? stored = _findComment(id);
    if (stored == null) return;

    // 「展开 / 收起」只看**用户交互标记** `expandedReplies`。
    // 绝不能看 `repliesLoaded`：微博内嵌的 2 条让它在解析阶段就是 true，
    // 拿它当开关会让楼层一进页面就是「收起 ^」、`...... 共 N 条回复 >`
    // 那行永远不出现（真机已复现这个 bug）。
    final bool expanded = state.expandedReplies.contains(id);
    // replies 取两边并集：UI 手上那份可能比状态更新（也绝不能因此丢内容）。
    final List<BiliComment> merged = _mergeReplies(stored.replies, comment.replies);

    if (expanded) {
      // 收起：去掉交互标记。列表**不清空** —— UI 收起时自己只渲染前 2 条，
      // 再展开就是纯本地切换（不发第二个请求）。
      _updateItem(
        id,
        (BiliComment c) => c.copyWith(
          replies: merged,
          repliesHasMore: false,
        ),
      );
      state = _copy(
        expandedReplies: Set<String>.from(state.expandedReplies)..remove(id),
      );
      return;
    }

    // 展开：先让内容可见（内嵌 2 条 / 之前拉到的全部），再说网络的事。
    _updateItem(
      id,
      (BiliComment c) => c.copyWith(
        replies: merged,
        repliesHasMore: false,
      ),
    );
    state = _copy(
      expandedReplies: Set<String>.from(state.expandedReplies)..add(id),
    );

    await _ensureChildReplies(comment);
  }

  /// 按 id 在 `top` / `items` 里找一条评论。
  BiliComment? _findComment(String id) {
    for (final BiliComment c in state.top) {
      if (c.id == id) return c;
    }
    for (final BiliComment c in state.items) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 把一条微博楼层的子评论补全到「到底」或页数上限。
  ///
  /// 三条守卫（缺一条就会打爆或重复请求）：
  /// - 正在加载的楼层直接返回；
  /// - 已到底的楼层直接返回；
  /// - **上次失败过的不自动重试**（用户再点「展开」才可能重新进来）。
  Future<void> _ensureChildReplies(BiliComment comment) async {
    final String id = comment.id;
    if (state.loadingReplies.contains(id)) return;
    if (state.repliesAllLoaded.contains(id)) return;
    if (state.repliesError.containsKey(id)) return;

    final ChildRepliesLoader? loader = _loadChildReplies;
    final String cursor = (comment.replyCursor ?? '').trim();

    // 没有拉取能力（B 站 / 单测未注入）或没有游标：内嵌的就是全部能拿到的。
    if (loader == null || cursor.isEmpty) {
      state = _copy(
        repliesAllLoaded: Set<String>.from(state.repliesAllLoaded)..add(id),
        repliesCursor: Map<String, String?>.from(state.repliesCursor)..[id] = null,
      );
      return;
    }

    state = _copy(
      loadingReplies: Set<String>.from(state.loadingReplies)..add(id),
      repliesError: Map<String, String>.from(state.repliesError)..remove(id),
    );

    // ⚠️ 首屏**不带**游标，`replyCursor` 是给「第 2 页」用的。
    //
    // 探针实测（`.env/weibo_subcomment_probe.md`）：
    // - 第 1 页 **不带 max_id** → 返回 10 条；
    // - 第 2 页 **带 max_id=<一级节点值>** → 返回 2 条、零重复。
    //
    // 早先把 `replyCursor` 直接当首屏游标，结果服务端回
    // `{"ok":1,"errno":100011,"msg":"暂无数据"}` —— 表现为展开后一条都补不出来。
    String? next;
    int pages = 0;
    bool allLoaded = false;
    String? failure;

    try {
      while (pages < childReplyPageLimit) {
        final int before = _repliesOf(id).length;
        final ({List<BiliComment> items, String? nextCursor}) page =
            // mid 来自本页内容的 `oid`（微博就是这条微博的 mid）：
            // 子评论接口的 Referer 必须指向微博详情页，缺了它服务端返回非 JSON。
            await loader(cid: id, maxId: next, mid: args.oid.trim());
        pages += 1;

        final List<BiliComment> merged =
            _mergeReplies(_repliesOf(id), page.items);
        _updateItem(id, (BiliComment c) => c.copyWith(replies: merged));

        // ⚠️ 游标推进规则（两条来源，按优先级）：
        //
        // 1. **首屏不带游标** —— 探针实测：不带 `max_id` 才能拿到第 1 页
        //    （10 条）；带上 `replyCursor` 反而回 `errno=100011 暂无数据`。
        // 2. 首屏之后用 `page.nextCursor`（仓库原样回传它收到的 maxId）；
        //    若仓库没给（null），则回退到一级评论节点的 `replyCursor`。
        //
        // 这样既不依赖「响应里带游标」（`hotflowChild` 的响应里确实没有），
        // 也保留了「上游若能给出更精确的游标就用它」的余地。
        final String fallback = cursor.trim();
        final String fromPage = (page.nextCursor ?? '').trim();
        next = page.items.isEmpty
            ? null
            : (fromPage.isNotEmpty
                ? fromPage
                : (fallback.isEmpty ? null : fallback));
        // 到底：本页 0 条 / 没有可用游标 / 一条新的都没并进来（全重复）。
        if (page.items.isEmpty || (next ?? '').trim().isEmpty) {
          allLoaded = true;
          break;
        }
        if (merged.length <= before) {
          // 游标没往前走（服务端重复给同一页）：停手，别把 3 页额度耗在死循环上。
          allLoaded = true;
          break;
        }
      }
      // 走完 3 页仍有游标 → 没到底（也算「拉完了本轮允许的部分」）。
    } on AppError catch (e) {
      // 界面只显示 e.message（「内容解析失败」这类笼统文案），
      // 但**真正有用的原因在 e.detail**（例如「响应结构异常」「不是合法 JSON」）。
      // 不打日志的话，真机上只能看到一个笼统的失败，必须先复现再猜代码。
      // 这里不记录任何请求内容与凭据，只记错误种类与 detail。
      Log.w(
        'CommentList',
        '子评论拉取失败 cid=$id：${e.kind.name}'
        '${e.detail == null || e.detail!.isEmpty ? '' : ' · ${e.detail}'}',
      );
      // 把 detail 一并显示：`message` 是给用户的笼统文案（「内容解析失败」），
      // 而 `detail` 才是能定位问题的东西（响应体摘要 / 结构形态）。
      // 两者都没有凭据，可以安全上屏 —— 否则真机上只能看到一句无信息的红字。
      failure = (e.detail == null || e.detail!.isEmpty)
          ? e.message
          : '${e.message}（${e.detail}）';
    } catch (e) {
      Log.w('CommentList', '子评论拉取异常 cid=$id：$e');
      failure = '子评论加载失败，已保留当前内容';
    }

    final Set<String> done = Set<String>.from(state.loadingReplies)
      ..remove(id);
    final Map<String, String?> cursors =
        Map<String, String?>.from(state.repliesCursor);
    final Set<String> all = Set<String>.from(state.repliesAllLoaded);
    final Map<String, String> errors =
        Map<String, String>.from(state.repliesError);

    if (failure != null) {
      errors[id] = failure;
      cursors[id] = next; // 留着游标：失败不自动重试，但别把位置弄丢。
      all.remove(id);
    } else {
      cursors[id] = allLoaded ? null : next;
      if (allLoaded) {
        all.add(id);
      } else {
        all.remove(id);
      }
      errors.remove(id);
    }

    state = _copy(
      loadingReplies: done,
      repliesCursor: cursors,
      repliesAllLoaded: all,
      repliesError: errors,
    );
  }

  /// 某条楼层当前已加载的子评论（微博用）。
  List<BiliComment> _repliesOf(String id) =>
      _findComment(id)?.replies ?? const <BiliComment>[];

  /// 按 id 去重合并两批子评论，**保留先到的顺序**。
  ///
  /// 内嵌的 2 条通常就是子接口第 1 页的前 2 条，所以直接拼接会出现重复条目：
  /// 2 + 10 应该还是 10，不是 12。
  static List<BiliComment> _mergeReplies(
    List<BiliComment> existing,
    List<BiliComment> incoming,
  ) {
    final List<BiliComment> out = <BiliComment>[];
    final Set<String> seen = <String>{};
    for (final BiliComment c in <BiliComment>[...existing, ...incoming]) {
      if (c.id.isEmpty) continue;
      if (!seen.add(c.id)) continue;
      out.add(c);
    }
    return out;
  }

  /// 按 id 就地替换一条评论（`top` / `items` 都找）。
  void _updateItem(String id, BiliComment Function(BiliComment) update) {
    final int ti = state.top.indexWhere((BiliComment c) => c.id == id);
    if (ti >= 0) {
      final List<BiliComment> list = List<BiliComment>.from(state.top);
      list[ti] = update(list[ti]);
      state = _copy(top: list);
      return;
    }
    final int ii = state.items.indexWhere((BiliComment c) => c.id == id);
    if (ii < 0) return;
    final List<BiliComment> list = List<BiliComment>.from(state.items);
    list[ii] = update(list[ii]);
    state = _copy(items: list);
  }

  /// B 站：收起时**丢弃**列表并复位标记，下次点击会重新请求。
  void _collapseRemote(int index, BiliComment comment) {
    final List<BiliComment> updated = List<BiliComment>.from(state.items);
    updated[index] = comment.copyWith(
      replies: const <BiliComment>[],
      repliesLoaded: false,
      repliesHasMore: false,
    );
    state = _copy(items: updated);
  }

  /// 展开某条评论的**完整图集**（用户点「共 N 张 · 点此加载全部」时才调用）。
  ///
  /// 三条硬约束：
  /// 1. **懒执行**：这个方法是唯一的解析入口，列表构建路径不会碰它；
  /// 2. **幂等**：已在解析中 / 已展开过的评论直接返回，不发第二个请求；
  /// 3. **降级**：解析失败只保留现有单图 + 一条可读提示，绝不整页崩。
  Future<void> expandCommentPics(BiliComment comment) async {
    final CommentPicResolver? resolver = _resolvePics;
    if (resolver == null) return; // 没注入解析器（B 站 / 单测）→ 空转。

    final String id = comment.id;
    if (comment.mixMediaIds.isEmpty) return; // 没有多图线索。
    if (state.resolvingPics.contains(id)) return; // 防重复触发。
    if (state.expandedPics.contains(id)) return; // 已展开过。

    // 定位：一级评论在 items，置顶在 top。两边都找，找不到就放弃。
    final (_CommentSlot slot, int index) = _locate(id);
    if (slot == _CommentSlot.none) return;

    state = _copy(
      resolvingPics: Set<String>.from(state.resolvingPics)..add(id),
      picsError: Map<String, String>.from(state.picsError)..remove(id),
    );

    try {
      final List<String> resolved = await resolver(
        comment.mixMediaIds,
        commentId: id,
      );

      final Set<String> resolving = Set<String>.from(state.resolvingPics)
        ..remove(id);

      if (resolved.isEmpty) {
        // 一张都没解析出来：保留单图，给可读提示（不重试）。
        state = _copy(
          resolvingPics: resolving,
          picsError: Map<String, String>.from(state.picsError)
            ..[id] = '多图加载失败，已保留现有图片',
        );
        return;
      }

      // 替换成完整图集（解析结果优先；接口那张单图通常就是图集里的第一张）。
      final BiliComment updated =
          comment.copyWith(images: resolved, mixMediaIds: const <String>[]);
      _replace(slot, index, updated);

      state = _copy(
        resolvingPics: resolving,
        expandedPics: Set<String>.from(state.expandedPics)..add(id),
      );
    } on AppError catch (e) {
      state = _copy(
        resolvingPics: Set<String>.from(state.resolvingPics)..remove(id),
        picsError: Map<String, String>.from(state.picsError)..[id] = e.message,
      );
    } catch (_) {
      state = _copy(
        resolvingPics: Set<String>.from(state.resolvingPics)..remove(id),
        picsError: Map<String, String>.from(state.picsError)
          ..[id] = '多图加载失败，已保留现有图片',
      );
    }
  }

  /// 在 `top` / `items` 里定位某条评论。
  (_CommentSlot, int) _locate(String id) {
    final int inTop = state.top.indexWhere((BiliComment c) => c.id == id);
    if (inTop >= 0) return (_CommentSlot.top, inTop);
    final int inItems = state.items.indexWhere((BiliComment c) => c.id == id);
    if (inItems >= 0) return (_CommentSlot.items, inItems);
    return (_CommentSlot.none, -1);
  }

  /// 用 [updated] 覆盖指定位置的评论。
  void _replace(_CommentSlot slot, int index, BiliComment updated) {
    final List<BiliComment> list = slot == _CommentSlot.top
        ? List<BiliComment>.from(state.top)
        : List<BiliComment>.from(state.items);
    if (index < 0 || index >= list.length) return;
    list[index] = updated;
    state = slot == _CommentSlot.top
        ? _copy(top: list)
        : _copy(items: list);
  }

  CommentListState _copy({
    bool? loading,
    bool? loadingMore,
    bool? initialized,
    List<BiliComment>? top,
    List<BiliComment>? items,
    bool? isEnd,
    String? cursor,
    AppError? error,
    bool clearError = false,
    CommentSort? sort,
    int? total,
    Set<String>? loadingReplies,
    Map<String, String>? repliesError,
    Map<String, List<BiliComment>>? collapsedReplies,
    Map<String, String?>? repliesCursor,
    Set<String>? repliesAllLoaded,
    Set<String>? expandedReplies,
    Set<String>? resolvingPics,
    Set<String>? expandedPics,
    Map<String, String>? picsError,
  }) =>
      CommentListState(
        loading: loading ?? state.loading,
        loadingMore: loadingMore ?? state.loadingMore,
        initialized: initialized ?? state.initialized,
        top: top ?? state.top,
        items: items ?? state.items,
        isEnd: isEnd ?? state.isEnd,
        cursor: cursor ?? state.cursor,
        error: clearError ? null : (error ?? state.error),
        sort: sort ?? state.sort,
        total: total ?? state.total,
        loadingReplies: loadingReplies ?? state.loadingReplies,
        repliesError: repliesError ?? state.repliesError,
        collapsedReplies: collapsedReplies ?? state.collapsedReplies,
        repliesCursor: repliesCursor ?? state.repliesCursor,
        repliesAllLoaded: repliesAllLoaded ?? state.repliesAllLoaded,
        expandedReplies: expandedReplies ?? state.expandedReplies,
        resolvingPics: resolvingPics ?? state.resolvingPics,
        expandedPics: expandedPics ?? state.expandedPics,
        picsError: picsError ?? state.picsError,
      );
}

/// 评论所在的分组（用于「按 id 改一条」时知道该改哪个列表）。
enum _CommentSlot { top, items, none }

/// 评论区状态。**按 [CommentArgs.platform] 选仓库**：
/// - B 站 → `commentRepoProvider`（既有实现，行为不变）；
/// - 微博 → `weiboCommentRepoProvider`（hotflow，内嵌楼中楼）。
///
/// 多图短链解析器 / 子评论拉取器**只注入给微博**：B 站评论没有多图短链、
/// 也没有微博那种「内嵌只有 2 条、要单独接口补全」的问题。注入等于给出一条
/// 本不该存在的能力（且会让「B 站零变化」这条红线变成口头承诺）。
final commentListProvider = StateNotifierProvider.autoDispose
    .family<CommentListNotifier, CommentListState, CommentArgs>(
  (ref, args) => CommentListNotifier(
    repo: args.platform == Platform.weibo
        ? ref.watch(weiboCommentRepoProvider)
        : ref.watch(commentRepoProvider),
    args: args,
    resolvePics: args.platform == Platform.weibo
        ? ref.watch(weiboCommentPicResolverProvider).resolveCommentPics
        : null,
    loadChildReplies: args.platform == Platform.weibo
        ? ref.watch(weiboCommentRepoProvider).loadChildReplies
        : null,
  ),
);
