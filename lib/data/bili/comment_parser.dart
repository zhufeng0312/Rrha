import '../../core/config/app_config.dart';
import '../models/bili_user.dart';
import '../models/comment.dart';

/// B 站评论 JSON → 模型。
///
/// 接口结构（`x/v2/reply/wbi/main`）与旧的 `x/v2/reply` 高度相似，
/// 但游标字段不同：新接口用 `cursor.pagination_reply.next_offset`，
/// 实测是**裸游标串**（形如 `CAESEDE4MzUwNzg0NzQyOTc0OTYa`），不是 pn 递增，
/// 也不是「自带 JSON 的字符串」—— 早先的注释把它写成后者，是错的。
///
/// 约定：[CommentPage.nextCursor] 只保存**裸游标值**，
/// 包装成 `pagination_str` 的 JSON 只发生在 `BiliClient.comments()` 一处。
class CommentParser {
  CommentParser._();

  static CommentPage parseMain(Map<String, dynamic> json, {int upMid = 0}) {
    final data = json['data'];
    if (data is! Map) return const CommentPage(isEnd: true);
    final map = Map<String, dynamic>.from(data);

    final comments = _parseList(map['replies'], upMid);
    final top = _parseList(map['top_replies'], upMid);

    String? next;
    var isEnd = false;

    final cursor = map['cursor'];
    if (cursor is Map) {
      final c = Map<String, dynamic>.from(cursor);
      isEnd = c['is_end'] as bool? ?? false;
      final paging = c['pagination_reply'];
      if (paging is Map) {
        final no = paging['next_offset'];
        if (no is String && no.trim().isNotEmpty) next = no.trim();
      }
      // 少数版本把 next 直接放在 `cursor.next`，那是旧 `x/v2/reply` 的
      // **页码语义**，与 wbi/main 的 offset 游标不是一回事，不能互相冒充：
      // 旧实现给它塞了字面量 `{"offset":""}`，等价于每页都从第一页开始
      // （「加载更多」原地打转）。既然还原不出合法游标，就按到底处理。
    }

    if (next == null || next.isEmpty) isEnd = true;

    var total = 0;
    final page = map['page'];
    if (page is Map) {
      total = (page['count'] as num?)?.toInt() ?? 0;
    }

    return CommentPage(
      topComments: top,
      comments: comments,
      isEnd: isEnd,
      nextCursor: next,
      total: total,
    );
  }

  static SubCommentPage parseReplies(
    Map<String, dynamic> json, {
    int upMid = 0,
    int pageSize = AppConfig.subCommentPageSize,
  }) {
    final data = json['data'];
    if (data is! Map) return const SubCommentPage();
    final map = Map<String, dynamic>.from(data);

    final list = _parseList(map['replies'], upMid);
    var count = 0;
    final page = map['page'];
    if (page is Map) {
      count = (page['count'] as num?)?.toInt() ?? 0;
    }
    return SubCommentPage(
      comments: list,
      hasMore: list.length >= pageSize,
      totalCount: count,
    );
  }

  // ------------------------------------------------------------ 内部

  static List<BiliComment> _parseList(Object? raw, int upMid) {
    if (raw is! List) return const <BiliComment>[];
    final out = <BiliComment>[];
    for (final e in raw) {
      if (e is Map) {
        final parsed = parseOne(Map<String, dynamic>.from(e), upMid);
        if (parsed != null) out.add(parsed);
      }
    }
    return out;
  }

  static BiliComment? parseOne(Map<String, dynamic> json, [int upMid = 0]) {
    final rpid = _asInt(json['rpid']) ?? _asInt(json['rpid_str']);
    if (rpid == null || rpid == 0) return null;

    final member = json['member'];
    final memberMap = member is Map ? Map<String, dynamic>.from(member) : const <String, dynamic>{};
    final mid = _asInt(memberMap['mid']) ?? 0;

    final content = json['content'];
    final contentMap = content is Map ? Map<String, dynamic>.from(content) : const <String, dynamic>{};
    final message = '${contentMap['message'] ?? json['message'] ?? ''}';

    final root = _asInt(json['root']) ?? 0;
    final parent = _asInt(json['parent']) ?? 0;
    final replyCount = _asInt(json['rcount']) ?? _asInt(json['count']) ?? 0;

    // 主接口会顺带返回前几条楼中楼。
    final subsRaw = json['replies'];
    final subs = <BiliComment>[];
    if (subsRaw is List && root == 0) {
      for (final s in subsRaw) {
        if (s is Map) {
          final parsed = parseOne(Map<String, dynamic>.from(s), upMid);
          if (parsed != null) subs.add(parsed);
        }
      }
    }

    return BiliComment(
      // 主键改为字符串主轴，**取值逻辑一个字没变**：仍是 rpid → rpid_str 的
      // 回退，且照样跳过 0 / 缺失的条目（见方法开头）。
      id: '$rpid',
      platformKey: 'bilibili',
      root: root,
      parent: parent,
      uname: '${memberMap['uname'] ?? '未知用户'}',
      avatar: memberMap['avatar']?.toString(),
      message: message,
      like: _asInt(json['like']) ?? 0,
      ctime: _asInt(json['ctime']) ?? 0,
      replyCount: replyCount,
      isUp: upMid > 0 && mid == upMid,
      replies: subs,
      repliesLoaded: subs.isNotEmpty,
      repliesHasMore: subs.isNotEmpty && replyCount > subs.length,
      images: parsePictures(contentMap),
      imageAspectRatios: parsePictureAspectRatios(contentMap),
      // B 站评论图片**全部**在 `content.pictures[]` 里，不像微博那样存在
      // 「接口说 N 张、只给 1 张」的落差（实测最多 3 张全给）。
      // 所以这里的「声明张数」= 实际解析到的张数，`imageCount` 恒不超过
      // `images.length`，UI 那条「共 N 张 · 点此加载全部」分支不会触发。
      imageCount: 0,
    );
  }

