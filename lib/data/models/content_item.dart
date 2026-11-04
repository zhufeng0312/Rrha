import '../../core/utils/html_text.dart';
import 'video_ref.dart';

/// 内容来源平台。
enum Platform {
  bilibili('Bilibili'),
  weibo('微博');

  const Platform(this.label);

  /// 展示用来源标签。
  final String label;

  String get key => name;

  static Platform? fromKey(String? key) {
    if (key == null) return null;
    for (final p in Platform.values) {
      if (p.key == key) return p;
    }
    return null;
  }
}

/// 内容形态。无法判定时一律落 [ContentKind.unknown]，UI 按纯文本卡片渲染。
enum ContentKind {
  video,
  dynamic,
  article,
  repost,
  unknown;

  String get key => name;

  static ContentKind fromKey(String? key) {
    if (key == null) return ContentKind.unknown;
    for (final k in ContentKind.values) {
      if (k.key == key) return k;
    }
    return ContentKind.unknown;
  }
}

/// 统一内容模型：Bilibili 与微博聚合到同一个模型里，才能合并成一条时间线。
///
/// 设计要点：
/// - [id] 必须是**跨刷新稳定**的键，新内容标记完全依赖它；
/// - [publishedAt] 在源缺失时间时回落到 [fetchedAt]，此时
///   [hasReliableTime] 为 false，UI 需要弱化展示而不是假装时间准确。
class ContentItem {
  const ContentItem({
    required this.id,
    required this.platform,
    required this.kind,
    required this.sourceId,
    required this.authorName,
    required this.title,
    required this.summary,
    required this.link,
    required this.fetchedAt,
    this.authorId,
    this.authorAvatar,
    this.coverUrl,
    this.images = const <String>[],
    this.origin,
    this.publishedAt,
    this.videoRef,
    this.commentOid,
    this.commentType,
    this.rawGuid = '',
    this.hasReliableTime = true,
    this.isNew = false,
    this.commentCount,
    this.likeCount,
    this.repostCount,
  });

  final String id;
  final Platform platform;
  final ContentKind kind;

  /// 订阅源 id（`{platform}:{uid}`）。
  final String sourceId;

  final String authorName;
  final String? authorId;
  final String? authorAvatar;

  /// 标题（列表主文案）。
  final String title;

  /// 正文纯文本。
  final String summary;

  final String? coverUrl;

  /// 这条内容的**全部**图片（已归一化为 https、已去重、已过滤空串）。
  ///
  /// 为什么与 [coverUrl] 并存而不是只留 [images]：时间线卡片只需要一张封面，
  /// 且大量既有布局/测试都直接读 [coverUrl]；把 [coverUrl] 的语义钉死成
  /// 「[images] 的第一张，没有图时为 null」，卡片侧就能零改动，
  /// 详情页再按 [images] 渲染九宫格。两者**必须由解析层同时填**。
  final List<String> images;

  /// 转发动态的**原动态**。
  ///
  /// 为什么只存一层：`orig` 在服务端理论上可以无限嵌套（转发一条转发……），
  /// 但真机数据里嵌套转发的比例极低（121 条样本里 orig.type 只有 AV/DRAW/ARTICLE），
  /// 无限递归既会让 JSON 体积失控，也会让「查看原动态」多出一堆没人看的层级。
  /// 解析层因此用 depth 上限硬截断：原动态自己还是转发时，它的 [origin] 就是 null。
  ///
  /// 为什么不让 UI 去原始 JSON 里现取原动态：时间线缓存的是原始 JSON，
  /// 但详情页/卡片拿到的只有 [ContentItem]；解析期一次性展开才能让
  /// 「原动态作者/时间/摘要/首图」在离线状态下也能渲染。
  final ContentItem? origin;

  /// 发布时间（UTC）。为 null 表示源未提供。
  final DateTime? publishedAt;

  /// 抓取时间（UTC）。
  final DateTime fetchedAt;

  /// 原始条目链接。
  final String link;

  /// 可播信息（B 站 bvid / 微博直链）。
  final VideoRef? videoRef;

  /// 评论区的 `oid`。
  ///
  /// **刻意与 [videoRef] 分开存**：B 站评论入口按内容类型分三套
  /// （视频投稿 = aid、图文动态 = 图片 id、转发动态 = 动态 id_str），
  /// 动态 JSON 的 `basic.comment_id_str` 直接给出了正确取值 —— 拿动态 id 去凑
  /// 只会拿到 `-404 啥都木有`。用 String 承载是因为这些 id 是 19 位大整数，
  /// 字符串形式最省心。
  final String? commentOid;

  /// 评论区的 `type`（1 = 视频，11 = 图文动态，17 = 转发动态），与 [commentOid] 配对。
  final int? commentType;

  /// 是否可以在 App 内查看到评论。
  bool get hasComments =>
      (commentOid?.isNotEmpty ?? false) && (commentType ?? 0) > 0;

  /// 是否有多张图。详情页据此决定渲染九宫格，卡片据此挂「共 N 张」角标。
  bool get hasMultipleImages => images.length > 1;

  final String rawGuid;

  /// [publishedAt] 是否直接来自源。false 时说明是回流值，展示需弱化。
  final bool hasReliableTime;

  /// 「新内容」标记：客户端派生，不写回源。
  final bool isNew;

