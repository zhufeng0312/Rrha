import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../core/storage/prefs.dart';
import '../../core/utils/async_utils.dart';
import '../../core/utils/logger.dart';
import '../bili/bili_timeline_source.dart';
import '../models/content_item.dart';
import '../models/subscription.dart';
import '../weibo/weibo_backend.dart';
import '../weibo/weibo_timeline_source.dart';
import 'source_cursor.dart';

/// 一次时间线刷新的结果。
class TimelineResult {
  const TimelineResult({
    required this.items,
    required this.statuses,
    this.lastUpdated,
    this.staleFallbackUsed = false,
    this.fatalError,
    this.emptyHint,
  });

  final List<ContentItem> items;

  /// key 形如 `{subscriptionId}#{routeKey}`。
  final Map<String, SourceStatus> statuses;

  final DateTime? lastUpdated;

  /// 本次是否有任何数据来自「过期缓存」降级。
  final bool staleFallbackUsed;

  /// 全部源都失败时的统一错误（供空态展示）。
  final AppError? fatalError;

  /// 空结果的解释文案。
  final String? emptyHint;
}

/// 「全部关注」模式拉一页的结果（带下一页游标）。
///
/// ## 两个游标是**两回事**
///
/// - [nextOffset]：B 站 `feed/all` 的 `offset`（19 位数字串）；
/// - [nextMaxId]：微博 `/feed/friends` 的 `max_id`（大整数串，向**更早**翻）。
///
/// 它们各自独立、**绝不混用**：把微博游标塞进 B 站请求（或反过来）会让翻页
/// 跳到毫不相关的位置，症状是「第二页全是重复内容」。任何一个为 null 只代表
/// 「那一侧到底了」，不代表整页停住。
///
/// ⚠️ 微博侧**曾经**用 `since_id`，那是语义错误（详见
/// `WeiboApiClient.buildFriendsUrl`）：`since_id` 指向「更新的方向」，
/// 传回去只会得到 0 条 —— 真机表现是「翻页处忽然只剩 B 站内容」。
class TimelineFollowingResult {
  const TimelineFollowingResult({
    required this.items,
    required this.status,
    this.weiboStatus,
    this.nextOffset,
    this.nextMaxId,
    this.hasMore = false,
    this.lastUpdated,
    this.error,
    this.emptyHint,
  });

  final List<ContentItem> items;

  /// B 站那一半的运行态（key 为 `{bilibili:following}#bilibiliDynamic`）。
  final SourceStatus status;

  /// 微博那一半的运行态（key 为 `{weibo:friends}#weiboUser`）。
  ///
  /// 单独一份而不是塞进 [status]：两边可能一成功一失败，而 UI 需要按源
  /// 分别给出提示（微博未登录时只该提示微博，不该把整页判成失败）。
  final SourceStatus? weiboStatus;

  /// B 站下一页游标；null / 空表示 B 站侧没有下一页。
  final String? nextOffset;

  /// 微博下一页游标；null / 空表示微博侧没有下一页。
  final String? nextMaxId;

  /// 是否还有下一页（**任一侧能翻就为 true**）。
  final bool hasMore;

  final DateTime? lastUpdated;

  /// 整页级错误（只在 B 站侧失败时设置；微博失败不进这里）。
  final AppError? error;

  final String? emptyHint;

  /// 按源汇总的状态表，键的拼法与 [TimelineResult.statuses] 一致。
  Map<String, SourceStatus> get statuses {
    final Map<String, SourceStatus> out = <String, SourceStatus>{
      '${status.subscriptionId}#${status.route?.key ?? 'all'}': status,
    };
    final SourceStatus? w = weiboStatus;
    if (w != null) {
      out['${w.subscriptionId}#${w.route?.key ?? 'all'}'] = w;
    }
    return out;
  }

  /// 两侧都到底（或都没有游标）才算真的到底。
  bool get isEnd =>
      !hasMore ||
      ((nextOffset == null || nextOffset!.isEmpty) &&
          (nextMaxId == null || nextMaxId!.isEmpty));
}

/// 「全部关注」里 B 站那一半的中间结果。
class _BiliFollowingPart {
  const _BiliFollowingPart({
    required this.items,
    required this.status,
    this.nextOffset,
    this.isEnd = true,
    this.lastUpdated,
    this.error,
    this.emptyHint,
  });

  final List<ContentItem> items;
  final SourceStatus status;
  final String? nextOffset;
  final bool isEnd;
  final DateTime? lastUpdated;
  final AppError? error;
  final String? emptyHint;
}