  /// 与 [parsePictures] **严格同序、同长度**的宽高比列表（`宽 / 高`）。
  ///
  /// 为什么不让 UI 自己去 JSON 里取：解析层是唯一读原始 JSON 的地方，
  /// 而且这里必须复用 [parsePictures] 的**同一套过滤规则**（去重、跳空地址、
  /// 新旧形态兜底）。两边各写一遍，迟早出现「第 2 张的宽高比配到了第 3 张图上」
  /// 这种偏移错误 —— 表现是图片被裁成奇怪的形状。
  ///
  /// 拿不到比例（字段缺失、非数字、0 或负数）→ 对应位置是 `null`。
  static List<double?> parsePictureAspectRatios(Map<String, dynamic> content) {
    final out = <double?>[];
    final seen = <String>{};

    void add(Object? entry) {
      if (entry is! Map) return;
      final map = Map<String, dynamic>.from(entry);
      final url = BiliUser.normalizeImageUrl(_asString(map['img_src']));
      if (url == null) return;
      // 与 parsePictures 用**同一个去重键**（归一化后的 url），保证下标对齐。
      if (!seen.add(url)) return;

      final w = _asNum(map['img_width']);
      final h = _asNum(map['img_height']);
      if (w == null || h == null || w <= 0 || h <= 0) {
        out.add(null);
      } else {
        out.add(w / h);
      }
    }

    final plural = content['pictures'];
    if (plural is List) {
      for (final e in plural) {
        add(e);
      }
    }
    add(content['picture']);

    return out;
  }

  /// 评论配图（`content.pictures[]`）→ **已归一化为 https** 的地址列表。
  ///
  /// 实测（2026-11-02，`.env/probe_bili_comment_pics.py`，样本
  /// `BV1RXx169Emu` 与 `opus/1266051909563711506` 各 20 条一级评论）：
  ///
  /// ```
  /// content.pictures[i] = {
  ///   img_src, img_width, img_height, img_size,
  ///   play_gif_thumbnail?, top_right_icon?   ← 动图才有
  /// }
  /// ```
  ///
  /// 三个必须照做的点：
  /// 1. **只有 `img_src` 一个地址字段**（没有 `url` / `large.url` /
  ///    `src` 那套微博命名）。照抄微博的取值路径会一张都拿不到。
  /// 2. 服务端给的是**明文 `http://i0.hdslb.com/...`**，必须过
  ///    [BiliUser.normalizeImageUrl] 转 https —— Android 9+ 默认禁明文，
  ///    直接用会全部走 `errorWidget`，表现就是「评论图一片灰」。
  ///    （这与时间线封面/头像用的是同一个函数，别自己写一套。）
  /// 3. 老接口在 `content.picture`（单数、Map）上也有过图，一并兼容；
  ///    本轮两个样本都是 0 命中，属于兜底分支。
  ///
  /// 张数不设上限：实测最多 3 张，[PhotoGrid] 的九宫格最多 9 格，
  /// 超过 9 张时它自己会折行 —— 这里截断反而会静默吞图。
  static List<String> parsePictures(Map<String, dynamic> content) {
    final out = <String>[];

    void add(Object? entry) {
      if (entry is! Map) return;
      final map = Map<String, dynamic>.from(entry);
      final url = BiliUser.normalizeImageUrl(_asString(map['img_src']));
      if (url == null) return;
      if (out.contains(url)) return;
      out.add(url);
    }

    final plural = content['pictures'];
    if (plural is List) {
      for (final e in plural) {
        add(e);
      }
    }
    // 老形态兜底：`content.picture` 是单个 Map。
    add(content['picture']);

    return out;
  }

  /// JSON 里的数字可能是 int、double 或字符串。
  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 取字符串，空白归一成 null（图片地址空串等同于「没有图」）。
  static String? _asString(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  /// 取数字（int / double / 数字字符串）。图片宽高在实测里是 int，
  /// 但按 `num` 收更保险 —— 服务端改过一次格式就会整片失效。
  static double? _asNum(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }
}