  /// 评论数 / 点赞数 / 转发数（卡片底部操作栏显示）。
  ///
  /// 为什么是 `int?` 而不是 `int` 默认 0：**「接口没给」和「确实是 0」必须能区分**。
  /// B 站动态的 `module_stat` 不是每条都有（部分形态缺段），微博的
  /// `mblog.*_count` 也可能缺；那时显示「0」就是在造数据。null = 不渲染数字。
  ///
  /// 字段路径（2026-10 用 `tools/probe_ui_fields.dart` 对真实响应核对过）：
  /// - B 站：`module_stat.comment.count` / `module_stat.like.count` /
  ///   `module_stat.forward.count`。**没有 `repost` 键**（探针实测 null），
  ///   转发数就是 `forward`。
  /// - 微博：`mblog.comments_count` / `mblog.attitudes_count` /
  ///   `mblog.reposts_count`（点赞在微博叫「attitudes」）。
  final int? commentCount;
  final int? likeCount;
  final int? repostCount;

  ContentItem copyWith({
    bool? isNew,
    int? commentCount,
    int? likeCount,
    int? repostCount,
  }) =>
      ContentItem(
        id: id,
        platform: platform,
        kind: kind,
        sourceId: sourceId,
        authorName: authorName,
        title: title,
        summary: summary,
        link: link,
        fetchedAt: fetchedAt,
        authorId: authorId,
        authorAvatar: authorAvatar,
        coverUrl: coverUrl,
        images: images,
        origin: origin,
        publishedAt: publishedAt,
        videoRef: videoRef,
        commentOid: commentOid,
        commentType: commentType,
        rawGuid: rawGuid,
        hasReliableTime: hasReliableTime,
        isNew: isNew ?? this.isNew,
        commentCount: commentCount ?? this.commentCount,
        likeCount: likeCount ?? this.likeCount,
        repostCount: repostCount ?? this.repostCount,
      );

  /// 按时间倒序排列用的比较键。
  DateTime get sortKey => publishedAt ?? fetchedAt;

  /// 是否可以在 App 内播放。
  bool get isPlayable {
    if (platform == Platform.bilibili) {
      return videoRef?.bvid != null;
    }
    return videoRef?.directVideoUrl != null;
  }

  /// 列表主文案：标题为空时退回正文首行。
  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    final s = HtmlText.singleLine(summary);
    if (s.isNotEmpty) return HtmlText.truncate(s, 60);
    return '（无标题）';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'platform': platform.key,
        'kind': kind.key,
        'sourceId': sourceId,
        'authorName': authorName,
        'authorId': authorId,
        'authorAvatar': authorAvatar,
        'title': title,
        'summary': summary,
        'coverUrl': coverUrl,
        'images': images,
        // 只序列化一层 origin：它的 origin 恒为 null（解析层 depth 上限 1），
        // 所以这里不会无限递归。
        'origin': origin?.toJson(),
        'publishedAt': publishedAt?.toIso8601String(),
        'fetchedAt': fetchedAt.toIso8601String(),
        'link': link,
        'videoRef': videoRef?.toJson(),
        'commentOid': commentOid,
        'commentType': commentType,
        'rawGuid': rawGuid,
        'hasReliableTime': hasReliableTime,
        'commentCount': commentCount,
        'likeCount': likeCount,
        'repostCount': repostCount,
      };

  static ContentItem? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final platform = Platform.fromKey(json['platform'] as String?);
    if (id is! String || platform == null) return null;
    final fetchedAt = DateTime.tryParse('${json['fetchedAt']}') ?? DateTime.now().toUtc();
    return ContentItem(
      id: id,
      platform: platform,
      kind: ContentKind.fromKey(json['kind'] as String?),
      sourceId: '${json['sourceId']}',
      authorName: '${json['authorName'] ?? ''}',
      authorId: json['authorId'] as String?,
      authorAvatar: json['authorAvatar'] as String?,
      title: '${json['title'] ?? ''}',
      summary: '${json['summary'] ?? ''}',
      coverUrl: json['coverUrl'] as String?,
      // 旧缓存里没有这两个键：缺 key 时回落成「空列表 / null」，
      // 而不是把整条缓存判为损坏 —— 时间线存的是原始 JSON 缓存在别处，
      // 但历史版本的 parsed 缓存仍可能被读到。
      images: _stringList(json['images']),
      origin: json['origin'] is Map
          ? ContentItem.fromJson(
              Map<String, dynamic>.from(json['origin'] as Map),
            )
          : null,
      publishedAt: json['publishedAt'] == null
          ? null
          : DateTime.tryParse('${json['publishedAt']}')?.toUtc(),
      fetchedAt: fetchedAt,
      link: '${json['link'] ?? ''}',
      videoRef: json['videoRef'] is Map<String, dynamic>
          ? VideoRef.fromJson(json['videoRef'] as Map<String, dynamic>)
          : null,
      commentOid: json['commentOid'] as String?,
      commentType: (json['commentType'] as num?)?.toInt(),
      rawGuid: '${json['rawGuid'] ?? ''}',
      hasReliableTime: json['hasReliableTime'] as bool? ?? true,
      // 旧缓存没有这三个键：缺 key 时回落 null（「不知道」），
      // 而不是 0 —— 卡片会因此不渲染数字，不会凭空显示「0」。
      commentCount: (json['commentCount'] as num?)?.toInt(),
      likeCount: (json['likeCount'] as num?)?.toInt(),
      repostCount: (json['repostCount'] as num?)?.toInt(),
    );
  }

  /// 把 JSON 里的任意 list 收敛成「非空字符串列表」。
  ///
  /// 容忍三件事：键缺失（旧数据）、元素不是 String（服务端偶尔给数字 id）、
  /// 空串与重复项。收敛在这里而不是解析层，是为了让**任何**写 JSON 的路径
  /// （缓存、迁移、测试夹具）都得到同一份干净数据。
  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    final out = <String>[];
    for (final e in raw) {
      final s = '${e ?? ''}'.trim();
      if (s.isEmpty || out.contains(s)) continue;
      out.add(s);
    }
    return List<String>.unmodifiable(out);
  }
}
