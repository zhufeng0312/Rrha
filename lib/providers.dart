import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/cache/cache_store.dart';
import 'core/cache/image_cache_store.dart';
import 'core/net/app_error.dart';
import 'core/net/dio_provider.dart';
import 'core/net/weibo_cookie_source.dart';
import 'core/storage/bili_credential_store.dart';
import 'core/storage/prefs.dart';
import 'core/storage/secure_store.dart';
import 'core/utils/logger.dart';
import 'data/bili/bili_client.dart';
import 'data/bili/bili_login.dart';
import 'data/bili/bili_timeline_source.dart';
import 'data/models/content_item.dart';
import 'data/models/danmaku_item.dart';
import 'data/models/subscription.dart';
import 'data/models/timeline_mode.dart';
import 'data/repo/comment_repo.dart';
import 'data/repo/subscription_repo.dart';
import 'data/repo/timeline_floor.dart';
import 'data/repo/timeline_repo.dart';
import 'data/repo/video_repo.dart';
import 'data/weibo/weibo_api_client.dart';
import 'data/weibo/weibo_comment_pic_resolver.dart';
import 'data/weibo/weibo_comment_repository.dart';
import 'data/weibo/weibo_timeline_source.dart';
import 'features/settings/bili_login_controller.dart';

// ---------------------------------------------------------------- 基础设施

/// 由 `main()` 在 ProviderScope 里用真实实例 override。
final prefsProvider = Provider<Prefs>((ref) {
  throw UnimplementedError('prefsProvider 必须在 ProviderScope 中 override');
});

/// 钥匙串（凭据的唯一落点）。
final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

/// 账号凭据的存取封装。**所有账号凭据都必须经它**，见其类注释。
final biliCredentialStoreProvider = Provider<BiliCredentialStore>(
  (ref) => BiliCredentialStore(secure: ref.watch(secureStoreProvider)),
);

/// 文件缓存。目录在首次读写时惰性创建，不占用冷启动时间。
final cacheStoreProvider = Provider<CacheStore>((ref) => CacheStore());

/// 图片的磁盘缓存。
///
/// 由 `main()` 在启动时创建、并在首帧前 `ensureReady()` 读索引，
/// 这里只是把它交给设置页（统计/清除）与预览页（保存前先查本地）——
/// **刻意不做默认实现**：调试热重载或单测里若忘了 override，
/// 会造出一个「索引没加载」的空缓存，表现为「图片全部走网络、缓存永远不命中」
/// 这种极难归因的现象，不如直接抛错。
final imageCacheStoreProvider = Provider<ImageCacheStore>(
  (ref) => throw UnimplementedError(
    'imageCacheStoreProvider 必须在 ProviderScope 中 override（见 main.dart）',
  ),
);

final biliDioProvider = Provider<Dio>((ref) {
  final dio = DioFactory.createBiliDio();
  ref.onDispose(dio.close);
  return dio;
});

// ---------------------------------------------------------------- 客户端

/// 扫码登录客户端。复用 B 站 Dio（同样的 UA / Referer，否则 passport 接口更易被风控）。
final biliLoginClientProvider = Provider<BiliLoginClient>(
  (ref) => BiliLoginClient(dio: ref.watch(biliDioProvider)),
);

/// 扫码登录状态机。凭据的读写全部委托给 [BiliCredentialStore]（系统钥匙串）。
final biliLoginProvider =
    StateNotifierProvider<BiliLoginController, LoginState>(
  (ref) => BiliLoginController(
    client: ref.watch(biliLoginClientProvider),
    store: ref.watch(biliCredentialStoreProvider),
  ),
);

final biliClientProvider = Provider<BiliClient>((ref) {
  // 只关心这两个输入：其它设置变化不该重建客户端（会丢掉 WBI 密钥缓存）。
  final fingerprint =
      ref.watch(settingsProvider.select((s) => s.useAnonymousFingerprint));

  // 登录态变化 → 重新注入 Cookie。重建会丢一次 WBI 密钥缓存，
  // 但登录/登出是低频事件，重取一次密钥可以接受。
  final cookie =
      ref.watch(biliLoginProvider.select((s) => s.session?.cookieHeader));

  final client = BiliClient(
    dio: ref.watch(biliDioProvider),
    useAnonymousFingerprint: fingerprint,
  );
  client.setAccountCookie(cookie);
  return client;
});

// ---------------------------------------------------------------- 仓库

final subscriptionRepoProvider = Provider<SubscriptionRepository>(
  (ref) => SubscriptionRepository(prefs: ref.watch(prefsProvider)),
);

/// B 站官方接口的内容源。
///
/// **刻意不依赖登录态**：登录与否由 `BiliTimelineSource.fetch` 自己判断并抛出
/// 可读错误。让「登录态」去决定这个对象存不存在的话，登录动作会连带把
/// `timelineRepoProvider` 甚至时间线 notifier 一起重建，已加载的内容会被清空。
final biliTimelineSourceProvider = Provider<BiliTimelineSource>(
  (ref) => BiliTimelineSource(
    client: ref.watch(biliClientProvider),
    cache: ref.watch(cacheStoreProvider),
  ),
);

