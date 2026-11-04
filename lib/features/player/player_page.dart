import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../core/storage/prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/logger.dart';
import '../../data/bili/bili_models.dart';
import '../../data/models/danmaku_item.dart';
import '../../providers.dart';
import '../../widgets/danmaku_font_scale_selector.dart';
import '../../widgets/error_view.dart';
import '../../widgets/video_description.dart';
import '../../widgets/video_stats_row.dart';
import '../comments/comment_section.dart';
import 'danmaku/danmaku_engine.dart';
import 'danmaku/danmaku_overlay.dart';
import 'playback_clock.dart';
import 'playback_progress.dart';
import 'player_adapter.dart';
import 'player_controls_controller.dart';
import 'player_controls_overlay.dart';
import 'player_load_failure.dart';
import 'player_options_button.dart';

/// 视频播放页：内置播放 + 弹幕 + 手势 + 全屏 + 评论。
///
/// 所有失败路径都必须产出可读错误（需求：WBI 签名失败也不许黑屏）。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.bvid,
    this.aid,
    this.page = 1,
    this.fallbackTitle = '',
  });

  final String bvid;

  /// RSS 里可能只有 bvid，也可能从 av 号拿到 aid。
  final int? aid;

  /// 分 P（从链接的 `?p=` 解析）。
  final int page;

  final String fallbackTitle;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  late final PlaybackClock _clock;
  final DanmakuEngine _engine = DanmakuEngine();

  /// 缓存的 `Prefs` 实例。
  ///
  /// 为什么不在需要时 `ref.read(prefsProvider)`：`dispose()` 里 `ref` 已经
  /// 失效（见 dispose 的注释），而进度落盘恰好只发生在那里。initState 里
  /// 取一次并持有，两个路径都能用。
  late final Prefs _prefs;

  BiliVideoInfo? _info;
  RrhaPlayer? _player;
  PlayUrlResult? _playUrl;

  AppError? _error;
  bool _loading = true;

  /// 当前加载走到哪一步：失败时用它决定用户看到什么文案、日志记什么阶段。
  PlayerLoadStage _stage = PlayerLoadStage.videoInfo;

  /// 加载代次：每次 [_load] 自增。
  ///
  /// 超时之后，上一次加载的 Future 其实还在跑（Dio 的请求、libmpv 的初始化
  /// 都不是说停就停）。没有这个代次，迟到的回调会把新状态覆盖成「加载中」，
  /// 或者让已经显示错误的页面又冒出画面 —— 表现为「点了重试还是黑屏」。
  int _loadGeneration = 0;

  AppError? _danmakuError;
  bool _danmakuLoading = false;
  int _danmakuCount = 0;

  bool _fullscreen = false;

  /// 控制栏显隐 + 3 秒自动隐藏 + 交互重置（纯 Dart，单测覆盖时序）。
  late final PlayerControlsController _controls;
  int _currentPage = 1;

  bool _playing = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double? _scrubValue;

  /// 当前倍速（1.0 = 原速）。
  ///
  /// 与播放器的 `speed` 保持一致：长按期间是 [longPressSpeed]，松手回到
  /// 用户所选档位 [AppConfig.playbackSpeeds] 中的那个值。
  double _speed = 1.0;

  /// 用户手动选定的倍速（长按结束要回到它，不是回到 1.0）。
  double _baseSpeed = 1.0;

  /// 是否正处于「长按快进」状态。
  ///
  /// 这个标志有两个用途：
  /// 1. 长按后手指继续滑动时，忽略横向拖动（否则会一边加速一边乱 seek）；
  /// 2. 松手时据此决定要不要复位倍速（避免重复调用 setSpeed）。
  bool _longPressing = false;

  /// 长按加速的倍速（B 站 App 与各家播放器一致用 2x）。
  static const double _longPressSpeed = 2.0;

  /// 「已从 xx:xx 继续」提示的当前值；null = 不显示。
  ///
  /// 为什么需要它：进度恢复现在是**静默跳转**（用户要求不弹窗），
  /// 若画面里一点反馈都没有，看到「视频从中间开始」会以为坏了。
  /// 一条 2.5 秒的角标既解释了原因，又不阻塞任何操作。
  Duration? _resumeHint;
  Timer? _resumeHintTimer;

  /// 是否已从通道 A（ExoPlayer）回退到通道 B（libmpv）。
  ///
  /// 用于界面标签如实反映实际生效的通道 —— 否则「通道A」的字样会误导排查。
  bool _fellBackToMpv = false;

  /// 进度条专用（低频，2~10Hz）。
  ///
  /// 刻意不复用 [_clock.positionMs]：那个每帧都在变，会让进度条与时间文本
  /// 每帧重建（Slider 的重建成本并不低），在验收 45fps 时是纯粹的浪费。
  final ValueNotifier<double> _progressMs = ValueNotifier<double>(0);

  /// 弹幕层的「非时钟」重绘触发源。
  ///
  /// 弹幕层只被播放位置时钟驱动重绘，于是有两类变化会「改了却看不见」：
  /// 1. 弹幕刚装载完（暂停中打开视频时，要等下一次位置回调才出现）；
  /// 2. 切换「显示弹幕 / 透明度」等设置（暂停时完全看不到反馈）。
  /// 这两处显式 tick 一次即可，不引入任何 widget 重建。
  final ValueNotifier<int> _danmakuTick = ValueNotifier<int>(0);

  // 手势状态
  double _dragStartX = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _dragPreview = Duration.zero;
  bool _dragging = false;

  bool _vDragging = false;
  bool _vDragLeftSide = true;
  double _vDragAccum = 0;
  double _vStartBrightness = 1.0;
  double _vStartVolume = 1.0;

  double _brightness = 1.0;
  double _volume = 1.0;

  /// 评论区锚点：统计行点「评论」时滚到这里。
  ///
  /// 为什么用 GlobalKey 而不是 ScrollController：`CommentSection` 自己持有
  /// 内部 `ListView` 的 controller（`embedded == false`），播放页拿不到；
  /// 而把评论区改成 `embedded: true` 塞进外层滚动会破坏它自带的
  /// 「滚到底自动翻页」（那正是 §7.7 修好的能力）。用 `Scrollable.ensureVisible`
  /// 既不动评论组件，也不需要跨组件共享 controller。
  final GlobalKey _commentAnchorKey = GlobalKey();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<void>? _completedSub;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.page;

    // 先缓存 Prefs：dispose 里不能再碰 ref（见 dispose 的注释）。
    _prefs = ref.read(prefsProvider);

    // 倍速是全局偏好（「今天想快点看完」），不是内容属性：进页面就套上上次的值。
    _baseSpeed = _prefs.playbackSpeed;
    _speed = _baseSpeed;

    _controls = PlayerControlsController()
      ..onChanged = () {
        if (mounted) setState(() {});
      }
      // 一进来就起表：视频刚打开时用户多半在看画面，3 秒后控制栏自己让位。
      ..bump();

    _clock = PlaybackClock(vsync: this);
    _clock.onHardSeek = () => _engine.seekTo(_clock.positionMs.value);
    _clock.setSpeed(_speed);

    _engine.updateSettings(ref.read(settingsProvider).danmaku);

    unawaited(_load());
  }

  @override
  void dispose() {
    // 退出时必须先把进度落盘：`_player` 一旦 dispose，`position` 就归零了。
    //
    // ⚠️ 这里**只能碰 `Prefs` 实例，绝对不能碰 `ref`**。
    //
    // 真机实测（2026-10-21，运行日志）：
    //     [PlayerPage] 保存播放进度失败（忽略）：Bad state:
    //     Cannot use "ref" after the widget was disposed.
    // 原因是 `dispose()` 已经在 `super.dispose()` 的流程里、State 已解绑，
    // 此时 `ref.read(...)` 直接抛 —— 于是「进度记忆」在最关键的路径上
    // 一次都没写成过：用户永远看不到「继续播放」。因为被 catch 吞成一行
    // 警告，这个缺陷在界面上**完全看不出来**（只会觉得「这功能没做」）。
    //
    // 修法：`Prefs` 在 initState 里就取好并缓存，dispose 时只用那个实例。
    final savedPos = _position > Duration.zero ? _position : _player?.position;
    final savedDur = _duration > Duration.zero ? _duration : _player?.duration;
    unawaited(_persistPosition(savedPos, savedDur));
    _resumeHintTimer?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    _durationSub?.cancel();
    _completedSub?.cancel();
    _player?.dispose();
    _clock.dispose();
    _progressMs.dispose();
    _danmakuTick.dispose();
    _engine.clear();
    _controls.dispose();
    unawaited(_restoreOrientation());
    super.dispose();
  }

  Future<void> _restoreOrientation() async {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // ------------------------------------------------------------ 加载流程

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    final startedAt = DateTime.now();
    _stage = PlayerLoadStage.videoInfo;

    setState(() {
      _loading = true;
      _error = null;
      _danmakuError = null;
    });

    try {
      final repo = ref.read(videoRepoProvider);
      // 显式卡 12 秒：Dio 的 8s connectTimeout 再加一次重试，断网时要拖到
      // 一分钟才报错，那期间页面就是「黑屏 + 转圈」，正是用户报的问题。
      final info = await repo
          .videoInfo(bvid: widget.bvid, aid: widget.aid)
          .timeout(AppConfig.playerInfoTimeout);
      if (!mounted || gen != _loadGeneration) return;
      Log.d(
        'PlayerPage',
        '加载视频信息成功 ${PlayerLoadFailure.logLine(
          stage: PlayerLoadStage.videoInfo,
          bvid: widget.bvid,
          cid: info.cidForPage(_currentPage),
          elapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
        )}',
      );
      setState(() => _info = info);

      _stage = PlayerLoadStage.playUrl;
      // 整段（取播放地址 + 初始化播放器）再加一道总超时兜底：
      // playUrl 内部可能连打两次请求，两次都慢时单靠分阶段超时会拖很久。
      await _preparePlayer(info, _currentPage, gen).timeout(
        AppConfig.playerLoadTotalTimeout,
      );
      if (!mounted || gen != _loadGeneration) return;
      unawaited(_loadDanmaku(info, _currentPage));
      // 进度记忆：进视频时**自动**跳到上次位置（用户要求不弹窗），
      // 画面内给一条 2.5 秒的「已从 xx:xx 继续」提示代替确认框。
      unawaited(_restorePlaybackPosition(info));
    } on AppError catch (e, st) {
      _failLoad(gen, e, st, startedAt);
    } catch (e, st) {
      _failLoad(gen, e, st, startedAt);
    }
  }

  /// 统一的失败收口：把异常归类成可读错误 + 记一条能定位问题的日志。
  void _failLoad(int gen, Object error, StackTrace st, DateTime startedAt) {
    if (!mounted || gen != _loadGeneration) return;

    final cid = _info?.cidForPage(_currentPage);
    final mapped = PlayerLoadFailure.map(
      stage: _stage,
      error: error,
      bvid: widget.bvid,
      cid: cid,
      channel: _player == null ? null : (_fellBackToMpv ? 'B(libmpv)' : 'A'),
    );

    Log.e(
      'PlayerPage',
      '加载失败 ${PlayerLoadFailure.logLine(
        stage: _stage,
        bvid: widget.bvid,
        cid: cid,
        channel: _fellBackToMpv ? 'B(libmpv)' : 'A',
        error: error,
        elapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
      )}',
    );
    Log.e('PlayerPage', '加载失败堆栈', error, st);

    setState(() {
      _error = mapped;
      _loading = false;
    });
  }

  /// 取流 + 初始化播放器。
  ///
  /// [qn] 是本次请求的清晰度；null 表示用「用户上次选的那档，没选过就用默认」。
  /// [resumeAt] 是重建后要跳回的位置（切清晰度/切分 P 时用，见 [_switchQuality]）。
  Future<void> _preparePlayer(
    BiliVideoInfo info,
    int page,
    int gen, {
    int? qn,
    Duration? resumeAt,
  }) async {
    final cid = info.cidForPage(page);
    final wantQn = qn ?? _effectiveQn();
    final stageStarted = DateTime.now();
    var result = await ref.read(videoRepoProvider).playUrl(
          bvid: info.bvid,
          cid: cid,
          qn: wantQn,
        );
    if (!mounted || gen != _loadGeneration) return;
    Log.d(
      'PlayerPage',
      '取播放地址成功 ${PlayerLoadFailure.logLine(
        stage: PlayerLoadStage.playUrl,
        bvid: info.bvid,
        cid: cid,
        channel: result.channel.name,
        elapsedMs: DateTime.now().difference(stageStarted).inMilliseconds,
      )}',
    );

    await _teardownPlayer();

    // 通道 A 失败时自动切到通道 B（libmpv）。
    //
    // 实机背景：华为 P40 Pro 上 MP4 单流走 ExoPlayer 会因海思硬解器
    // 初始化失败而报 MediaCodecVideoRenderer error（详见 player_adapter.dart
    // 中 createMpvFallbackFor 的注释）。libmpv 不依赖系统 MediaCodec，
    // 同一路流交给它能正常播放，所以这里必须兜底，否则用户直接看到黑屏报错。
    //
    // ⚠️ initialize() 必须带超时：真机上曾出现过「两条通道都卡在初始化、
    // 界面永远转圈」的情况（Impeller 与 libmpv 的纹理兼容问题就是其一）。
    // 没有超时的话，失败不会变成错误，用户只能看着黑屏。
    _stage = PlayerLoadStage.initChannelA;
    final aStarted = DateTime.now();

    // 诊断开关：跳过通道 A，直接用 DASH + libmpv 播放。
    //
    // 通道 B 平时只在通道 A 失败时才被走到，属于「灰度路径」；一旦它出
    // 「有画面没声音」这类问题，正常使用根本复现不了。强制走一次是唯一
    // 可靠的回归手段（设置页可随时关掉）。
    final forceB = ref.read(settingsProvider).forceChannelB;
    RrhaPlayer player;
    if (forceB) {
      _stage = PlayerLoadStage.initChannelB;
      Log.w('PlayerPage', '已开启「强制通道 B」，跳过通道 A');
      final dash = await ref.read(videoRepoProvider).playUrl(
            bvid: info.bvid,
            cid: cid,
            qn: wantQn,
            preferDash: true,
            useCache: false,
          );
      final forced = createMpvFallbackFor(dash);
      if (forced == null) {
        throw AppError(
          AppErrorKind.parse,
          '强制通道 B 时没有取到可用的 DASH 流',
          detail: 'bvid=${info.bvid} cid=$cid channel=${dash.channel.name}',
          retryable: true,
        );
      }
      _fellBackToMpv = true;
      result = dash;
      player = forced;
    } else {
      player = createPlayerFor(result);
    }
    try {
      await player.initialize().timeout(AppConfig.playerInitTimeout);
      // 日志里的通道名必须与真实走的通道一致，否则排查时会把人带沟里
      // （强制通道 B 时若仍打印「通道 A 初始化成功」，日志就自相矛盾）。
      Log.d(
        'PlayerPage',
        '${_fellBackToMpv ? '通道 B' : '通道 A'} 初始化成功 '
            '${PlayerLoadFailure.logLine(
          stage: _stage,
          bvid: info.bvid,
          cid: cid,
          channel: _fellBackToMpv
              ? 'B(libmpv)'
              : 'A(${result.channel.name})',
          elapsedMs: DateTime.now().difference(aStarted).inMilliseconds,
        )}',
      );
    } catch (e, st) {
      // 通道 A（MP4 单流）失败时，**优先改用 DASH 流**，而不是把同一个 MP4 URL
      // 再塞给 libmpv。
      //
      // 真机实例（BV1XUJe6KE31）：fnval=1 返回的 MP4 单流挂在
      // `cbf929o.edge.mountaintoys.cn` 这个节点上，ExoPlayer 拉不到（超时），
      // 换成 libmpv 也照样 `Failed to open`；而同一时刻重新请求 fnval=4048 拿到
      // 的 DASH 流是 200（带 Referer）。也就是说「MP4 流坏了 ≠ 视频坏了」。
      Log.w('PlayerPage', '通道 A 初始化失败，尝试改取 DASH 流：$e');
      RrhaPlayer? fallback;
      try {
        final dash = await ref.read(videoRepoProvider).playUrl(
              bvid: info.bvid,
              cid: cid,
              qn: wantQn,
              preferDash: true,
              useCache: false,
            );
        if (dash.channel == PlayChannel.dash && dash.videoUrl != null) {
          final candidate = createMpvFallbackFor(dash);
          if (candidate != null) {
            fallback = candidate;
            result = dash; // 让界面标签如实显示成走 DASH
            Log.d(
              'PlayerPage',
              '已改取 DASH 流（视频地址长度 ${dash.videoUrl?.length}）',
            );
          }
        }
      } catch (e2) {
        Log.w('PlayerPage', '改取 DASH 流也失败：$e2');
      }

      // DASH 那条路不通时，才退而用原来的（可能是坏节点的）MP4 单流。
      fallback ??= createMpvFallbackFor(result);
      if (fallback == null) rethrow;

      Log.w('PlayerPage',
          '通道 A 初始化失败，回退到通道 B（libmpv）：$e');
      Log.d('PlayerPage', '通道 A 失败堆栈：$st');
      await player.dispose();
      if (!mounted || gen != _loadGeneration) return;

      player = fallback;
      _stage = PlayerLoadStage.initChannelB;
      final bStarted = DateTime.now();
      try {
        await player.initialize().timeout(AppConfig.playerInitTimeout);
      } catch (e2, st2) {
        Log.e('PlayerPage', '通道 B 也初始化失败', e2, st2);
        rethrow;
      }
      // 记下实际生效的通道，供界面标签与排查使用。
      _fellBackToMpv = true;
      Log.d(
        'PlayerPage',
        '通道 B 初始化成功（已回退）${PlayerLoadFailure.logLine(
          stage: PlayerLoadStage.initChannelB,
          bvid: info.bvid,
          cid: cid,
          channel: 'B(libmpv)',
          elapsedMs: DateTime.now().difference(bStarted).inMilliseconds,
        )}',
      );
    }

    if (!mounted || gen != _loadGeneration) {
      await player.dispose();
      return;
    }

    _stage = PlayerLoadStage.startPlayback;
    _bindPlayer(player);
    setState(() {
      _player = player;
      _playUrl = result;
      _loading = false;
    });
    // 倍速必须在 play() 之前落到播放器上：先开播再变速会出现
    // 「第一秒是原速、之后才变快」的可闻跳变。
    if (_speed != 1.0) {
      await player.setSpeed(_speed);
    }
    await player.play();
    // 切清晰度 / 切分 P 的重建：**必须跳回原位**，否则用户点一下清晰度
    // 就被踢回视频开头（§3.3 明确点名的坑）。
    final resume = resumeAt;
    if (resume != null && resume > Duration.zero) {
      await player.seek(resume);
      _clock.seek(resume);
    }
    // 打开即播放：再对齐一次，保证「自动播放 + 弹幕立即滚动 + 图标为 ⏸」
    // 三件事同时成立，而不是等某次流推送来纠正。
    _syncFromPlayer(player);
  }

  void _bindPlayer(RrhaPlayer player) {
    _positionSub = player.positionStream.listen((p) {
      if (!mounted) return;
      _position = p;
      // 进度条走低频通道；弹幕走每帧插值的 _clock。
      _progressMs.value = p.inMilliseconds.toDouble();
      _clock.onPosition(p);
    });
    _playingSub = player.playingStream.listen((playing) {
      if (!mounted) return;
      _clock.setPlaying(playing);
      setState(() => _playing = playing);
    });
    _durationSub = player.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _completedSub = player.completedStream.listen((_) {
      if (!mounted) return;
      // 播放结束必须**连时钟一起停**：只把按钮改回 ▶ 的话，
      // PlaybackClock 仍在外推，弹幕会继续空跑（时间轴越走越远）。
      _syncFromPlayer(player);
    });

    // 底层播放器报错（典型：libmpv 拉 DASH 流被 403 拦下）。
    //
    // 这类失败**不抛异常、不结束**，只是永远没有画面：弹幕还在滚、进度条还在走，
    // 用户看到的就是「黑屏但一切正常」。必须在这里转成可读错误 + 给重试按钮，
    // 否则又回到「黑屏无从下手」的老问题。
    // 不保存 subscription：adapter 在 dispose 时会关闭这条流，订阅随之结束。
    player.errorStream.listen((message) {
      if (!mounted) return;
      final cid = _info?.cidForPage(_currentPage);
      final detail = '${_stage.label} · bvid=${widget.bvid}'
          '${cid != null ? ' · cid=$cid' : ''}'
          ' · 通道=${_fellBackToMpv ? 'B(libmpv)' : 'A'}'
          '\n播放器原始报错：$message';
      Log.e('PlayerPage', '播放器报错 ${PlayerLoadFailure.logLine(
        stage: _stage,
        bvid: widget.bvid,
        cid: cid,
        channel: _fellBackToMpv ? 'B(libmpv)' : 'A',
        error: message,
      )}');
      setState(() {
        _error = AppError(
          AppErrorKind.parse,
          '播放失败：$message',
          detail: detail,
          retryable: true,
        );
        _loading = false;
      });
    });

    // 订阅完之后**主动对齐一次真实状态**。
    //
    // 必要性：`_preparePlayer()` 的调用顺序是「先 _bindPlayer()、后 play()」，
    // 而 libmpv 在 `open()` 完成后就已经开始播放。只依赖流推送的话，
    // 那次「已经在播放」的变化发生在订阅窗口之外，`_playing` 就永远停在
    // 初始 false —— 按钮显示 ▶、`PlaybackClock` 不推进（弹幕不动），
    // 于是第一次点击实际执行的是 pause()、第二次才真正 play()。
    _syncFromPlayer(player);
  }

  /// 把界面状态与弹幕时钟对齐到播放器的真实状态（不依赖任何状态变化事件）。
  void _syncFromPlayer(RrhaPlayer player) {
    if (!mounted) return;

    final playing = player.isPlaying;
    _clock.setPlaying(playing);
    // 注意：**不再**用播放状态去干预控制栏的自动隐藏。
    // 早先是 `setPaused(!playing)`，结果视频一进暂停/加载态控制栏就永久挂住 ——
    // 那正是用户报的「控制栏一直显示、点不掉」的根因（详见控制器的类注释）。
    _controls.setPaused(!playing);

    final duration = player.duration;
    if (_playing != playing || (duration > Duration.zero && _duration != duration)) {
      setState(() {
        _playing = playing;
        if (duration > Duration.zero) _duration = duration;
      });
    }
  }

  Future<void> _teardownPlayer() async {
    await _positionSub?.cancel();
    await _playingSub?.cancel();
    await _durationSub?.cancel();
    await _completedSub?.cancel();
    _positionSub = null;
    _playingSub = null;
    _durationSub = null;
    _completedSub = null;

    final player = _player;
    _player = null;
    await player?.dispose();
  }

  // ------------------------------------------------------------ 清晰度 / 倍速 / 进度

  /// 播放偏好里存的 qn；没选过就返回 [AppConfig.preferredQuality]。
  int _effectiveQn() =>
      _prefs.preferredQn ?? AppConfig.preferredQuality;

  /// 在当前 P 的进度记录键：`bvid@p分`。
  ///
  /// 带分 P 的理由：同一个 bvid 的不同 P 是不同内容，共用一条记录会让
  /// 「P1 看到一半、进 P2 直接跳到 P1 的进度」。
  String get _progressKey => PlaybackProgress.keyFor(widget.bvid, _currentPage);

  Future<void> _savePlaybackPosition() async {
    final player = _player;
    if (player == null) return;
    final pos = _position > Duration.zero ? _position : player.position;
    final dur = _duration > Duration.zero ? _duration : player.duration;
    await _persistPosition(pos, dur);
  }

  /// 真正写盘。位置与时长**由调用方先同步取好**（见 dispose 里的说明）。
  Future<void> _persistPosition(Duration? pos, Duration? dur) async {
    try {
      switch (PlaybackProgress.decide(position: pos, duration: dur)) {
        case PlaybackProgressAction.skip:
          return;
        case PlaybackProgressAction.clear:
          await _prefs.clearPlaybackPosition(_progressKey);
        case PlaybackProgressAction.save:
          await _prefs.setPlaybackPositionMs(
            _progressKey,
            pos!.inMilliseconds,
          );
      }
    } catch (e) {
      // 进度记忆失败绝不能影响播放/退出。
      Log.w('PlayerPage', '保存播放进度失败（忽略）：$e');
    }
  }

  /// 进入时**自动**跳回上次看到的位置。
  ///
  /// ## 为什么不再弹「继续播放？」
  ///
  /// 最初按 §3.5 做的是弹窗确认（怕静默跳转让人以为视频坏了）。
  /// 2026-10-21 用户明确要求：**不要弹窗，默认继续播放**。
  ///
  /// 于是这里改成「静默跳转 + 画面内提示」：
  /// - 直接 `seek` 到上次位置，不打断；
  /// - 同时在画面中央显示一条 `已从 02:07 继续` 的短提示（约 2.5 秒后自动消失）。
  ///   这条提示解决的就是当初那个「以为视频坏了」的问题，但不需要用户点一下。
  ///
  /// 跳转的时机很关键：必须在播放器 `initialize()` **之后**（否则 seek 会被
  /// 媒体的初始 position 覆盖回 0），这一点由调用点保证（见 `_load`）。
  Future<void> _restorePlaybackPosition(BiliVideoInfo info) async {
    final ms = _prefs.playbackPositionMs(_progressKey);
    final dur = _duration > Duration.zero
        ? _duration
        : Duration(seconds: info.duration);
    if (!PlaybackProgress.shouldOfferResume(savedMs: ms, duration: dur)) return;
    if (!mounted) return;

    final resume = Duration(milliseconds: ms!);
    Log.d(
      'PlayerPage',
      '自动继续播放：跳转到 ${_formatDuration(resume)} '
          '（当前 ${_formatDuration(_position)} / '
          '总时长 ${_formatDuration(_duration)}）',
    );
    await _seekTo(resume);
    if (!mounted) return;

    // 画面内短提示：跳转是静默的，用户需要知道「为什么不是从头开始」。
    setState(() => _resumeHint = resume);
    _resumeHintTimer?.cancel();
    _resumeHintTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _resumeHint = null);
    });

    // 跳转后再对齐一次真实位置：某些实现（ExoPlayer 在还没缓冲到目标点时）
    // 会先把 position 报回一个较早的值，日志里要能看出「请求 02:07、落在 00:21」。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    Log.d(
      'PlayerPage',
      '自动继续播放：跳转后位置 '
          '${_formatDuration(_player?.position ?? Duration.zero)}',
    );
  }

  /// 切换清晰度：重新取流 → 重建播放器 → **跳回原位**。
  ///
  /// 顺序里每一步都踩过坑（§3.3 / §3.5）：
  /// 1. 重建前记下 position —— 播放器一 dispose，position 就归零；
  /// 2. 记住用户选择（`preferredQn`），下次进任意视频直接用它；
  /// 3. 新流可能根本不支持该档（不同稿件/账号权限不同），所以用的是
  ///    「接口实际返回的 quality」，而不是用户点的那个值。
  Future<void> _switchQuality(int qn) async {
    final info = _info;
    if (info == null) return;
    final current = _playUrl?.quality;
    if (current != null && current == qn) return;

    _controls.bump();
    final resume = _position > Duration.zero ? _position : _clock.anchorPosition;
    final gen = ++_loadGeneration;
    final startedAt = DateTime.now();
    _stage = PlayerLoadStage.playUrl;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 先落盘用户选择：即使这次重建失败，下次进来也是他要的档位。
      await _prefs.setPreferredQn(qn);
      await _preparePlayer(
        info,
        _currentPage,
        gen,
        qn: qn,
        resumeAt: resume,
      ).timeout(AppConfig.playerLoadTotalTimeout);
      if (!mounted || gen != _loadGeneration) return;
      Log.d(
        'PlayerPage',
        '清晰度切换完成 qn=$qn 实际=${_playUrl?.quality} '
            '${PlayerLoadFailure.logLine(
          stage: PlayerLoadStage.startPlayback,
          bvid: widget.bvid,
          cid: info.cidForPage(_currentPage),
          channel: _fellBackToMpv ? 'B(libmpv)' : 'A',
          elapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
        )}',
      );
    } on AppError catch (e, st) {
      _failLoad(gen, e, st, startedAt);
    } catch (e, st) {
      _failLoad(gen, e, st, startedAt);
    }
  }

  /// 切换倍速（并记住）。
  Future<void> _setSpeed(double speed) async {
    final player = _player;
    _baseSpeed = speed;
    _speed = speed;
    _clock.setSpeed(speed);
    if (mounted) setState(() {});
    await player?.setSpeed(speed);
    // 只记非原速：原速是默认值，不必占一个键。
    await _prefs.setPlaybackSpeed(speed);
  }

  /// 长按开始：加速到 2x。
  ///
  /// 与横向拖动共存的做法：拖动回调里先判 [_longPressing] 直接 return
  /// （长按后再滑动会同时触发两者，状态会互相踩）。
  void _onLongPressStart(LongPressStartDetails _) {
    if (_player == null || _error != null) return;
    _longPressing = true;
    _speed = _longPressSpeed;
    _clock.setSpeed(_longPressSpeed);
    _controls.bump();
    setState(() {});
    unawaited(_player?.setSpeed(_longPressSpeed) ?? Future<void>.value());
  }

  /// 长按结束：回到用户所选倍速。
  void _onLongPressEnd(LongPressEndDetails _) {
    if (!_longPressing) return;
    _longPressing = false;
    _speed = _baseSpeed;
    _clock.setSpeed(_baseSpeed);
    _controls.bump();
    setState(() {});
    unawaited(_player?.setSpeed(_baseSpeed) ?? Future<void>.value());
  }

  /// 长按被取消（滑出组件边界、被别的识别器抢走）：同样要复位倍速。
  ///
  /// 不做这件事的话，`onLongPressCancel` 之后倍速会**永久停在 2x** ——
  /// 用户只会觉得「视频莫名其妙变快了，怎么点都没用」。
  void _onLongPressCancel() {
    if (_longPressing) _onLongPressEnd(const LongPressEndDetails());
  }

  /// 打开「播放信息」：通道 / qn / 编解码等**开发者诊断**信息。
  ///
  /// §4.1 明确要求把「通道A(MP4 qn=64)」这类字样从元信息行里挪走 ——
  /// 它和「UP 主 · 时长 · 播放数」挤一行会让人以为它是给用户看的。
  void _showPlaybackInfo() {
    _controls.beginDrag();
    final result = _playUrl;
    final lines = <String>[
      '通道：${_fellBackToMpv ? 'B（libmpv，已回退）' : 'A（ExoPlayer）'}',
      if (result != null) '实际形态：${result.channel.name.toUpperCase()}',
      if (result != null) 'qn：${result.quality}',
      if (result != null && result.format != null) '格式：${result.format}',
      if (result != null && result.audioBandwidth > 0)
        '音频码率：${result.audioBandwidth ~/ 1000} kbps',
      if (result != null && result.videoCodecId != null)
        '视频 codecid：${result.videoCodecId}（7 = AVC / 12 = HEVC / 13 = AV1）',
      '倍速：${PlayerOptionsButton.formatSpeed(_speed)}'
          '${_longPressing ? '（长按中）' : ''}',
      'bvid：${widget.bvid}',
      if (_info != null) 'cid：${_info!.cidForPage(_currentPage)}',
    ];
    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('播放信息', style: TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(l, style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ).whenComplete(() {
        if (mounted) _controls.endDrag();
      }),
    );
  }

  /// 统计行点「评论」：把评论区滚进视野。
  void _scrollToComments() {
    _controls.bump();
    final ctx = _commentAnchorKey.currentContext;
    if (ctx == null) return;
    unawaited(
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 260),
        alignment: 0.0,
      ),
    );
  }

  Future<void> _loadDanmaku(BiliVideoInfo info, int page) async {
    final cid = info.cidForPage(page);
    setState(() {
      _danmakuLoading = true;
      _danmakuError = null;
    });

    try {
      final items = await ref.read(videoRepoProvider).danmaku(cid);
      if (!mounted) return;
      _engine.load(items);
      // 装载完立刻让弹幕层重绘一次：否则暂停中打开视频时，
      // 弹幕要等下一次位置回调（最长约 0.5s）才出现。
      _danmakuTick.value++;
      setState(() {
        _danmakuLoading = false;
        _danmakuCount = items.length;
      });
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _danmakuError = e;
        _danmakuLoading = false;
        _danmakuCount = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _danmakuError = AppError(AppErrorKind.unknown, '弹幕处理失败：$e');
        _danmakuLoading = false;
      });
    }
  }

  // ------------------------------------------------------------ 交互

  Future<void> _togglePlay() async {
    _controls.bump();
    final player = _player;
    if (player == null) return;
    if (player.isPlaying) {
      await player.pause();
      // 暂停即落盘：用户切走应用/直接杀进程时，dispose 不一定跑得到。
      unawaited(_savePlaybackPosition());
    } else {
      await player.play();
    }
    // 以真实状态收尾：某些实现（例如 libmpv 已经在目标状态）不会再推一次流，
    // 只靠订阅回调的话图标与弹幕时钟就可能停在上一状态。
    _syncFromPlayer(player);
  }

  Future<void> _seekTo(Duration position) async {
    _controls.bump();
    final clamped = _clampToDuration(position);
    await _player?.seek(clamped);
    _clock.seek(clamped);
    setState(() => _position = clamped);
  }

  /// 把目标位置夹到 [0, 总时长]。
  ///
  /// ⚠️ 总时长可能是 0（播放器还没推出 duration），此时**不能**夹成 0 ——
  /// 那会让「继续播放」刚跳过去就被拽回开头，看起来像「跳转无效」。
  /// 这种边界在真机上很容易撞到：`_duration` 只在 durationStream 推送后才有值，
  /// 而恢复进度的弹窗可能比它更早出现。
  Duration _clampToDuration(Duration position) {
    final total = _duration.inMilliseconds;
    if (total <= 0) return position < Duration.zero ? Duration.zero : position;
    return Duration(
      milliseconds: position.inMilliseconds.clamp(0, total),
    );
  }

  Future<void> _toggleFullscreen() async {
    _controls.bump();
    final next = !_fullscreen;
    setState(() => _fullscreen = next);

    if (next) {
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _switchPart(int page) async {
    final info = _info;
    if (info == null || page == _currentPage) return;
    _controls.bump();
    // 切分 P 前先把**当前这 P** 的进度落盘：否则「看到一半切去 P2 再回来」会丢进度。
    await _savePlaybackPosition();
    final gen = ++_loadGeneration;
    final startedAt = DateTime.now();
    _stage = PlayerLoadStage.playUrl;
    setState(() {
      _currentPage = page;
      _loading = true;
      _error = null;
    });
    try {
      await _preparePlayer(info, page, gen)
          .timeout(AppConfig.playerLoadTotalTimeout);
      if (!mounted || gen != _loadGeneration) return;
      unawaited(_loadDanmaku(info, page));
    } on AppError catch (e, st) {
      _failLoad(gen, e, st, startedAt);
    } catch (e, st) {
      _failLoad(gen, e, st, startedAt);
    }
  }

  Future<void> _toggleDanmakuEnabled() async {
    _controls.bump();
    final settings = ref.read(settingsProvider);
    await ref.read(settingsProvider.notifier).setDanmaku(
          settings.danmaku.copyWith(enabled: !settings.danmaku.enabled),
        );
  }

  void _showDanmakuSettings() {
    // 面板期间别让控制栏自己消失：用户改完设置回来还得再点一次唤出，很别扭。
    _controls.beginDrag();
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => const _DanmakuSettingsSheet(),
      ).whenComplete(() {
        if (mounted) _controls.endDrag();
      }),
    );
  }

  // ------------------------------------------------------------ 手势

  void _onDragStart(DragStartDetails d) {
    // 长按加速中又滑动：既加速又 seek 会让「长按快进」直接变成乱跳。
    // 这里直接忽略这次拖动，松手后倍速复位即可。
    if (_longPressing) return;
    _dragging = true;
    // 拖动期间停表：否则拖到一半控制栏消失，时间提示也跟着没了。
    _controls.beginDrag();
    _dragStartX = d.localPosition.dx;
    _dragStartPosition = _position;
    _dragPreview = _position;
  }

  void _onHorizontalDrag(DragUpdateDetails d) {
    if (_longPressing) return;
    final width = context.size?.width ??
        MediaQuery.of(context).size.width;
    if (width <= 0) return;
    final delta = d.localPosition.dx - _dragStartX;
    final ms = (_duration.inMilliseconds * (delta / width)).round();
    setState(() {
      _dragPreview = _dragStartPosition + Duration(milliseconds: ms);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    _controls.endDrag();
    unawaited(_seekTo(_dragPreview));
  }

  void _onVerticalDragStart(DragStartDetails d) {
    final width = context.size?.width ?? MediaQuery.of(context).size.width;
    _vDragging = true;
    _controls.beginDrag();
    _vDragLeftSide = d.localPosition.dx < width / 2;
    _vDragAccum = 0;
    _vStartBrightness = _brightness;
    _vStartVolume = _volume;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    final height = context.size?.height ?? 200;
    if (height <= 0) return;
    _vDragAccum += -d.delta.dy / height;

    if (_vDragLeftSide) {
      setState(() {
        _brightness = (_vStartBrightness + _vDragAccum).clamp(0.15, 1.0);
      });
    } else {
      final value = (_vStartVolume + _vDragAccum).clamp(0.0, 1.0);
      setState(() => _volume = value);
      unawaited(_player?.setVolume(value) ?? Future<void>.value());
    }
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    _vDragging = false;
    _controls.endDrag();
    setState(() {});
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    ref.listen<SettingsState>(settingsProvider, (previous, next) {
      _engine.updateSettings(next.danmaku);
      // 弹幕设置变更不经过播放时钟，不显式通知就看不到效果（暂停时尤其明显）。
      _danmakuTick.value++;
    });
    final settings = ref.watch(settingsProvider);

    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(child: _playerStack(settings)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _info?.title ?? widget.fallbackTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: Column(
        children: <Widget>[
          AspectRatio(aspectRatio: 16 / 9, child: _playerStack(settings)),
          Expanded(child: _lowerSection()),
        ],
      ),
    );
  }

  Widget _lowerSection() {
    final info = _info;
    if (info == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 头部（标题 / 元信息 / 简介 / 统计行 / 分P）**不能无限增高**：
        // 它下面是把剩余高度全吃掉的评论区，头部一旦超了就会在 6.1 寸机器上
        // RenderFlex overflow（§4.3 明确提醒过）。这里给头部设个上限，
        // 超出时头部自己内部滚动 —— 页面结构不变，小屏也不会崩。
        final maxHeader = constraints.maxHeight * 0.52;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeader),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: _header(info),
                ),
              ),
            ),
            const Divider(height: 1),
            // 视频评论：oid = aid，type = 1（与动态评论共用同一个组件）。
            // 这个 key 是统计行「点评论滚过去」的锚点。
            Expanded(
              child: CommentSection(
                key: _commentAnchorKey,
                oid: '${info.aid}',
                upMid: info.ownerMid,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 播放页头部：标题 → UP 主/时长/播放数 → 简介 → 统计行 → 分 P。
  ///
  /// 顺序刻意按 B 站本体的信息架构排（§4.3 的建议）：
  /// 用户肌肉记忆一致，「想看的数字在哪」不用重新学一遍。
  Widget _header(BiliVideoInfo info) {
    final desc = info.description?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          info.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 6),
        // 元信息行：**只留用户真正关心的东西**。
        // 通道与 qn 属于开发者诊断，已挪到「更多 → 播放信息」（§4.1）。
        Text(
          '${info.ownerName} · ${_formatDuration(Duration(seconds: info.duration))} · '
          '${_formatCount(info.view)} 播放',
          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
        ),
        if (desc.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          VideoDescription(text: desc),
        ],
        const SizedBox(height: 2),
        // 统计行：赞 / 币 / 藏 / 分享 / 评论（P0 · §3.1，数据早就在模型里）。
        VideoStatsRow(
          view: info.view,
          danmaku: info.danmakuCount,
          like: info.likeCount,
          coin: info.coinCount,
          favorite: info.favoriteCount,
          share: info.shareCount,
          reply: info.replyCount,
          onTapReply: _scrollToComments,
        ),
        if (info.isMultiPart) ...<Widget>[
          const SizedBox(height: 4),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: info.pages.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final p = info.pages[index];
                final selected = p.page == _currentPage;
                return ChoiceChip(
                  label: Text(
                    p.label,
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: selected,
                  onSelected: (_) => unawaited(_switchPart(p.page)),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _playerStack(SettingsState settings) {
    return Container(
      color: Colors.black,
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: _videoLayer()),

          // 亮度用应用内遮罩实现（不请求系统 WRITE_SETTINGS 权限）。
          if (_brightness < 0.999)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 1 - _brightness),
                ),
              ),
            ),

          // 弹幕层：必须 IgnorePointer，否则会吞掉手势。
          Positioned.fill(
            child: IgnorePointer(
              child: DanmakuOverlay(
                engine: _engine,
                clock: _clock.positionMs,
                extraRepaint: _danmakuTick,
              ),
            ),
          ),

          Positioned.fill(child: _gestureLayer()),

          // 「更多」入口：清晰度 / 倍速 / 分P（§3.3 / §3.4 / §3.6）。
          //
          // 放在手势层**之上**：它是一个有界按钮，不会像铺满全屏的容器那样
          // 吃掉下层手势（§7.10 的教训）。
          // 位置固定在右上角：普通态与全屏态共用同一份渲染，
          // 于是「全屏也能选清晰度/倍速/分P」不需要第二套实现。
          if (_player != null && _error == null)
            Positioned(
              right: 4,
              top: 40,
              child: Material(
                color: Colors.transparent,
                child: PlayerOptionsButton(
                  qualities: _playUrl?.qualities ?? const <QualityOption>[],
                  currentQuality: _playUrl?.quality ?? 0,
                  speed: _speed,
                  pages: _info?.pages ?? const <BiliPage>[],
                  currentPage: _currentPage,
                  onSelectQuality: (qn) => unawaited(_switchQuality(qn)),
                  onSelectSpeed: (v) => unawaited(_setSpeed(v)),
                  onSelectPage: (p) => unawaited(_switchPart(p)),
                  onOpenPlaybackInfo: _showPlaybackInfo,
                ),
              ),
            ),

          if (_controls.visible) _controlsOverlay(settings),

          _overlayIndicators(),
        ],
      ),
    );
  }

  Widget _videoLayer() {
    if (_error != null) {
      // ⚠️ 这里必须用紧凑样式的错误面板：
      // 视频区只有 16:9 那么高，完整版 ErrorView（大图标 + 折叠诊断 + 大按钮）
      // 会把「重试」按钮挤出可视区 —— 真机上表现为「有报错但点不到重试」。
      // 诊断详情改由专门的一行小字 + 「设置 → 运行日志」承担。
      final cid = _info?.cidForPage(_currentPage);
      return Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Flexible(
              child: ErrorView(
                error: _error!,
                onRetry: _load,
                compact: true,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${_stage.label} · bvid=${widget.bvid}'
              '${cid != null ? ' · cid=$cid' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
            const Text(
              '详细原因见「设置 → 运行日志」',
              style: TextStyle(fontSize: 10, color: Colors.white24),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final player = _player;
    if (player == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return player.buildView(context);
  }

  Widget _gestureLayer() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 单击：显示 ↔ 隐藏。
      //
      // ⚠️ 与 onDoubleTap 共存时，单击**必然**要等双击判定窗口（Flutter 内部
      // 约 300ms，不可配）。这是「保留双击播放/暂停」的固有代价：
      // 快速连点两次会被判成双击 → 暂停，而控制栏不变。
      // 因此痛感主要靠「3 秒自动隐藏」+ 隐藏做彻底来消化，
      // 不为它牺牲双击（用户已明确要求保留）。
      onTap: _controls.toggle,
      onDoubleTap: () => unawaited(_togglePlay()),
      // 长按加速（N1）：2x 播放，松手回原档位。
      //
      // 与下面三个 onHorizontalDrag* 可以同时注册：Flutter 的手势竞技场里
      // 长按（LongPressGestureRecognizer）和拖动（HorizontalDrag）是互斥竞争，
      // 按下不动 → 长按胜出；按下即移动 → 拖动胜出。它们不会同时触发。
      onLongPressStart: _onLongPressStart,
      onLongPressEnd: _onLongPressEnd,
      onLongPressCancel: _onLongPressCancel,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onHorizontalDrag,
      onHorizontalDragEnd: _onDragEnd,
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
    );
  }

  /// 拖动时的手势指示器 + 弹幕状态角标。
  ///
  /// 注意：这里**不能**整体包 `IgnorePointer`，否则左上角的「重试」会被
  /// 一并吞掉点不动；只把纯展示的拖动指示器包起来。
  Widget _overlayIndicators() {
    // 控制栏隐藏时，**除了「加载中 / 错误」这两类状态提示**，其余全部一起隐藏。
    //
    // 为什么加载态与错误态例外：它们是「这条内容现在是什么状态」的如实反馈，
    // 不是操作入口。隐藏它们只会让用户对着黑屏猜；而拖动指示器属于操作反馈，
    // 必须与控制栏同进同退。
    final showTransient = _controls.visible;

    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          // 长按加速提示：**不受控制栏显隐影响**。
          //
          // 理由：它是「你现在按住的那个动作」的即时反馈，不是操作入口。
          // 长按时控制栏正处在 3 秒自动隐藏的边缘，若跟它一起隐藏，
          // 用户会看到「画面变快了，但屏幕上什么都没有」，只能靠猜。
          if (_longPressing)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.fast_forward_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${PlayerOptionsButton.formatSpeed(_longPressSpeed)} 快进中',
                        style: const TextStyle(fontSize: 14, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 「已从 xx:xx 继续」的短提示（进度自动恢复用）。
          //
          // 同样**不受控制栏显隐影响**：它是进入这个视频那一刻的解释，
          // 只在开头 2.5 秒存在，跟控制栏的自动隐藏没有关系。
          if (_resumeHint != null)
            Positioned(
              // ⚠️ 放**右上**而不是左上：左上角是弹幕「加载中 / 加载失败」
              // 角标的位置，进视频那一刻两者必定同时出现，叠在一起会糊成一团。
              right: 8,
              top: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.history_rounded,
                        size: 13,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '已从 ${_formatDuration(_resumeHint!)} 继续',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (showTransient && _dragging)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_formatDuration(_dragPreview)} / ${_formatDuration(_duration)}',
                    style: const TextStyle(fontSize: 14, color: Colors.white),
                  ),
                ),
              ),
            ),
          if (showTransient && _vDragging)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        _vDragLeftSide
                            ? Icons.brightness_6_rounded
                            : Icons.volume_up_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${((_vDragLeftSide ? _brightness : _volume) * 100).round()}%',
                        style: const TextStyle(fontSize: 14, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_danmakuError != null)
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.subtitles_off_rounded,
                      size: 13,
                      color: Colors.orangeAccent,
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      '弹幕加载失败',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.orangeAccent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        _controls.bump();
                        final info = _info;
                        if (info != null) {
                          unawaited(_loadDanmaku(info, _currentPage));
                        }
                      },
                      child: const Text(
                        '重试',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_danmakuLoading)
            const Positioned(
              left: 8,
              top: 8,
              child: IgnorePointer(
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                    SizedBox(width: 6),
                    Text(
                      '弹幕加载中',
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 控制栏：交给 [PlayerControlsOverlay] 渲染。
  ///
  /// **不要**在把控制栏放回 `Stack` 时改变它与 [_gestureLayer] 的相对层级，
  /// 也不要在这里再包一层带 `decoration` / `color` 的铺满全屏的容器 ——
  /// 那会让下层手势层收不到事件（详见 [PlayerControlsOverlay] 的类注释，
  /// 以及 §7.10 记录的那个「控制栏点不掉」缺陷）。
  Widget _controlsOverlay(SettingsState settings) {
    return Positioned.fill(
      child: PlayerControlsOverlay(
        title: _info?.title ?? widget.fallbackTitle,
        danmakuCount: _danmakuCount,
        playing: _playing,
        progressMs: _progressMs,
        duration: _duration,
        danmakuEnabled: settings.danmaku.enabled,
        fullscreen: _fullscreen,
        progressBar: _progressBar(),
        onBack: () => Navigator.of(context).maybePop(),
        onTogglePlay: () => unawaited(_togglePlay()),
        onToggleDanmaku: () => unawaited(_toggleDanmakuEnabled()),
        onOpenDanmakuSettings: _showDanmakuSettings,
        onToggleFullscreen: () => unawaited(_toggleFullscreen()),
      ),
    );
  }

  Widget _progressBar() {
    final total = _duration.inMilliseconds.toDouble();
    return ValueListenableBuilder<double>(
      valueListenable: _progressMs,
      builder: (context, ms, _) {
        final fallback = total <= 0 ? 0.0 : (ms / total).clamp(0.0, 1.0);
        return Slider(
          value: _scrubValue ?? fallback,
          onChanged: total <= 0
              ? null
              : (v) => setState(() => _scrubValue = v),
          onChangeEnd: total <= 0
              ? null
              : (v) {
                  setState(() => _scrubValue = null);
                  unawaited(_seekTo(
                    Duration(milliseconds: (v * total).round()),
                  ));
                },
        );
      },
    );
  }

  // ------------------------------------------------------------ 格式化

  /// 时间格式化。单一实现在 [PlayerControlsOverlay.formatDuration]，
  /// 避免播放页与控制栏出现两套不一致的格式。
  static String _formatDuration(Duration d) =>
      PlayerControlsOverlay.formatDuration(d);

  static String _formatCount(int value) {
    if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return '$value';
  }
}

/// 播放器内的弹幕设置面板（与设置页共用同一份偏好）。
class _DanmakuSettingsSheet extends ConsumerWidget {
  const _DanmakuSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).danmaku;

    Future<void> update(DanmakuSettings value) =>
        ref.read(settingsProvider.notifier).setDanmaku(value);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '弹幕设置',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: settings.enabled,
            onChanged: (v) => update(settings.copyWith(enabled: v)),
            title: const Text('显示弹幕', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 4),
          DanmakuFontScaleSelector(
            value: settings.fontScale,
            compact: true,
            onChanged: (v) => update(settings.copyWith(fontScale: v)),
          ),
          const SizedBox(height: 8),
          Text(
            '透明度 ${(settings.opacity * 100).round()}%',
            style: const TextStyle(fontSize: 12),
          ),
          Slider(
            value: settings.opacity.clamp(0.1, 1.0),
            min: 0.1,
            max: 1.0,
            divisions: 18,
            onChanged: (v) => update(settings.copyWith(opacity: v)),
          ),
          Text(
            '同屏上限 ${settings.maxOnScreen} 条',
            style: const TextStyle(fontSize: 12),
          ),
          Slider(
            value: settings.maxOnScreen.clamp(50, 500).toDouble(),
            min: 50,
            max: 500,
            divisions: 9,
            onChanged: (v) => update(settings.copyWith(maxOnScreen: v.round())),
          ),
          if (settings.blockKeywords.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '已屏蔽关键词：${settings.blockKeywords.join('、')}',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 4),
          const Text(
            '关键词屏蔽、滚动时长在「设置 → 弹幕」中调整。',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
