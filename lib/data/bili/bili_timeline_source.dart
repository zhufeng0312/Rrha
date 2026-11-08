import 'dart:convert';

import '../../core/cache/cache_store.dart';
import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../core/utils/logger.dart';
import '../models/bili_user.dart';
import '../models/content_item.dart';
import '../models/subscription.dart';
import 'bili_client.dart';
import 'bili_content_parser.dart';
import 'bili_models.dart';

/// 一次 B 站官方接口拉取的结果。
class BiliFetchResult {
  const BiliFetchResult({
    required this.items,
    required this.fetchedAt,
    this.fromCache = false,
    this.emptyHint,
    this.nextPage,
    this.nextOffset,
  });

  final List<ContentItem> items;
  final DateTime fetchedAt;

  /// 是否来自 TTL 内的缓存。
  final bool fromCache;

  /// 空结果的解释文案。
  final String? emptyHint;

  /// 下一页**页码**（投稿路由用）。null = 该路由不用页码 / 已到底。
  final int? nextPage;

  /// 下一页 **offset**（动态路由用）。null = 到底或该路由不用 offset。
  final String? nextOffset;
}

/// 一次「全部关注」动态流拉取的结果（含游标与是否到底）。
class BiliFollowingFeedPage {
  const BiliFollowingFeedPage({
    required this.items,
    required this.fetchedAt,
    this.nextOffset,
    this.hasMore = false,
    this.fromCache = false,
  });

  final List<ContentItem> items;
  final DateTime fetchedAt;

  /// 下一页游标；null 表示没有下一页。
  final String? nextOffset;

  final bool hasMore;
  final bool fromCache;

  bool get isEnd => !hasMore || nextOffset == null;
}

/// B 站官方接口内容源。
///
/// 与 `RssHubClient` + `RssParser` 平行：那条路吃 RSSHub 的 RSS（公共实例、
/// 不稳定、且需要实例侧配 Cookie），这条**带用户登录态直连平台**。
///
/// **为什么必须带缓存**：关注列表动辄几十人，每个源一次刷新就是一个请求；
/// 没有缓存的话每次下拉都会打出几十个请求，必然被风控。
/// 这里复用与 RSS 侧同一个 [CacheStore] 和同一个 TTL
/// （[AppConfig.timelineCacheTtl]，5 分钟）。
class BiliTimelineSource {
  BiliTimelineSource({required BiliClient client, required CacheStore cache})
      : _client = client,
        _cache = cache;

  final BiliClient _client;
  final CacheStore _cache;

  /// 「全部关注」这条虚拟源的稳定 id。
  ///
  /// 它同时决定 [ContentItem.sourceId]，而已读标记是**按 sourceId 分组**存的 ——
  /// 所以这个值必须与页码、游标无关，且跨刷新不变。一旦让它跟着分页变化，
  /// 每翻一页都会被当成「一个新源」：已读集合永远是空的，界面上就满屏「新」角标。
  static const String followingSourceId = 'bilibili:following';

  /// 「全部关注」用的虚拟订阅。
  ///
  /// 解析层（`BiliContentParser.fromDynamic`）需要 [Subscription] 提供 sourceId
  /// 与作者兜底名，而关注流不属于任何一条订阅，因此造一个**稳定**的虚拟源：
  /// uid 固定为 `following`（不是真的 mid），其 [Subscription.id] 正好等于
  /// [followingSourceId]。
  static final Subscription followingSubscription = Subscription(
    platform: Platform.bilibili,
    uid: 'following',
    routes: const <FeedRoute>{FeedRoute.bilibiliDynamic},
    addedAt: DateTime.utc(2026, 1, 1),
  );

