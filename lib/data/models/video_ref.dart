/// 内容的可播信息。
///
/// B 站只拿到 bvid 就够（cid/aid 由 view 接口补），微博则只可能拿到一条
/// 带时效签名的直链，两者语义差别很大，所以分成两组字段而不是硬塞一个 url。
class VideoRef {
  const VideoRef({
    this.bvid,
    this.aid,
    this.cid,
    this.page = 1,
    this.directVideoUrl,
    this.coverUrl,
    this.sourceUrl,
    this.duration,
    this.isVertical,
  });

  /// B 站 BV 号。
  final String? bvid;

  /// B 站 aid（从链接里提取到 av 号时可用）。
  final int? aid;

  /// B 站 cid（RSS 里通常没有，需要 view 接口补）。
  final int? cid;

  /// 分 P。
  final int page;

  /// 微博视频直链（带时效签名，不保证可用）。
  final String? directVideoUrl;

  final String? coverUrl;

  /// 原始页面地址。
  final String? sourceUrl;

  /// 视频时长。
  ///
  /// 微博侧实测来源：`page_info.media_info.duration`（**double，单位秒**，
  /// 例 `26.331`）。B 站侧来自 playurl 的 `timelength`（毫秒）。
  ///
  /// 为 null = 接口没给，卡片**不显示时长**，绝不拿 0 冒充。
  final Duration? duration;

  /// 视频是否为竖屏。
  ///
  /// 微博实测来源：`page_info.video_orientation`（`"vertical"` / `"horizontal"`）。
  /// 卡片据此让封面**居中留边**而不是硬裁 16:9 —— 竖屏视频被裁成 16:9
  /// 会把画面主体切掉一大半（实测封面是 480×853）。
  /// null = 未知，按横屏处理。
  final bool? isVertical;

  bool get hasBili => bvid != null || aid != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bvid': bvid,
        'aid': aid,
        'cid': cid,
        'page': page,
        'directVideoUrl': directVideoUrl,
        'coverUrl': coverUrl,
        'sourceUrl': sourceUrl,
        'durationMs': duration?.inMilliseconds,
        'isVertical': isVertical,
      };

  static VideoRef? fromJson(Map<String, dynamic> json) {
    final int? durationMs = (json['durationMs'] as num?)?.toInt();
    return VideoRef(
      bvid: json['bvid'] as String?,
      aid: (json['aid'] as num?)?.toInt(),
      cid: (json['cid'] as num?)?.toInt(),
      page: (json['page'] as num?)?.toInt() ?? 1,
      directVideoUrl: json['directVideoUrl'] as String?,
      coverUrl: json['coverUrl'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      isVertical: json['isVertical'] as bool?,
    );
  }
}
