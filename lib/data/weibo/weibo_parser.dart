import 'dart:convert';

import '../../core/utils/html_text.dart';
import '../../core/utils/id_hash.dart';
import '../../core/utils/time_parse.dart';
import '../models/content_item.dart';
import '../models/subscription.dart';
import '../models/video_ref.dart';

/// 微博 `getIndex` 接口的 JSON → [ContentItem]。
///
/// 与 `BiliContentParser` 平行：那个吃 B 站官方接口的动态/投稿 JSON，这个吃
/// `m.weibo.cn/api/container/getIndex` 的 `cards[].mblog`。产物必须**同形** ——
/// 尤其是 [ContentItem.id] 必须走同一套 [IdHash] 算法，否则数据源一换、
/// 整条时间线会被错标成「新」。
///
/// ## 实测依据（不要凭想象改这里）
///
/// 所有字段名都来自真机采样存档，见 `.env/weibo_mblog_structure.md`、
/// `.env/weibo_mblog_structure2.md`、`.env/weibo_mblog_structure3.md`：
///
/// - `mblog.text` 是 **HTML**（表情是 `<span class="url-icon"><img alt="[酷]">`），
///   必须清洗；长文（`isLongText=true`）在列表接口里给的是**截断预览**，
///   `textLength` 会大于 `text` 的实际长度。
/// - `mblog.id` / `mid` 是 **String**（19 位，两者同值），而 `mblog.user.id` 是
///   **int** —— 类型不统一，各自处理，不能一把梭。
/// - `mblog.created_at` 形如 `Mon Aug 07 20:15:27 +0800 2023`，**年份在最后**，
///   走 [TimeParse.parseWeibo]（不能复用 `parseRss`，理由见那个方法）。
/// - `mblog.pics` 是 `List<Map>`，元素 5 个 key：`geo`/`large`/`pid`/`size`/`url`；
///   `url` 是 orj360 缩略，`large.url` 是 mw2000 原图，**都是 https 绝对地址**。
/// - `mblog.page_info` 不一定是视频：实测见过 `type="webpage"`（外链卡）与
///   `type="topic"`（超话卡），两者**都没有** `media_info`。判视频必须以
///   `media_info` 是否存在且非空为准。
/// - `mblog.retweeted_status`（31 条样本里 4 条）与主 mblog **完全同形**：
///   `id`/`mid`/`created_at`/`text`/`user`/`pics` 全同名、同类型，配图同样在
///   `pics[i].large.url`。所以转发分支直接递归复用本类的映射，不另写字段表。
/// - 旧版单图字段 `thumbnail_pic` / `bmiddle_pic` / `original_pic` 存在但**不用**：
///   只能表达第一张（多图会丢），且 `bmiddle_pic` 是明文 `http://`（Android 9+ 裂图）。
///
/// 任何一步拿不到关键字段就返回 null（丢弃这一条），**绝不抛异常**：
/// 上游是一屏 11~30 条，一条畸形不该让整屏消失。
class WeiboParser {
  WeiboParser._();

  /// 原微博最多展开一层（与 [ContentItem.origin] 的约定一致：`origin.origin`
  /// 恒为 null，序列化因此不会无限递归）。
  static const int _maxOriginDepth = 1;

  /// 标题截断长度：与 [ContentItem.displayTitle] 的 60 字保持一致。
  static const int _titleMaxChars = 60;