/// 「全部关注」里微博那一半的中间结果。
class _WeiboFriendsPart {
  const _WeiboFriendsPart({
    required this.items,
    required this.status,
    this.nextMaxId,
    this.hasMore = false,
    this.fetchedAt,
    this.error,
    this.emptyHint,
  });

  final List<ContentItem> items;
  final SourceStatus status;
  final String? nextMaxId;
  final bool hasMore;
  final DateTime? fetchedAt;
  final AppError? error;
  final String? emptyHint;
}

class _FetchTask {
  const _FetchTask({
    required this.subscription,
    required this.route,
    this.cursor = SourceCursor.first,
  });

  final Subscription subscription;
  final FeedRoute route;

  /// 该源本次要拉的翻页位置（见 [SourceCursor]）。
  final SourceCursor cursor;

  /// 与 `TimelineResult.statuses` 一致的键。
  String get key => '${subscription.id}#${route.key}';
}

class _FetchOutcome {
  const _FetchOutcome({
    required this.task,
    required this.items,
    required this.status,
    this.error,
    this.emptyHint,
    this.nextCursor,
  });

  final _FetchTask task;
  final List<ContentItem> items;
  final SourceStatus status;
  final AppError? error;
  final String? emptyHint;

  /// 该源下一页的游标；null = 这个源已经到底（不再参与后续翻页）。
  final SourceCursor? nextCursor;
}

/// 时间线聚合仓库。
///
/// 职责：
/// 1. 把「订阅源 × 路由」展开成拉取任务，按并发上限执行；
/// 2. 每个任务独立失败/降级 —— 一个源挂了不能拖垮整条时间线；
/// 3. 合并、按发布时间倒序、标记新内容。
class TimelineRepository {
  TimelineRepository({
    required Prefs prefs,
    BiliTimelineSource? bili,
    WeiboTimelineSource? weibo,
  })  : _prefs = prefs,
        _bili = bili,
        _weibo = weibo;

  final Prefs _prefs;

  /// B 站官方接口内容源。
  ///
  /// **为 null 表示当前未登录** —— 此时 B 站订阅会给出「先去登录」的明确提示，
  /// 而不是悄悄回落到 RSSHub（那会让用户以为新架构生效了，其实没有）。
  final BiliTimelineSource? _bili;

  /// 微博官方接口内容源。
  ///
  /// 与 [_bili] 不同，它**不是**「登录了才有」：对象永远存在，cookie 由数据源
  /// 在 `fetch` 里现读现判（空 → auth 错误）。为 null 只可能是调用方（单测）
  /// 刻意没注入，那时给一条明确的可读错误，而不是静默返回空结果 —— 静默空会
  /// 让「注入漏了」这种接线 bug 表现成「这个博主没有微博」。
  final WeiboTimelineSource? _weibo;

  /// 把 B 站与微博的关注流合并成一条时间线。
  ///
  /// **纯函数**（不碰 IO、不读 Prefs），所以能离线单测 —— 去重与排序正是这条
  /// 需求最容易出错的两处，必须能被钉死。
  ///
  /// 三条规则：
  /// 1. **按 id 去重**：同一 id 只留第一条（`IdHash` 保证同一内容跨平台路径
  ///    得到同一个 id；而服务端分页偶尔把同一条动态放进相邻两页，不去重就会
  ///    出现两张一模一样的卡片）。
  /// 2. **按 [ContentItem.sortKey] 倒序**：`publishedAt ?? fetchedAt`，与逐源
  ///    聚合模式同一套排序口径，所以「全部关注」里 B 站与微博会真正交错。
  /// 3. **不截断**：截断是调用方的事（本函数只负责合并，便于单测断言长度）。
  ///
  /// 一边为空、两边都空都返回正常结果（不抛、不补占位）。
  static List<ContentItem> mergeFollowing(
    List<ContentItem> bili,
    List<ContentItem> weibo,
  ) {
    final Map<String, ContentItem> merged = <String, ContentItem>{};
    for (final ContentItem item in bili) {
      merged.putIfAbsent(item.id, () => item);
    }
    for (final ContentItem item in weibo) {
      merged.putIfAbsent(item.id, () => item);
    }
    final List<ContentItem> out = merged.values.toList()
      ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return out;
  }

