import '../../core/utils/html_text.dart';
import '../../core/utils/id_hash.dart';
import '../models/bili_user.dart';
import '../models/content_item.dart';
import '../models/subscription.dart';
import '../models/video_ref.dart';

/// B 站官方接口的 JSON → [ContentItem]。
///
/// 与 `RssParser` 平行：那个吃 RSSHub 吐的 XML，这个吃官方 API 的 JSON。
/// 两者的产物必须**同形** —— 尤其是 [ContentItem.id] 必须走同一套
/// [IdHash] 算法，否则数据源一换、整条时间线会被错标成「新」。
class BiliContentParser {
  BiliContentParser._();

  /// 单条动态详情（`/x/polymer/web-dynamic/v1/detail` 的 `data.item`）→ [ContentItem]。
  ///
  /// 用于「按动态链接打开」：用户从浏览器复制 `bilibili.com/opus/<id>` 或
  /// `t.bilibili.com/<id>` 过来，App 需要把**单条**动态渲染成详情页。
  ///
  /// 直接复用 [_fromDynamic]：detail 接口返回的 `item` 与 feed/space 的
  /// `items[]` 元素**同形**（同样有 `basic` / `modules` / `id_str`），
  /// 所以字段映射一行都不用重写 —— 这是刻意的，两套映射迟早会漂。
  static ContentItem? fromDynamicDetail(
    Object? raw, {
    required Subscription sub,
    required DateTime fetchedAt,
  }) =>
      fromDynamic(raw, sub: sub, fetchedAt: fetchedAt);

  /// 从动态详情 item 里取**评论入口** `(oid, type)`。
  ///
  /// 这是「按动态链接打开」必须单独提供的能力：`oid` 只有
  /// `basic.comment_id_str` 里那一个正确答案（拿 opus 链接里的数字去凑
  /// 必然 `-404 啥都木有`，见 `BiliClient.dynamicDetail` 的注释）。
  ///
  /// 返回 null = 接口没给（部分转发动态的 `comment_id_str` 是空串）。
  static ({String oid, int type})? commentEntryOf(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final basic = map['basic'] is Map
        ? Map<String, dynamic>.from(map['basic'] as Map)
        : const <String, dynamic>{};
    final oid = _str(basic['comment_id_str']) ?? _str(basic['comment_id']);
    final type = _int(basic['comment_type']) ?? 0;
    if (oid == null || type <= 0) return null;
    return (oid: oid, type: type);
  }