  /// 一条 mblog → [ContentItem]。失败返回 null（不抛）。
  ///
  /// [depth] 是**原微博的展开层数**：0 = 用户看到这条，1 = 它的
  /// `retweeted_status`。上限见 [_maxOriginDepth]。
  static ContentItem? fromMblog(
    Object? mblog, {
    required Subscription sub,
    required DateTime fetchedAt,
    int depth = 0,
  }) {
    if (mblog is! Map) return null;
    // 统一收敛成 `Map<String, Object?>`：后面所有取值都基于它，
    // 免得每个辅助方法都要重新判一次动态类型。
    final Map<String, Object?> m = mblog.cast<String, Object?>();

    // `id` 与 `mid` 实测同值，但都有才有保底：优先 mid（它才是 status URL
    // 用的那个），退回 id。两者都缺 → 这条没有稳定键，只能丢。
    final String? mid = _str(m['mid']) ?? _str(m['id']);
    if (mid == null) return null;

    // id 契约：**用 status 网页地址做 hash 输入**。
    // 为什么不用裸 mid：RSSHub 那条链路未来若也并入微博，其 guid 就是这条
    // 网页地址；两边输入一致，id 才能对上（B 站就是这么做的，见
    // BiliContentParser 对 bvid 链接的处理）。
    final String link = 'https://m.weibo.cn/status/$mid';

    final Map<String, Object?> user = _map(m['user']);

    // 正文：**先清洗再判定空**。HTML 里全是标签的「纯表情微博」清洗后可能
    // 只剩空串，那时 title 必须是空串，而不是伪造一个占位文案。
    final String rawText = _str(m['text']) ?? '';
    final String summary = HtmlText.toPlainText(rawText);

    final DateTime? published = TimeParse.parseWeibo(_str(m['created_at']));

    // 图片：**全部**取，优先 large.url（mw2000 原图），缺失再退 url。
    final List<String> images = _extractImages(m);

    final Object? retweeted = m['retweeted_status'];
    final bool hasRetweet = retweeted is Map && retweeted.isNotEmpty;
    final Object? mediaInfo = _mediaInfoOf(m);
    final bool hasVideo = mediaInfo is Map && mediaInfo.isNotEmpty;

    // 形态判定优先级：视频 > 转发 > 动态。
    //
    // 为什么视频在前：一条「转发了一条视频」的微博，主体内容仍是可播的视频，
    // 归成 repost 会让详情页丢掉播放器。两者的 origin 分支不受影响。
    final ContentKind kind = hasVideo
        ? ContentKind.video
        : (hasRetweet ? ContentKind.repost : ContentKind.dynamic);

    final String? coverUrl = images.isEmpty ? null : images.first;

    return ContentItem(
      id: IdHash.itemId(Platform.weibo.key, link),
      platform: Platform.weibo,
      kind: kind,
      sourceId: sub.id,
      authorName: _str(user['screen_name']) ?? sub.displayName,
      // `user.id` 实测是 **int**（与 mblog.id 的 String 不同），统一转字符串。
      authorId: _str(user['id']),
      // 头像优先大图；`profile_image_url` 是 180px 方裁，只作兜底。
      authorAvatar: _str(user['avatar_hd']) ??
          _str(user['profile_image_url']) ??
          _str(user['avatar_large']),
      title: _title(summary),
      summary: summary,
      coverUrl: coverUrl,
      images: images,
      origin: _parseOrigin(
        retweeted,
        sub: sub,
        fetchedAt: fetchedAt,
        depth: depth,
      ),
      publishedAt: published,
      fetchedAt: fetchedAt,
      link: link,
      videoRef: hasVideo
          ? _videoRefOf(
              m['page_info'],
              coverUrl: coverUrl,
              sourceUrl: link,
            )
          : null,
      // 微博评论区走 WebView，不走 App 内评论接口，所以 oid/type 一律不填。
      rawGuid: link,
      // 计数：微博的命名很反直觉 —— 点赞叫 `attitudes_count`（不是 like_count）。
      // 缺字段就留 null（卡片不渲染数字），不拿 0 冒充。
      commentCount: _intOf(m['comments_count']),
      likeCount: _intOf(m['attitudes_count']),
      repostCount: _intOf(m['reposts_count']),
      // 时间解析失败就是 false —— 绝不拿 fetchedAt 冒充发布时间。
      hasReliableTime: published != null,
    );
  }

  /// 微博的计数既可能是 int，也可能是数字字符串（个别接口版本）。
  ///
  /// 失败返回 **null** 而不是 0：`int.tryParse('')` 之类的坏数据不能被当成
  /// 「确实 0 条评论」，否则卡片会显示一个假的 0。
  static int? _intOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// 从响应体里取出 cards 中的 mblog 列表（只取 `card_type == 9` 且 mblog 非空的）。
  ///
  /// `card_type == 9` 是博文卡；header 卡（11）、广告卡等一律跳过 —— 实测第 1 页
  /// 11/11 都是 9，但**不能假设**，因为一旦混进 header 卡就会多出一条空微博。
  ///
  /// 非法 JSON / 结构不符一律返回空列表，绝不抛异常。
  static List<Object?> extractMblogs(Object? responseBody) {
    final Object? decoded = _decode(responseBody);
    final Map<String, Object?> root = _map(decoded);
    final Map<String, Object?> data = _map(root['data']);
    final Object? cards = data['cards'];
    if (cards is! List) return const <Object?>[];

    final List<Object?> out = <Object?>[];
    for (final Object? card in cards) {
      if (card is! Map) continue;
      // 数字与字符串两种形态都认（服务端个别版本给 "9"）。
      if (!_isPostCard(card['card_type'])) continue;
      final Object? mblog = card['mblog'];
      if (mblog is Map && mblog.isNotEmpty) out.add(mblog);
    }
    return out;
  }