  /// 拉取「全部关注」动态流的一页。
  ///
  /// 分页流**按页缓存**（键里带页码与游标），TTL 与其它 B 站源一致（5 分钟）。
  Future<BiliFollowingFeedPage> fetchFollowing({
    String? offset,
    int page = 1,
    bool forceRefresh = false,
  }) async {
    _requireLogin();

    final cacheKey = _followingCacheKey(page: page, offset: offset);

    if (!forceRefresh) {
      final cached = await _cache.read(cacheKey, ignoreTtl: true);
      if (cached != null && cached.isFresh(AppConfig.timelineCacheTtl)) {
        final feed = _decodeFeed(cached.body);
        final items = _parseFollowing(feed.items, fetchedAt: cached.fetchedAt);
        Log.d(
          'BiliTimelineSource',
          '关注流 page=$page 命中缓存：${items.length} 条',
        );
        return BiliFollowingFeedPage(
          items: items,
          fetchedAt: cached.fetchedAt,
          nextOffset: feed.nextOffset,
          hasMore: feed.hasMore,
          fromCache: true,
        );
      }
    }

    final feed = await _client.followingFeed(offset: offset, page: page);
    final now = DateTime.now().toUtc();

    // 缓存原始 JSON（items + 游标 + has_more 一起存）：
    // 只存 items 的话，翻页游标会在缓存命中后丢失，第二页就接不上了。
    try {
      await _cache.write(cacheKey, jsonEncode(feed.toJson()), statusCode: 200);
    } catch (e) {
      Log.w('BiliTimelineSource', '关注流写缓存失败（忽略）：$e');
    }

    final items = _parseFollowing(feed.items, fetchedAt: now);
    Log.d(
      'BiliTimelineSource',
      '关注流 page=$page 拉取成功：原始 ${feed.items.length} 条 → 解析出 ${items.length} 条，'
      'hasMore=${feed.hasMore}',
    );
    return BiliFollowingFeedPage(
      items: items,
      fetchedAt: now,
      nextOffset: feed.nextOffset,
      hasMore: feed.hasMore,
    );
  }

  /// 拉取一个「B 站订阅源 × 路由」的内容。
  ///
  /// [page] / [offset] 是**翻页游标**（2026-11-08 新增）：
  /// - 投稿路由（`bilibiliVideo`）用 [page]（接口参数 `pn`，1 起）；
  /// - 动态路由（`bilibiliDynamic`）用 [offset]（接口参数 `offset`，首屏不传）。
  ///
  /// 早先这两个参数根本不存在，每个源永远只拉第一页 —— 这正是
  /// 「精选订阅里更早的动态看不到」的根因（见 `SourceCursor` 的注释）。
  Future<BiliFetchResult> fetch({
    required Subscription sub,
    required FeedRoute route,
    bool forceRefresh = false,
    int page = 1,
    String? offset,
  }) async {
    final mid = int.tryParse(sub.uid.trim());
    if (mid == null || mid <= 0) {
      throw AppError.parse('B 站订阅源的 UID 不合法：${sub.uid}');
    }
    if (route == FeedRoute.weiboUser) {
      throw AppError.parse('微博源不该走 B 站官方接口（内部路由分派错误）');
    }

    // 登录态的检查放在这里（而不是放在 provider 是否构造这个对象上）：
    // 否则「有没有登录」会去影响仓库实例的生命周期，进而牵连时间线的
    // notifier 被重建、已加载内容被清空 —— 那是更难查的一类问题。
    _requireLogin();

    // ⚠️ 缓存键**必须**带上翻页游标：
    // 只按 (route, mid) 缓存的话，翻到第 2 页时 TTL 内会直接命中第 1 页的
    // 缓存，症状是「翻页后内容完全不变、滚不到更早的东西」。
    final cacheKey = _cacheKey(route, mid, page: page, offset: offset);

    if (!forceRefresh) {
      final cached = await _cache.read(cacheKey, ignoreTtl: true);
      if (cached != null && cached.isFresh(AppConfig.timelineCacheTtl)) {
        final items = _parse(
          route: route,
          raw: _decode(cached.body),
          sub: sub,
          fetchedAt: cached.fetchedAt,
        );
        Log.d(
          'BiliTimelineSource',
          'mid=$mid ${route.key} page=$page 命中缓存：${items.length} 条',
        );
        return BiliFetchResult(
          items: items,
          fetchedAt: cached.fetchedAt,
          fromCache: true,
          emptyHint: items.isEmpty ? _emptyHint(route) : null,
        );
      }
    }

    final rawPage = await _fetchRawPage(route, mid, page: page, offset: offset);
    final raw = rawPage.items;
    final now = DateTime.now().toUtc();

    // 缓存原始 JSON 而不是解析后的模型：解析规则升级后旧缓存依然可用
    // （与 RSS 侧缓存 XML 原文同一个理由）。
    try {
      await _cache.write(cacheKey, jsonEncode(raw), statusCode: 200);
    } catch (e) {
      // 缓存写失败不该让整次刷新失败。
      Log.w('BiliTimelineSource', '写缓存失败（忽略）：$e');
    }

    List<ContentItem> items =
        _parse(route: route, raw: raw, sub: sub, fetchedAt: now);

    // 投稿路由补头像（见 [BiliClient.userAvatar] 的注释：`vlist` 里没有 `face`）。
    // 动态路由的 `module_author.face` 本来就有，不用走这一步。
    if (route == FeedRoute.bilibiliVideo && items.isNotEmpty) {
      items = await _attachAvatar(items, mid);
    }

    // 这条日志是刻意留的：真机上出问题时，设置页的日志页能一眼看出
    // 到底是「服务端没给」还是「给了但没解析出来」。
    Log.d(
      'BiliTimelineSource',
      'mid=$mid ${route.key} page=$page 拉取成功：'
      '原始 ${raw.length} 条 → 解析出 ${items.length} 条'
      '${rawPage.nextOffset == null ? '' : ' 下一页 offset=${rawPage.nextOffset}'}',
    );
    return BiliFetchResult(
      items: items,
      fetchedAt: now,
      emptyHint: items.isEmpty ? _emptyHint(route) : null,
      nextPage: rawPage.nextPage,
      nextOffset: rawPage.nextOffset,
    );
  }

