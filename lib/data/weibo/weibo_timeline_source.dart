import 'dart:convert';

import '../../core/cache/cache_store.dart';
import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../core/net/weibo_cookie_source.dart';
import '../../core/utils/logger.dart';
import '../models/content_item.dart';
import '../models/subscription.dart';
import 'weibo_api_client.dart';
import 'weibo_parser.dart';

/// 一次微博博主时间线拉取的结果。
class WeiboFetchResult {
  const WeiboFetchResult({
    required this.items,
    required this.fetchedAt,
    this.fromCache = false,
    this.nextSinceId,
    this.emptyHint,
    this.authorName,
  });

  final List<ContentItem> items;
  final DateTime fetchedAt;

  /// 本次结果里带出的博主昵称（无条目则 null）。
  ///
  /// 为什么不另开请求：`mblog.user.screen_name` 本来就在同一份响应里，
  /// [WeiboParser] 已经把它填进了 [ContentItem.authorName]。这里只是把
  /// 「解析结果里第一条的作者名」原样透出来，让上游（订阅列表）能在**零额外
  /// 请求**的前提下把「微博 1782488734」换成博主真名。
  ///
  /// 缓存命中与网络拉取两条路径都会填 —— 缓存里存的就是原始 mblog，
  /// 昵称不缺；只填一条路径会让「刷新时改名失效」这种问题时有时无。
  final String? authorName;

  /// 是否来自 TTL 内的缓存。
  final bool fromCache;

  /// 下一页游标；null 表示服务端没给（视为到底）。
  ///
  /// 字符串原样透出：19 位游标过数值类型会丢精度。
  final String? nextSinceId;

  /// 空结果的解释文案。
  final String? emptyHint;
}

/// 一次「我关注的人」混合动态流（`/feed/friends`）拉取的结果。
class WeiboFriendsFeedPage {
  const WeiboFriendsFeedPage({
    required this.items,
    required this.fetchedAt,
    this.nextMaxId,
    this.hasMore = false,
    this.fromCache = false,
  });

  final List<ContentItem> items;
  final DateTime fetchedAt;

  /// 向**更早**翻页的游标（`max_id`）；null 表示服务端没给（视为到底）。
  ///
  /// ⚠️ 不是 `since_id` —— 那个方向相反，详见
  /// `WeiboApiClient.buildFriendsUrl` 的注释。
  final String? nextMaxId;

  final bool hasMore;
  final bool fromCache;

  bool get isEnd => !hasMore || nextMaxId == null;
}

/// 微博时间线数据源：**登录检查 + 缓存 + 解析**三段。
///
/// 结构与 `BiliTimelineSource` 刻意保持一致（同一个 [CacheStore]、同一个
/// [AppConfig.timelineCacheTtl]、同样的「缓存原始 JSON 而不是解析后的模型」），
/// 这样两条链路的行为可以互相印证，出问题时按同一套思路排查。
///
/// ## 登录检查为什么在这里
///
/// 不放在「provider 是否构造这个对象」上：那样登录/登出会连带把仓库实例
/// 重建，进而让时间线 notifier 一起重建、已加载内容被清空 —— 这是比
/// 「报一条未登录」难查得多的一类问题。所以对象永远存在，登录与否在
/// [fetch] 里现判。
class WeiboTimelineSource {
  WeiboTimelineSource({
    required WeiboApiClient client,
    required CacheStore cache,
    required WeiboCookieSource cookies,
  })  : _client = client,
        _cache = cache,
        _cookies = cookies;

  final WeiboApiClient _client;
  final CacheStore _cache;
  final WeiboCookieSource _cookies;

  /// uid 校验：微博 uid 是纯数字，拼进 URL 之前必须确认。
  static final RegExp _digits = RegExp(r'^\d+$');

  /// 「全部关注」里微博那一半的**虚拟源 id**。
  ///
  /// 与 B 站 [BiliTimelineSource.followingSourceId] 同一个理由：它决定
  /// [ContentItem.sourceId]，而已读标记是**按 sourceId 分组**存的 —— 这个值必须
  /// 与页码/游标无关、跨刷新不变。跟着游标变化的话，每翻一页都会被当成
  /// 「一个全新的源」：已读集合永远为空，界面上满屏「新」角标。
  static const String friendsSourceId = 'weibo:friends';

  /// 「关注流」用的虚拟订阅（解析层需要 [Subscription] 提供 sourceId 与作者兜底名）。
  ///
  /// uid 固定为 `friends`（不是真 uid），其 [Subscription.id] 正好是
  /// [friendsSourceId]。
  static final Subscription friendsSubscription = Subscription(
    platform: Platform.weibo,
    uid: 'friends',
    routes: const <FeedRoute>{FeedRoute.weiboUser},
    addedAt: DateTime.utc(2026, 1, 1),
  );

