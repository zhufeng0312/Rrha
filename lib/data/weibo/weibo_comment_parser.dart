import '../../core/utils/html_text.dart';
import '../../core/utils/time_parse.dart';
import '../models/comment.dart';

/// 微博 `comments/hotflow` JSON → 模型。
///
/// 结构（实测，见 `.env/weibo_comment_probe.md`）：
///
/// ```
/// { "ok": 1,
///   "data": {
///     "data": [ ...评论数组... ],        ← 列表在**两级 data**，不是 cards
///     "max_id": <游标>,                  ← 翻页游标（实测 int，仍按 String 收发）
///     "max_id_type": 0,
///     "total_number": 788
///   } }
/// ```
///
/// ## 三条必须守住的坑
///
/// 1. **评论 id 只读 String 的 `id`**。同值的 `gid` 是 int 且已越过 2^53，
///    走数值会丢精度 —— 本文件**完全不读 `gid`**。
/// 2. **正文 `text` 是 HTML 片段**：`<span class="url-icon"><img alt="[怒]">`
///    要还原成 `[怒]` 再剥标签，否则 UI 上直接出现一堆尖括号。
/// 3. `created_at` 是 `Mon Aug 07 20:15:58 +0800 2023`，必须用
///    [TimeParse.parseWeibo]（年份在**最后**，`parseRss` 解析必失败）。
///
/// ## 二级评论
///
/// 楼中楼**内嵌在同一条一级评论的 `comments[]` 里**（同一份响应即可拿到），
/// 不需要第二个接口。该 key **可选**（无楼中楼时整个 key 不存在），
/// 且只展开一层（`comments[i].comments` 不存在，不递归）。
///
/// ⚠️ 但内嵌的 `comments[]` **恒为前 2 条**（实测）。完整回复要走
/// `comments/hotflowChild`，见 [parseChildPage] 与
/// `WeiboCommentRepository.loadChildReplies`。
class WeiboCommentParser {
  WeiboCommentParser._();

  /// `<img alt="[怒]" src="…">` → `[怒]`。
  ///
  /// 先做这一步再剥标签：一旦先剥标签，alt 文本就丢了，表情只剩下空白。
  static final RegExp _imgAltRe = RegExp(
    r'''<img[^>]*?\salt\s*=\s*["']([^"']*)["'][^>]*>''',
    caseSensitive: false,
  );

  /// 没有 alt 的 `<img>`：直接去掉（微博的图片表情都有 alt，这里只兜底）。
  static final RegExp _plainImgRe = RegExp(r'<img[^>]*>', caseSensitive: false);

  /// 解析一页评论。
  ///
  /// [data] 传**整个响应体**（含 `ok` / `data`），本方法自己找 `data.data[]`。
  /// 任何畸形输入都返回空页而不是抛异常：评论区的容错优先级高于严格性 ——
  /// 一条脏数据不该让整页评论变成「加载失败」。
  static CommentPage parsePage(Object? data) {
    final Map<String, dynamic>? root = _asMap(data);
    if (root == null) return const CommentPage(isEnd: true);

    final Map<String, dynamic>? inner = _asMap(root['data']);
    if (inner == null) return const CommentPage(isEnd: true);

    final List<BiliComment> comments = parseList(inner['data']);
    final String? cursor = _asCursor(inner['max_id']);
    final int total = _asInt(inner['total_number']) ?? 0;

    // 末页判定：**只看「有没有游标」和「列表是否为空」**。
    // 不用「条数 < 页长」：实测第 3 页 18 条时游标仍在，18 是剩余量而不是页长。
    final bool isEnd = comments.isEmpty || cursor == null || cursor.isEmpty;

    return CommentPage(
      comments: comments,
      isEnd: isEnd,
      nextCursor: cursor,
      total: total,
    );
  }