  /// 把「已经展示的条目」与「新翻到的一页」合成一条**仍然严格倒序**的列表。
  ///
  /// ## 为什么不能直接 append（真机缺陷，2026-10-25）
  ///
  /// 两侧翻页的**时间跨度完全不对等**：
  /// - B 站 `feed/all` 一页 20 条可能只覆盖 **9 小时**（关注的人多、发得勤）；
  /// - 微博 `/feed/friends` 一页 20 条能覆盖 **近一个月**（只关注了几个人）。
  ///
  /// 于是第一页排完序后，末尾往往是一批「一个月前」的微博；第二页带回的却是
  /// 「9 小时前」的 B 站动态。直接 append 会让「一个月前」之后紧跟「9 小时前」，
  /// 用户看到的就是「**微博近一个月的内容夹在 B 站 9 小时前后动态的中间**」。
  ///
  /// 旧实现的注释写着「追加的页天然更旧，顺序仍然正确」—— 那句话只在
  /// 「两侧每页跨度一致」时成立，而现实中恰恰不一致。游标各自独立翻页
  /// 意味着**两页之间没有全局单调性**，只有合并重排才能保证时间顺序。
  ///
  /// ## 规则
  ///
  /// 1. 按 id 去重（先到先得，与 [mergeFollowing] 同一纪律）；
  /// 2. 合并后**整体重排**（[ContentItem.sortKey] 倒序）—— 已加载的条目永远
  ///    严格倒序，翻多少页都成立；
  /// 3. 时间戳相同的条目保持原有相对顺序（**稳定排序**），否则每次翻页
  ///    同秒发布的几条会互相换位，卡片看起来会「跳」。
  static List<ContentItem> mergeContinuing(
    List<ContentItem> loaded,
    List<ContentItem> next,
  ) {
    final List<ContentItem> out = <ContentItem>[];
    final Set<String> seen = <String>{};
    for (final ContentItem item in <ContentItem>[...loaded, ...next]) {
      if (seen.add(item.id)) out.add(item);
    }
    // Dart 的 `List.sort` **不保证稳定**：相同 sortKey 的相对顺序会被打乱。
    // 所以把原始下标当第二关键字，做成稳定的倒序。
    final List<int> order = List<int>.generate(out.length, (int i) => i);
    order.sort((int a, int b) {
      final int byTime = out[b].sortKey.compareTo(out[a].sortKey);
      return byTime != 0 ? byTime : a.compareTo(b);
    });
    return <ContentItem>[for (final int i in order) out[i]];
  }

  /// 「全部关注」模式拉一页的结果。
  ///
  /// 与 [TimelineResult] 分开是因为它的语义不同：那是「一次刷新合并所有源」，
  /// 这是「一页 + 下一页游标」，翻页靠游标而不是重新合并。
  ///
  /// ## 两侧独立
  ///
  /// - [offset] 是 **B 站** 的游标，[maxId] 是 **微博** 的游标，各自原样透传，
  ///   绝不互相顶替（形态完全不同，混用会跳到毫不相关的位置）。
  /// - **微博失败不拖垮 B 站**：微博抛错时 B 站内容照常返回，失败只记进
  ///   [TimelineFollowingResult.weiboStatus]。
  /// - 现有「B 站未登录」分支保持行为（整页只有那一条 auth 错误），但即便那时
  ///   微博侧仍会尝试拉取 —— 用户可能只登录了微博。
  Future<TimelineFollowingResult> loadFollowing({
    String? offset,
    String? maxId,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    // 两侧**并行**发起：串行会让首屏等待翻倍，而它们本来就互不依赖。
    // 微博侧的错误在这里被兜住（`_loadWeiboFriends` 自己 catch），所以
    // 「微博失败拖垮 B 站」在结构上就不可能发生。
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      _loadBiliFollowing(offset: offset, page: page, forceRefresh: forceRefresh),
      _loadWeiboFriends(maxId: maxId, forceRefresh: forceRefresh),
    ]);

    final _BiliFollowingPart biliPart = results[0]! as _BiliFollowingPart;
    final _WeiboFriendsPart? weiboPart = results[1] as _WeiboFriendsPart?;

    final List<ContentItem> merged = mergeFollowing(
      biliPart.items,
      weiboPart?.items ?? const <ContentItem>[],
    );

    final bool biliHasMore = !biliPart.isEnd;
    final bool weiboHasMore = weiboPart?.hasMore ?? false;

    // 空态文案：两侧的解释各占一句，用「；」连起来 —— 任一侧成功有内容时
    // 整块丢掉（调用方只在 merged.isEmpty 时才用）。
    final List<String> hints = <String>[];
    if (biliPart.emptyHint != null) hints.add(biliPart.emptyHint!);
    if (weiboPart?.emptyHint != null) hints.add(weiboPart!.emptyHint!);
    // 微博失败时给一行可读提示（不整页变红）：B 站内容仍在，微博那块缺了。
    if (weiboPart?.error != null) {
      hints.add('微博关注流暂时拉不到（${weiboPart!.error!.message}）');
    }
    final String? hint = hints.isEmpty ? null : hints.join('；');