  /// 从 `GET /feed/friends` 的响应体里取出 `data.statuses[]`。
  ///
  /// ## 为什么不能复用 [extractMblogs]
  ///
  /// 两个接口的**结构不同**（真机探针已确认）：
  ///
  /// - `api/container/getIndex` → `data.cards[i].mblog = {...}`（有外壳）；
  /// - `feed/friends` → `data.statuses[i] = {...}`（**裸 mblog**，没有 `mblog`
  ///   外壳，元素本身就是 `id`/`mid`/`text`/`user`/`created_at`/`pics` 那一套）。
  ///
  /// 拿 `extractMblogs` 解关注流会得到「200 + ok=1 + 0 条」的假阴性 —— 这正是
  /// 探针第一轮把关注流误判成「不可用」的原因。所以拆成两个入口，但**产物同形**：
  /// 取出来的每个元素仍然直接喂给 [fromMblog]（mblog 形状完全一致），
  /// 于是 id 契约（status 网页地址 → hash）、字段映射、原微博展开全部共用一套。
  ///
  /// 非法 JSON / 结构不符 / 空列表一律返回空列表，绝不抛异常（与 [extractMblogs]
  /// 同一条纪律：上游偶尔给 HTML 抗风控页）。
  static List<Object?> extractStatuses(Object? responseBody) {
    final Object? decoded = _decode(responseBody);
    final Map<String, Object?> root = _map(decoded);
    final Map<String, Object?> data = _map(root['data']);
    final Object? statuses = data['statuses'];
    if (statuses is! List) return const <Object?>[];

    final List<Object?> out = <Object?>[];
    for (final Object? status in statuses) {
      // 元素类型不收死成 Map：解析器自己要容错，这里只把明显不是对象的扔掉。
      if (status is Map && status.isNotEmpty) out.add(status);
    }
    return out;
  }

  // ---------------------------------------------------------------- 内部

  /// `card_type` 是否为博文卡（实测是 int 9，容错字符串 "9"）。
  static bool _isPostCard(Object? raw) {
    if (raw is num) return raw.toInt() == 9;
    if (raw is String) return int.tryParse(raw.trim()) == 9;
    return false;
  }

  /// 抽**全部**配图地址。
  ///
  /// 实测（`.env/weibo_mblog_structure2.md` §A）：`pics` 是 `List<Map>`，
  /// 元素 5 个一级 key（`pid`/`url`/`size`/`geo`/`large`）：
  /// - `pics[i].url` → `https://wx2.sinaimg.cn/orj360/<pid>.jpg`（长边 ~360 缩略）
  /// - `pics[i].large.url` → `https://wx2.sinaimg.cn/mw2000/<pid>.jpg`（原图尺度）
  ///
  /// 所以原图必须取 `large.url`；只有 `url` 的旧数据回退到 `url`，
  /// 而不是整张丢掉。全部去空、去重，**保持服务端顺序**（用户看图顺序）。
  ///
  /// 注意：`page_info` 的封面（`page_pic.url`）**不占** `pics`，不要合并进来 ——
  /// 那是外链卡的预览图，混进九宫格会让张数变多。
  static List<String> _extractImages(Map<String, Object?> mblog) {
    final Object? raw = mblog['pics'];
    if (raw is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? e in raw) {
      if (e is! Map) continue;
      final String? url = _normalizeUrl(
        _str(_map(e['large'])['url']) ?? _str(e['url']),
      );
      if (url == null || out.contains(url)) continue;
      out.add(url);
    }
    return List<String>.unmodifiable(out);
  }