  /// `/x/space/wbi/arc/search` → `data.list.vlist[]` 的一项（投稿视频）。
  ///
  /// 关键字段：`bvid` / `aid` / `title` / `pic` / `created`(秒) / `description`。
  static ContentItem? fromUserVideo(
    Object? raw, {
    required Subscription sub,
    required DateTime fetchedAt,
  }) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);

    final bvid = _str(map['bvid']);
    final aid = _int(map['aid']);
    if (bvid == null && aid == null) return null;

    // 与 RSS 路径对齐：RSS 的 guid 通常就是视频页链接，
    // 这里也用同一条链接做 hash 输入，两边的 id 才能对上。
    final link = bvid != null
        ? 'https://www.bilibili.com/video/$bvid'
        : 'https://www.bilibili.com/video/av$aid';

    final created = _int(map['created']) ?? 0;
    final published = created > 0
        ? DateTime.fromMillisecondsSinceEpoch(created * 1000, isUtc: true)
        : null;

    final cover = BiliUser.normalizeImageUrl(_str(map['pic']));

    return ContentItem(
      id: IdHash.itemId(Platform.bilibili.key, link),
      platform: Platform.bilibili,
      kind: ContentKind.video,
      sourceId: sub.id,
      authorName: _str(map['author']) ?? sub.displayName,
      authorId: '${_int(map['mid']) ?? sub.uid}',
      title: HtmlText.singleLine(_str(map['title']) ?? ''),
      summary: HtmlText.toPlainText(_str(map['description']) ?? ''),
      coverUrl: cover,
      images: cover == null ? const <String>[] : <String>[cover],
      publishedAt: published,
      fetchedAt: fetchedAt,
      link: link,
      videoRef: VideoRef(bvid: bvid, aid: aid, coverUrl: cover, sourceUrl: link),
      // 投稿列表里的条目就是那个视频，评论入口是 aid + type=1。
      commentOid: aid != null && aid > 0 ? '$aid' : null,
      commentType: aid != null && aid > 0 ? 1 : null,
      rawGuid: link,
      hasReliableTime: published != null,
    );
  }

  /// `/x/polymer/web-dynamic/v1/feed/space` → `data.items[]` 的一项（UP 主动态）。
  ///
  /// 动态的 `type` 五花八门（视频投稿 / 图文 / 纯文本 / 转发 / 专栏…），
  /// 这里**不追求穷举**，而是按「能拿到什么就用什么」降级：
  /// 拿不到正文就退标题、拿不到封面就留空，绝不整条丢掉。
  /// 识别不出的类型落 [ContentKind.dynamic]，UI 会当纯文本卡片渲染。
  static ContentItem? fromDynamic(
    Object? raw, {
    required Subscription sub,
    required DateTime fetchedAt,
  }) =>
      _fromDynamic(raw, sub: sub, fetchedAt: fetchedAt, depth: 0);

  /// [depth] 是**原动态的展开层数**：0 = 用户看到的这条，1 = 它的 `orig`。
  ///
  /// 上限钉死在 1：原动态自己还是转发时不再往下展开（[ContentItem.origin] 为 null）。
  /// 这样接口返回的任意嵌套形态都不会让模型变成递归结构。
  static ContentItem? _fromDynamic(
    Object? raw, {
    required Subscription sub,
    required DateTime fetchedAt,
    required int depth,
  }) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);

    final idStr = _str(map['id_str']) ?? _str(map['id_str']) ?? _str(map['dyn_id_str']);
    if (idStr == null) return null;

    final type = _str(map['type']) ?? '';
    final modules = map['modules'] is Map
        ? Map<String, dynamic>.from(map['modules'] as Map)
        : const <String, dynamic>{};

    // 评论入口：动态的 `basic` 段**直接声明**了正确的 (oid, type) 组合。
    //
    // 实测结论（2026-10，脚本 .env/probe_dynamic_basic.py 与 probe_dynamic_comment2.py）：
    //   DYNAMIC_TYPE_AV      -> comment_id_str = aid（视频 aid）,  comment_type = 1
    //   DYNAMIC_TYPE_DRAW    -> comment_id_str = 图片/opus id,     comment_type = 11
    //   DYNAMIC_TYPE_FORWARD -> comment_id_str = 动态 id_str,      comment_type = 17
    // 三者**不能互相顶替**：拿动态 id 配 type=17 去请求图文动态只会得到
    // `-404 啥都木有`（早先就是这么猜的，脚本实测否掉了）。
    // 只有 `basic` 缺失时才回退到「动态 id + 17」——那正是转发动态的形态。
    final basic = map['basic'] is Map
        ? Map<String, dynamic>.from(map['basic'] as Map)
        : const <String, dynamic>{};
    final commentOid =
        _str(basic['comment_id_str']) ?? _str(basic['comment_id']) ?? idStr;
    final commentType = _int(basic['comment_type']) ?? 17;

    final author = modules['module_author'] is Map
        ? Map<String, dynamic>.from(modules['module_author'] as Map)
        : const <String, dynamic>{};

    // 计数：`module_stat.{comment,like,forward}.count`。
    // 探针（tools/probe_ui_fields.dart，2026-10 真实响应）确认：
    // - 三个都是 `{count: int, forbidden: bool}` 形态，取 `count`；
    // - **没有 `repost` 键**，转发数就是 `forward`；
    // - 不是每条动态都有 `module_stat`（部分形态缺段），缺了就填 null，
    //   卡片据此不渲染数字，而不是显示「0」。
    final stat = modules['module_stat'] is Map
        ? Map<String, dynamic>.from(modules['module_stat'] as Map)
        : const <String, dynamic>{};
    int? statCount(String key) {
      final v = stat[key];
      if (v is Map) return _int(Map<String, dynamic>.from(v)['count']);
      // 少数版本直接给 int，一并兼容。
      return _int(v);
    }

    final commentCount = statCount('comment');
    final likeCount = statCount('like');
    final repostCount = statCount('forward');

    final dynamicModule = modules['module_dynamic'] is Map
        ? Map<String, dynamic>.from(modules['module_dynamic'] as Map)
        : const <String, dynamic>{};

    // 正文
    final desc = dynamicModule['desc'] is Map
        ? Map<String, dynamic>.from(dynamicModule['desc'] as Map)
        : const <String, dynamic>{};
    var text = _str(desc['text']) ?? '';

    // major：真正承载内容的字段，随类型不同而不同
    final major = dynamicModule['major'] is Map
        ? Map<String, dynamic>.from(dynamicModule['major'] as Map)
        : const <String, dynamic>{};
    final majorType = _str(major['type']) ?? '';

    final archive = major['archive'] is Map
        ? Map<String, dynamic>.from(major['archive'] as Map)
        : null;
    final opus = major['opus'] is Map
        ? Map<String, dynamic>.from(major['opus'] as Map)
        : null;

    // 新版动态（opus 形态）把正文放在 `major.opus.summary.text`。
    // 少了这层回退，图文动态会**整片退化成「（无标题）」**——
    // 真机上就是这么撞见的（151 条里有十几条标题为空）。
    if (text.trim().isEmpty && opus != null) {
      final summary = opus['summary'];
      if (summary is Map) {
        text = _str(Map<String, dynamic>.from(summary)['text']) ?? '';
      }
    }

    // ---- 形态判定 ----
    String bvid = '';
    String title = '';
    String link = 'https://t.bilibili.com/$idStr';
    var kind = ContentKind.dynamic;

    // 图片统一走 _extractImages：图文动态**全部**图片都拿得到，
    // 不再像早先那样只取第一张（那正是「多图只显示第一张」的根因）。
    var images = _extractImages(major);

    if (archive != null) {
      // 视频投稿
      kind = ContentKind.video;
      bvid = _str(archive['bvid']) ?? '';
      title = _str(archive['title']) ?? '';
      final cover = BiliUser.normalizeImageUrl(_str(archive['cover']));
      images = cover == null ? const <String>[] : <String>[cover];
      if (bvid.isNotEmpty) link = 'https://www.bilibili.com/video/$bvid';
    } else if (opus != null) {
      title = _str(opus['title']) ?? '';
    }

    if (type == 'DYNAMIC_TYPE_FORWARD') {
      kind = ContentKind.repost;
    } else if (majorType == 'MAJOR_TYPE_ARTICLE') {
      kind = ContentKind.article;
    }

    // 标题兜底：动态常常没有标题，用正文首行；纯图片动态本来就没有文字，
    // 就如实标成「[图片]」，而不是丢给 UI 去显示「（无标题）」。
    final effectiveTitle = title.trim().isNotEmpty
        ? HtmlText.singleLine(title)
        : (text.trim().isNotEmpty
            ? HtmlText.truncate(HtmlText.singleLine(text), 60)
            : '[图片]');

    final pubTs = _int(author['pub_ts']) ?? 0;
    final published = pubTs > 0
        ? DateTime.fromMillisecondsSinceEpoch(pubTs * 1000, isUtc: true)
        : null;

    // 全空（连图片都没有）说明这条动态没有任何可展示内容（B 站偶发的占位项）。
    // ⚠️ 这里必须看**原始** title / 正文，不能拿上面兜底后的 effectiveTitle ——
    // 它现在保证非空，用它判断会导致「永不丢弃」。
    // 判定依据从「首图」升级为「全部图片」：`images` 为空等价于旧代码的
    // `cover.isEmpty`（images 非空时 first 必非空），语义没有放宽。
    if (title.trim().isEmpty && text.trim().isEmpty && images.isEmpty) {
      return null;
    }

    // 视频类动态（major.archive）在语义上**就是那条投稿视频**，
    // 所以 id 必须用视频链接算 —— 否则同一个视频会分别从「投稿列表」和
    // 「动态流」各进来一次，时间线上出现两张一模一样的卡片
    // （真机首测就撞上了这个：32 条里有 20 条是重复的）。
    final idKey = bvid.isNotEmpty
        ? 'https://www.bilibili.com/video/$bvid'
        : 'https://t.bilibili.com/$idStr';

    return ContentItem(
      id: IdHash.itemId(Platform.bilibili.key, idKey),
      platform: Platform.bilibili,
      kind: kind,
      sourceId: sub.id,
      authorName: _str(author['name']) ?? sub.displayName,
      authorId: '${_int(author['mid']) ?? sub.uid}',
      // 头像：`module_author.face`（探针确认每条动态都有）。
      //
      // 这里**必须过 normalizeImageUrl**：服务端给的是明文 `http://i0.hdslb.com/...`，
      // Android 9+ 默认禁明文，直接用会一张都加载不出来（图片全走 errorBuilder）。
      // 这正是「B 站卡片不显示头像」的根因之一：早先这个字段**根本没被赋值**。
      authorAvatar: BiliUser.normalizeImageUrl(_str(author['face'])),
      title: effectiveTitle,
      summary: HtmlText.toPlainText(text),
      coverUrl: images.isEmpty ? null : images.first,
      images: images,
      origin: _parseOrigin(map, sub: sub, fetchedAt: fetchedAt, depth: depth),
      publishedAt: published,
      fetchedAt: fetchedAt,
      link: link,
      videoRef: bvid.isEmpty
          ? null
          : VideoRef(
              bvid: bvid,
              coverUrl: images.isEmpty ? null : images.first,
              sourceUrl: link,
            ),
      commentOid: commentOid,
      commentType: commentType,
      commentCount: commentCount,
      likeCount: likeCount,
      repostCount: repostCount,
      rawGuid: idKey,
      hasReliableTime: published != null,
    );
  }

  // ---------------------------------------------------------------- 工具

  /// 从 `module_dynamic.major` 里抽出**全部**图片地址。
  ///
  /// 实测（2026-10-16，脚本 `.env/probe_media_repost.py` / `probe_media_repost2.py`，
  /// 抓 `feed/all` 连翻 6 页共 121 条真实动态）：
  /// - 新版形态的图片在 `major.opus.pics[]`，元素字段是
  ///   `url` / `width` / `height` / `size` / `live_url` / `aigc` / `warning`
  ///   —— **不是 `src`**（照抄旧代码的 `src` 会一条图都取不到）；
  /// - 旧形态在 `major.draw.items[]`，元素字段才是 `src`（本批 0 次，但仍要兼容）；
  /// - 服务端给的地址是明文 `http://i0.hdslb.com/...`，必须过
  ///   [BiliUser.normalizeImageUrl] 转 https（否则 Android 9+ 默认禁明文，直接裂图）；
  /// - 张数最多见过 9 张（分布 {1:34, 2:2, 3:1, 5:1, 7:4, 8:1, 9:1}），
  ///   所以详情页用九宫格、缩略图必须带 `cacheWidth`。
  ///
  /// 顺序：opus 优先（新版服务端即使两者都在，opus 才是完整那份），
  /// draw 仅作兜底。返回顺序即用户看图顺序，**不要排序**。
  static List<String> _extractImages(Map<String, dynamic> major) {
    final out = <String>[];

    void addAll(Object? list, String Function(Map<String, dynamic>) pick) {
      if (list is! List) return;
      for (final e in list) {
        if (e is! Map) continue;
        final url = BiliUser.normalizeImageUrl(pick(Map<String, dynamic>.from(e)));
        if (url == null) continue;
        if (out.contains(url)) continue; // 去重：同一张图在 pics 与 items 里都出现时不重复渲染
        out.add(url);
      }
    }

    final opus = major['opus'];
    if (opus is Map) {
      addAll(Map<String, dynamic>.from(opus)['pics'], (m) => _str(m['url']) ?? '');
    }
    final draw = major['draw'];
    if (draw is Map) {
      // 旧形态字段名是 `src`，个别版本的接口给 `url`，两个都收。
      addAll(
        Map<String, dynamic>.from(draw)['items'],
        (m) => _str(m['src']) ?? _str(m['url']) ?? '',
      );
    }

    return out;
  }

  /// 展开被转发的原动态，**只展开一层**（[depth] 上限 1）。
  ///
  /// `orig` 不是 Map / 为空 → null；原动态的 `id_str` 与主动态相同 → 丢弃
  /// （防自引用）。实测 121 条样本里转发 36 条、`orig` **从未缺失**，
  /// `orig` 内部结构与本条完全同形（同样有 `basic` / `id_str` / `modules` /
  /// 甚至嵌套 `orig`），所以直接复用 [_fromDynamic] 递归即可，不必另写一套字段映射。
  ///
  /// ⚠️ 自引用比较**必须用裸 `id_str`，不能用 [ContentItem.id]**。
  /// 原因：视频类动态的 id 是用 bvid 链接算的（为了跟投稿列表去重，见上文），
  /// 于是「转发了别人发的同一个视频」时，主动态与原动态的 **id 完全相同** ——
  /// 用 id 比较会把这种**完全正常的**转发误判成自引用、把原动态整块丢掉。
  /// 单测里就是先写成 id 比较才撞出这个坑的。而 `id_str` 标识的是**动态本身**，
  /// 只有服务端真的回填错误时才会两边相同，那才是要拦的情况。
  ///
  /// ⚠️ 原动态拿不到评论入口：`orig.basic.comment_id_str` 实测是**空串**、
  /// `comment_type` 是 `0`，所以原动态独立页会落进详情页既有的
  /// 「接口没有给出这条内容的评论入口」兜底文案 —— 这是如实降级，不是 bug。
  static ContentItem? _parseOrigin(
    Map<String, dynamic> map, {
    required Subscription sub,
    required DateTime fetchedAt,
    required int depth,
  }) {
    if (depth >= 1) return null;
    final raw = map['orig'];
    if (raw is! Map || raw.isEmpty) return null;

    final rawMap = Map<String, dynamic>.from(raw);
    final selfRawId = _str(map['id_str']) ?? _str(map['dyn_id_str']);
    final originRawId = _str(rawMap['id_str']) ?? _str(rawMap['dyn_id_str']);
    if (selfRawId != null && originRawId != null && selfRawId == originRawId) {
      return null;
    }

    return _fromDynamic(rawMap, sub: sub, fetchedAt: fetchedAt, depth: depth + 1);
  }

  static int? _int(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }
}
