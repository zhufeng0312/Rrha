/// B 站接口返回的数据模型。
library;

/// 视频分 P。
class BiliPage {
  const BiliPage({
    required this.cid,
    required this.page,
    required this.part,
    this.duration = 0,
  });

  final int cid;
  final int page;
  final String part;
  final int duration;

  String get label => page <= 1 && part.isEmpty ? 'P1' : 'P$page $part';

  static BiliPage fromJson(Map<String, dynamic> json) => BiliPage(
        cid: (json['cid'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        part: '${json['part'] ?? ''}',
        duration: (json['duration'] as num?)?.toInt() ?? 0,
      );
}

/// `x/web-interface/view` 的结果。
class BiliVideoInfo {
  const BiliVideoInfo({
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.title,
    required this.ownerName,
    required this.ownerMid,
    this.cover,
    this.description,
    this.duration = 0,
    this.ownerAvatar,
    this.pubdate,
    this.pages = const <BiliPage>[],
    this.view = 0,
    this.danmakuCount = 0,
    this.replyCount = 0,
    this.likeCount = 0,
    this.coinCount = 0,
    this.favoriteCount = 0,
    this.shareCount = 0,
  });

  final String bvid;
  final int aid;
  final int cid;
  final String title;
  final String ownerName;
  final int ownerMid;
  final String? cover;
  final String? description;
  final int duration;
  final String? ownerAvatar;
  final DateTime? pubdate;
  final List<BiliPage> pages;

  final int view;
  final int danmakuCount;
  final int replyCount;
  final int likeCount;
  final int coinCount;
  final int favoriteCount;
  final int shareCount;

  bool get isMultiPart => pages.length > 1;

  /// 取指定分 P 的 cid，取不到时回落到第一个。
  int cidForPage(int page) {
    for (final p in pages) {
      if (p.page == page) return p.cid;
    }
    return pages.isEmpty ? cid : pages.first.cid;
  }

  static BiliVideoInfo fromJson(Map<String, dynamic> json) {
    final owner = json['owner'];
    final stat = json['stat'];
    final pagesRaw = json['pages'];

    final pages = <BiliPage>[];
    if (pagesRaw is List) {
      for (final p in pagesRaw) {
        if (p is Map) pages.add(BiliPage.fromJson(Map<String, dynamic>.from(p)));
      }
    }

    final pub = (json['pubdate'] as num?)?.toInt();
    return BiliVideoInfo(
      bvid: '${json['bvid'] ?? ''}',
      aid: (json['aid'] as num?)?.toInt() ?? 0,
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      title: '${json['title'] ?? ''}',
      ownerName: owner is Map ? '${owner['name'] ?? ''}' : '',
      ownerMid: owner is Map ? ((owner['mid'] as num?)?.toInt() ?? 0) : 0,
      ownerAvatar: owner is Map ? owner['face']?.toString() : null,
      cover: json['pic']?.toString(),
      description: json['desc']?.toString(),
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      pubdate: pub == null || pub <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(pub * 1000, isUtc: true),
      pages: pages,
      view: _stat(stat, 'view'),
      danmakuCount: _stat(stat, 'danmaku'),
      replyCount: _stat(stat, 'reply'),
      likeCount: _stat(stat, 'like'),
      coinCount: _stat(stat, 'coin'),
      favoriteCount: _stat(stat, 'favorite'),
      shareCount: _stat(stat, 'share'),
    );
  }

  static int _stat(Object? stat, String key) {
    if (stat is! Map) return 0;
    return (stat[key] as num?)?.toInt() ?? 0;
  }
}

/// `/x/polymer/web-dynamic/v1/feed/all` 的一页 —— 「我关注的动态流」。
///
/// 这个接口一次就能拿回**所有**关注 UP 的最新更新（首页实测 20 条、涉及 13 个
/// UP 主），所以时间线不必再按「订阅源 × 路由」逐个请求；
/// `offset` 是游标而不是页码，翻页时必须原样回传上一页的值。
class BiliFollowingFeed {
  const BiliFollowingFeed({
    required this.items,
    this.nextOffset,
    this.hasMore = false,
    this.updateNum = 0,
  });

  /// 原始 items。刻意不在这里转成 ContentItem ——
  /// 那是 `BiliContentParser` 的职责，与「client 只取原文」的分工保持一致。
  final List<Object?> items;

  /// 下一页游标（原样回传，不要解析成数字）。
  final String? nextOffset;

  final bool hasMore;

  /// 服务端标注的新动态数。
  final int updateNum;

  static const BiliFollowingFeed empty =
      BiliFollowingFeed(items: <Object?>[]);

  static BiliFollowingFeed fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final map = Map<String, dynamic>.from(raw);

    final items = map['items'];

    // ⚠️ 实测（2026-10，脚本 .env/probe_feed_types.py）这三类字段的 JSON 类型**并不统一**：
    //   offset      -> 纯数字**字符串**（19 位大整数，如 "1259324277086224400"）
    //   update_num  -> **字符串** "0"
    //   has_more    -> 真正的 bool
    // 按 JSON 类型硬转会直接抛 `type 'String' is not a subtype of type 'num?'`
    // —— 真机时间线就是这样整页报错的。所以这里一律按「宽松解析」处理。
    //
    // 顺带一个必须记牢的点：offset 是 19 位整数，**绝不能当数字处理**
    // （double 只有 53 位有效位），原样回传才是对的。
    return BiliFollowingFeed(
      items: items is List ? items : const <Object?>[],
      nextOffset: _asOffset(map['offset']),
      hasMore: _asBool(map['has_more']),
      updateNum: _asInt(map['update_num']),
    );
  }

  /// 游标：任何非空形态都转成字符串，空串 / null 归一成 null。
  static String? _asOffset(Object? v) {
    if (v == null) return null;
    if (v is String) {
      final s = v.trim();
      return s.isEmpty ? null : s;
    }
    if (v is num) return '$v';
    return null;
  }

  static int _asInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == 'true' || s == '1';
    }
    return false;
  }

  /// 供分页缓存落盘：缓存**原始 JSON**，解析规则升级后旧缓存依然可用
  /// （与 RSS 侧缓存 XML 原文同一个理由）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items,
        'offset': nextOffset,
        'has_more': hasMore,
        'update_num': updateNum,
      };
}