  // ------------------------------------------------------------ 内部

  /// 给一批**投稿**条目补上 UP 主头像。
  ///
  /// 为什么需要：投稿接口（`arc/search`）的 `vlist[]` 只给 `author` + `mid`，
  /// **没有 `face`**（真机缓存核实），所以 `fromUserVideo` 产出的
  /// `authorAvatar` 恒为 null，卡片只能显示首字母占位。
  ///
  /// 三条纪律：
  /// 1. **一个 UP 只问一次**：整批条目的 `authorId` 几乎都是同一个 mid，
  ///    按 mid 去重后最多 1 个请求（这里再按 mid 命中一次内存缓存）；
  /// 2. **失败绝不抛**：`userAvatar` 自己吞异常返回 null，这里保住原条目；
  /// 3. **磁盘缓存 24 小时**：头像 URL 很少变，翻页时每页都问一次没有必要。
  Future<List<ContentItem>> _attachAvatar(
    List<ContentItem> items,
    int mid,
  ) async {
    String? face = _avatarCache[mid];
    if (face == null) {
      const String key = 'bili-avatar://card';
      face = await _readAvatarCache(mid, key);
      if (face == null) {
        final fetched = await _client.userAvatar(mid: mid);
        if (fetched != null && fetched.isNotEmpty) {
          face = BiliUser.normalizeImageUrl(fetched);
          if (face != null) {
            _avatarCache[mid] = face;
            await _writeAvatarCache(mid, key, face);
          }
        }
      } else {
        _avatarCache[mid] = face;
      }
    }
    if (face == null || face.isEmpty) return items;
    return <ContentItem>[
      for (final ContentItem item in items)
        item.authorAvatar == null || item.authorAvatar!.isEmpty
            ? item.copyWith(authorAvatar: face)
            : item,
    ];
  }

  /// 头像 URL 的内存缓存（同一进程内跨翻页复用）。
  final Map<int, String> _avatarCache = <int, String>{};