/// 微博登录 cookie 的**全局**读取通道（`rrha/weibo_cookie`）。
///
/// 刻意不依赖任何 WebView 页面：数据层要在后台刷新时间线，那时微博页面
/// 通常已销毁，per-view 通道早就读不到了。
///
/// 安全性：`read()` 返回值是用户凭据，只允许塞进请求头 —— 不要 log、不要
/// 落盘、不要展示。这个 provider 本身也不持有任何值（每层都是转发调用）。
final weiboCookieSourceProvider = Provider<WeiboCookieSource>(
  (ref) => WeiboCookieSource(),
);

/// 微博官方接口客户端。
///
/// 与 B 站客户端不同，它**没有任何可注入的登录态**：cookie 是每次请求
/// 现读（见 [WeiboTimelineSource.fetch]），所以这个对象可以长期复用、
/// 不需要因登录动作而重建。内部是裸 Dio，刻意不挂重试拦截器。
final weiboApiClientProvider = Provider<WeiboApiClient>(
  (ref) => WeiboApiClient(),
);

/// 微博官方接口的内容源。
///
/// **刻意不依赖登录态**（与 [biliTimelineSourceProvider] 同一个理由，也是
/// B 站踩过的坑）：登录与否由 `WeiboTimelineSource.fetch` 自己判断并抛出
/// 可读的 auth 错误。让「是否登录」去决定这个对象存不存在的话，登录动作
/// 会连带把 `timelineRepoProvider` 甚至时间线 notifier 一起重建，已加载的
/// 内容会被清空 —— 表现为「登录之后时间线反而变空了」。
final weiboTimelineSourceProvider = Provider<WeiboTimelineSource>(
  (ref) => WeiboTimelineSource(
    client: ref.watch(weiboApiClientProvider),
    cache: ref.watch(cacheStoreProvider),
    cookies: ref.watch(weiboCookieSourceProvider),
  ),
);

final timelineRepoProvider = Provider<TimelineRepository>(
  (ref) => TimelineRepository(
    prefs: ref.watch(prefsProvider),
    bili: ref.watch(biliTimelineSourceProvider),
    weibo: ref.watch(weiboTimelineSourceProvider),
  ),
);

final videoRepoProvider = Provider<VideoRepository>(
  (ref) => VideoRepository(client: ref.watch(biliClientProvider)),
);

final commentRepoProvider = Provider<CommentRepository>(
  (ref) => CommentRepository(client: ref.watch(biliClientProvider)),
);

/// 微博评论仓库（`m.weibo.cn/comments/hotflow`）。
///
/// 与 [weiboApiClientProvider] 同一条纪律：
/// - 内部是**裸 Dio**，不挂重试拦截器（微博对密集请求会冷却，重试交给用户）；
/// - 不持有任何登录态，cookie 每次请求现读 —— 而且**即便 cookie 为空也要能
///   工作**：hotflow 实测不要求登录（见 `.env/weibo_comment_probe.md` 第五节）。
final weiboCommentRepoProvider = Provider<WeiboCommentRepository>(
  (ref) => WeiboCommentRepository(
    cookies: ref.watch(weiboCookieSourceProvider),
  ),
);

/// 微博评论**多图**短链解析器（`mix_media_ids` → 图片直链）。
///
/// ⚠️ 懒执行：只在用户点「共 N 张 · 点此加载全部」时调用，
/// **绝不进列表构建路径**（滚一屏几十个请求必然触发风控）。
/// 失败不重试；实例内按评论 id 缓存，同一条只解析一次。
final weiboCommentPicResolverProvider = Provider<WeiboCommentPicResolver>(
  (ref) => WeiboCommentPicResolver(
    cookies: ref.watch(weiboCookieSourceProvider),
  ),
);

// ---------------------------------------------------------------- 设置状态

/// 设置状态。
///
/// 【2026-10-22】这里曾有 `baseUrl` / `weiboBaseUrl` 两个字段，用于填 RSSHub
/// 实例地址。RSSHub 整条链路已移除（见 `timeline_repo.dart` 的 `_fetchOne`
/// 注释），两个字段随之删掉 —— 留着它们只会在设置页摆出两个「改了也没用」
/// 的输入框。
class SettingsState {
  const SettingsState({
    required this.danmaku,
    required this.useAnonymousFingerprint,
    this.forceChannelB = false,
  });

  factory SettingsState.fromPrefs(Prefs p) => SettingsState(
        danmaku: p.danmakuSettings,
        useAnonymousFingerprint: p.useAnonymousFingerprint,
        forceChannelB: p.forceChannelB,
      );

  final DanmakuSettings danmaku;
  final bool useAnonymousFingerprint;

  /// 强制用通道 B（libmpv + DASH）播放，跳过通道 A —— 仅用于排查问题。
  final bool forceChannelB;

  SettingsState copyWith({
    DanmakuSettings? danmaku,
    bool? useAnonymousFingerprint,
    bool? forceChannelB,
  }) =>
      SettingsState(
        danmaku: danmaku ?? this.danmaku,
        useAnonymousFingerprint:
            useAnonymousFingerprint ?? this.useAnonymousFingerprint,
        forceChannelB: forceChannelB ?? this.forceChannelB,
      );
}