/// 播放通道。
enum PlayChannel {  /// 单文件 MP4/FLV → 走 video_player。
  mp4,

  /// DASH 音视频分离 → 走 media_kit（音频用 audio-file 附加）。
  dash,

  /// 没有可用流。
  none,
}

/// B 站 CDN 节点选择。
///
/// 【实机修复 · 2026-10-18】旧实现只取流对象里的 `baseUrl`，而 B 站现在把
/// **`baseUrl` 一律调度到 PCDN 节点**（第三方边缘分发，如
/// `*.edge.mountaintoys.cn:4483`、`*.mcdn.bilivideo.cn:8082`）。实测
/// （荣耀 Magic8 Pro / 移动网络 + 桌面网络双向复现）：
///
/// | 节点 | 实测 |
/// |---|---|
/// | `*.edge.mountaintoys.cn:4483` | HEAD 超时，连 TCP 都建不起来 |
/// | `*.mcdn.bilivideo.cn:8082` | 404 或超时 |
/// | `upos-sz-mirror*.bilivideo.com:443` | 200，稳定可达 |
///
/// 而**同一份 `backupUrl` 里必然有一条 `upos-*` 标准 CDN**。只认 `baseUrl`
/// 会同时引出三种症状：
/// 1. 视频流也拉不到 → libmpv `Failed to open` / `ffurl_read returned 0xffffff92`；
/// 2. 视频流侥幸通了、音频流的 PCDN 节点不通 → **有画面没声音**；
/// 3. 换个播放器也没用（节点坏了，不是解码器坏了）。
///
/// 因此这里统一把候选地址按「标准 CDN → 其它 → PCDN」排序，把可达节点排在
/// 最前面；PCDN 仍保留在队尾，避免官方哪天只给 PCDN 时彻底无解。
class BiliCdn {
  BiliCdn._();

