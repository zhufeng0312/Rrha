/// 时间线的取数模式（方案 C）。
///
/// 背景：一次刷新 = 订阅源数 × 路由数 个请求（6 个源就是 12 个请求），
/// 而 B 站提供了「我关注的动态流」接口（`/x/polymer/web-dynamic/v1/feed/all`），
/// **一个请求**就能拿回所有关注 UP 的最新更新（首页实测 20 条、涉及 13 个 UP 主），
/// 并用 offset 游标翻页。
///
/// 但逐源聚合仍有价值（只盯几个人、微博源、RSSHub 路由），所以两种模式并存：
/// 默认走「全部关注」，用户可随时切回「精选订阅」。
enum TimelineMode {
  /// 全部关注：一次请求一页，滚到底用 offset 游标拉下一页。
  allFollowing('allFollowing', '全部关注'),

  /// 精选订阅：按「订阅源 × 路由」逐个聚合（原有逻辑，保留不变）。
  selectedSubscriptions('selectedSubscriptions', '精选订阅');

  const TimelineMode(this.key, this.label);

  final String key;
  final String label;

  /// 是否按「一页一页往下翻」的方式取数。
  bool get isPaged => this == TimelineMode.allFollowing;

  static TimelineMode fromKey(String? key) {
    for (final m in TimelineMode.values) {
      if (m.key == key) return m;
    }
    return TimelineMode.allFollowing;
  }
}
