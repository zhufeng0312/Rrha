import 'dart:async';

/// 播放器控制栏的「显隐状态 + 自动隐藏计时 + 交互重置」。
///
/// 为什么把它抽成纯 Dart 类（而不是塞进 `_PlayerPageState`）：
/// 这三件事的时序很容易写错（定时器没取消 → 隐藏后又被旧定时器唤回；
/// 拖动中仍在计时 → 拖到一半控制栏消失），
/// 而它们**完全不依赖 widget**，抽出来就能用纯单测把时序钉死。
///
/// ## 三条规则
///
/// 1. **隐藏 = 立即隐藏**（单击的反馈必须当下可见，不要淡出动画的延迟）；
/// 2. **暂停时也自动隐藏**（⚠️ 见下）；
/// 3. **拖动期间暂停计时**，拖动结束后重新计时 —— 否则拖到一半控制栏消失。
///
/// ## ⚠️ 为什么「暂停时不自动隐藏」这条原来的规则被推翻了
///
/// 最初的实现是「暂停就停表，让用户能安心看画面」。真机上它变成了：
/// 视频一旦处于暂停/加载态，控制栏就**永远不会隐藏**，永久遮住画面 ——
/// 这正是用户报的「控制栏一直显示、点不掉」。
/// 叠加 `onTap` + `onDoubleTap` 共存导致单击要等约 300ms 判定窗口，
/// 用户以为没反应又点一下 → 被判成双击 → 暂停/继续，
/// 于是控制栏就这么一直挂在那儿，怎么点都消不掉。
///
/// 结论：**暂停状态绝不能成为「永不隐藏」的理由**。
/// 隐藏掉的控制栏一次单击就能唤回（哪怕要等那 300ms），
/// 而永久遮挡画面是用户无法自救的。这里选择前者。
class PlayerControlsController {
  PlayerControlsController({
    this.autoHideDelay = const Duration(seconds: 3),
    bool initialVisible = true,
  }) : _visible = initialVisible;

  /// 无操作多久后自动隐藏。
  final Duration autoHideDelay;

  bool _visible;
  Timer? _timer;

  /// 「正在拖动（进度条 / 亮度 / 音量）」或「弹幕设置面板打开」状态：
  /// 为 true 时暂停计时。
  bool _interacting = false;

  /// 可见性变化回调。由 StatefulWidget 接上 `setState`。
  void Function()? onChanged;

  bool get visible => _visible;

  /// 计时器是否在跑（单测用；也是「拖动中不该有计时器」这条规则的观测点）。
  bool get timerActive => _timer?.isActive ?? false;

  /// 单击：显示 ↔ 隐藏。
  ///
  /// 隐藏时**必须**先取消计时器，否则一个已经排队的隐藏回调会在
  /// 用户刚唤出控制栏后立刻把它再藏起来 —— 表现为「点了没反应」。
  void toggle() {
    if (_visible) {
      hide();
    } else {
      show();
    }
  }

  /// 显示控制栏并开始计时（若当前允许计时）。
  void show() {
    _visible = true;
    _restartTimer();
    onChanged?.call();
  }

  /// 立即隐藏并停表。
  void hide() {
    _cancelTimer();
    if (!_visible) return;
    _visible = false;
    onChanged?.call();
  }

  /// 任意交互（点按钮、拖动结束、切页…）：重置计时。
  ///
  /// 与 [show] 的区别：**不**强制把控制栏变可见 —— 交互发生在隐藏状态下时
  /// 不该把控制栏「弹」出来（例如用户在全屏拖亮度）。
  void bump() => _restartTimer();

  /// 开始「持续交互」（拖动、弹幕设置面板打开）：暂停计时。
  void beginDrag() {
    _interacting = true;
    _cancelTimer();
  }

  /// 结束「持续交互」：重新计时。
  ///
  /// 注意：如果用户在这期间把控制栏点掉了，这里**不会**把它唤回来 ——
  /// 计时器只在「当前可见」时才起表（见 [autoHideAllowed]）。
  void endDrag() {
    _interacting = false;
    _restartTimer();
  }

  /// 保留这个别名是为了兼容「暂停」这个语义上的调用点：
  /// 暂停**不再**影响计时（见类注释里的说明）。
  void setPaused(bool paused) {
    // 刻意什么都不做：暂停不应该阻止自动隐藏。
    // 保留方法是为了让调用方（播放状态回调）不必改动，也为了把
    // 「这里曾经有个例外，被推翻了」这件事留在代码里。
  }

  void dispose() => _cancelTimer();

  /// 当前是否**允许**自动隐藏。单测直接断言这个判定。
  bool get autoHideAllowed => _visible && !_interacting;

  void _restartTimer() {
    _cancelTimer();
    if (!autoHideAllowed) return;
    _timer = Timer(autoHideDelay, () {
      // 计时到点时再判一次：这段时间里可能已经进入拖动了。
      if (!autoHideAllowed) return;
      _visible = false;
      onChanged?.call();
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