  /// 把图片地址归一化成 https 绝对地址（`//host/x.jpg` → `https://host/x.jpg`）。
  ///
  /// 实测微博的图片**已经**是 https 绝对地址，这里只是兜底：协议相对写法一旦
  /// 出现，Android 9+ 的明文策略会直接让图裂掉。
  static String? _normalizeUrl(String? url) {
    if (url == null) return null;
    final String s = url.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('http://')) return 'https://${s.substring(7)}';
    return s;
  }

  /// `page_info.media_info` 节点；不存在返回 null。
  static Object? _mediaInfoOf(Map<String, Object?> mblog) {
    final Object? pageInfo = mblog['page_info'];
    if (pageInfo is! Map) return null;
    return pageInfo['media_info'];
  }

  /// 从 `page_info` 里取可播信息。
  ///
  /// ## 字段名**已由真机实测钉死**（2026-10-27，见 `.env/weibo_video_probe.md`）
  ///
  /// 早先这里是「按候选键名逐个试」的猜测实现，注释也写明「本分支尚未经真实
  /// 样本实测」。现在有了第一条真实视频样本（`page_info.type == "video"`），
  /// 实测结构如下 —— **改这里之前先看这张表**：
  ///
  /// ```
  /// page_info.type              : "video"
  /// page_info.object_id         : "1034:5358370303967334"
  /// page_info.title             : "来唱轻松快乐的生日快乐歌吧"
  /// page_info.video_orientation : "vertical" | "horizontal"
  /// page_info.play_count        : "6万次播放"（中文串，不可直接转数字）
  /// page_info.page_pic.url      : https://wx4.sinaimg.cn/.../xxx.jpg  ← 封面在这
  /// page_info.media_info        : **只有 3 个 key**
  ///   media_info.stream_url     : https://f.video.weibocdn.com/o0/xxx.mp4?Expires=...
  ///   media_info.stream_url_hd  : 同上（本例与 stream_url 同值）
  ///   media_info.duration       : **double 秒**（例 26.331）
  /// page_info.urls              : mp4_720p_mp4 / mp4_hd_mp4 / mp4_ld_mp4
  /// ```
  ///
  /// ## 两条硬结论（都有实测证据，别改回去）
  ///
  /// 1. **封面不在 `media_info` 里**，在 `page_info.page_pic.url`。
  ///    早先从 `media_info.cover_url / cover / big_pic_info` 找，
  ///    这三个 key 在本例里**一个都不存在** → 视频卡片永远没有封面。
  /// 2. **直链必须带 `Referer: https://weibo.com/` 才能下**：
  ///    实测不带 → `HTTP 403 · text/html · len=238`；
  ///    带上 → `HTTP 200 · video/mp4 · len=2730923`。
  ///    Referer 由播放页负责注入（见 `SimpleVideoPage`），本函数只提供地址。
  ///
  /// `directVideoUrl` 为 null = 宁可不可播，也不填一个错地址：详情页会落到
  /// 「这条视频没有可播地址」的既有兜底，而不是拿错 URL 去请求 404。
  static VideoRef _videoRefOf(
    Object? pageInfo, {
    required String? coverUrl,
    required String sourceUrl,
  }) {
    final Map<String, Object?> page = _map(pageInfo);
    final Map<String, Object?> info = _map(page['media_info']);
    final Map<String, Object?> urls = _map(page['urls']);

    // 直链优先级：media_info 的两档（实测口径），再退 page_info.urls 的三档。
    // 顺序即优先级：先高清，再普通。
    const List<String> candidates = <String>[
      'stream_url_hd',
      'stream_url',
    ];
    String? direct;
    for (final String key in candidates) {
      final String? candidate = _normalizeUrl(_str(info[key]));
      if (candidate != null) {
        direct = candidate;
        break;
      }
    }
    if (direct == null) {
      for (final String key in <String>[
        'mp4_720p_mp4',
        'mp4_hd_mp4',
        'mp4_ld_mp4',
      ]) {
        final String? candidate = _normalizeUrl(_str(urls[key]));
        if (candidate != null) {
          direct = candidate;
          break;
        }
      }
    }

    // 封面：**实测在 page_info.page_pic.url**，media_info 里没有封面字段。
    // 仍保留 mblog 首图兜底（视频微博也可能同时带 pics，历史数据里有）。
    final String? pageCover = _normalizeUrl(_str(_map(page['page_pic'])['url']));
    final String? mediaCover = _normalizeUrl(_str(info['cover_url']));

    // 时长：media_info.duration 是 **double 秒**（26.331）。
    final Duration? duration = _durationOf(info['duration']);

    // 方向：video_orientation == "vertical" 才认竖屏；其余/缺失一律不猜。
    final String? orientation = _str(page['video_orientation'])?.toLowerCase();

    return VideoRef(
      directVideoUrl: direct,
      coverUrl: pageCover ?? mediaCover ?? coverUrl,
      sourceUrl: sourceUrl,
      duration: duration,
      isVertical: orientation == null ? null : orientation == 'vertical',
    );
  }

  /// `media_info.duration` → [Duration]。
  ///
  /// 实测是 **double 秒**（`26.331`）。但服务端个别版本可能给毫秒整数，
  /// 所以按量级判断：**小于 10000 当作秒**（一条微博视频不会是 9999 秒≈2.7h
  /// 以上；而毫秒值一定远大于它）。这是有意的、注释在案的经验判断，
  /// 不是随手写的魔法数。
  static Duration? _durationOf(Object? raw) {
    final double? value = raw is num
        ? raw.toDouble()
        : (raw is String ? double.tryParse(raw.trim()) : null);
    if (value == null || value <= 0) return null;
    // < 10000 视为「秒」，否则视为「毫秒」。
    final int ms = value < 10000 ? (value * 1000).round() : value.round();
    if (ms <= 0) return null;
    return Duration(milliseconds: ms);
  }

  /// 展开被转发的原微博，**只展开一层**。
  ///
  /// ## 同形是**实测确认**的，不是假设
  ///
  /// 3 页深度采样（`.env/weibo_mblog_structure3.md`）在 31 条 mblog 里抓到
  /// **4 条** `retweeted_status` 真实样本，展开后确认它与主 mblog **完全同形**：
  ///
  /// ```
  /// mblog.retweeted_status.id         : String : "5346379155378373"
  /// mblog.retweeted_status.mid        : String : "5346379155378373"
  /// mblog.retweeted_status.created_at : String : "Wed Sep 23 18:33:04 +0800 2026"
  /// mblog.retweeted_status.text       : String : HTML（含 <br /> 与 &#129392; 实体）
  /// mblog.retweeted_status.user.id    : int    : 7736078413   ← 仍是 int
  /// mblog.retweeted_status.user.screen_name    : String : "蓝色香蕉人"
  /// mblog.retweeted_status.user.avatar_hd      : String : https 绝对地址
  /// mblog.retweeted_status.pics[0].large.url   : String : https://wx4.sinaimg.cn/mw2000/….jpg
  /// ```
  ///
  /// 所以直接递归复用 [fromMblog] 就是**正确做法**，不需要另写一套转发字段表：
  /// id 契约（status URL → hash）、created_at 格式、pics 的 `large.url` 原图优先，
  /// 这些规则在两层上是同一套。
  ///
  /// 原微博的 `sourceId` 沿用**同一条订阅**：它是同一个人在时间线里看到的一条内容，
  /// 给它编一个新 sourceId 会让「按订阅过滤」把 origin 挡在外面。
  ///
  /// 只展开一层（[_maxOriginDepth]）：[ContentItem.origin] 的约定就是
  /// `origin.origin` 恒为 null，序列化因此不会无限递归。
  static ContentItem? _parseOrigin(
    Object? retweeted, {
    required Subscription sub,
    required DateTime fetchedAt,
    required int depth,
  }) {
    if (depth >= _maxOriginDepth) return null;
    if (retweeted is! Map || retweeted.isEmpty) return null;
    return fromMblog(
      retweeted,
      sub: sub,
      fetchedAt: fetchedAt,
      depth: depth + 1,
    );
  }

  /// 标题 = 清洗后正文的**首行**截断。
  ///
  /// 与 [ContentItem.displayTitle] 同一套做法（那里是「title 空则退 summary 首行」，
  /// 这里是「直接把首行塞进 title」），但有一处关键差异：**正文为空时返回空串**，
  /// 不伪造 `（无标题）`。伪造会把「纯图微博」和「正文解析失败」混成同一种展示，
  /// 反而看不出问题；空 title 交给 [ContentItem.displayTitle] 兜底才是单点决定。
  static String _title(String summary) {
    final String line = HtmlText.singleLine(summary);
    if (line.isEmpty) return '';
    return HtmlText.truncate(line, _titleMaxChars);
  }

  static Object? _decode(Object? body) {
    if (body == null) return null;
    if (body is! String) return body; // 已经是解好的结构
    if (body.isEmpty) return null;
    try {
      // 与 `WeiboApiDiag` 同一条解析路径（都是 `dart:convert` 的 jsonDecode），
      // 保证「诊断里看得见」和「解析器吃得到」是同一份数据。
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// 容错取 Map：非 Map 一律当空 Map，调用方不必再判 null。
  ///
  /// 键统一成 String：JSON 对象的 key 必然是字符串，这里 `cast` 只是把
  /// `Map<dynamic, dynamic>` 收敛成静态类型，不会做任何值转换。
  static Map<String, Object?> _map(Object? v) {
    if (v is! Map) return const <String, Object?>{};
    return v.cast<String, Object?>();
  }

  /// 容错取字符串：null / 空串 / 空白都当「没有」。
  ///
  /// 数字也能转（`user.id` 是 int，`mid` 在个别版本可能是数字）——
  /// 19 位 mid 走 `num.toString()` 会丢精度，但那种情况下源数据本身已经错了，
  /// 这里**只做转换不做修复**，不去猜一个可能错的 id。
  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is String) {
      final String s = v.trim();
      return s.isEmpty ? null : s;
    }
    if (v is num || v is bool) return '$v';
    return null;
  }
}
