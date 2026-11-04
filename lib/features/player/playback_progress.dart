/// 一次「播放进度该不该落盘」的判定结果。
enum PlaybackProgressAction {
  /// 进度太短（刚点开就退出），不值得记。
  skip,

  /// 已经看到结尾，应该**清除**记录（下次进来不该再问「继续播放」）。
  clear,

  /// 写一条新记录。
  save,
}

/// 播放进度记忆的**纯判定逻辑**。
///
/// ## 为什么要抽出来
///
/// 这段逻辑原来长在 `_PlayerPageState` 里，于是它有两个致命的特点：
/// 1. 只能在真机上验证（要播一会儿、退出、再进来，看有没有弹窗）；
/// 2. 它的失败是**静默的** —— 判断错、或者写盘那一步抛异常，界面完全看不出来，
///    用户只会觉得「这功能好像没做」。
///
/// 第 2 点真出过一次（2026-10-21）：`dispose()` 里用 `ref.read(...)` 抛
/// `Bad state: Cannot use "ref" after the widget was disposed`，
/// 被 catch 吞成一行警告，于是进度**一次都没写成过**。
/// 判定与写盘分开之后，判定这一半现在能被单测钉住。
class PlaybackProgress {
  PlaybackProgress._();

  /// 少于这个时长不记：「点开→立刻退出」是浏览行为，不是观看行为。
  static const Duration minWatched = Duration(seconds: 3);

  /// 距离结尾这么近就当作「看完了」，清掉记录。
  static const Duration endMargin = Duration(seconds: 5);

  /// 有这个时长才值得弹「上次看到 x，继续吗？」（太短会打断用户）。
  static const Duration minResumePrompt = Duration(seconds: 10);

  /// 判定该做什么。
  ///
  /// [position] 为 null 表示播放器还没就绪（例如初始化就失败了），直接跳过 ——
  /// 这时候 `player.position` 恒为 0，写进去会把「上次的进度」覆盖成 3 秒。
  static PlaybackProgressAction decide({
    required Duration? position,
    required Duration? duration,
  }) {
    if (position == null || position <= minWatched) return PlaybackProgressAction.skip;
    final d = duration;
    if (d != null && d > Duration.zero && position >= d - endMargin) {
      return PlaybackProgressAction.clear;
    }
    return PlaybackProgressAction.save;
  }

  /// 是否应该在进入视频时**自动跳回**上次位置。
  ///
  /// 语义变更（2026-10-21，用户要求）：这个方法原本叫「该不该弹窗询问」，
  /// 现在改成「该不该静默恢复」。判据一个没变 —— 弹窗 vs 自动跳转只是
  /// 交互形式，不影响「多短算浏览、多近算看完」。
  ///
  /// [savedMs] 是上次存的毫秒数，[duration] 是本次视频总时长（未知时传 null）。
  static bool shouldOfferResume({
    required int? savedMs,
    required Duration? duration,
  }) {
    if (savedMs == null) return false;
    final saved = Duration(milliseconds: savedMs);
    if (saved < minResumePrompt) return false;
    final d = duration;
    // 上次的记录离结尾太近（比如上次是「看完」但没来得及清）：不该再恢复。
    if (d != null && d > Duration.zero && saved >= d - endMargin) return false;
    return true;
  }

  /// 把 bvid + 分 P 拼成存储键。
  ///
  /// 带分 P 是必须的：同一 bvid 的不同 P 是不同内容，共用一条记录会让
  /// 「P1 看到一半、进 P2 直接跳到 P1 的进度」。
  static String keyFor(String bvid, int page) => '$bvid@p$page';
}