  /// 拉取一个微博订阅源的一页内容。
  ///
  /// [sinceId] 是翻页游标；首屏传 null。它会进缓存键，所以「首页」与
  /// 「第二页」不会互相顶掉缓存。
  Future<WeiboFetchResult> fetch({
    required Subscription sub,
    required FeedRoute route,
    bool forceRefresh = false,
    String? sinceId,
  }) async {
    // 路由必须是微博：传错时明确报解析错误（内部路由分派 bug），
    // 而不是静默打微博接口拿一份牛头不对马嘴的数据。
    if (route != FeedRoute.weiboUser) {
      throw AppError.parse(
        '微博数据源只能处理 ${FeedRoute.weiboUser.key} 路由，'
        '实际收到 ${route.key}（内部路由分派错误）',
      );
    }

    final String uid = sub.uid.trim();
    if (!_digits.hasMatch(uid)) {
      throw AppError.parse('微博订阅源的 UID 必须是纯数字，实际为「${sub.uid}」');
    }

    // 登录检查放在这里（见类注释）：空串 = 未登录。
    final String cookie = await _cookies.read();
    if (cookie.isEmpty) {
      throw const AppError(
        AppErrorKind.auth,
        '微博未登录：请打开「微博」页面登录一次',
        retryable: false,
      );
    }

    final String cursor = (sinceId ?? '').trim();
    final String cacheKey = _cacheKey(uid: uid, sinceId: cursor);

    if (!forceRefresh) {
      final CachedBody? cached = await _cache.read(cacheKey, ignoreTtl: true);
      if (cached != null && cached.isFresh(AppConfig.timelineCacheTtl)) {
        final _RawPage raw = _decodeCached(cached.body);
        final List<ContentItem> items =
            _parse(raw.mblogs, sub: sub, fetchedAt: cached.fetchedAt);
        // 这条日志刻意留：真机上「没内容」时要能分清是服务端没给、
        // 解析丢了、还是读到了缓存。不含任何凭据。
        Log.d(
          'WeiboTimelineSource',
          'uid=$uid since=${cursor.isEmpty ? '首屏' : '有'} 命中缓存：'
          '${raw.mblogs.length} 条原始 → ${items.length} 条',
        );
        return WeiboFetchResult(
          items: items,
          fetchedAt: cached.fetchedAt,
          fromCache: true,
          nextSinceId: raw.sinceId,
          emptyHint: items.isEmpty ? _emptyHint : null,
          authorName: _authorNameOf(items, sub: sub),
        );
      }
    }

    final WeiboPage page = await _client.userTimeline(
      uid: uid,
      cookie: cookie,
      sinceId: cursor.isEmpty ? null : cursor,
    );
    final DateTime now = DateTime.now().toUtc();

    // 缓存**原始 mblog JSON + 游标**，不是解析后的 ContentItem：
    // 解析规则升级（`WeiboParser` 改字段映射）后旧缓存依然可用；
    // 只存 items 的话游标会在缓存命中后丢失，第二页就接不上了。
    try {
      await _cache.write(
        cacheKey,
        jsonEncode(<String, Object?>{
          'mblogs': page.mblogs,
          'sinceId': page.sinceId,
          'total': page.total,
        }),
        statusCode: page.httpStatus,
      );
    } catch (e) {
      // 缓存写失败不该让整次刷新失败。
      Log.w('WeiboTimelineSource', '写缓存失败（忽略）：$e');
    }

    final List<ContentItem> items =
        _parse(page.mblogs, sub: sub, fetchedAt: now);
    Log.d(
      'WeiboTimelineSource',
      'uid=$uid 拉取成功：HTTP ${page.httpStatus}，原始 ${page.mblogs.length} 条 → '
          '解析出 ${items.length} 条，游标 ${page.sinceId == null ? '无' : '有'}',
    );
    return WeiboFetchResult(
      items: items,
      fetchedAt: now,
      nextSinceId: page.sinceId,
      emptyHint: items.isEmpty ? _emptyHint : null,
      authorName: _authorNameOf(items, sub: sub),
    );
  }

  // ------------------------------------------------------------ 关注流

