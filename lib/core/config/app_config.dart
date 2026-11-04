/// 全局常量与默认配置。
///
/// 所有「魔法数字」集中在这里，便于验收时按真机表现调整
/// （尤其是弹幕与缓存相关参数）。
class AppConfig {
  AppConfig._();

  // ---------------------------------------------------------------- 网络

  static const Duration connectTimeout = Duration(seconds: 8);
  static const Duration receiveTimeout = Duration(seconds: 15);
  static const Duration sendTimeout = Duration(seconds: 15);

  /// 失败重试次数（仅幂等 GET，指数退避）。
  static const int maxRetries = 1;
  static const Duration retryBaseDelay = Duration(milliseconds: 1500);

  /// 浏览器 UA：B 站与部分公共实例会按 UA 做风控。
  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  // ---------------------------------------------------------------- 缓存

  /// 时间线本地缓存 TTL：硬性要求至少 5 分钟。
  ///
  /// B 站与微博共用这一份（都缓存官方接口的原始 JSON）。
  static const Duration timelineCacheTtl = Duration(minutes: 5);

  // ---------------------------------------------------------------- 拉取

  /// 单路由请求条目上限。
  static const int fetchLimit = 20;

  /// 时间线合并后的最大条目数。
  static const int timelineMaxItems = 200;

  /// 并发拉取上限：公共实例是共享资源，禁止无限并发。
  static const int maxConcurrentFetches = 3;

  /// 每源保留的「已读」id 数量上限（用于新内容标记）。
  static const int seenIdsPerSource = 300;

  // ---------------------------------------------------------------- 关注列表

  /// 「我关注的 UP 主」每页条数。B 站该接口上限 50。
  static const int followingPageSize = 50;

  /// 从关注列表批量导入时默认勾选的条数。
  ///
  /// 存在的理由：关注几十上百人时，「全部导入」会让每次时间线刷新变成
  /// 上百个请求，必然触发风控。所以默认只勾前几个，其余由用户自己挑。
  static const int followingImportDefaultPicks = 5;

  /// 单个 UP 主每次拉取的投稿条数上限。
  static const int userVideoFetchLimit = 20;

  // ---------------------------------------------------------------- 评论

  static const int commentPageSize = 20;
  static const int subCommentPageSize = 10;

  // ---------------------------------------------------------------- 弹幕

  /// 同屏活跃弹幕上限（默认值，可在设置中调整，硬上限见下）。
  static const int danmakuMaxOnScreen = 200;

  /// 硬上限：压力测试注入 500 条即对应此值。
  static const int danmakuHardLimit = 500;

  /// 滚动弹幕穿过整屏所需秒数（B 站官方约 4s，长弹幕会更快）。
  static const double danmakuScrollSeconds = 4.0;

  /// TextPainter 布局缓存条数上限（布局是最大开销，必须缓存）。
  static const int danmakuTextCacheSize = 600;

  /// 弹幕基础字号（B 站标准 25px）。
  static const double danmakuBaseFontSize = 25.0;

  // ---------------------------------------------------------------- 播放

  /// 首选清晰度：64 = 720P。仅作请求值，实际以服务端 accept_quality 为准。
  static const int preferredQuality = 64;

  /// 播放器位置回调的插值窗口：超出该偏差才硬跳（拖动进度条）。
  static const int positionJumpThresholdMs = 400;

  /// 取视频信息（`/x/web-interface/view`）的超时。
  ///
  /// Dio 的 connectTimeout 是 8s、再加一次重试，断网时要拖到一分钟才报错；
  /// 用户盯着黑屏一分钟等于「卡死」。这里独立卡 12 秒。
  static const Duration playerInfoTimeout = Duration(seconds: 12);

  /// 播放器**初始化**的超时。
  ///
  /// 为什么必须有：真机上出现过「通道 A 与通道 B 都卡在 initialize()、
  /// 界面永远转圈」的情况（Impeller 与 libmpv 的纹理兼容问题就是其一）。
  /// 没有超时，失败不会变成可读错误，用户只能盯着黑屏。
  /// 20 秒足够覆盖 libmpv 的冷启动，又不至于让人以为卡死。
  static const Duration playerInitTimeout = Duration(seconds: 20);

  /// 播放页整段加载（取播放地址 + 初始化播放器）的总超时兜底。
  ///
  /// playUrl 内部可能连打两次请求（fnval=1 拿不到再打 fnval=4048），
  /// 单靠分阶段超时会拖到一分多钟，所以再加一道总闸。
  static const Duration playerLoadTotalTimeout = Duration(seconds: 45);

  /// 设置页「测试连接」使用的轻量路由。
  static const String connectivityProbePath = '/bilibili/user/video/2267573';
}