  Future<String?> _readAvatarCache(int mid, String prefix) async {
    try {
      final CachedBody? body = await _cache.read(
        '$prefix/$mid',
        ignoreTtl: true,
      );
      if (body == null) return null;
      // 头像用**更长的 TTL**（24h）：URL 里带内容指纹，变了就换 URL 了。
      if (DateTime.now().toUtc().difference(body.fetchedAt) >
          const Duration(hours: 24)) {
        return null;
      }
      final String text = body.body.trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAvatarCache(int mid, String prefix, String url) async {
    try {
      await _cache.write('$prefix/$mid', url, statusCode: 200);
    } catch (e) {
      Log.w('BiliTimelineSource', '写头像缓存失败（忽略）：$e');
    }
  }

  /// 登录态检查抽成一处：逐源拉取与「全部关注」都要用，
  /// 两处各写一份很容易漏掉一处，症状是「未登录时静默返回空列表」。
  void _requireLogin() {
    if (_client.hasAccountCookie) return;
    throw const AppError(
      AppErrorKind.auth,
      'B 站订阅需要先登录账号（设置 → B 站账号 → 扫码登录）',
      retryable: false,
    );
  }

  /// 关注流的分页缓存键。
  ///
  /// **页码与游标都要进键**：只按页码缓存会在「游标推进了但页码没变」时读到旧数据，
  /// 症状是第二页和第一页一模一样。
  static String _followingCacheKey({required int page, String? offset}) =>
      'bili-api://following/page=$page/offset=${(offset ?? '').trim()}';

  static BiliFollowingFeed _decodeFeed(String body) {
    try {
      return BiliFollowingFeed.fromJson(jsonDecode(body));
    } catch (e) {
      Log.w('BiliTimelineSource', '关注流缓存解析失败，按空结果处理：$e');
      return BiliFollowingFeed.empty;
    }
  }

  /// 关注流的 items → [ContentItem]。
  ///
  /// 全部挂到虚拟源 [followingSubscription] 上，使 sourceId 稳定可缓存已读标记
  /// （见 [followingSourceId] 的注释）；字段映射与逐源模式共用同一个
  /// `BiliContentParser.fromDynamic`，两种模式产出的卡片因此完全同形。
  static List<ContentItem> _parseFollowing(
    List<Object?> raw, {
    required DateTime fetchedAt,
  }) {
    final out = <ContentItem>[];
    for (final e in raw) {
      final item = BiliContentParser.fromDynamic(
        e,
        sub: followingSubscription,
        fetchedAt: fetchedAt,
      );
      if (item != null) out.add(item);
    }
    return out;
  }

  /// 取一页原始数据，**同时返回下一页游标**。
  ///
  /// 两种路由的游标语义不同（页码 vs offset），所以用一个内部小结构
  /// 一起带回来，而不是让调用方自己去猜「这一页还能不能翻」。
  Future<_RawPage> _fetchRawPage(
    FeedRoute route,
    int mid, {
    required int page,
    String? offset,
  }) async {
    switch (route) {
      case FeedRoute.bilibiliVideo:
        // 投稿列表用页码翻页（`pn` 从 1 起）。
        final items = await _client.userVideoItems(mid: mid, pn: page);
        // 返回条数达到一页上限 = 可能还有下一页。
        // 拿不满就不给下一页，避免「最后几页全是空请求」。
        final bool mayHaveMore = items.length >= AppConfig.userVideoFetchLimit;
        return _RawPage(
          items: items,
          nextPage: mayHaveMore ? page + 1 : null,
        );
      case FeedRoute.bilibiliDynamic:
        // 动态用 offset 串翻页；服务端直接给下一页 offset（到底时为空）。
        final p = await _client.userDynamicPage(mid: mid, offset: offset);
        return _RawPage(items: p.items, nextOffset: p.nextOffset);
      case FeedRoute.weiboUser:
        throw AppError.parse('微博源不该走 B 站官方接口（内部路由分派错误）');
    }
  }

  List<ContentItem> _parse({
    required FeedRoute route,
    required List<Object?> raw,
    required Subscription sub,
    required DateTime fetchedAt,
  }) {
    final out = <ContentItem>[];
    for (final e in raw) {
      final item = switch (route) {
        FeedRoute.bilibiliVideo =>
          BiliContentParser.fromUserVideo(e, sub: sub, fetchedAt: fetchedAt),
        FeedRoute.bilibiliDynamic =>
          BiliContentParser.fromDynamic(e, sub: sub, fetchedAt: fetchedAt),
        FeedRoute.weiboUser => null,
      };
      if (item != null) out.add(item);
    }
    return out;
  }

  static String _emptyHint(FeedRoute route) => switch (route) {
        FeedRoute.bilibiliVideo => '该 UP 主最近没有新投稿',
        FeedRoute.bilibiliDynamic => '该 UP 主最近没有新动态',
        FeedRoute.weiboUser => '该微博源没有内容',
      };

  /// 逐源缓存键。
  ///
  /// ⚠️ 翻页之后**必须**把游标编进键里，否则第 2 页会命中第 1 页的缓存
  /// （TTL 5 分钟内），症状是「翻页后内容完全不变」。
  ///
  /// 首屏（page=1 且无 offset）刻意**保持旧格式** `bili-api://{route}/{mid}`：
  /// 设备上已有大量按这个键写入的缓存，改格式会让升级后的首次冷启动
  /// 全部 miss、白拉一轮。只有翻页才用带后缀的新键。
  static String _cacheKey(
    FeedRoute route,
    int mid, {
    required int page,
    String? offset,
  }) {
    final base = 'bili-api://${route.key}/$mid';
    final off = (offset ?? '').trim();
    if (page <= 1 && off.isEmpty) return base;
    return '$base/page=$page/offset=$off';
  }

  static List<Object?> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is List ? decoded : const <Object?>[];
    } catch (e) {
      Log.w('BiliTimelineSource', '缓存内容解析失败，按空结果处理：$e');
      return const <Object?>[];
    }
  }
}

/// 一页原始数据的内部载体：items + 下一页游标（二选一）。
class _RawPage {
  const _RawPage({required this.items, this.nextPage, this.nextOffset});

  final List<Object?> items;

  /// 投稿路由的下一页页码；null = 到底。
  final int? nextPage;

  /// 动态路由的下一页 offset；null = 到底。
  final String? nextOffset;
}
