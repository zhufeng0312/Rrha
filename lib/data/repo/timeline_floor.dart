import '../models/content_item.dart';

/// 时间线「显示下界」与可见/缓冲切分（**纯函数**，不碰 IO、不读 Prefs）。
///
/// ## 为什么需要「显示下界」（真机缺陷 2026-10-26）
///
/// 「全部关注」是**两个独立游标各自翻页**：
/// - B 站 `feed/all` 一页 20 条只覆盖**几小时**（关注的人多、发得勤）；
/// - 微博 `/feed/friends` 一页 20 条覆盖**3~11 天**。
///
/// 密度相差约 25 倍，于是每翻一页，微博的「已覆盖水位」会飞快走到一个月前，
/// 而 B 站还停在几天内。**中间那一大段在内存里只有微博数据** —— 用户往下滚
/// 就看到「一大段只有微博」，继续滚才「闪一下」补上 B 站。
///
/// 关键认知：**那次「闪」不是修复，而是迟到的数据终于被插回它本该在的位置。**
/// 问题出在「把还没拉全的时间段先显示了」，不在排序、也不在渲染。
///
/// ## 判据
///
/// 对每一侧算一个**覆盖水位** `W`：该时间点**更新（含相等）**的内容已经全部
/// 加载完毕。那么「两侧都完整」的区间上界就是两侧水位里**较晚**的那个：
///
/// ```text
/// floor  = max(W_bili, W_weibo)
/// 可见   = 时间 >= floor 的条目
/// 缓冲   = 时间 <  floor 的条目（已加载，但还不能显示）
/// ```
///
/// 水位为 null 表示**该侧不构成约束**，有两种情况：
/// - 该侧已到底（游标没了）：更早的时间点也是完整的；
/// - 该侧一条内容都没有（未登录 / 关注的 UP 主确实没发）：拿不到水位。
///   若把它当成约束，floor 会被顶到「现在」，整条时间线被隐藏。
///
/// ## 由此得到的两个结构性保证（也是本方案的全部价值）
///
/// 1. **可见列表永远严格按时间倒序** —— 切分是已排序序列的子序列；
/// 2. **新内容永远只追加在末尾**：新一页的条目一定比当前 floor 更旧，
///    而已显示的条目一定不比 floor 更旧 —— 因此**不存在「往视口上方插条目」**，
///    也就不可能闪烁。
///
/// 上一轮那些 anchor / `jumpTo` / `GlobalKey` 补丁因此全部可以作废：
/// 它们修的是症状（插入后把视口钉回去），这里消掉的是成因（不再插入）。
///
/// ## 为什么两侧仍然都翻页
///
/// 有人会想「只翻水位较晚的那一侧」来省请求。但那样会让被跳过的那侧水位
/// 冻住，而 floor = max(两侧) 又必须靠它推进 —— 一旦它翻页返回的是重复内容，
/// floor 就永远不动，用户滚到底卡死。
///
/// 两侧都翻则**没有任何 stall 风险**：微博确实会多翻十几页，但那些内容全都
/// 进 [TimelineFloorSplit.buffered]（不会显示），等 floor 退到那里时会**立即**
/// 出现、不需要额外请求 —— 相当于免费预取。正确性换取这点请求量是值得的。
class TimelineFloor {
  const TimelineFloor._();

  /// 某一侧的「覆盖水位」。
  ///
  /// 返回 null 表示**不构成约束**（[exhausted]，或该侧没有可用条目）。
  /// 返回非 null 时语义是：**该时间点更新（含相等）的内容已全部加载**。
  ///
  /// ⚠️ `hasReliableTime == false` 的条目不参与计算：它们的
  /// [ContentItem.sortKey] 回落到抓取时间，拿它当水位会把 floor 顶到「现在」，
  /// 导致整条时间线被隐藏。
  static DateTime? watermark({
    required Iterable<ContentItem> items,
    required Platform platform,
    required bool exhausted,
  }) {
    // 已到底：更早的时间点同样是完整的，不构成约束。
    if (exhausted) return null;
    DateTime? oldest;
    for (final ContentItem i in items) {
      if (i.platform != platform) continue;
      if (!i.hasReliableTime) continue;
      final DateTime t = i.sortKey;
      if (oldest == null || t.isBefore(oldest)) oldest = t;
    }
    return oldest;
  }

  /// 算 floor 并切分可见 / 缓冲。
  ///
  /// [all] 必须**已经按时间倒序**（调用方用
  /// `TimelineRepository.mergeContinuing` 得到）。
  ///
  /// [previousFloor] 把结果夹成**单调**（只许往更旧的方向移动）：万一某侧水位
  /// 因为异常数据「变新」，已经显示过的条目就会凭空消失 —— 那比顺序错误更糟。
  static TimelineFloorSplit split({
    required List<ContentItem> all,
    required bool biliExhausted,
    required bool weiboExhausted,
    DateTime? previousFloor,
  }) {
    final DateTime? wBili = watermark(
      items: all,
      platform: Platform.bilibili,
      exhausted: biliExhausted,
    );
    final DateTime? wWeibo = watermark(
      items: all,
      platform: Platform.weibo,
      exhausted: weiboExhausted,
    );

    // 取**较晚**的那个：较早的一侧虽然已拉得更深，但另一侧还没到，
    // 那段区间正是「本该同时有、却只有一侧」的区间，必须扣住不显示。
    DateTime? floor;
    for (final DateTime? w in <DateTime?>[wBili, wWeibo]) {
      if (w == null) continue;
      if (floor == null || w.isAfter(floor)) floor = w;
    }

    // 单调化：只允许变旧，绝不允许变新。
    if (floor != null &&
        previousFloor != null &&
        floor.isAfter(previousFloor)) {
      floor = previousFloor;
    }

    final List<ContentItem> visible = <ContentItem>[];
    final List<ContentItem> buffered = <ContentItem>[];
    for (final ContentItem i in all) {
      // 时间不可信的条目一律显示：否则它会永远卡在缓冲里出不来。
      // 它排在最前，UI 侧本来就会弱化展示（见 `ContentCard`）。
      if (floor == null || !i.hasReliableTime || !i.sortKey.isBefore(floor)) {
        visible.add(i);
      } else {
        buffered.add(i);
      }
    }

    return TimelineFloorSplit(
      floor: floor,
      visible: visible,
      buffered: buffered,
    );
  }
}

/// [TimelineFloor.split] 的结果。
class TimelineFloorSplit {
  const TimelineFloorSplit({
    required this.visible,
    required this.buffered,
    this.floor,
  });

  /// 可见下界；null 表示不设限（两侧都完整，或都没有水位）。
  final DateTime? floor;

  /// 可以显示的条目（时间 >= [floor]），已按时间倒序。
  final List<ContentItem> visible;

  /// 已加载但暂不可显示的条目（时间 < [floor]），已按时间倒序。
  ///
  /// 不是「丢弃」：等 floor 退到它们之后会按原顺序放出来。
  final List<ContentItem> buffered;

  bool get isEmpty => visible.isEmpty;

  /// 诊断用一行摘要（进「运行日志」）。
  String debugLabel() {
    final String f = floor == null ? '-' : floor!.toIso8601String();
    return 'floor=$f 可见=${visible.length} 缓冲=${buffered.length}';
  }
}