  /// 是否为 PCDN 节点。
  static bool isPcdn(String url) {
    final low = url.toLowerCase();
    if (low.contains(':4483')) return true;
    if (low.contains('mcdn')) return true;
    if (low.contains('mountaintoys')) return true;
    return false;
  }

  /// 0 = 标准 CDN（最可信），1 = 其它，2 = PCDN（垫底）。
  static int _rank(String url) {
    if (isPcdn(url)) return 2;
    if (url.toLowerCase().contains('bilivideo.com')) return 0;
    return 1;
  }

  /// 从一个 `dash.video[i]` / `dash.audio[i]` / `durl[i]` 对象取出**全部**
  /// 候选地址：`baseUrl` + `backupUrl`，去重后按可达性排序。
  static List<String> candidatesOf(Object? stream) {
    if (stream is! Map) return const <String>[];
    final out = <String>[];
    void add(Object? v) {
      if (v is String && v.isNotEmpty && !out.contains(v)) out.add(v);
    }

    // dash 用 baseUrl/backupUrl，durl 用 url/backup_url —— 两套命名都要认。
    add(stream['baseUrl'] ?? stream['base_url'] ?? stream['url']);
    final backup = stream['backupUrl'] ?? stream['backup_url'];
    if (backup is List) {
      for (final b in backup) {
        add(b);
      }
    }
    if (out.isEmpty) return const <String>[];

    // 稳定排序：rank 小的在前，同 rank 保持接口给的原始顺序。
    final order = List<int>.generate(out.length, (i) => i);
    order.sort((a, b) {
      final r = _rank(out[a]).compareTo(_rank(out[b]));
      return r != 0 ? r : a.compareTo(b);
    });
    return <String>[for (final i in order) out[i]];
  }
}

/// 可选清晰度。
class QualityOption {
  const QualityOption({required this.qn, required this.label});

  final int qn;
  final String label;

  static QualityOption fromJson(Map<String, dynamic> json) => QualityOption(
        qn: (json['quality'] as num?)?.toInt() ?? 0,
        label: '${json['new_description'] ?? json['display_desc'] ?? json['quality'] ?? ''}',
      );
}

/// `x/player/wbi/playurl` 的结果。
///
/// 每一条流都带**候选地址列表**而不是单个 URL：B 站把 `baseUrl` 调度到 PCDN
/// 节点（经常不可达），而 `backupUrl` 里才有标准 CDN。详见 [BiliCdn]。
class PlayUrlResult {
  const PlayUrlResult({
    required this.channel,
    this.urls = const <String>[],
    this.videoUrls = const <String>[],
    this.audioUrls = const <String>[],
    this.quality = 0,
    this.qualities = const <QualityOption>[],
    this.duration,
    this.format,
    this.audioBandwidth = 0,
    this.videoCodecId,
  });

  final PlayChannel channel;

  /// MP4/FLV 单文件候选地址（已按可达性排序，首个最可信）。
  final List<String> urls;

  /// DASH 视频流候选地址。
  final List<String> videoUrls;

  /// DASH 音频流候选地址。
  final List<String> audioUrls;

  /// MP4 单文件地址（= `urls.first`）。
  String? get url => urls.isEmpty ? null : urls.first;

  /// DASH 视频流地址（= `videoUrls.first`）。
  String? get videoUrl => videoUrls.isEmpty ? null : videoUrls.first;

  /// DASH 音频流地址（= `audioUrls.first`）。
  String? get audioUrl => audioUrls.isEmpty ? null : audioUrls.first;

  final int quality;
  final List<QualityOption> qualities;
  final Duration? duration;
  final String? format;
  final int audioBandwidth;
  final int? videoCodecId;

  bool get isPlayable => channel != PlayChannel.none;

  static PlayUrlResult none() => const PlayUrlResult(channel: PlayChannel.none);