  /// `data.data[]` → 评论列表。
  static List<BiliComment> parseList(Object? data) {
    final List<BiliComment> out = <BiliComment>[];
    if (data is! List) return out;
    for (final Object? e in data) {
      final BiliComment? parsed = parseOne(e);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }

  /// 解析**子评论接口**（`comments/hotflowChild`）的一页。
  ///
  /// ## 与 [parsePage] 的结构性差异（最容易写错的地方）
  ///
  /// | 项 | `hotflow`（一级） | `hotflowChild`（二级） |
  /// | --- | --- | --- |
  /// | 列表路径 | `data.data[]` | **`data`（直接就是 List）** |
  /// | 游标 | 响应里有 `max_id` | **响应里没有**，要取一级节点的 `max_id` |
  ///
  /// 所以这里绝不能复用 [parsePage]：那会把「`data` 是 List」判成畸形输入，
  /// 直接返回空页 —— 表现为「展开了但一条都没有」。
  ///
  /// 返回 `null` = 响应结构不对（不是对象，或 `data` 不是 List）——
  /// 调用方转成「解析失败」。这么严是为了**早暴露路径写错**：
  /// 若把 `data.data` 那套结构喂进来，应该报错而不是静默返回空列表
  /// （否则表现为「展开了但一条都没有」，极难定位）。
  ///
  /// 「本页 0 条」是**正常的到底信号**，返回空列表而不是 null。
  static List<BiliComment>? parseChildPage(Object? data) {
    final Map<String, dynamic>? root = _asMap(data);
    if (root == null) return null;
    // 列表**直接**挂在 `data` 上（一级接口是 `data.data`）。
    final Object? list = root['data'];
    if (list is! List) return null;
    return parseList(list);
  }

  /// 单条评论。返回 null = 这条没有可用的 id（无法稳定标识就丢弃）。
  ///
  /// 只按**显式白名单**取字段：`user.badge.*`（几十个 key）、
  /// `comment_dynamic_message.*`、`report_scheme` 等都是噪声，不整条兜底。
  static BiliComment? parseOne(Object? raw) {
    final Map<String, dynamic>? json = _asMap(raw);
    if (json == null) return null;

    final String id = _asId(json['id']);
    if (id.isEmpty) return null;

    final Map<String, dynamic>? user = _asMap(json['user']);

    // 头像：avatar_hd（高清）优先，回退 profile_image_url / avatar_large。
    final String? avatar = _firstNonEmpty(<Object?>[
      user?['avatar_hd'],
      user?['profile_image_url'],
      user?['avatar_large'],
    ]);

    final String uname =
        _asString(user?['screen_name']) ?? _asString(user?['name']) ?? '未知用户';

    // 楼中楼：可选 key。缺失 = 没有楼中楼，不是错误。
    final List<BiliComment> subs = <BiliComment>[];
    final Object? nested = json['comments'];
    if (nested is List) {
      for (final Object? e in nested) {
        final BiliComment? parsed = parseOne(e);
        if (parsed != null) subs.add(parsed);
      }
    }

    return BiliComment(
      id: id,
      // 微博没有 B 站那套 root/parent 数值层级：一级评论 root=0，
      // 内嵌的二级评论标记为非 0（用自身 id 的 hash 无意义，这里用 1 表示
      // 「这是楼中楼」，UI 只把 root 用于展示判断，不参与请求）。
      root: json.containsKey('rootid') && !_isRootSelf(json) ? 1 : 0,
      // 点赞：**只有一级评论有 `like_count`**，二级评论没有该字段 → 0。
      like: _asInt(json['like_count']) ?? 0,
      // ctime 是 B 站的时间戳语义，微博恒 0；时间走 createdAtOverride。
      ctime: 0,
      createdAtOverride: TimeParse.parseWeibo(_asString(json['created_at'])),
      platformKey: 'weibo',
      uname: uname,
      avatar: avatar,
      message: plainText(_asString(json['text'])),
      replyCount: subs.length,
      // 一级评论没有 is_mblog_author（那是二级评论才有的键）；
      // 拿 user.id 与博主比对需要 uid，而调用方只给 mid。宁可不标也不误标。
      isUp: _asBool(json['is_mblog_author']) ?? false,
      replies: subs,
      // 内嵌即已加载：二级评论就在这份响应里，再点「展开」不该发第二个请求。
      repliesLoaded: subs.isNotEmpty,
      repliesHasMore: false,
      images: parseImages(json),
      // 仅用于显示「共 N 张」：实测存在 pic_num=3 却只给 1 张的情况。
      imageCount: _asInt(json['pic_num']) ?? 0,
      // 多图线索：**原样**带进模型，不在这里跟随短链（那是网络 IO）。
      mixMediaIds: parseMixMediaIds(json),
      // 「共 N 条回复」的 N。⚠️ 含被折叠 / 已删除的回复，**不等于**接口能
      // 返回的条数（实测 68 vs 12），只能用于文案，绝不能当 loading 分母。
      totalReplies: _asInt(json['total_number']) ?? 0,
      // 续拉二级回复的游标。子接口自己不给游标，只能用这个（int 也转 String）。
      replyCursor: _asCursor(json['max_id']),
    );
  }

  /// 多图短链（`mix_media_ids`）→ `List<String>`。
  ///
  /// 实测（见 `.env/weibo_comment_multi_pic_probe.md`）：一条 N 图评论的
  /// `mix_media_ids` 正好有 N 项，每项是 **`http://t.cn/<8 位短码>`**。
  /// `pic` / `pics` 仍然只有 1 张代表图 —— 完整图集**只**存在这里。
  ///
  /// 本方法**只做搬运**：去空白项、去重、保持接口给的原始顺序，
  /// 且前缀**原样保留**（还是 `http://`）。升级 https、跟随重定向、把
  /// `bmiddle` 换 `large` 全部由仓库层 `WeiboCommentPicResolver` 完成。
  ///
  /// 缺失 / 类型不对 / 空 List → 空列表，不抛异常（评论区容错优先）。
  /// 非字符串元素（数字 / null / 嵌套对象）一律跳过：短链只能是字符串。
  static List<String> parseMixMediaIds(Map<String, dynamic> json) {
    final Object? raw = json['mix_media_ids'];
    if (raw is! List) return const <String>[];

    final List<String> out = <String>[];
    for (final Object? e in raw) {
      if (e is! String) continue;
      final String s = e.trim();
      if (s.isEmpty) continue;
      if (out.contains(s)) continue;
      out.add(s);
    }
    return List<String>.unmodifiable(out);
  }

  /// 一条评论的图片 URL 列表（已归一化为 https，已过滤残片）。
  ///
  /// 实测结构（见 `.env/weibo_comment_pics_probe.md`）：
  ///
  /// | 容器 | 形态 | 说明 |
  /// | --- | --- | --- |
  /// | `pic` | Map（单数） | **一级评论的真实字段** |
  /// | `pics` | List（复数） | 二级评论落在它上面；本轮一级样本里是 404 残片 |
  ///
  /// 两个容器**都要读**：实测一级样本在 `pic`、二级样本在 `pics`，
  /// 只读一个就会漏掉一半。每个容器内 `large.url`（原图）优先，
  /// 回退到 `url`（`orj360` 缩略）。
  ///
  /// 明确**不**读的字段：`pic_infos` / `pic_ids` / `picInfo` / `pic_list` /
  /// `pic_urls` —— 探针确认它们在本接口里根本不存在。
  static List<String> parseImages(Map<String, dynamic> json) {
    final List<String> out = <String>[];

    // 1) `pic`：单数 Map。
    _addPicEntry(out, json['pic']);

    // 2) `pics`：复数 List，逐项取；残片在这一步被过滤掉。
    final Object? plural = json['pics'];
    if (plural is List) {
      for (final Object? e in plural) {
        _addPicEntry(out, e);
      }
    }

    // 同一条评论的 `pic` 与 `pics` 可能指向同一张（实测样本 1 就是如此，
    // 只是 `pics` 那份是残片）：去重后再返回，避免 UI 上同一张图出现两次。
    return out.toSet().toList(growable: false);
  }

  /// 读一个图片容器（`pic` 或 `pics[i]`），把可用的 URL 追加到 [out]。
  ///
  /// 取址顺序：`large.url`（原尺寸）→ `url`（长边 360）。
  /// 两个都取不到 / 都被判为残片 → 什么都不加。
  static void _addPicEntry(List<String> out, Object? entry) {
    final Map<String, dynamic>? pic = _asMap(entry);
    if (pic == null) return;

    final Map<String, dynamic>? large = _asMap(pic['large']);
    final String? url = _firstNonEmpty(<Object?>[
      large?['url'],
      pic['url'],
    ]);
    if (url == null) return;

    final String? normalized = _normalizePicUrl(url, pid: pic['pid']);
    if (normalized != null) out.add(normalized);
  }

  /// 归一化图片 URL；判为残片返回 null。
  ///
  /// **残片长什么样**（实测 HTTP 404）：`https://ss1.sinaimg.cn/orj360/&690`
  /// —— 末段文件名以 `&` / `?` / `=` 开头，且 `pid` 为 null。
  /// 这是接口拼 URL 时丢了图片 id 的产物，点开必然是 404 白页，
  /// 所以宁可整条丢掉也不显示「裂图」。
  ///
  /// 同时把 `//host/...` 补成 https（本接口实测全是绝对地址，这里是兜底）。
  static String? _normalizePicUrl(String raw, {Object? pid}) {
    final String url = raw.trim();
    if (url.isEmpty) return null;

    // 末段文件名（query 之前）。
    final String tail = url.split('?').first.split('/').last;

    // pid 为 null 且 URL 里带 &：这就是残片（`&690` 那种尾巴）。
    final bool pidMissing = _asString(pid)?.trim().isNotEmpty != true;
    if (pidMissing && url.contains('&')) return null;

    // 末段以 & / ? / = 开头（或整体就是空文件名）→ 残片。
    if (tail.isEmpty) return null;
    final String first = tail.substring(0, 1);
    if (first == '&' || first == '?' || first == '=') return null;

    // 补协议：`//wx2.sinaimg.cn/...` → `https://wx2.sinaimg.cn/...`。
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('http://')) return 'https://${url.substring(7)}';
    if (url.startsWith('https://')) return url;
    // 其它形态（相对路径等）本接口不该出现，不猜，直接丢。
    return null;
  }

