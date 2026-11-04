import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config/diagnostics_config.dart';
import '../../core/net/app_error.dart';
import '../../widgets/cached_image.dart';
import 'player_adapter.dart';

/// **详情页内嵌**的微博视频播放器：进入即自动播放，交互与 B 站播放页一致。
///
/// ## 为什么需要它，而不是直接用 `SimpleVideoPage`
///
/// 用户的原话是「点击视频的时候进的是视频详情页，能看到评论的那种」，并且
/// 明确选了「进详情页后视频自动播放」。也就是说**评论和视频必须在同一页**：
/// 先落全屏播放页、再让用户返回去找评论，是把一次操作拆成三次。
///
/// ## `referer` 不是可选项（实测结论，别删）
///
/// 同一条 `f.video.weibocdn.com/*.mp4` 直链（`.env/weibo_video_probe.md`）：
/// - **不带 Referer** → `HTTP 403 · text/html · 238 字节`
/// - **带 `Referer: https://weibo.com/`** → `HTTP 200 · video/mp4 · 2,730,923 字节`
///
/// 微博 CDN 的防盗链是硬性的，漏了这个参数就必然播不了，而失败表现是
/// 「画面全黑、没有任何提示」。
///
/// ## 交互规格：**对齐 B 站播放页**（用户明确要求）
///
/// 逐条照 `docs/HANDOVER.md` §7.23 + `player_page.dart` 的实现来：
///
/// | 手势 | 行为 |
/// | --- | --- |
/// | 单击 | 显示 / 隐藏控制栏（3 秒自动隐藏） |
/// | **双击** | 播放 / 暂停 |
/// | **长按** | 2.0x 快进，松手回到用户所选倍速（本组件无倍速选择，回 1.0x） |
/// | 横向拖动 | 拖动预览进度条，松手才 seek |
/// | 底部控制栏 | 播放/暂停 + 进度条 + 时间 + 全屏 |
///
/// **刻意不做**：弹幕（微博没有弹幕接口）、清晰度切换（`media_info` 只给
/// 一条直链）、倍速菜单、进度记忆。这些在 `PlayerPage` 里都有，但依赖
/// 微博拿不到的数据；造一个空菜单比不给更糟。
///
/// ## 手势冲突的既有结论（照抄 `player_page.dart` 的注释，别再踩一次）
///
/// - 单击与双击共存时，**单击必然要等双击判定窗口**（Flutter 内部约 300ms，
///   不可配）。这是保留双击的固有代价，靠「控制栏 3 秒自动隐藏」消化；
/// - 长按与横向拖动在手势竞技场里**互斥竞争**：按下不动 → 长按胜出；
///   按下即移动 → 拖动胜出，两者不会同时触发。
class InlineVideoPlayer extends StatefulWidget {
  const InlineVideoPlayer({
    super.key,
    required this.url,
    this.posterUrl,
    this.referer,
    this.hintDuration,
    this.isVertical,
    this.playerFactory,
    this.allowFullscreen = true,
  });

  /// 视频直链（微博带时效签名）。
  final String url;

  /// 封面：初始化期间先铺它，避免一块黑矩形。
  final String? posterUrl;

  /// 必需。微博固定传 `https://weibo.com/`，否则 CDN 403。
  final String? referer;

  /// 接口给的时长（播放器还没报出时长时用它显示总长）。
  final Duration? hintDuration;

  /// 竖屏视频用更高的一档高度，否则 16:9。
  final bool? isVertical;

  /// 见类注释「为可测性留的」。null 时用真 [MpvPlayerAdapter]。
  final RrhaPlayer Function()? playerFactory;

