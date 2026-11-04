import 'content_item.dart';

/// 平台无关的评论模型。
///
/// 名字沿用历史上的 `BiliComment`（改造面最小），但现在同时承载微博评论：
///
/// | 字段 | B 站 | 微博 |
/// | --- | --- | --- |
/// | [id] | `rpid`（int → 转字符串） | `id`（**本来就是 16 位字符串**） |
/// | [ctime] | Unix 秒 | 恒 0（时间走 [createdAtOverride]） |
/// | [like] | `like` | `like_count`（仅一级评论有） |
///
/// ## 为什么主键是 `String`
///
/// 微博评论的 `id` 是字符串，而同值的 `gid` 是 int 且已越过 2^53 ——
/// 用数值做主轴迟早丢精度（`gid` 一律不读）。B 站的 `rpid` 是 int64，
/// Dart 的 `int` 是 64 位整数，转字符串再转回来无损，所以两边都能用 String。
class BiliComment {
  const BiliComment({
    required this.id,
    required this.uname,
    required this.message,
    this.root = 0,
    this.parent = 0,
    this.avatar,
    this.like = 0,
    this.ctime = 0,
    this.createdAtOverride,
    this.platformKey,
    this.replyCount = 0,
    this.isUp = false,
    this.replies = const <BiliComment>[],
    this.repliesLoaded = false,
    this.repliesHasMore = false,
    this.images = const <String>[],
    this.imageAspectRatios = const <double?>[],
    this.imageCount = 0,
    this.mixMediaIds = const <String>[],
    this.totalReplies = 0,
    this.replyCursor,
  });

  /// 评论唯一标识（字符串主轴）。
  final String id;

  /// B 站兼容入口：老代码按 `rpid` 取整数 id。
  ///
  /// ⚠️ 只用于兼容既有断言；微博 id 转 int 会失真，
  /// **不要**在新代码里拿它当逻辑键（一律用 [id]）。
  int get rpid => int.tryParse(id) ?? 0;

  /// 楼层根 id：0 表示主楼，非 0 表示这是楼中楼。
  final int root;

  final int parent;

  final String uname;
  final String? avatar;
  final String message;

  /// 点赞数（热度排序依据）。
  final int like;

  /// 发表时间（Unix 秒，B 站专用）。
  final int ctime;

  /// 已解析好的发表时间（微博用：`created_at` 是英文串，不是时间戳）。
  ///
  /// 非空时优先于 [ctime]，见 [createdAt]。
  final DateTime? createdAtOverride;

  /// 来源平台标记（`'bilibili'` / `'weibo'`），**仅供调试**，不参与逻辑。
  final String? platformKey;

  /// 楼中楼总数（微博取内嵌 `comments[]` 的条数）。
  final int replyCount;

  /// 是否 UP 主 / 博主本人。
  final bool isUp;

  /// 已加载的楼中楼。
  ///
  /// 微博的楼中楼**内嵌在同一份 hotflow 响应里**，解析时就填好，
  /// 不需要第二个接口（见 `WeiboCommentParser`）。
  final List<BiliComment> replies;

  final bool repliesLoaded;
  final bool repliesHasMore;

  /// 评论配图（已归一化为 https、已过滤残片）。
  ///
  /// 微博评论的 hotflow 接口**一条评论只回 1 张图**（实测：`mix_media_ids`
  /// 与 `pic_num` 吻合，但 `pic` 恒为 1 个 Map、`pics` 恒为 1 项），
  /// 所以这里通常长度 0 或 1；B 站评论恒为空。
  ///
  /// URL 一律取**大图**（`pic.large.url` / `pics[i].large.url`），
  /// 拿不到才回退缩略（`url`，长边 360）。
  final List<String> images;

  /// 每张图的**真实宽高比**（`宽 / 高`），与 [images] **按下标一一对应**。
  ///
  /// 为什么需要它：B 站评论图常是手机截图或超长竖图（探针实测有一张
  /// `1080×9109`，比例 0.12）。若一律按 4:3 + `BoxFit.cover` 渲染，
  /// 这种图会被裁成中间一小条，用户看不出截的是什么。
  ///
  /// 缺失 / 比例异常时对应位置放 `null`（或整体为空列表），
  /// UI 会退回默认的 4:3 策略 —— 不是「坏数据」，是「不知道」。
  ///
  /// 微博侧恒为空：那套接口只给单张代表图，没有可靠的宽高字段。
  final List<double?> imageAspectRatios;

  /// 接口声明的图片张数（微博 `pic_num`）。
  ///
  /// 可能大于 [images].length（实测存在 `pic_num=3` 但只给出 1 张的评论），
  /// **只用于显示「共 N 张」角标 —— 绝不能拿它去索引 [images]**。
  /// B 站恒为 0。
  final int imageCount;

  /// 多图短链（微博 `mix_media_ids` **原样**）。空 = 没有多图线索。
  ///
  /// ⚠️ 这里是 **`http://t.cn/…`**（接口给的就是 http），解析时要先升级成
  /// https（Android 9+ 明文策略会拦 `http://`）。
  ///
  /// 为什么解析层不直接给图片直链：短链跟随是**网络 IO**，而
  /// `WeiboCommentParser` 是零 IO 的纯函数（被大量单测钉死）。所以解析层
  /// 只做数据搬运，真正的短链解析在仓库层的
  /// `WeiboCommentPicResolver.resolveCommentPics`，且只在用户点
  /// 「点此加载全部」时触发 —— **绝不进列表构建路径**。
  ///
  /// B 站恒为空 → 走不到多图分支。
  final List<String> mixMediaIds;