  /// 从 `data` 解析，自动选择 MP4 或 DASH。
  ///
  /// [requestedQn] 用于在多个 DASH 流里挑一个不超过它的最高清晰度。
  static PlayUrlResult fromJson(Object? data, {required int requestedQn}) {
    if (data is! Map) return none();
    final map = Map<String, dynamic>.from(data);

    final qualities = <QualityOption>[];
    final formats = map['support_formats'];
    if (formats is List) {
      for (final f in formats) {
        if (f is Map) {
          qualities.add(QualityOption.fromJson(Map<String, dynamic>.from(f)));
        }
      }
    }

    final durationSec = (map['timelength'] as num?)?.toInt();
    final duration = durationSec == null || durationSec <= 0
        ? null
        : Duration(milliseconds: durationSec);

    // ---- 通道 A：durl（单文件）----
    final durl = map['durl'];
    if (durl is List && durl.isNotEmpty) {
      final first = durl.first;
      if (first is Map) {
        // durl 同样带 backup_url（PCDN 问题一模一样，见 [BiliCdn]）。
        final urls = BiliCdn.candidatesOf(first);
        if (urls.isNotEmpty) {
          return PlayUrlResult(
            channel: PlayChannel.mp4,
            urls: urls,
            quality: (map['quality'] as num?)?.toInt() ?? requestedQn,
            qualities: qualities,
            duration: duration,
            format: map['format']?.toString(),
          );
        }
      }
    }

    // ---- 通道 B：dash（音视频分离）----
    final dash = map['dash'];
    if (dash is Map) {
      final videos = _asMapList(dash['video']);
      final audios = _asMapList(dash['audio']);

      final video = _pickVideo(videos, requestedQn);
      final audio = _pickAudio(audios);

      // 先判空再取名：Dart 不会因为 `videoUrl != null` 就把 `video` 提升为
      // 非空类型，所以必须直接对 video 做判空。
      if (video != null) {
        final videoUrls = BiliCdn.candidatesOf(video);
        if (videoUrls.isNotEmpty) {
          return PlayUrlResult(
            channel: PlayChannel.dash,
            videoUrls: videoUrls,
            audioUrls: audio == null
                ? const <String>[]
                : BiliCdn.candidatesOf(audio),
            quality: (video['id'] as num?)?.toInt() ?? requestedQn,
            qualities: qualities,
            duration: duration,
            audioBandwidth: (audio?['bandwidth'] as num?)?.toInt() ?? 0,
            videoCodecId: (video['codecid'] as num?)?.toInt(),
          );
        }
      }
    }

    return none();
  }

  static List<Map<String, dynamic>> _asMapList(Object? value) {
    if (value is! List) return <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    for (final e in value) {
      if (e is Map) out.add(Map<String, dynamic>.from(e));
    }
    return out;
  }

  /// 优先 AVC（codecid=7，兼容性最好），在不超过 [requestedQn] 的前提下取最高。
  static Map<String, dynamic>? _pickVideo(
    List<Map<String, dynamic>> videos,
    int requestedQn,
  ) {
    if (videos.isEmpty) return null;

    final avc = videos.where((v) => (v['codecid'] as num?)?.toInt() == 7).toList();
    final pool = avc.isNotEmpty ? avc : videos;

    int qnOf(Map<String, dynamic> v) => (v['id'] as num?)?.toInt() ?? 0;

    pool.sort((a, b) => qnOf(a).compareTo(qnOf(b)));

    Map<String, dynamic>? best;
    for (final v in pool) {
      if (qnOf(v) <= requestedQn) best = v;
    }
    // 所有流都高于请求清晰度时，取最低的那条（总比没有好）。
    return best ?? pool.first;
  }

  /// 音频取码率最高的一条。
  static Map<String, dynamic>? _pickAudio(List<Map<String, dynamic>> audios) {
    if (audios.isEmpty) return null;
    final sorted = List<Map<String, dynamic>>.from(audios)
      ..sort((a, b) => ((a['bandwidth'] as num?)?.toInt() ?? 0)
          .compareTo((b['bandwidth'] as num?)?.toInt() ?? 0));
    return sorted.last;
  }
}