  /// 拉「我关注的人」的混合动态流（一页）。
  ///
  /// 与 [fetch] 的区别：那条是「某一条订阅（某个 uid）」，这条是**不针对任何
  /// uid** 的关注流（`GET {mbBase}/feed/friends`），一页 20 条 / 约 6 个作者，
  /// 这是「全部关注」模式里微博那一半的唯一入口。
  ///
  /// 三条硬约束（都是真机踩出来的）：
  ///
  /// 1. **空 cookie → auth 错误，一个请求都不发**。该接口未登录恒 432 + 空 body；
  ///    先判空能省掉一次必然失败的请求（微博对密集请求会冷却）。
  /// 2. **游标走 `since_id`，原样拼 URL**。它是大整数游标，过数值类型会丢精度；
  ///    它同时进缓存键，所以「首页」与「第二页」不会互相顶掉缓存。
  /// 3. **解析走 `extractStatuses` + [WeiboParser.fromMblog]**：`data.statuses[]`
  ///    的元素是裸 mblog 形状（没有 `cards[].mblog` 外壳），不能复用
  ///    `extractMblogs` —— 那会稳定得到「200 + 0 条」的假阴性。
  Future<WeiboFriendsFeedPage> fetchFriendsFeed({
    String? maxId,
    bool forceRefresh = false,
  }) async {
    // 登录检查放在这里（与 [fetch] 同一处纪律）：空串 = 未登录。
    final String cookie = await _cookies.read();
    if (cookie.isEmpty) {
      throw const AppError(
        AppErrorKind.auth,
        '微博未登录：请打开「微博」页面登录一次',
        retryable: false,
      );
    }

    final String cursor = (maxId ?? '').trim();
    final String cacheKey = _friendsCacheKey(maxId: cursor);

    if (!forceRefresh) {
      final CachedBody? cached = await _cache.read(cacheKey, ignoreTtl: true);
      if (cached != null && cached.isFresh(AppConfig.timelineCacheTtl)) {
        final _RawFriendsPage raw = _decodeFriendsCached(cached.body);
        final List<ContentItem> items =
            _parseFriends(raw.statuses, fetchedAt: cached.fetchedAt);
        Log.d(
          'WeiboTimelineSource',
          '关注流 max=${cursor.isEmpty ? '首屏' : '有'} 命中缓存：'
          '${raw.statuses.length} 条原始 → ${items.length} 条',
        );
        return WeiboFriendsFeedPage(
          items: items,
          fetchedAt: cached.fetchedAt,
          nextMaxId: raw.maxId,
          hasMore: raw.maxId != null,
          fromCache: true,
        );
      }
    }

    final WeiboFriendsPage page = await _client.friendsFeed(
      cookie: cookie,
      maxId: cursor.isEmpty ? null : cursor,
    );
    final DateTime now = DateTime.now().toUtc();

    // 存**原始 status + 游标**：解析规则升级后旧缓存仍可用，且缓存命中后
    // 翻页游标还在（只存 items 会让第二页接不上）。
    try {
      await _cache.write(
        cacheKey,
        jsonEncode(<String, Object?>{
          'statuses': page.statuses,
          'maxId': page.maxId,
        }),
        statusCode: page.httpStatus,
      );
    } catch (e) {
      Log.w('WeiboTimelineSource', '关注流写缓存失败（忽略）：$e');
    }

    final List<ContentItem> items = _parseFriends(page.statuses, fetchedAt: now);
    // 这条日志刻意留：真机上「没有微博卡片」时要能分清是服务端没给、
    // 解析丢了、还是读到了缓存。不含任何凭据。
    Log.d(
      'WeiboTimelineSource',
      '关注流拉取成功：HTTP ${page.httpStatus}，原始 ${page.statuses.length} 条 → '
          '解析出 ${items.length} 条，游标 ${page.maxId == null ? '无' : '有'}',
    );
    return WeiboFriendsFeedPage(
      items: items,
      fetchedAt: now,
      nextMaxId: page.maxId,
      hasMore: page.maxId != null,
    );
  }

  // ------------------------------------------------------------ 内部

  /// 关注流的缓存键：**游标必须进键**（理由与 [_cacheKey] 相同）。
  ///
  /// 键前缀仍是 `friends/since=`：改了会让老用户的旧缓存全部失效，
  /// 而旧缓存里存的是**空结果**（since_id 时代的错误产物），本来也不该复用。
  /// 为彻底避开那批空缓存，键改用 `max=`。
  static String _friendsCacheKey({required String maxId}) =>
      'weibo-api://friends/max=$maxId';

  /// 关注流的原始 status → [ContentItem]。
  ///
  /// 全部挂到虚拟源 [friendsSubscription] 上，使 sourceId 恒为
  /// [friendsSourceId]（已读标记才有依据）；单条解析失败由
  /// [WeiboParser.fromMblog] 自己丢弃，**绝不抛异常**。
  static List<ContentItem> _parseFriends(
    List<Object?> statuses, {
    required DateTime fetchedAt,
  }) {
    final List<ContentItem> out = <ContentItem>[];
    for (final Object? status in statuses) {
      final ContentItem? item = WeiboParser.fromMblog(
        status,
        sub: friendsSubscription,
        fetchedAt: fetchedAt,
      );
      if (item != null) out.add(item);
    }
    return out;
  }