  /// 该评论「声称」的回复总数（微博 `total_number`）。
  ///
  /// ⚠️ 这是微博 App 里显示的数字，含被折叠 / 已删除的回复，
  /// **大于等于实际能拉到的条数**（实测样本：声称 68，接口只给 12）。
  /// 只能用于文案「共 N 条回复」，**绝不能当作可拉取条数或 loading 分母**
  /// —— 否则进度永远停在 12/68。
  ///
  /// B 站恒为 0（B 站的总数在 [replyCount] 里）。
  final int totalReplies;

  /// 续拉二级回复的游标（取自带该评论的**一级节点** `max_id`；B 站恒 null）。
  ///
  /// 为什么游标不来自子接口：实测 `comments/hotflowChild` 的响应里
  /// **一个游标字段都没有**，续拉要拿同一楼层一级评论节点的 `max_id`
  /// （见 `.env/weibo_subcomment_probe.md` §二）。
  ///
  /// 按 String 存：实测是 int（15 位），但服务端随时可能换成字符串，
  /// 混用会在 `int.parse` 上炸。
  final String? replyCursor;

  BiliComment copyWith({
    List<BiliComment>? replies,
    bool? repliesLoaded,
    bool? repliesHasMore,
    List<String>? images,
    List<double?>? imageAspectRatios,
    int? imageCount,
    List<String>? mixMediaIds,
    int? totalReplies,
    String? replyCursor,
  }) =>
      BiliComment(
        id: id,
        uname: uname,
        message: message,
        root: root,
        parent: parent,
        avatar: avatar,
        like: like,
        ctime: ctime,
        createdAtOverride: createdAtOverride,
        platformKey: platformKey,
        replyCount: replyCount,
        isUp: isUp,
        replies: replies ?? this.replies,
        repliesLoaded: repliesLoaded ?? this.repliesLoaded,
        repliesHasMore: repliesHasMore ?? this.repliesHasMore,
        images: images ?? this.images,
        imageAspectRatios: imageAspectRatios ?? this.imageAspectRatios,
        imageCount: imageCount ?? this.imageCount,
        mixMediaIds: mixMediaIds ?? this.mixMediaIds,
        totalReplies: totalReplies ?? this.totalReplies,
        replyCursor: replyCursor ?? this.replyCursor,
      );

  /// 发表时间：优先用解析好的 [createdAtOverride]，其次回落到 [ctime]。
  DateTime? get createdAt {
    final DateTime? override = createdAtOverride;
    if (override != null) return override;
    return ctime <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ctime * 1000, isUtc: true);
  }
}

/// 一页评论。
class CommentPage {
  const CommentPage({
    this.topComments = const <BiliComment>[],
    this.comments = const <BiliComment>[],
    this.isEnd = false,
    this.nextCursor,
    this.total = 0,
    this.fromCache = false,
  });

  /// 置顶评论（接口单独返回，不参与分页游标）。
  final List<BiliComment> topComments;

  final List<BiliComment> comments;

  final bool isEnd;

  /// 下一页游标（B 站：`cursor.pagination_reply.next_offset`；微博：`data.max_id`）。
  final String? nextCursor;

  final int total;

  final bool fromCache;

  bool get isEmpty => topComments.isEmpty && comments.isEmpty;
}

/// 评论排序方式。
///
/// 微博的 hotflow **只有一种顺序**（热门），本枚举只对 B 站有意义 ——
/// 微博界面会把排序切换按钮隐藏掉（见 `comment_section.dart`）。
enum CommentSort {
  /// 热度（接口 mode=3）。
  hot(3, '热度'),

  /// 时间（接口 mode=2）。
  time(2, '时间');

  const CommentSort(this.mode, this.label);

  final int mode;
  final String label;

  /// 从字符串还原（[name] 的正向映射），未知值回落到 [hot]。
  static CommentSort fromKey(String? key) {
    if (key == null) return CommentSort.hot;
    for (final CommentSort s in CommentSort.values) {
      if (s.name == key) return s;
    }
    return CommentSort.hot;
  }
}

/// 楼中楼一页。
class SubCommentPage {
  const SubCommentPage({
    this.comments = const <BiliComment>[],
    this.hasMore = false,
    this.totalCount = 0,
  });

  final List<BiliComment> comments;
  final bool hasMore;
  final int totalCount;
}

/// 一次评论请求的平台无关参数。
///
/// 抽出来的原因：B 站用 `oid + type + upMid`，微博只有 `mid`（塞进 [oid]），
/// 把两套参数摊平成命名参数会让每个调用点都背一半无用参数。
///
/// - [platform]：决定用哪个仓库实现（B 站 / 微博）；
/// - [oid]：B 站 = aid / 动态 id；微博 = mid；
/// - [type]：B 站专用（1 视频 / 11 图文动态 / 17 转发动态），微博固定 0；
/// - [upMid]：B 站专用（判定 UP 主标记），微博 0；
/// - [sort]：[CommentSort.name]，微博侧忽略（hotflow 只有一种顺序）。
class CommentRequest {
  const CommentRequest({
    required this.platform,
    required this.oid,
    this.type = 0,
    this.upMid = 0,
    this.sort,
  });

  final Platform platform;
  final String oid;
  final int type;
  final int upMid;
  final String? sort;

  /// 解析成 [CommentSort]（B 站仓库用）。
  CommentSort get sortValue => CommentSort.fromKey(sort);

  @override
  bool operator ==(Object other) =>
      other is CommentRequest &&
      other.platform == platform &&
      other.oid == oid &&
      other.type == type &&
      other.upMid == upMid &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(platform, oid, type, upMid, sort);
}