    return TimelineFollowingResult(
      items: merged,
      status: biliPart.status,
      weiboStatus: weiboPart?.status,
      nextOffset: biliPart.nextOffset,
      nextMaxId: weiboPart?.nextMaxId,
      // **任一侧能翻就继续**：微博到底而 B 站还有时，仍要能往下翻。
      hasMore: biliHasMore || weiboHasMore,
      lastUpdated: biliPart.lastUpdated ?? weiboPart?.fetchedAt,
      error: biliPart.error,
      emptyHint: merged.isEmpty ? hint : null,
    );
  }

  /// B 站那一半：完全保持原有行为（含「未登录」分支与错误文案）。
  Future<_BiliFollowingPart> _loadBiliFollowing({
    String? offset,
    required int page,
    required bool forceRefresh,
  }) async {
    final source = _bili;
    if (source == null) {
      const err = AppError(
        AppErrorKind.auth,
        '「全部关注」需要先登录 B 站账号（设置 → B 站账号 → 扫码登录）',
        retryable: false,
      );
      return _BiliFollowingPart(
        items: const <ContentItem>[],
        status: const SourceStatus(
          subscriptionId: BiliTimelineSource.followingSourceId,
          error: '需要先登录 B 站账号',
        ),
        error: err,
        emptyHint: err.message,
      );
    }

    try {
      final res = await source.fetchFollowing(
        offset: offset,
        page: page,
        forceRefresh: forceRefresh,
      );

      // 新内容标记与逐源模式同一套规则：源还没有已读记录时不标，
      // 否则用户第一次用「全部关注」会看到满屏「新」。
      final sourceId = BiliTimelineSource.followingSourceId;
      final seen = _prefs.seenIds(sourceId);
      final marked = <ContentItem>[];
      for (final item in res.items) {
        marked.add(
          seen.isNotEmpty && !seen.contains(item.id)
              ? item.copyWith(isNew: true)
              : item,
        );
      }

      return _BiliFollowingPart(
        items: marked,
        status: SourceStatus(
          subscriptionId: sourceId,
          route: FeedRoute.bilibiliDynamic,
          lastSuccessAt: res.fetchedAt,
          fromCache: res.fromCache,
          cachedAgeLabel: res.fromCache ? _ageLabel(res.fetchedAt) : null,
          itemCount: marked.length,
        ),
        nextOffset: res.nextOffset,
        isEnd: res.isEnd,
        lastUpdated: res.fetchedAt,
        emptyHint: marked.isEmpty ? '关注的 UP 主最近没有新动态' : null,
      );
    } on AppError catch (e) {
      return _BiliFollowingPart(
        items: const <ContentItem>[],
        status: SourceStatus(
          subscriptionId: BiliTimelineSource.followingSourceId,
          route: FeedRoute.bilibiliDynamic,
          error: e.message,
          errorKind: e.kind,
        ),
        error: e,
      );
    }
  }

  /// 微博那一半（`/feed/friends`）。
  ///
  /// **绝不抛**：任何失败都转成 [TimelineFollowingResult.weiboStatus] 里的一条
  /// 可读状态并返回 null 内容 —— 这是「微博失败不拖垮 B 站」的落点。
  /// 未注入数据源（单测漏接线）时同样只报微博这一侧，不影响 B 站。
  Future<_WeiboFriendsPart?> _loadWeiboFriends({
    String? maxId,
    required bool forceRefresh,
  }) async {
    final source = _weibo;
    if (source == null) {
      return _WeiboFriendsPart(
        items: const <ContentItem>[],
        status: const SourceStatus(
          subscriptionId: WeiboTimelineSource.friendsSourceId,
          route: FeedRoute.weiboUser,
          error: '微博数据源未配置（内部接线缺失）',
          errorKind: AppErrorKind.unknown,
        ),
        error: const AppError(
          AppErrorKind.unknown,
          '微博数据源未配置（内部接线缺失）',
          retryable: false,
        ),
      );
    }

    try {
      final WeiboFriendsFeedPage res = await source.fetchFriendsFeed(
        maxId: maxId,
        forceRefresh: forceRefresh,
      );

      // 新内容标记：与 B 站侧同一条纪律 —— 没有已读记录时不标。
      final String sourceId = WeiboTimelineSource.friendsSourceId;
      final Set<String> seen = _prefs.seenIds(sourceId);
      final List<ContentItem> marked = <ContentItem>[];
      for (final ContentItem item in res.items) {
        marked.add(
          seen.isNotEmpty && !seen.contains(item.id)
              ? item.copyWith(isNew: true)
              : item,
        );
      }

      return _WeiboFriendsPart(
        items: marked,
        status: SourceStatus(
          subscriptionId: sourceId,
          route: FeedRoute.weiboUser,
          lastSuccessAt: res.fetchedAt,
          fromCache: res.fromCache,
          cachedAgeLabel: res.fromCache ? _ageLabel(res.fetchedAt) : null,
          itemCount: marked.length,
        ),
        nextMaxId: res.nextMaxId,
        hasMore: !res.isEnd,
        fetchedAt: res.fetchedAt,
        emptyHint: marked.isEmpty ? '关注的人最近没有新微博' : null,
      );
    } on AppError catch (e) {
      return _WeiboFriendsPart(
        items: const <ContentItem>[],
        status: SourceStatus(
          subscriptionId: WeiboTimelineSource.friendsSourceId,
          route: FeedRoute.weiboUser,
          error: e.message,
          errorKind: e.kind,
        ),
        error: e,
      );
    } catch (e) {
      // 非 AppError（适配器裸异常等）：同样只影响微博这一侧。
      Log.w('Timeline', '微博关注流拉取失败（只影响微博侧）：$e');
      return _WeiboFriendsPart(
        items: const <ContentItem>[],
        status: const SourceStatus(
          subscriptionId: WeiboTimelineSource.friendsSourceId,
          route: FeedRoute.weiboUser,
          error: '微博关注流拉取失败',
          errorKind: AppErrorKind.unknown,
        ),
        error: const AppError(
          AppErrorKind.unknown,
          '微博关注流拉取失败',
          retryable: true,
        ),
      );
    }
  }

  /// 拉取「精选订阅」的一屏内容。
  ///
  /// [cursors] 是**每个源**的翻页位置（键 `{subscriptionId}#{routeKey}`）。
  /// 不传 = 全部从第一页开始（首屏 / 下拉刷新）。
  ///
  /// 返回值里的 [SelectedPage.nextCursors] 是该批源的下一页游标，
  /// provider 拿着它就能在滚到底时继续往后翻。
  Future<SelectedPage> loadPage({
    required List<Subscription> subscriptions,
    bool forceRefresh = false,
    Map<String, SourceCursor> cursors = const <String, SourceCursor>{},
  }) async {
    final result = await _loadInternal(
      subscriptions: subscriptions,
      forceRefresh: forceRefresh,
      cursors: cursors,
      // 翻页时**不要**再按「最多 200 条」整体截断：那是首屏的保护，
      // 翻页本来就是在追加更早的内容，截断会让用户永远到不了更早的条目。
      applyLimit: cursors.isEmpty,
    );
    return SelectedPage(
      items: result.items,
      statuses: result.statuses,
      nextCursors: result.nextCursors,
      hasMore: result.nextCursors.isNotEmpty,
      lastUpdated: result.lastUpdated,
      staleFallbackUsed: result.staleFallbackUsed,
      fatalError: result.fatalError,
      emptyHint: result.emptyHint,
    );
  }

  Future<TimelineResult> load({
    required List<Subscription> subscriptions,
    bool forceRefresh = false,
  }) async {
    return _loadInternal(
      subscriptions: subscriptions,
      forceRefresh: forceRefresh,
      cursors: const <String, SourceCursor>{},
      applyLimit: true,
    );
  }

  Future<_LoadResult> _loadInternal({
    required List<Subscription> subscriptions,
    required bool forceRefresh,
    required Map<String, SourceCursor> cursors,
    required bool applyLimit,
  }) async {
    final tasks = <_FetchTask>[];
    for (final sub in subscriptions) {
      for (final route in sub.activeRoutes) {
        final key = '${sub.id}#${route.key}';
        tasks.add(
          _FetchTask(
            subscription: sub,
            route: route,
            cursor: cursors[key] ?? SourceCursor.first,
          ),
        );
      }
    }

    // 翻页时**只请求还有下一页的源**：到底的源不再发请求。
    // 首屏（cursors 为空）不经过这层过滤。
    final activeTasks = cursors.isEmpty
        ? tasks
        : tasks.where((t) => cursors.containsKey(t.key)).toList();

    if (activeTasks.isEmpty) {
      return const _LoadResult(
        items: <ContentItem>[],
        statuses: <String, SourceStatus>{},
        nextCursors: <String, SourceCursor>{},
        emptyHint: '还没有订阅源。去「订阅」页添加 B 站 UID 或微博 UID。',
      );
    }

    final outcomes = await mapLimit<_FetchTask, _FetchOutcome>(
      activeTasks,
      AppConfig.maxConcurrentFetches,
      (t) => _fetchOne(t, forceRefresh: forceRefresh),
    );

    final merged = <String, ContentItem>{};
    final statuses = <String, SourceStatus>{};
    final nextCursors = <String, SourceCursor>{};
    var staleUsed = false;
    DateTime? lastUpdated;
    String? hint;
    final errors = <AppError>[];

    for (final o in outcomes) {
      for (final item in o.items) {
        merged.putIfAbsent(item.id, () => item);
      }
      statuses['${o.task.subscription.id}#${o.task.route.key}'] = o.status;
      // 只有**成功且还有下一页**的源才进入下一轮翻页。
      // 失败时不给游标：否则会在错误的游标上反复重试同一个坏页。
      final next = o.nextCursor;
      if (next != null && o.error == null) {
        nextCursors[o.task.key] = next;
      }
      if (o.status.fromCache) staleUsed = true;
      if (o.status.lastSuccessAt != null) {
        final prev = lastUpdated;
        if (prev == null || o.status.lastSuccessAt!.isAfter(prev)) {
          lastUpdated = o.status.lastSuccessAt;
        }
      }
      if (o.error != null) errors.add(o.error!);
      if (hint == null && o.emptyHint != null) hint = o.emptyHint;
    }

    // 排序 + 截断
    final sorted = merged.values.toList()
      ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
    final limited = applyLimit && sorted.length > AppConfig.timelineMaxItems
        ? sorted.sublist(0, AppConfig.timelineMaxItems)
        : sorted;

    // 标记新内容：源没有已读记录时不标（首次订阅不该满屏「新」）。
    final seenCache = <String, Set<String>>{};
    final marked = <ContentItem>[];
    for (final item in limited) {
      final seen = seenCache.putIfAbsent(item.sourceId, () => _prefs.seenIds(item.sourceId));
      final isNew = seen.isNotEmpty && !seen.contains(item.id);
      marked.add(isNew ? item.copyWith(isNew: true) : item);
    }

    AppError? fatal;
    if (marked.isEmpty && errors.isNotEmpty && errors.length == outcomes.length) {
      fatal = errors.first;
    }

    return _LoadResult(
      items: marked,
      statuses: statuses,
      nextCursors: nextCursors,
      lastUpdated: lastUpdated,
      staleFallbackUsed: staleUsed,
      fatalError: fatal,
      emptyHint: hint ?? (marked.isEmpty ? '这些源最近没有新内容' : null),
    );
  }

  /// 把当前时间线上的条目全部记为已读（用户进入时间线后调用）。
  Future<void> markAllSeen(List<ContentItem> items) async {
    if (items.isEmpty) return;
    final bySource = <String, Set<String>>{};
    for (final item in items) {
      bySource.putIfAbsent(item.sourceId, () => Set<String>.from(_prefs.seenIds(item.sourceId)))
          .add(item.id);
    }
    for (final entry in bySource.entries) {
      await _prefs.setSeenIds(entry.key, entry.value);
    }
    await _prefs.setLastTimelineViewAt(DateTime.now().toUtc());
  }

  Future<void> clearSeen() => _prefs.clearSeenIds();

  // ------------------------------------------------------------ 内部

  /// 按平台分派到对应的官方数据源。
  ///
  /// 【2026-10-22 移除 RSSHub】这里曾经还有第三条分支：落到 RSSHub 拼
  /// `/bilibili/user/video/:uid` 之类的路由去拉 XML。但 `Platform` 只有
  /// `bilibili` / `weibo` 两个值，而两者都在上面被 return 掉了 —— 那条分支
  /// **从新架构落地那天起就不可达**，属于死代码（加上公共实例已全部不可用）。
  ///
  /// 现在这里是穷尽的 `switch`：将来新增平台时编译器会直接报错，
  /// 不会再出现「悄悄掉进某条谁也不认识的兜底路径」这种情况。
  Future<_FetchOutcome> _fetchOne(_FetchTask task, {required bool forceRefresh}) {
    switch (task.route.platform) {
      case Platform.bilibili:
        return _fetchBili(task, forceRefresh: forceRefresh);
      case Platform.weibo:
        // 微博走官方接口（`m.weibo.cn`），但**必须**带 m 站登录 cookie ——
        // 游客态恒 432。cookie 由 `WeiboTimelineSource` 自己现读，未登录时
        // 抛 auth 错误，由这里转成一条可读的源状态。
        return _fetchWeibo(task, forceRefresh: forceRefresh);
    }
  }

  /// B 站订阅源：走官方接口（带登录态）。
  Future<_FetchOutcome> _fetchBili(
    _FetchTask task, {
    required bool forceRefresh,
  }) async {
    final source = _bili;
    if (source == null) {
      const err = AppError(
        AppErrorKind.auth,
        'B 站订阅需要先登录账号（设置 → B 站账号 → 扫码登录）',
        retryable: false,
      );
      return _FetchOutcome(
        task: task,
        items: const <ContentItem>[],
        status: SourceStatus(
          subscriptionId: task.subscription.id,
          route: task.route,
          error: err.message,
        ),
        error: err,
      );
    }

    try {
      final res = await source.fetch(
        sub: task.subscription,
        route: task.route,
        forceRefresh: forceRefresh,
        page: task.cursor.page,
        offset: task.cursor.offset,
      );
      // 下一页游标：投稿看 nextPage，动态看 nextOffset。
      // 两者都为 null 说明这个源到底了，后续翻页不再请求它。
      final SourceCursor? next = _nextCursor(task.cursor, res);
      return _FetchOutcome(
        task: task,
        items: res.items,
        status: SourceStatus(
          subscriptionId: task.subscription.id,
          route: task.route,
          lastSuccessAt: res.fetchedAt,
          fromCache: res.fromCache,
          cachedAgeLabel: res.fromCache ? _ageLabel(res.fetchedAt) : null,
          itemCount: res.items.length,
        ),
        emptyHint: res.emptyHint,
        nextCursor: next,
      );
    } on AppError catch (e) {
      return _FetchOutcome(
        task: task,
        items: const <ContentItem>[],
        status: SourceStatus(
          subscriptionId: task.subscription.id,
          route: task.route,
          error: e.message,
        ),
        error: e,
      );
    }
  }

  /// 由本次拉取结果推出该源的**下一页**游标。
  ///
  /// - 投稿路由：`nextPage` 非空 → 页码 +1（服务端不直接给页码）；
  /// - 动态路由：`nextOffset` 非空 → 用服务端给的 offset；
  /// - 都没有 → null（到底）。
  ///
  /// ⚠️ 这里**不能**用「本页条数 < 每页上限」来判定到底：
  /// B 站动态接口会过滤掉部分条目（审核中/仅粉丝可见），一页 10 条
  /// 也可能还有下一页。只认服务端明确给的 offset。
  static SourceCursor? _nextCursor(SourceCursor cur, BiliFetchResult res) {
    if (res.nextOffset != null) {
      return cur.copyWith(offset: res.nextOffset);
    }
    if (res.nextPage != null) {
      return cur.copyWith(page: res.nextPage);
    }
    return null;
  }

  /// 微博订阅源：走官方接口（`m.weibo.cn/api/container/getIndex`）。
  ///
  /// 与 [_fetchBili] 结构一致（成功 / `on AppError` 两个出口），差异只有一处：
  /// 微博**没有**「未注入 = 未登录」的语义，[WeiboTimelineSource] 自己判登录。
  /// 所以 `_weibo == null` 只可能是接线漏了 —— 那种情况必须报错而不是返回空，
  /// 否则会表现为「这个博主没有微博」而不是「代码没接线」。
  Future<_FetchOutcome> _fetchWeibo(
    _FetchTask task, {
    required bool forceRefresh,
  }) async {
    final source = _weibo;
    if (source == null) {
      const err = AppError(
        AppErrorKind.unknown,
        '微博数据源未配置（内部接线缺失），请重新打开 App',
        retryable: false,
      );
      return _FetchOutcome(
        task: task,
        items: const <ContentItem>[],
        status: SourceStatus(
          subscriptionId: task.subscription.id,
          route: task.route,
          error: err.message,
          errorKind: err.kind,
        ),
        error: err,
      );
    }

    try {
      final res = await source.fetch(
        sub: task.subscription,
        route: task.route,
        forceRefresh: forceRefresh,
        // 翻页游标：首屏为 null。**这一行曾经缺失**，导致微博源永远只拉
        // 第一页 —— 用户看到的「warma 的动态只有近 10 天」就是这个原因
        // （一页 20 条，慢更博主 20 条能横跨十几天）。
        sinceId: task.cursor.sinceId,
      );
      // 昵称回填：拉取结果里自带博主 `screen_name`（见 `WeiboParser`），
      // **零额外请求**。失败绝不影响内容展示 —— `_backfillWeiboAlias` 自己吞异常。
      await _backfillWeiboAlias(task.subscription, res.authorName);

      // 下一页游标。三条纪律，缺一条都会让翻页链断掉或空转：
      //
      // 1. **空串一律当没有**：服务端在到底时会回 `since_id: ""`，
      //    把它当合法游标会在同一位置无限重试（表现为「滚到底一直转圈」）；
      // 2. **本页 0 条 → 不给游标**：0 条意味着这个方向已经没有内容了，
      //    再拿同一份游标去问只会拿回同样的 0 条。这是防止
      //    `getIndex` 的 `since_id` 方向万一与预期相反时的**保险丝** ——
      //    即使方向反了，也只会翻一页就停，不会把整条时间线拖进死循环；
      // 3. 游标原样透传（19 位大整数过数值类型会丢精度）。
      final String nextId = (res.nextSinceId ?? '').trim();
      final bool canPage = nextId.isNotEmpty && res.items.isNotEmpty;
      return _FetchOutcome(
        task: task,
        items: res.items,
        status: SourceStatus(
          subscriptionId: task.subscription.id,
          route: task.route,
          lastSuccessAt: res.fetchedAt,
          fromCache: res.fromCache,
          cachedAgeLabel: res.fromCache ? _ageLabel(res.fetchedAt) : null,
          itemCount: res.items.length,
        ),
        emptyHint: res.emptyHint,
        nextCursor:
            canPage ? task.cursor.copyWith(sinceId: nextId) : null,
      );
    } on AppError catch (e) {
      return _FetchOutcome(
        task: task,
        items: const <ContentItem>[],
        status: SourceStatus(
          subscriptionId: task.subscription.id,
          route: task.route,
          error: e.message,
          errorKind: e.kind,
        ),
        error: e,
        // 失败时也给出引导：占位卡会把用户送到内置浏览器，那里能看到真实内容。
        emptyHint: e.kind == AppErrorKind.auth
            ? WeiboCopy.statusPanelReason
            : null,
      );
    }
  }

  /// 把拉取到的博主昵称写进该订阅的别名（**仅当别名还是空的**）。
  ///
  /// 三条硬约束，缺一条都会比「显示 UID」更糟：
  ///
  /// 1. **不覆盖用户已设的别名** —— 用户手动起的名字永远优先。这里读的是
  ///    `Prefs` 里的**当前**值（不是本次拉取开始时的那份快照），避免覆盖掉
  ///    拉取期间用户刚改的名字。
  /// 2. **绝不新增请求**：昵称来自刚拿到的那一页内容（`mblog.user.screen_name`）。
  /// 关注列表接口第 1 页只给 9 个关注且无总数，不适合回填。
  /// 3. **失败只记日志**：写 Prefs 失败、订阅在拉取期间被删掉、昵称为空 ——
  ///    任一种都只是「别名没回填」，绝不能让整次刷新失败或吞掉内容。
  ///
  /// 日志不含凭据（只有订阅 id 与昵称长度之外的公开信息）。
  Future<void> _backfillWeiboAlias(
    Subscription sub,
    String? authorName,
  ) async {
    try {
      final String name = (authorName ?? '').trim();
      if (name.isEmpty) return;

      final List<Subscription> list = _prefs.subscriptions;
      final int index = list.indexWhere((s) => s.id == sub.id);
      // 拉取期间被删了：没有可写的目标，静默结束（不是错误）。
      if (index < 0) return;

      final Subscription current = list[index];
      // 已有别名 → 用户手动设的，绝不覆盖。
      final String? existing = current.alias?.trim();
      if (existing != null && existing.isNotEmpty) return;

      list[index] = current.copyWith(alias: name);
      await _prefs.setSubscriptions(list);
      Log.d('Timeline', '已回填微博昵称（${sub.id}）');
    } catch (e) {
      // 只记一条不含凭据的日志：回填失败不该影响内容展示。
      Log.w('Timeline', '回填微博昵称失败（忽略）：$e');
    }
  }

  static String _ageLabel(DateTime fetchedAt) {
    final diff = DateTime.now().toUtc().difference(fetchedAt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }
}

/// [_loadInternal] 的内部结果：比 [TimelineResult] 多带一份「下一页游标」。
class _LoadResult extends TimelineResult {
  const _LoadResult({
    required super.items,
    required super.statuses,
    required this.nextCursors,
    super.lastUpdated,
    super.staleFallbackUsed,
    super.fatalError,
    super.emptyHint,
  });

  /// 每个源下一页的游标；空 Map = 所有源都到底了。
  final Map<String, SourceCursor> nextCursors;
}