  /// 微博正文 HTML → 纯文本。
  ///
  /// 两步且顺序不能反：
  /// 1. `<img alt="[怒]">` → `[怒]`（先把表情文字捞出来）；
  /// 2. 交给 [HtmlText.toPlainText] 剥标签 + 解实体。
  static String plainText(String? html) {
    if (html == null || html.isEmpty) return '';
    String s = html.replaceAllMapped(_imgAltRe, (Match m) => m.group(1) ?? '');
    s = s.replaceAll(_plainImgRe, '');
    return HtmlText.toPlainText(s);
  }

  /// 游标：**按 String 存**。实测是 int，但服务端随时可能换成字符串，
  /// 混用会在 `int.parse` 上炸；这里只做 `toString()`，不做任何加工。
  static String? _asCursor(Object? v) {
    if (v == null) return null;
    if (v is String) {
      final String s = v.trim();
      return s.isEmpty ? null : s;
    }
    if (v is num) return v.toString();
    return null;
  }

  /// 评论 id：只认字符串形态的 `id` / `mid`。
  ///
  /// **绝不**回落到 `gid`（int，16 位已超 2^53，读出来就是错的 id）。
  static String _asId(Object? v) {
    if (v is String) {
      final String s = v.trim();
      if (s.isNotEmpty) return s;
      return '';
    }
    // 极少见：服务端把 id 传成 num。15~16 位仍在 int64 安全范围内，
    // 转成字符串是安全的（对比 gid 一旦经过 double 才会失真）。
    if (v is int) return '$v';
    return '';
  }

  /// 一级评论的 `rootid` 等于自身 id；二级评论的 `rootid` 指向一级评论 id。
  static bool _isRootSelf(Map<String, dynamic> json) {
    final String rootId = _asString(json['rootid']) ?? '';
    final String selfId = _asId(json['id']);
    return rootId.isEmpty || rootId == selfId;
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is! Map) return null;
    return v.cast<String, dynamic>();
  }

  static String? _asString(Object? v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num) return '$v';
    return null;
  }

  static String? _firstNonEmpty(List<Object?> candidates) {
    for (final Object? c in candidates) {
      final String? s = _asString(c);
      if (s != null && s.trim().isNotEmpty) return s.trim();
    }
    return null;
  }

  static bool? _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final String s = v.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return null;
  }

  /// 数字字段 **num / String 双兼容**（同类字段在微博别处出现过 `"101.9万"`，
  /// 那种解析不出就按 0，不猜）。
  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }
}