  /// 是否允许全屏（详情页里默认允许；嵌套场景可关掉）。
  final bool allowFullscreen;

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer>
    with WidgetsBindingObserver {
  RrhaPlayer? _player;
  AppError? _error;
  bool _loading = true;
  bool _playing = false;
  bool _ready = false;
  bool _fullscreen = false;

  /// 控制栏显隐。与 B 站一致：单击切换、3 秒自动隐藏。
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 长按 2x 快进中。
  bool _longPressing = false;

  /// 与 B 站播放页同一个数值（`player_page.dart` 的 `_longPressSpeed`）。
  static const double _longPressSpeed = 2.0;

  /// 横向拖动中：进度条显示预览值，松手才真的 seek。
  double? _dragPreview;

  /// 诊断用：手势层收到的单击次数（只在诊断开关打开时显示）。
  int _tapCount = 0;

  /// 诊断用：命中测试到达手势层的次数（`onTapDown`）。
  int _downCount = 0;

  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切到后台就暂停：内嵌播放器不像全屏播放页那样有「明确的离开动作」，
    // 不暂停的话用户切去别的 App，声音还在后面放。
    if (state == AppLifecycleState.paused && _playing) {
      unawaited(_player?.pause() ?? Future<void>.value());
    }
  }

  Future<void> _init() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _ready = false;
      });
    }

    _cancelSubs();

    try {
      final RrhaPlayer player = widget.playerFactory?.call() ??
          MpvPlayerAdapter(
            videoUrls: <String>[widget.url],
            headers: widget.referer == null
                ? null
                : <String, String>{'Referer': widget.referer!},
          );

      await player.initialize();
      if (!mounted) {
        // 初始化期间页面已销毁：立刻释放，不留下占用解码器的孤儿。
        await player.dispose();
        return;
      }

      _player = player;
      _listen(player);
      // 自动播放：用户已经用「点卡片」表达了要看的意图，不必再点一次。
      await player.play();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _ready = true;
      });
      _scheduleHide();
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _ready = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppError(
          AppErrorKind.unknown,
          '视频播放失败',
          // detail 只放 URL 本身，不含 cookie / 请求头。
          detail: widget.url,
        );
        _loading = false;
        _ready = false;
      });
    }
  }

  void _listen(RrhaPlayer player) {
    _subs.add(player.playingStream.listen((bool playing) {
      if (!mounted) return;
      if (playing != _playing) setState(() => _playing = playing);
    }));
    // 播完（26 秒的微博短视频很常见）回到可重播状态。
    //
    // 不处理的话表现是：进页面自动播完 → 画面定格在最后一帧 → 点一下才重播，
    // 而画面上没有任何「点一下重播」的提示。
    _subs.add(player.completedStream.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _controlsVisible = true;
      });
      _hideTimer?.cancel();
    }));
    _subs.add(player.errorStream.listen((String raw) {
      if (!mounted) return;
      // libmpv 拉流失败时既不抛异常也不结束，只在这条流上说话 ——
      // 不接的话表现就是「黑屏 + 转圈，永远不结束」。
      setState(() {
        _error = AppError(
          AppErrorKind.network,
          '视频加载失败（可能是直链已过期）',
          detail: raw,
        );
        _loading = false;
        _ready = false;
      });
    }));
  }

  void _cancelSubs() {
    for (final StreamSubscription<dynamic> s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _cancelSubs();
    _player?.dispose();
    _player = null;
    super.dispose();
  }

  // ---------------------------------------------------------------- 控制栏

  /// 3 秒后自动隐藏控制栏（与 B 站一致）。
  ///
  /// 暂停时不隐藏：暂停就是「我要操作」，把控制栏藏起来反而要重新点出来。
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (kWeiboDiagnosticsEnabled) _tapCount++;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _showControls() {
    if (!mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  // ---------------------------------------------------------------- 手势

  Future<void> _togglePlay() async {
    final RrhaPlayer? p = _player;
    if (p == null || !_ready) return;
    if (_playing) {
      await p.pause();
      _hideTimer?.cancel();
      if (mounted) setState(() => _controlsVisible = true);
      return;
    }
    // 已播到结尾：先回到 0 再播，否则 `play()` 从末尾开始等于没反应。
    final Duration total = _effectiveDuration;
    if (total > Duration.zero &&
        p.position >= total - const Duration(milliseconds: 400)) {
      await p.seek(Duration.zero);
    }
    await p.play();
    _showControls();
  }

  /// 长按开始：2x 快进。
  ///
  /// 与 B 站一致，并且**松手要回到用户原本的档位**——本组件没有倍速选择，
  /// 所以恒回 1.0x。踩过的坑（§7.23）：只记一个全局变量、松手不还原，
  /// 用户会看到「松手后突然变慢」。
  void _onLongPressStart(LongPressStartDetails _) {
    final RrhaPlayer? p = _player;
    if (p == null || !_ready) return;
    _longPressing = true;
    setState(() {});
    unawaited(p.setSpeed(_longPressSpeed));
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (!_longPressing) return;
    _longPressing = false;
    setState(() {});
    unawaited(_player?.setSpeed(1.0) ?? Future<void>.value());
  }

  /// 长按被取消（手指移出、手势竞技场判给拖动）也必须还原倍速。
  ///
  /// 不做这件事的话，`onLongPressCancel` 之后倍速会**永久停在 2x**。
  void _onLongPressCancel() {
    if (_longPressing) _onLongPressEnd(const LongPressEndDetails());
  }

  void _onDragStart(DragStartDetails _) {
    if (!_ready) return;
    setState(() => _dragPreview = _progressFraction);
    _hideTimer?.cancel();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_ready || _longPressing) return;
    final double total = _effectiveDuration.inMilliseconds.toDouble();
    if (total <= 0) return;
    // 拖动距离 → 进度增量：一屏宽 ≈ 整个视频时长，手感与 B 站接近。
    final double delta = d.primaryDelta ?? 0;
    final double next =
        (_dragPreview ?? _progressFraction) + delta / (context.size?.width ?? 320);
    setState(() => _dragPreview = next.clamp(0.0, 1.0));
  }

  void _onDragEnd(DragEndDetails _) {
    final double? target = _dragPreview;
    if (target == null) return;
    final Duration total = _effectiveDuration;
    setState(() => _dragPreview = null);
    if (total > Duration.zero) {
      unawaited(
        _player?.seek(Duration(
              milliseconds: (target * total.inMilliseconds).round(),
            )) ??
            Future<void>.value(),
      );
    }
    _scheduleHide();
  }

  Future<void> _toggleFullscreen() async {
    if (!widget.allowFullscreen) return;
    setState(() => _fullscreen = !_fullscreen);
    // 全屏后系统栏也一起收起来，否则竖向高度被吃掉一块。
    await SystemChrome.setEnabledSystemUIMode(
      _fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (!mounted) return;
    if (!_fullscreen) {
      // 退出全屏要恢复系统栏（上面那次 setEnabledSystemUIMode 的另一半）。
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // ---------------------------------------------------------------- 数值

  /// 有效总时长：播放器报出的优先，没有就用接口给的 hint。
  ///
  /// 为什么需要 hint：mpv 在媒体真正加载完成前 `duration` 是 0，
  /// 那段时间进度条会算成 0/0 而看起来「坏了」。
  Duration get _effectiveDuration {
    final Duration fromPlayer = _player?.duration ?? Duration.zero;
    if (fromPlayer > Duration.zero) return fromPlayer;
    return widget.hintDuration ?? Duration.zero;
  }

  /// 当前进度比例（0..1）。
  double get _progressFraction {
    final double total = _effectiveDuration.inMilliseconds.toDouble();
    if (total <= 0) return 0;
    final double ms = (_player?.position ?? Duration.zero).inMilliseconds.toDouble();
    return (ms / total).clamp(0.0, 1.0);
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final bool vertical = widget.isVertical ?? false;

    // 竖屏视频用更高的一档高度（3:4），横屏保持 16:9。
    //
    // 为什么不能一律 16:9：实测这条微博视频封面是 **480×853**（竖构图），
    // 塞进 16:9 后画面只占中间窄窄一条，主体小到看不清。3:4 是折中：
    // 明显更可用，又不会像 9:16 那样把详情页正文和评论挤到屏幕外。
    final Widget frame = AspectRatio(
      aspectRatio: vertical ? 3 / 4 : 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 竖屏铺 contain 留边；横屏铺满。
              if (widget.posterUrl != null && !_ready)
                CachedImage(
                  url: widget.posterUrl!,
                  width: double.infinity,
                  height: double.infinity,
                  fit: vertical ? BoxFit.contain : BoxFit.cover,
                  cacheWidth:
                      (MediaQuery.sizeOf(context).width * 3).round(),
                ),

              // ⚠️ `IgnorePointer` 是**必须**的，不是防御性代码。
              //
              // `media_kit` 的 `Video` 根节点是 `Container(color: ...)`，
              // 而 `RenderDecoratedBox.hitTestSelf` **恒返回 true**
              // （`painting/decoration.dart` 的 `Decoration.hitTest => true`）。
              // 于是画面本身就成了命中目标，把手势层整个挡掉 ——
              // 真机表现为「画面在动，但点一下、双击、长按全都无反应」，
              // 诊断角标显示 `tap=0`（手势层一次事件都没收到）。
              //
              // 这与 §7.10 那个「渐变装饰层吃掉手势」是同一个渲染层陷阱，
              // 只是这次来自第三方组件的内部实现。包一层 `IgnorePointer`
              // 让画面永远不参与命中，事件就能落到上面的手势层。
              if (_ready && _player != null)
                IgnorePointer(child: _player!.buildView(context)),

              // 手势层必须**盖在画面之上**才能收到点击。
              if (_ready) Positioned.fill(child: _gestureLayer()),

              // 加载中：转圈。
              if (_loading)
                const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),

              // 失败：可读错误 + 重试。
              if (_error != null && !_loading) _errorLayer(),

              // 长按快进提示：**不受控制栏显隐影响**。
              //
              // 理由（照抄 §7.23）：它是「你现在按住的那个动作」的即时反馈，
              // 不是操作入口。跟着隐藏会让用户看到「画面变快了但屏幕上什么都没有」。
              if (_longPressing)
                IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.fast_forward_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_longPressSpeed.toStringAsFixed(1)}x 快进中',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 控制栏（含淡入淡出）。
              if (_ready && _controlsVisible) _controlsLayer(),

              // 诊断角标：编译期开关打开时才渲染（正式包零成本）。
              //
              // 真机上「画面在动但点不出控制栏」时，肉眼无法区分
              // 「手势层没收到事件」和「控制栏状态没刷新」，所以把
              // 状态直接打出来。与探针面板用同一个开关。
              if (kWeiboDiagnosticsEnabled)
                Positioned(
                  left: 4,
                  top: 4,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Text(
                        'r=$_ready v=$_controlsVisible p=$_playing '
                        'tap=$_tapCount down=$_downCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (!_fullscreen) return frame;

    // 全屏：铺满整屏 + 黑色底 + 右上角退出按钮。
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Center(
          child: Stack(
            children: <Widget>[
              frame,
              Positioned(
                right: 8,
                top: 8,
                child: IconButton(
                  tooltip: '退出全屏',
                  icon: const Icon(Icons.fullscreen_exit_rounded,
                      color: Colors.white),
                  onPressed: _toggleFullscreen,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gestureLayer() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 诊断用：命中测试到达本层就记数。它与 `_tapCount` 分开，
      // 用来区分「完全没命中」与「命中了但手势被上层竞技场抢走」。
      //
      // 只在诊断开关打开时才 setState —— 正式包里这行是死代码，
      // 不会带来一次多余的 rebuild。
      onTapDown: (_) {
        if (!kWeiboDiagnosticsEnabled) return;
        if (mounted) setState(() => _downCount++);
      },
      // 单击：显示 ↔ 隐藏（与 B 站一致）。
      onTap: _toggleControls,
      // 双击：播放 / 暂停（用户明确要求「双击播放，双击暂停」）。
      onDoubleTap: () => unawaited(_togglePlay()),
      onLongPressStart: _onLongPressStart,
      onLongPressEnd: _onLongPressEnd,
      onLongPressCancel: _onLongPressCancel,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
    );
  }

  Widget _errorLayer() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white70, size: 28),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!.message,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: _init,
                icon: const Icon(Icons.refresh_rounded,
                    size: 16, color: Colors.white),
                label: const Text('重试',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部控制栏：播放/暂停 + 进度 + 时间 + 全屏。
  ///
  /// 布局与 B 站播放页一致（`player_controls_overlay.dart` 的底条），
  /// 但**没有弹幕相关按钮**：微博没有弹幕数据，画一个点了没反应的
  /// 弹幕开关比不给更糟（用户也明确要求「不需要弹幕功能」）。
  ///
  /// ## 命中区域必须收窄
  ///
  /// 用 `Positioned(left/right/bottom)` 而不是 `Positioned.fill + Align`：
  /// **只有底部条本身**占命中区域。`Align` 会撑满整个可用空间
  /// （`hitTestSelf` 为 false 但它的 child 会被布局到整块区域，
  /// 上层 Stack 子节点优先命中），结果「双击画面暂停」「长按快进」
  /// 全被这层吃掉 —— 本轮真机前的单测就是这样发现它的。
  ///
  /// 早先这里还套过一个 `IgnorePointer`（默认 `ignoring: true`），
  /// 那会让整条控制栏的按钮全点不动：渲染正常、点击全失效，
  /// 这种错法在截图上完全看不出来（历史教训见 §7.10 的渐变装饰层）。
  Widget _controlsLayer() {
    final Duration total = _effectiveDuration;
    final Duration position = _player?.position ?? Duration.zero;
    final double fraction = _dragPreview ?? _progressFraction;
    final bool scrubbing = _dragPreview != null;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // ⚠️ 这层 `GestureDetector` 是**必须**的，用来「吃掉」控制栏范围内的点击。
      //
      // 不加的话：点控制栏按钮时，`InkWell`（按钮）与下面手势层的
      // `onTap`（切换控制栏）会**同时进入手势竞技场**，而手势层是 opaque 的、
      // 又在 Stack 下层，真机上表现为「点了暂停，视频暂停了，
      // 但控制栏同时被隐藏」—— 诊断角标上的 `tap` 会在点按钮时 +1。
      //
      // 不给 `onTapDown` 空实现 —— 只注册 `onTapDown` 的手势识别器在手势
      // 竞技场里会被判为「不参与竞争」，事件照样漏到下面。
      // 必须注册 `onTap`（哪怕动作是空的）才会真正赢下竞技场并消费事件。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Container(
          // 纯色半透明渐变不放 `BackdropFilter`：列表内禁止毛玻璃
          // （会显著掉帧，项目硬约束）。
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Color(0x00000000), Color(0xCC000000)],
            ),
          ),
          padding: const EdgeInsets.fromLTRB(6, 18, 6, 4),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: _playing ? '暂停' : '播放',
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: Icon(
                  _playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                ),
                onPressed: () => unawaited(_togglePlay()),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: fraction,
                    // 拖动进度条本身也走 seek（与横向拖动互补）。
                    onChanged: total <= Duration.zero
                        ? null
                        : (double v) => setState(() => _dragPreview = v),
                    onChangeEnd: total <= Duration.zero
                        ? null
                        : (double v) {
                            setState(() => _dragPreview = null);
                            unawaited(
                              _player?.seek(Duration(
                                    milliseconds:
                                        (v * total.inMilliseconds).round(),
                                  )) ??
                                  Future<void>.value(),
                            );
                            _scheduleHide();
                          },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  // 拖动时显示目标位置，松手才回到真实进度 ——
                  // 否则数字会跟手指打架。
                  '${_fmt(scrubbing
                      ? Duration(
                          milliseconds:
                              (fraction * total.inMilliseconds).round())
                      : position)} / ${_fmt(total)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    height: 1.2,
                    fontFeatures: <FontFeature>[
                      // 等宽数字：否则秒数跳动时整行左右抖。
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              if (widget.allowFullscreen)
                IconButton(
                  tooltip: '全屏',
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  icon: const Icon(Icons.fullscreen_rounded,
                      color: Colors.white),
                  onPressed: () => unawaited(_toggleFullscreen()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// `mm:ss` / `h:mm:ss`。负值按 `0:00` 处理（时长未就绪时会出现）。
  static String _fmt(Duration d) {
    final int total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}