  /// 解关注流缓存。格式不对一律当空结果，绝不让整次刷新失败。
  ///
  /// 只认 `maxId`：`sinceId` 时代的缓存存的是「向更新方向」的游标，
  /// 复用它会把用户重新送回「第 2 页 0 条」的坑里，所以干脆不读。
  static _RawFriendsPage _decodeFriendsCached(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return const _RawFriendsPage(<Object?>[], null);
      final Object? statuses = decoded['statuses'];
      final Object? maxId = decoded['maxId'];
      return _RawFriendsPage(
        statuses is List ? statuses.cast<Object?>() : const <Object?>[],
        maxId is String && maxId.trim().isNotEmpty ? maxId.trim() : null,
      );
    } catch (e) {
      Log.w('WeiboTimelineSource', '关注流缓存解析失败，按空结果处理：$e');
      return const _RawFriendsPage(<Object?>[], null);
    }
  }

  /// 从解析结果里取博主昵称（无条目 / 只有占位值 → null）。
  ///
  /// 取**第一条** item 的 [ContentItem.authorName]：一条订阅就是一个博主，
  /// 同一页里这个字段恒为该博主（转发条目的 `mblog.user` 仍是博主本人，
  /// 原博主在 `origin` 里）。
  ///
  /// 过滤掉「回退值」是必须的：[WeiboParser] 在 `user.screen_name` 缺失时会
  /// 拿 `sub.displayName` 兜底，而那正是「微博 1782488734」—— 若把它当昵称
  /// 写进别名，界面不会有任何变化，却会永久占住别名位（用户手动设置前
  /// 看着像「已修好但没生效」）。所以与兜底文案相同的一律视为「拿不到」。
  static String? _authorNameOf(
    List<ContentItem> items, {
    required Subscription sub,
  }) {
    if (items.isEmpty) return null;
    final String name = items.first.authorName.trim();
    if (name.isEmpty) return null;
    final String placeholder = sub.displayName;
    if (name == placeholder) return null;
    // 兜底文案即使别名已被别处改过，也可能以「微博 <uid>」的形态出现。
    if (name == '微博 ${sub.uid.trim()}') return null;
    return name;
  }

  static const String _emptyHint = '该博主最近没有新微博';

  /// 缓存键：**uid 与游标都要进键**。
  ///
  /// 只按 uid 缓存会让「第 2 页」读到「第 1 页」的内容（游标推进了但键没变）；
  /// 只按游标缓存则会在两个博主之间串数据。
  static String _cacheKey({required String uid, required String sinceId}) =>
      'weibo-api://weiboUser/$uid/since=$sinceId';

  /// 把原始 mblog 列表解析成 [ContentItem]。
  ///
  /// `sourceId` 由 [WeiboParser] 从并 `sub.id` 取（一条订阅 = 一个稳定 sourceId，
  /// 已读标记才靠得住）。解析失败的单条由解析器自己丢弃，**绝不抛异常**：
  /// 上游一次给 11 条，一条畸形不该让整屏消失。
  static List<ContentItem> _parse(
    List<Object?> mblogs, {
    required Subscription sub,
    required DateTime fetchedAt,
  }) {
    final List<ContentItem> out = <ContentItem>[];
    for (final Object? mblog in mblogs) {
      final ContentItem? item = WeiboParser.fromMblog(
        mblog,
        sub: sub,
        fetchedAt: fetchedAt,
      );
      if (item != null) out.add(item);
    }
    return out;
  }

  /// 解缓存内容。格式不对一律当空结果（与 `BiliTimelineSource._decode` 同理）：
  /// 缓存损坏不该让整次刷新失败，重新拉一次就自愈了。
  static _RawPage _decodeCached(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return const _RawPage(<Object?>[], null);
      final Object? mblogs = decoded['mblogs'];
      final Object? sinceId = decoded['sinceId'];
      return _RawPage(
        mblogs is List ? mblogs.cast<Object?>() : const <Object?>[],
        sinceId is String && sinceId.trim().isNotEmpty ? sinceId.trim() : null,
      );
    } catch (e) {
      Log.w('WeiboTimelineSource', '缓存内容解析失败，按空结果处理：$e');
      return const _RawPage(<Object?>[], null);
    }
  }
}

/// 缓存里那一份原始数据的解包结果。
class _RawPage {
  const _RawPage(this.mblogs, this.sinceId);

  final List<Object?> mblogs;
  final String? sinceId;
}

/// 关注流缓存里那一份原始数据的解包结果。
class _RawFriendsPage {
  const _RawFriendsPage(this.statuses, this.maxId);

  final List<Object?> statuses;

  /// 向更早翻页的游标（`max_id`）。语义详见 `WeiboApiClient.buildFriendsUrl`。
  final String? maxId;
}