/// 构造顺序技巧：`StateNotifier` 的 `super(...)` 里不能引用 `this._prefs`，
/// 因此先用参数算出初始 state 再交给私有构造。
class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier(Prefs prefs) : this._(prefs, SettingsState.fromPrefs(prefs));

  SettingsNotifier._(this._prefs, SettingsState initial) : super(initial);

  final Prefs _prefs;

  Future<void> setDanmaku(DanmakuSettings value) async {
    await _prefs.setDanmakuSettings(value);
    state = SettingsState.fromPrefs(_prefs);
  }

  Future<void> setUseAnonymousFingerprint(bool value) async {
    await _prefs.setUseAnonymousFingerprint(value);
    state = SettingsState.fromPrefs(_prefs);
  }

  Future<void> setForceChannelB(bool value) async {
    await _prefs.setForceChannelB(value);
    state = SettingsState.fromPrefs(_prefs);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>(
  (ref) => SettingsNotifier(ref.watch(prefsProvider)),
);

// ---------------------------------------------------------------- 界面导航

/// 底部导航当前页。放在 provider 里是为了让空态里的
/// 「去添加订阅」按钮能直接切换标签页。
final homeTabProvider = StateProvider<int>((ref) => 0);

/// 「回到时间线顶部」的信号（每点一次底部「时间线」标签自增一次）。
///
/// ## 为什么用计数器而不是 bool
///
/// 用 `StateProvider<bool>` 的话，连续点两次标签不会产生「又变了一次」的事件
/// （true → true 没有状态变化，监听器不会触发）。计数器每次 +1，保证**每一次
/// 点击都能被消费**，这正是「点一下回顶部」的语义。
///
/// `HomeShell` 在用户点「时间线」标签时自增；`TimelinePage` 监听并滚回顶部。
/// 用 provider 而不是回调/GlobalKey：三个页面都在 `IndexedStack` 里常驻，
/// 直接持有对方的 State 会让耦合变重，且页面被重建时引用失效。
final timelineScrollToTopProvider = StateProvider<int>((ref) => 0);

// ---------------------------------------------------------------- 订阅源列表

class SubscriptionsNotifier extends StateNotifier<List<Subscription>> {
  SubscriptionsNotifier(Prefs prefs)
      : _prefs = prefs,
        _repo = SubscriptionRepository(prefs: prefs),
        super(prefs.subscriptions);

  final Prefs _prefs;
  final SubscriptionRepository _repo;

  void reload() {
    state = _prefs.subscriptions;
  }

  Future<AddSubscriptionResult> add({
    required Platform platform,
    required String uid,
    Set<FeedRoute>? routes,
    String? alias,
  }) async {
    final result = await _repo.add(
      platform: platform,
      uidInput: uid,
      routes: routes,
      alias: alias,
    );
    if (result.ok) reload();
    return result;
  }

  Future<void> remove(String id) async {
    await _repo.remove(id);
    reload();
  }

  Future<void> updateAlias(String id, String? alias) async {
    await _repo.updateAlias(id, alias);
    reload();
  }

  Future<void> toggleRoute(String id, FeedRoute route, bool enabled) async {
    await _repo.toggleRoute(id, route, enabled);
    reload();
  }
}

final subscriptionsProvider =
    StateNotifierProvider<SubscriptionsNotifier, List<Subscription>>(
  (ref) => SubscriptionsNotifier(ref.watch(prefsProvider)),
);

// ---------------------------------------------------------------- 时间线

class TimelineState {
  const TimelineState({
    this.loading = false,
    this.refreshing = false,
    this.loadingMore = false,
    this.initialized = false,
    this.mode = TimelineMode.allFollowing,
    this.items = const <ContentItem>[],
    this.statuses = const <String, SourceStatus>{},
    this.subscriptions = const <Subscription>[],
    this.error,
    this.emptyHint,
    this.lastUpdated,
    this.staleFallbackUsed = false,
    this.followingOffset,
    this.followingMaxId,
    this.followingPage = 1,
    this.followingHasMore = false,
    this.displayFloor,
    this.bufferedCount = 0,
    this.biliEnded = false,
    this.weiboEnded = false,
    this.followingPool,
  });

  final bool loading;
  final bool refreshing;

  /// 「全部关注」模式下正在拉下一页。
  final bool loadingMore;

  final bool initialized;

  /// 当前取数模式（默认「全部关注」，见 [TimelineMode]）。
  final TimelineMode mode;

  final List<ContentItem> items;
  final Map<String, SourceStatus> statuses;
  final List<Subscription> subscriptions;
  final AppError? error;
  final String? emptyHint;
  final DateTime? lastUpdated;
  final bool staleFallbackUsed;

  /// 「全部关注」模式的下一页游标。
  ///
  /// ⚠️ 这是 **B 站** `feed/all` 的 `offset`（19 位数字串），与
  /// [followingMaxId] 是两套独立游标，**绝不混用**（混用会跳到毫不相关的
  /// 位置，症状是第二页全是重复内容）。
  final String? followingOffset;

  /// 「全部关注」模式的**微博**下一页游标（`/feed/friends` 的 `max_id`）。
  ///
  /// 与 [followingOffset] 独立维护：两边形态不同、互不接管；任何一侧为 null
  /// 只代表那一侧到底了。
  ///
  /// ⚠️ 曾经叫 `since_id`，那是语义错误：`since_id` 指向「更新的方向」，
  /// 传回去只会拿到 0 条，真机表现为「翻页处只剩 B 站内容」。
  final String? followingMaxId;

  /// 已加载到第几页（下一页请求要带上 page+1）。
  final int followingPage;

  /// 是否还有下一页。
  final bool followingHasMore;

  /// 「显示下界」（详见 `TimelineFloor`）。
  ///
  /// [items] 只存**可见**条目（时间 >= 本字段）；比它更旧的内容虽然已经加载，
  /// 也一律扣在缓冲里不显示 —— 因为那段区间里另一侧还没拉全，
  /// 显示出来就会呈现「本该同时有、却只有一侧」的假象。
  ///
  /// null 表示不设限（两侧都完整，或只有一侧可用）。
  final DateTime? displayFloor;

  /// 已加载但被 [displayFloor] 扣住的条目数（只用于日志/调试）。
  final int bufferedCount;

  /// B 站一侧是否已到底（`has_more=false` 或没有游标）。
  ///
  /// 到底之后该侧不再构成 floor 约束：更早的时间点同样是完整的，
  /// 于是允许出现**真实的**纯 B 站段。
  final bool biliEnded;

  /// 微博一侧是否已到底（`maxId == null`）。
  final bool weiboEnded;

  /// 「全部关注」的**全量池**：已加载但被 [displayFloor] 扣住、暂不显示的条目。
  ///
  /// `items` 只放可见条目，所以重新切分 floor 时**看不到**被扣住的那些 ——
  /// 没有这个池，每轮切分都会把「已经加载但未显示」的内容算成没加载，
  /// 导致 floor 无法正确推进（也会白白重复请求已经拿到过的页）。
  ///
  /// 不暴露给 UI：它是内部账本，渲染只看 [items]。
  final List<ContentItem>? followingPool;

  /// 全量池（不细分时回落到 [items]），供 loadMore 做增量合并。
  List<ContentItem> get allLoaded => followingPool ?? items;

  bool get isEmpty => items.isEmpty;

  int get newCount => items.where((i) => i.isNew).length;

  /// 是否还能继续往下翻（供 UI 显示加载态 / 到底提示）。
  ///
  /// 判据是「**任一侧**还有游标」：微博到底而 B 站还有时必须继续能翻，
  /// 不能因为微博侧没游标就把整页停住。
  bool get canLoadMore =>
      mode.isPaged &&
      followingHasMore &&
      ((followingOffset?.isNotEmpty ?? false) ||
          (followingMaxId?.isNotEmpty ?? false));

  /// 有错误但仍展示了内容：属于「部分降级」，UI 用横幅提示而不是整页错误。
  bool get partialFailure =>
      items.isNotEmpty && statuses.values.any((s) => s.hasError);

  int get failingSourceCount => statuses.values.where((s) => s.hasError).length;

  TimelineState copyWith({
    bool? loading,
    bool? refreshing,
    bool? loadingMore,
    bool? initialized,
    TimelineMode? mode,
    List<ContentItem>? items,
    Map<String, SourceStatus>? statuses,
    List<Subscription>? subscriptions,
    AppError? error,
    bool clearError = false,
    String? emptyHint,
    bool clearEmptyHint = false,
    DateTime? lastUpdated,
    bool? staleFallbackUsed,
    String? followingOffset,
    bool clearFollowingOffset = false,
    String? followingMaxId,
    bool clearFollowingMaxId = false,
    int? followingPage,
    bool? followingHasMore,
    DateTime? displayFloor,
    bool clearDisplayFloor = false,
    int? bufferedCount,
    bool? biliEnded,
    bool? weiboEnded,
    List<ContentItem>? followingPool,
  }) =>
      TimelineState(
        loading: loading ?? this.loading,
        refreshing: refreshing ?? this.refreshing,
        loadingMore: loadingMore ?? this.loadingMore,
        initialized: initialized ?? this.initialized,
        mode: mode ?? this.mode,
        items: items ?? this.items,
        statuses: statuses ?? this.statuses,
        subscriptions: subscriptions ?? this.subscriptions,
        error: clearError ? null : (error ?? this.error),
        emptyHint:
            clearEmptyHint ? null : (emptyHint ?? this.emptyHint),
        lastUpdated: lastUpdated ?? this.lastUpdated,
        staleFallbackUsed: staleFallbackUsed ?? this.staleFallbackUsed,
        followingOffset:
            clearFollowingOffset ? null : (followingOffset ?? this.followingOffset),
        followingMaxId: clearFollowingMaxId
            ? null
            : (followingMaxId ?? this.followingMaxId),
        followingPage: followingPage ?? this.followingPage,
        followingHasMore: followingHasMore ?? this.followingHasMore,
        displayFloor:
            clearDisplayFloor ? null : (displayFloor ?? this.displayFloor),
        bufferedCount: bufferedCount ?? this.bufferedCount,
        biliEnded: biliEnded ?? this.biliEnded,
        weiboEnded: weiboEnded ?? this.weiboEnded,
        followingPool: followingPool ?? this.followingPool,
      );
}

class TimelineNotifier extends StateNotifier<TimelineState> {
  TimelineNotifier({required Ref ref, required Prefs prefs})
      : _ref = ref,
        _prefs = prefs,
        super(const TimelineState());

  /// 刻意持有 `ref` 而不是仓库实例。
  ///
  /// 原因：登录态一变，B 站数据源（连带整个 `timelineRepoProvider`）就会重建。
  /// 如果 notifier 直接 `watch` 仓库，它自己也会被重建 —— 已加载的时间线会被
  /// 清空，表现为「登录之后时间线反而变空」这种极难排查的现象。
  /// 所以仓库改成**每次 refresh 现取**。
  final Ref _ref;
  final Prefs _prefs;

  /// 每个取数模式上一次成功渲染的状态（**双模式快照**）。
  ///
  /// 为什么需要它：`setMode` 早先是「先清空 items，再 force 刷新」，
  /// 于是点开「精选订阅」必然先闪一屏「占位卡 + 迷你转圈」，
  /// 而逐源聚合要拉 7 个源、这个中间态会持续好几秒。
  ///
  /// 为什么不能简单「不清空 items」：两种模式的 `sourceId` 语义不同
  /// （`feed/all` vs `平台:uid#route`），混着显示会让**已读标记与去重失效**
  /// （见 `setMode` 的注释）。所以按模式各存一份，切过去时直接换上**该模式自己的**
  /// 旧内容 —— 语义正确，且立刻有东西可看。
  final Map<TimelineMode, TimelineState> _snapshots =
      <TimelineMode, TimelineState>{};

  /// 把当前 state 记进它所属模式的快照位。
  ///
  /// 只在「有内容」时记：把一屏空列表记成快照，下次切过去还是空白，
  /// 等于没修。`loadMore` 追加的页也走这里，所以翻过两页再切走再切回，
  /// 回来仍是两页的内容。
  void _rememberSnapshot() {
    if (state.items.isEmpty) return;
    _snapshots[state.mode] = state;
  }

  /// 刷新时间线。
  ///
  /// 基地址与订阅源都从 [Prefs] 现读 —— 这样「设置页改完地址，下次刷新即生效」，
  /// 不需要额外的失效通知。
  ///
  /// 按当前模式分派：默认「全部关注」只打**一个**请求（拉 20 条 + 游标），
  /// 「精选订阅」保留原有的逐源聚合逻辑。
  Future<void> refresh({bool force = false, bool silent = false}) async {
    final mode = _prefs.timelineMode;
    if (mode.isPaged) {
      await _refreshFollowing(force: force, silent: silent);
    } else {
      await _refreshSubscriptions(force: force, silent: silent);
    }
  }

  /// 「全部关注」模式：首屏只拉一页，游标留给 [loadMore]。
  Future<void> _refreshFollowing({
    required bool force,
    required bool silent,
  }) async {
    final subs = _prefs.subscriptions;
    final firstLoad = !state.initialized;

    if (!silent) {
      state = state.copyWith(
        loading: firstLoad,
        refreshing: !firstLoad,
        mode: TimelineMode.allFollowing,
        subscriptions: subs,
        clearError: true,
      );
    }

    final repo = _ref.read(timelineRepoProvider);
    try {
      // 首屏两侧都从零开始（两个游标各自传 null）。
      final result = await repo.loadFollowing(page: 1, forceRefresh: force);

      // 首屏也要过一遍 floor：此时两侧各只有一页，微博那一页往往已经
      // 覆盖好几天、B 站只有几小时 —— 不切分的话首屏尾部立刻就是
      // 「本该同时有、却只有微博」的区间。
      //
      // `result.items` 已经由 `loadFollowing` 合并成严格倒序，直接拿来切分。
      final TimelineFloorSplit split = TimelineFloor.split(
        all: result.items,
        biliExhausted: result.nextOffset == null,
        weiboExhausted: result.nextMaxId == null,
      );

      state = TimelineState(
        initialized: true,
        mode: TimelineMode.allFollowing,
        items: split.visible,
        // 两侧状态一起放进来：微博失败只是一条「部分降级」提示，
        // 不会把整页判成失败（B 站内容仍在）。
        statuses: result.statuses,
        subscriptions: subs,
        error: result.error,
        emptyHint: result.emptyHint,
        lastUpdated: result.lastUpdated,
        followingOffset: result.nextOffset,
        followingMaxId: result.nextMaxId,
        followingPage: 1,
        followingHasMore: !result.isEnd,
        displayFloor: split.floor,
        bufferedCount: split.buffered.length,
        biliEnded: result.nextOffset == null,
        weiboEnded: result.nextMaxId == null,
        followingPool: result.items,
      );
      Log.d('Timeline', '首屏 ${split.debugLabel()}');
      // 写快照：切模式时要用它做到「秒回」（见 [setMode]）。
      _rememberSnapshot();
    } catch (e) {
      state = state.copyWith(
        initialized: true,
        loading: false,
        refreshing: false,
        mode: TimelineMode.allFollowing,
        subscriptions: subs,
        error: e is AppError ? e : AppError(AppErrorKind.unknown, '刷新失败：$e'),
      );
    }
  }

  /// 「全部关注」模式：滚到底拉下一页（用上一页返回的两个游标）。
  ///
  /// 自带 `loadingMore` / `canLoadMore` 守卫，所以滚动回调可以放心地重复调用。
  ///
  /// ⚠️ **两个游标独立透传**：B 站传 `offset`、微博传 `maxId`。某一边到底
  /// （游标为 null）时只把那一侧传 null，另一侧照常推进 —— 否则「微博到底、
  /// B 站还有」就会整页停住。
  /// 「全部关注」模式：滚到底拉下一页（用上一页返回的两个游标）。
  ///
  /// 自带 `loadingMore` / `canLoadMore` 守卫，所以滚动回调可以放心地重复调用。
  ///
  /// ⚠️ **两个游标独立透传**：B 站传 `offset`、微博传 `maxId`。某一边到底
  /// （游标为 null）时只把那一侧传 null，另一侧照常推进 —— 否则「微博到底、
  /// B 站还有」就会整页停住。
  ///
  /// ## 按「时间水位」推进（真机缺陷 2026-10-26）
  ///
  /// 现象：往下滚时会出现**一大段只有微博**的区间，继续滚才闪一下补上 B 站。
  ///
  /// 根因不是排序、也不是渲染，而是**两侧翻页节奏差了一个数量级**：
  /// - B 站 `feed/all` 一页 20 条只覆盖**几小时**（关注的人多、发得勤）；
  /// - 微博 `/feed/friends` 一页 20 条覆盖**3~6 天**。
  ///
  /// 每滚一次就两侧各取一页，微博的「已覆盖水位」会飞快走到一个月前，
  /// 而 B 站还停在几天内 —— 中间那一大段自然只有微博内容。
  ///
  /// 修法：**只在必要时才翻某一侧**。每页先比较两侧游标的「水位」
  /// （各自最新一页里最旧那条的时间），谁的水位更新就只翻谁，直到两侧
  /// 大致对齐（差距小于 [_timelineWatermarkSlack]）才同时翻。
  ///
  /// 这样滚到底看到的永远是「B 站 + 微博」交错，而不是先微博一大片再补 B 站。
  Future<void> loadMore() async {
    if (!state.mode.isPaged) return;
    if (state.loadingMore || state.loading || !state.canLoadMore) return;

    final offset = state.followingOffset;
    final maxId = state.followingMaxId;
    final bool hasOffset = offset != null && offset.isNotEmpty;
    final bool hasMax = maxId != null && maxId.isNotEmpty;
    if (!hasOffset && !hasMax) return;

    // 两侧**都翻**（各自游标为 null 的那侧自然不翻）。
    //
    // ## 为什么放弃「按水位只翻一侧」（2026-10-26 复盘）
    //
    // 曾尝试比较两侧已加载内容的最旧时间，只翻「落后」的那侧，想让两侧
    // 时间跨度对齐。真机日志证明这**把问题从一边翻到了另一边**：
    //
    //   loadMore#3  bili=Y weibo=N | 水位 bili=10-25 weibo=10-16
    //   loadMore#4  bili=Y weibo=N | 水位 bili=10-24 weibo=10-16  ← 微博卡住不动
    //   loadMore#5  bili=Y weibo=Y | 水位 bili=10-24 weibo=10-16
    //
    // 微博水位连续几轮不变（被跳过），B 站一路推进 —— 用户从「一大段只有微博」
    // 变成「一大段只有 B 站」。两种都错。
    //
    // 结论：**两侧必须都翻**。某一时间窗里只剩一个平台，是「那个平台的人
    // 在那段时间真的发得更多」的自然结果，不是 bug，不该用策略去掩盖。
    final bool fetchBili = hasOffset;
    final bool fetchWeibo = hasMax;

    final nextPage = state.followingPage + 1;
    state = state.copyWith(loadingMore: true, clearError: true);

    final repo = _ref.read(timelineRepoProvider);
    try {
      final result = await repo.loadFollowing(
        offset: fetchBili ? offset : null,
        maxId: fetchWeibo ? maxId : null,
        page: nextPage,
      );

      // 合并进**全量池**（不是 items —— items 只有可见那部分）。
      //
      // 仍然要整体重排：两侧游标各自翻页，两页之间**没有全局单调性**
      // （B 站一页几小时、微博一页十几天），见
      // [TimelineRepository.mergeContinuing] 的注释。
      final List<ContentItem> merged =
          TimelineRepository.mergeContinuing(state.allLoaded, result.items);

      // 重新算显示下界并切分可见/缓冲（详见 `TimelineFloor`）。
      //
      // 传 `previousFloor: state.displayFloor` 是为了单调：floor 只许往更旧
      // 的方向走，否则水位异常「变新」会让已经显示过的条目凭空消失。
      final TimelineFloorSplit split = TimelineFloor.split(
        all: merged,
        biliExhausted: (fetchBili ? result.nextOffset == null : state.biliEnded),
        weiboExhausted:
            (fetchWeibo ? result.nextMaxId == null : state.weiboEnded),
        previousFloor: state.displayFloor,
      );

      // 诊断日志：直接在「运行日志」里看 floor 有没有推进、缓冲有没有吃满。
      {
        final int biliCount = result.items
            .where((ContentItem i) => i.platform == Platform.bilibili)
            .length;
        final int weiboCount = result.items
            .where((ContentItem i) => i.platform == Platform.weibo)
            .length;
        // 「本页真正新增了多少」——与 biliCount/weiboCount 的差就是去重掉的量。
        // 若这个差值长期 = 20，说明服务端在重复返回已加载过的内容（游标没生效）。
        final Set<String> before = <String>{
          for (final ContentItem i in state.allLoaded) i.id,
        };
        final int reallyNew =
            result.items.where((ContentItem i) => !before.contains(i.id)).length;
        Log.d(
          'Timeline',
          'loadMore#$nextPage 翻页 bili=${fetchBili ? 'Y' : 'N'} '
              'weibo=${fetchWeibo ? 'Y' : 'N'} '
              '| 拉回 bili=$biliCount weibo=$weiboCount '
              '| 去重后新增 $reallyNew 条 | 池 ${merged.length} 条 '
              '| ${split.debugLabel()}',
        );
      }

      state = state.copyWith(
        loadingMore: false,
        // ⚠️ 只放**可见**条目。缓冲的那些留在 followingPool 里，
        // 等 floor 退过去之后自然出现在 visible 中 —— 不需要重新请求。
        items: split.visible,
        followingPool: merged,
        displayFloor: split.floor,
        bufferedCount: split.buffered.length,
        biliEnded: fetchBili ? result.nextOffset == null : state.biliEnded,
        weiboEnded: fetchWeibo ? result.nextMaxId == null : state.weiboEnded,
        // 状态表要换成**本页**的：否则微博侧一旦恢复，横幅会一直挂着旧的失败。
        statuses: result.statuses,
        lastUpdated: result.lastUpdated ?? state.lastUpdated,
        // 游标只在「这一侧确实翻了」时推进。没翻的那一侧保持原值，
        // 否则会被这次的空结果覆盖成 null，导致那一侧永久停止翻页。
        followingOffset: fetchBili ? result.nextOffset : state.followingOffset,
        clearFollowingOffset: fetchBili && result.nextOffset == null,
        followingMaxId: fetchWeibo ? result.nextMaxId : state.followingMaxId,
        clearFollowingMaxId: fetchWeibo && result.nextMaxId == null,
        followingPage: nextPage,
        followingHasMore: _stillHasMore(
          fetchBili: fetchBili,
          fetchWeibo: fetchWeibo,
          biliEnded: fetchBili && result.nextOffset == null,
          weiboEnded: fetchWeibo && result.nextMaxId == null,
        ),
        error: result.error,
      );
      // 翻页结果也要进快照：不然「翻到第 3 页 → 切走 → 切回」只剩第 1 页。
      _rememberSnapshot();
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        error: e is AppError ? e : AppError(AppErrorKind.unknown, '加载更多失败：$e'),
      );
    }
  }

  /// 更新后的「还有下一页」判定。
  ///
  /// 注意「这一轮只翻了一侧」的情形：没翻的那一侧游标还在，就仍然能继续翻。
  bool _stillHasMore({
    required bool fetchBili,
    required bool fetchWeibo,
    required bool biliEnded,
    required bool weiboEnded,
  }) {
    final bool biliHasMore = fetchBili ? !biliEnded : true;
    final bool weiboHasMore = fetchWeibo ? !weiboEnded : true;
    return biliHasMore || weiboHasMore;
  }

  /// 切换取数模式：换上**该模式自己的**上次内容，然后按缓存刷新。
  ///
  /// 两处关键改动（修「点开精选订阅先闪旧画面」，见 docs/UI_HANDOFF.md §4）：
  ///
  /// 1. **不再清空成空 state**：原来的写法 `state = TimelineState(mode: ...)`
  ///    会把 items 清掉，界面立刻只剩「占位卡 + 迷你转圈」；
  /// 2. **`force: false`**：原来强制跳过缓存，逐源聚合要真拉 7 个源，
  ///    那个空窗期会持续好几秒。走缓存则是「秒回」，过期才真拉。
  ///
  /// **仍然不能简单「不清空 items」**：两种模式产出的 sourceId 语义不同
  /// （`feed/all` vs `平台:uid#route`），混在一起会让已读标记与去重都失去依据。
  /// 所以这里换成**按模式各存一份快照**，切过去装的是该模式自己的内容 ——
  /// 语义正确，且第一帧就有东西看。
  Future<void> setMode(TimelineMode mode) async {
    if (state.mode == mode && state.initialized) return;
    await _prefs.setTimelineMode(mode);

    // 切走之前先把当前模式的内容记下来，下次切回来直接可用。
    _rememberSnapshot();

    final TimelineState? snap = _snapshots[mode];
    state = snap == null
        // 首次进入这个模式：没有任何可复用的内容，只能转圈等第一页。
        ? TimelineState(mode: mode, subscriptions: _prefs.subscriptions)
        // 有快照 → 立刻有内容（并保留原来的游标/页码，可以继续往下翻）。
        : snap.copyWith(
            mode: mode,
            subscriptions: _prefs.subscriptions,
            loading: false,
            refreshing: false,
            loadingMore: false,
            clearError: true,
          );

    await refresh(force: false);
  }

  Future<void> _refreshSubscriptions({
    required bool force,
    required bool silent,
  }) async {
    final subs = _prefs.subscriptions;
    final firstLoad = !state.initialized;

    if (!silent) {
      state = TimelineState(
        loading: firstLoad,
        refreshing: !firstLoad,
        initialized: state.initialized,
        mode: TimelineMode.selectedSubscriptions,
        items: state.items,
        statuses: state.statuses,
        subscriptions: subs,
        lastUpdated: state.lastUpdated,
        staleFallbackUsed: state.staleFallbackUsed,
      );
    }

    final repo = _ref.read(timelineRepoProvider);
    try {
      final result = await repo.load(
        subscriptions: subs,
        forceRefresh: force,
      );

      // 微博昵称回填的「最后一公里」。
      //
      // `TimelineRepository` 在拉取成功后会把这个博主真实昵称写进 `Prefs`
      // 的别名（见 `_backfillWeiboAlias`），但订阅源页读的是
      // [subscriptionsProvider] 自己缓存的那份列表 —— 不重读的话，用户得
      // 重启 App 才能看到「微博 1782488734」变成真名。
      //
      // 只在**别名真的变了**时才 reload：B 站订阅、以及没有回填的轮次都
      // 不会多一次通知、多一次重建（行为与本改动之前完全一致）。
      final List<Subscription> latestSubs = _prefs.subscriptions;
      final bool aliasesChanged = !_sameAliases(latestSubs, subs);
      final List<Subscription> effectiveSubs =
          aliasesChanged ? latestSubs : subs;
      if (aliasesChanged) {
        _ref.read(subscriptionsProvider.notifier).reload();
      }

      state = TimelineState(
        initialized: true,
        mode: TimelineMode.selectedSubscriptions,
        items: result.items,
        statuses: result.statuses,
        subscriptions: effectiveSubs,
        error: result.fatalError,
        emptyHint: result.emptyHint,
        lastUpdated: result.lastUpdated,
        staleFallbackUsed: result.staleFallbackUsed,
      );
      // 写快照：切回本模式时靠它做到「秒回」（见 [setMode]）。
      _rememberSnapshot();
    } catch (e) {
      state = TimelineState(
        initialized: true,
        mode: TimelineMode.selectedSubscriptions,
        items: state.items,
        statuses: state.statuses,
        subscriptions: subs,
        error: e is AppError
            ? e
            : AppError(AppErrorKind.unknown, '刷新失败：$e'),
        lastUpdated: state.lastUpdated,
      );
    }
  }

  /// 两份订阅列表的别名是否完全一致（id → alias）。
  ///
  /// 只比别名（而不是整个对象）：能触发重读的信号只有微博昵称回填，
  /// 其它字段变了也不需要在这里处理。
  static bool _sameAliases(
    List<Subscription> a,
    List<Subscription> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
      if ((a[i].alias ?? '').trim() != (b[i].alias ?? '').trim()) return false;
    }
    return true;
  }

  /// 把当前条目全部标记为已读，并清掉 UI 上的「新」角标。
  Future<void> markCurrentSeen() async {
    final items = state.items;
    if (items.isEmpty) return;
    await _ref.read(timelineRepoProvider).markAllSeen(items);
    // ⚠️ 必须连**缓冲池**一起清：池里的条目晚些时候会被 floor 放出来，
    // 若只清可见的，那些迟到的条目会带着「新」角标冒出来 —— 用户明明
    // 已经点过「已读」，却又看到一批「新」内容。
    final List<ContentItem>? pool = state.followingPool;
    state = state.copyWith(
      items: items.map((i) => i.copyWith(isNew: false)).toList(),
      followingPool: pool == null
          ? null
          : <ContentItem>[for (final i in pool) i.copyWith(isNew: false)],
    );
  }

  Future<void> clearSeenMarks() async {
    await _ref.read(timelineRepoProvider).clearSeen();
    final List<ContentItem>? pool = state.followingPool;
    state = state.copyWith(
      items: state.items.map((i) => i.copyWith(isNew: false)).toList(),
      followingPool: pool == null
          ? null
          : <ContentItem>[for (final i in pool) i.copyWith(isNew: false)],
    );
  }
}

final timelineProvider =
    StateNotifierProvider<TimelineNotifier, TimelineState>((ref) {
  final notifier = TimelineNotifier(
    ref: ref,
    prefs: ref.watch(prefsProvider),
  );

  // 登录态就绪/变化时静默补刷一次。
  //
  // 必要性：冷启动时钥匙串是**首帧之后**才读完的，所以第一轮刷新很可能
  // 发生在「看起来还没登录」的时刻 —— 少了这一次，B 站订阅会一直挂着
  // 「需要先登录」的错误，直到用户自己想起来下拉刷新。
  ref.listen<bool>(
    biliLoginProvider.select((s) => s.session != null),
    (prev, next) {
      if (prev != next) notifier.refresh(silent: true);
    },
  );

  return notifier;
});
