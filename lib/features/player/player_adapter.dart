import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;

import '../../core/utils/logger.dart';
import '../../data/bili/bili_models.dart';

/// 播放器抽象。
///
/// 本项目需要两条播放通道：
/// - **通道 A**：B 站 `durl` 单文件 MP4 → `video_player`（ExoPlayer，
///   零额外体积、硬解性能最好）；
/// - **通道 B**：B 站 DASH 音视频分离流 → `media_kit`（libmpv），
///   音频通过 mpv 的 `audio-file` 选项附加。
///
/// 抽象出这层是为了让播放页完全不关心后端差异，也让「通道 B 出问题时
/// 换回通道 A」只需要改一处。
abstract class RrhaPlayer {
  /// 视频画面。
  Widget buildView(BuildContext context);

  Stream<Duration> get positionStream;

  /// 播放状态流。
  ///
  /// 实现方**必须保证订阅时补发当前值**（即新订阅者立刻收到 [isPlaying]）：
  /// 播放页是「先订阅、后 play()」，而且 libmpv 在 `open()` 后就自动播放，
  /// 错过那一次状态变化会让界面永远停在初始的 false
  /// （按钮显示 ▶、弹幕时钟不推进 → 一条弹幕都不动）。
  Stream<bool> get playingStream;

  /// 时长流。同样必须补发当前值：duration 往往只推一次。
  Stream<Duration> get durationStream;

  /// 播放结束（只发一次）。
  Stream<void> get completedStream;

  /// 播放**错误**流（尽力而为，可能为空）。
  ///
  /// 为什么需要它：真机上出现过「弹幕在滚、进度在走、但画面全黑、也没有声音」——
  /// 底层播放器其实拉流失败了（403/超时），可它既不抛异常也不结束，`initialize()`
  /// 照样返回成功。没有这条流，界面就只会静默黑屏，用户和开发者都无从下手。
  Stream<String> get errorStream;

  Duration get position;
  Duration get duration;
  bool get isPlaying;
  double get aspectRatio;

  /// 当前倍速（1.0 = 原速）。
  ///
  /// 播放页要用它实现「长按 2x、松手回到用户所选倍速」：只记一个全局变量的话，
  /// 用户选了 1.5x 再长按，松手会掉回 1.0x（真机上就是「松手后突然变慢」）。
  double get speed;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 0.0 ~ 1.0
  Future<void> setVolume(double volume);

  /// 设置播放倍速。`1.0` = 原速，`2.0` = 两倍速。
  ///
  /// 两条通道的原生 API 都支持（ExoPlayer `setPlaybackSpeed`、mpv `speed`），
  /// **必须两边都实现**：真机上 DASH 内容走通道 B 的比例不低，
  /// 只实现通道 A 会表现成「有的视频能长按快进、有的不能」。
  ///
  /// 变速时保持音调不变由底层负责：mpv 默认 `audio-pitch-correction=yes`，
  /// ExoPlayer 的时间拉伸同样不变调，因此这里不需要额外参数。
  Future<void> setSpeed(double speed);

  Future<void> dispose();
}

/// 根据 B 站 playurl 结果构造合适的播放器。
///
/// 传入的是**候选地址列表**（已按可达性排序，见 `BiliCdn`）：B 站把
/// `baseUrl` 调度到经常不可达的 PCDN 节点，适配器内部会在失败时逐个换节点，
/// 这样「换节点」这件事对播放页完全透明。
RrhaPlayer createPlayerFor(PlayUrlResult result) {
  switch (result.channel) {
    case PlayChannel.mp4:
      return VideoPlayerAdapter(
        urls: result.urls,
        headers: _biliHeaders,
      );
    case PlayChannel.dash:
      return MpvPlayerAdapter(
        videoUrls: result.videoUrls,
        audioUrls: result.audioUrls,
        headers: _biliHeaders,
      );
    case PlayChannel.none:
      throw StateError('没有可播放的流');
  }
}

/// 构造「通道 B（libmpv）」播放器，用于通道 A 失败后的兜底。
///
/// 【实机修复 · 2026-10-14】
/// 华为 P40 Pro（Kirin 990）上，MP4 单流走通道 A（ExoPlayer）会失败：
///     Decoder init failed: OMX.hisi.video.decoder.avc
///     Caused by: IllegalStateException at MediaCodec.native_stop
/// 格式本身被判定为 `format_supported=YES`，问题出在海思硬件解码器与
/// ExoPlayer 异步 MediaCodec 适配器的兼容性上，属于设备/ROM 层面的缺陷，
/// 应用侧无法通过参数绕开。
///
/// 但本工程本来就内置了 libmpv（`MpvPlayerAdapter`）作为通道 B，而 libmpv
/// 自带软件/硬件解码实现、不依赖系统 MediaCodec，因此把同一条 MP4 单流交给
/// 它就能正常播放。这不是降级妥协，而是双通道设计的本来用途。
///
/// 返回 null 表示该结果无法用通道 B 播放（没有可用的视频地址）。
RrhaPlayer? createMpvFallbackFor(PlayUrlResult result) {
  // DASH 直接被 mpv 接管；MP4 单流则把同一批候选地址当视频源，音频由容器自带。
  final videoUrls = result.channel == PlayChannel.dash && result.videoUrls.isNotEmpty
      ? result.videoUrls
      : result.urls;
  if (videoUrls.isEmpty) return null;
  return MpvPlayerAdapter(
    videoUrls: videoUrls,
    audioUrls: result.audioUrls,
    headers: _biliHeaders,
  );
}

/// B 站 CDN 对 Referer 有校验，播放请求必须带。
const Map<String, String> _biliHeaders = <String, String>{
  'Referer': 'https://www.bilibili.com/',
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
};

// ---------------------------------------------------------------- 通道 A

/// 基于 `video_player`（Android ExoPlayer）的适配器。
class VideoPlayerAdapter implements RrhaPlayer {
  VideoPlayerAdapter({required List<String> urls, Map<String, String>? headers})
      : _urls = urls,
        _headers = headers;

  /// 候选地址（已按可达性排序）。
  final List<String> _urls;
  final Map<String, String>? _headers;

  vp.VideoPlayerController? _controller;

  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();

  /// 播放状态流：**订阅时补发当前值**。
  ///
  /// 播放页是「先 `_bindPlayer()` 订阅、后 `play()`」，而 media_kit 在 `open()`
  /// 完成后自己就开始播放 —— 用普通 `StreamController` 会错过那次「已在播放」
  /// 的变化，订阅方就永远停在初始 `false`：按钮显示 ▶、`PlaybackClock` 不推进，
  /// 于是**弹幕一条都不动**（真机症状）。补发当前值从机制上杜绝这类竞态。
  late final StreamController<bool> _playing =
      StreamController<bool>.broadcast(onListen: _replayPlaying);

  /// 时长流同样补发：通道 A 只在 `initialize()` 里推一次 duration，
  /// 若订阅发生在初始化之后，那一次推送就丢了（进度条与总时长会一直停在 0）。
  late final StreamController<Duration> _duration =
      StreamController<Duration>.broadcast(onListen: _replayDuration);

  final StreamController<void> _completed =
      StreamController<void>.broadcast();

  /// 通道 A 的错误：video_player 把它塞在 `value.hasError` 里，
  /// 这里转成流，避免播放页去轮询 controller。
  final StreamController<String> _errors = StreamController<String>.broadcast();

  Duration _lastPosition = Duration.zero;
  bool _lastPlaying = false;
  bool _completedSent = false;
  bool _errorSent = false;
  double _volume = 1.0;
  double _speed = 1.0;

  void _replayPlaying() {
    if (!_playing.isClosed) _playing.add(isPlaying);
  }

  void _replayDuration() {
    if (!_duration.isClosed) _duration.add(duration);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Duration get position => _controller?.value.position ?? Duration.zero;

  @override
  Duration get duration => _controller?.value.duration ?? Duration.zero;

  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  double get speed => _speed;

  @override
  double get aspectRatio {
    final r = _controller?.value.aspectRatio ?? 16 / 9;
    if (r <= 0 || r.isNaN || r.isInfinite) return 16 / 9;
    return r;
  }

  @override
  Future<void> initialize() async {
    // 逐个尝试候选节点。
    //
    // 必要性：ExoPlayer 的 `initialize()` 是**同步等首帧**的，节点不可达时
    // 会一直卡到它自己的超时；而 B 站 durl 的首选节点（PCDN）经常不可达，
    // `backup_url` 里的标准 CDN 才是通的。不换节点的话，通道 A 会稳定失败，
    // 把每次播放都推给通道 B —— 而通道 B 又有它自己的问题（无声音等）。
    Object? lastError;
    StackTrace? lastStack;
    for (var i = 0; i < _urls.length; i++) {
      final controller = vp.VideoPlayerController.networkUrl(
        Uri.parse(_urls[i]),
        // video_player 2.14 的 httpHeaders 是非空参数，必须显式兜底。
        httpHeaders: _headers ?? const <String, String>{},
      );
      try {
        await controller.initialize();
        _controller = controller;
        await controller.setVolume(_volume);
        // 倍速要在 initialize 之后补一次：`initialize()` 之前调
        // `setPlaybackSpeed` 在部分 ExoPlayer 版本上会被丢弃，
        // 表现成「用户选了 1.5x、进页面却是原速」。
        if (_speed != 1.0) {
          await controller.setPlaybackSpeed(_speed);
        }
        _duration.add(controller.value.duration);
        controller.addListener(_onValueChanged);
        Log.d(
          'VideoPlayerAdapter',
          '通道 A 初始化完成（节点 ${i + 1}/${_urls.length}）：${_urls[i]}',
        );
        return;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        await controller.dispose();
        Log.w(
          'VideoPlayerAdapter',
          '通道 A 第 ${i + 1}/${_urls.length} 个节点失败：$e',
        );
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
    throw StateError('没有可用的播放地址');
  }

  void _onValueChanged() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;

    if (value.position != _lastPosition) {
      _lastPosition = value.position;
      if (!_position.isClosed) _position.add(value.position);
    }
    if (value.isPlaying != _lastPlaying) {
      _lastPlaying = value.isPlaying;
      if (!_playing.isClosed) _playing.add(value.isPlaying);
    }
    if (!_errorSent && value.hasError) {
      _errorSent = true;
      final desc = value.errorDescription ?? '播放器报错';
      Log.w('VideoPlayerAdapter', '通道 A 错误：$desc');
      if (!_errors.isClosed) _errors.add(desc);
    }
    if (!_completedSent &&
        value.isInitialized &&
        value.duration > Duration.zero &&
        !value.isPlaying &&
        value.position >= value.duration - const Duration(milliseconds: 200)) {
      _completedSent = true;
      if (!_completed.isClosed) _completed.add(null);
    }
  }

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> seek(Duration position) async {
    _completedSent = false;
    await _controller?.seekTo(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _controller?.setVolume(_volume);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 4.0);
    await _controller?.setPlaybackSpeed(_speed);
  }

  @override
  Future<void> dispose() async {
    _controller?.removeListener(_onValueChanged);
    await _controller?.dispose();
    await _position.close();
    await _playing.close();
    await _duration.close();
    await _completed.close();
  }

  @override
  Widget buildView(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: vp.VideoPlayer(controller),
      ),
    );
  }
}

// ---------------------------------------------------------------- 通道 B

/// 基于 `media_kit`（libmpv）的适配器，用于 DASH 音视频分离流。
///
/// 音频通过 mpv 的 `audio-file` 选项附加到同一条播放管线上，
/// 因此音视频天然同步，不需要手动对轴。
///
/// 【失败自愈】B 站每条流都给一批候选节点（PCDN + 标准 CDN），首选的那个
/// 经常不可达。这里在收到 mpv 错误且**尚未成功出画**时，自动换下一个候选
/// 节点重开，用户不会看到一次无谓的报错。
class MpvPlayerAdapter implements RrhaPlayer {
  MpvPlayerAdapter({
    required List<String> videoUrls,
    List<String> audioUrls = const <String>[],
    Map<String, String>? headers,
  })  : _videoUrls = videoUrls,
        _audioUrls = audioUrls,
        _headers = headers;

  final List<String> _videoUrls;
  final List<String> _audioUrls;
  final Map<String, String>? _headers;

  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  /// 当前使用的候选下标。
  int _videoIndex = 0;
  int _audioIndex = 0;

  /// 已经成功出过画（拿到视频尺寸）。只有它还是 false 时才值得换节点。
  bool _videoOk = false;

  /// 正在 `open()` 的过程中：此时冒出来的错误属于「上一个节点」的残留，
  /// 不能触发换节点，否则会连环重开。
  bool _opening = false;
  bool _disposed = false;

  String get _videoUrl => _videoUrls[_videoIndex];
  String? get _audioUrl =>
      _audioUrls.isEmpty ? null : _audioUrls[_audioIndex];

  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();

  /// 与通道 A 同一个理由：libmpv 在 `open()` 之后**立刻开始播放**，
  /// 而播放页是在 `initialize()` 返回之后才订阅的 —— 不补发当前值的话，
  /// 那次 `playing=true` 永远推不到界面（症状：已在播放，按钮却显示 ▶，
  /// 且弹幕时钟不推进 → 没有弹幕）。
  late final StreamController<bool> _playing =
      StreamController<bool>.broadcast(onListen: _replayPlaying);

  /// 时长流同样补发：duration 只在打开媒体时推一次，订阅晚一步就丢了。
  late final StreamController<Duration> _duration =
      StreamController<Duration>.broadcast(onListen: _replayDuration);

  final StreamController<void> _completed =
      StreamController<void>.broadcast();

  /// 通道 B 的错误（libmpv 拉流失败、解码失败等）。
  ///
  /// 真机教训：libmpv 在「URL 403 / 拉不到流」时**不抛异常、不结束**，
  /// `open()` 照样返回成功 —— 表现就是「弹幕在滚、进度在走、画面全黑、
  /// 也没有声音」。把这条流接到界面上，用户才能看到「播放失败」而不是无限黑屏。
  final StreamController<String> _errors = StreamController<String>.broadcast();

  double _volume = 1.0;

  /// 当前倍速。mpv 的 `speed` 属性在换节点重开媒体后**会保留**，
  /// 但这里仍记一份：`speed` getter 需要同步返回，不能每次去问 mpv。
  double _speed = 1.0;

  void _replayPlaying() {
    if (!_playing.isClosed) _playing.add(isPlaying);
  }

  void _replayDuration() {
    if (!_duration.isClosed) _duration.add(duration);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Stream<String> get errorStream => _errors.stream;

  @override
  Duration get position => _player?.state.position ?? Duration.zero;

  @override
  Duration get duration => _player?.state.duration ?? Duration.zero;

  @override
  bool get isPlaying => _player?.state.playing ?? false;

  @override
  double get speed => _speed;

  @override
  double get aspectRatio {
    final state = _player?.state;
    final w = state?.width ?? 0;
    final h = state?.height ?? 0;
    if (w <= 0 || h <= 0) return 16 / 9;
    return w / h;
  }

  @override
  Future<void> initialize() async {
    // 打开 mpv 自己的日志（warn 级别）：真机上「有声音没画面」这类问题，
    // libmpv 的 vo/hwdec 报错是唯一能定位它的线索，默认级别下什么都看不到。
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    _player = player;

    // ⚠️ Android 上必须显式指定 hwdec，不能吃 media_kit 的默认值。
    //
    // media_kit 在 Android 上默认 `hwdec=auto-safe`，实际选中 `mediacodec`：
    // 解码帧直接输出成 **OES 外部纹理**再交给 Flutter 合成。这条路径在部分
    // 新机/新系统上失败 —— 真机症状（荣耀 Magic8 Pro / Android 16）：
    // **有音频、有进度、弹幕照滚，但画面从头到尾一片黑**，且 libmpv 零报错。
    //
    // 试过 `mediacodec-copy`（解码帧先拷贝再上传）仍然黑屏，因此这里用纯软解
    // `hwdec=no`：软解把帧交给 mpv 自己的 `vo=gpu` 渲染进普通 GL 纹理，绕开
    // 所有 mediacodec/OES 路径。1080P H.264 在旗舰机上是几个百分点 CPU，
    // 换来「一定能出画面」，比黑屏可接受得多。
    _videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        hwdec: 'no',
      ),
    );

    _subs.add(player.stream.position.listen((p) {
      if (!_position.isClosed) _position.add(p);
    }));
    _subs.add(player.stream.playing.listen((p) {
      if (!_playing.isClosed) _playing.add(p);
    }));
    _subs.add(player.stream.duration.listen((d) {
      if (!_duration.isClosed) _duration.add(d);
    }));
    _subs.add(player.stream.completed.listen((done) {
      if (done && !_completed.isClosed) _completed.add(null);
    }));

    // libmpv 的错误必须显式接出来：它在拉流失败时既不抛异常也不结束，
    // 不接这条流就只能是「静默黑屏」。
    _subs.add(player.stream.error.listen(_handleError));

    // 出画判定：拿到非零视频尺寸才算这条节点真的可用。
    // 用它而不是「playing=true」—— mpv 打开一条空流时同样会 playing，
    // 那个信号会让我们永远停在坏节点上。
    _subs.add(player.stream.width.listen((w) {
      if ((w ?? 0) > 0) _videoOk = true;
    }));
    _subs.add(player.stream.height.listen((h) {
      if ((h ?? 0) > 0) _videoOk = true;
    }));

    // 显式把 Referer / UA 设成 mpv 的全局 HTTP 头，作为第二道保险。
    //
    // 为什么不能只靠 `Media.httpHeaders`：B 站 CDN 对 DASH 流强制校验 Referer
    // （同一个 URL 实测「不带 Referer → 403，带上 → 200」），而 Media.httpHeaders
    // 在部分版本/调用路径下并没有落到 mpv 的 `http-header-fields` 上，结果就是
    // 「流拉不到，但 open() 不报错」→ 画面全黑、也没有声音。
    try {
      final fields = (_headers ?? const <String, String>{})
          .entries
          .map((e) => '${e.key}: ${e.value}')
          .join(',');
      if (fields.isNotEmpty) {
        final platform = player.platform;
        // NativePlayer#setProperty 是 mpv 的通用入口；用 dynamic 避免依赖
        // media_kit 内部的导出路径。
        await (platform as dynamic)?.setProperty('http-header-fields', fields);
        Log.d('MpvPlayerAdapter', '已设置 http-header-fields：$fields');
      }
      // 不可达节点的连接超时（秒）。
      //
      // 踩过的坑：候选里排在队尾的是 PCDN 节点（TCP 都连不上），而 mpv 默认
      // `network-timeout=60`——不缩短的话，换节点要白等一分钟，用户会觉得
      // 「卡死了」。正常节点 8 秒足够建连 + 读到首包。
      await (player.platform as dynamic)?.setProperty('network-timeout', '8');
    } catch (e) {
      Log.w('MpvPlayerAdapter', '设置 mpv 属性失败（忽略）：$e');
    }

    await _openMedia();
    await player.setVolume(_volume * 100);
    // 倍速在媒体打开之后再设：mpv 在 idle 状态下接受 `speed`，但
    // `loadfile` 之后可能被重置，重设一次最稳（且只在非原速时才发命令）。
    if (_speed != 1.0) {
      await player.setRate(_speed);
    }
    Log.d(
      'MpvPlayerAdapter',
      '通道 B 初始化完成：video=$_videoUrl '
          'audio=${_audioUrl ?? '（无独立音轨）'} '
          '（候选 ${_videoUrls.length} 视频 / ${_audioUrls.length} 音频）',
    );
  }

  /// 按当前下标打开媒体。换节点时复用同一套 player/vo，只重开媒体。
  Future<void> _openMedia() async {
    final player = _player;
    if (player == null) return;
    _opening = true;
    try {
      // ⚠️ 这里**不能**用 `Media.extras: {'audio-file': url}`。
      //
      // media_kit 1.2.6 的 `Player.open()` 做了两件事：把 URI 写进临时文件后
      // `loadlist`、再设 `playlist-pos`（见 pub-cache 里 real.dart:137-236）。
      // 它**从头到尾没读过 `Media.extras`** —— 整个 media_kit 源码里 extras
      // 只出现在 Media 模型自身，没有任何地方消费它。也就是说把 mpv 选项塞进
      // extras 是无效的，真机症状正是一条真实的坑：
      // **DASH 视频画面正常、弹幕正常、进度正常，但完全没有声音，且 mpv
      // 一条报错都不报**（因为它压根没去加载那个音频文件）。
      //
      // 正确做法是 mpv 的 `audio-add` 命令：把另一个文件作为**外部音轨**
      // 并入当前播放，两条流按各自时间戳对齐（B 站 DASH 的音视频都从 0 开始，
      // 因此不需要手动对轴）。
      Log.d(
        'MpvPlayerAdapter',
        '打开媒体：video=$_videoUrl '
            'audio=${_audioUrl ?? '（无独立音轨）'}',
      );
      await player.open(Media(_videoUrl, httpHeaders: _headers));
      await _attachAudio();
    } finally {
      _opening = false;
    }
  }

  /// 把独立的音频流挂成外部音轨。
  Future<void> _attachAudio() async {
    final url = _audioUrl;
    final player = _player;
    if (url == null || player == null) return;

    // 必须等主文件加载完再挂：idle 状态下 `audio-add` 会直接失败。
    await _waitLoaded();

    try {
      // `select` 让新音轨立刻成为当前音轨（否则 mpv 可能停在无音轨状态）。
      await (player.platform as dynamic)?.command(
        <String>['audio-add', url, 'select'],
      );
      Log.d('MpvPlayerAdapter', '已附加外部音轨（audio-add select）：$url');
    } catch (e) {
      Log.w('MpvPlayerAdapter', 'audio-add 失败，退回 aid=auto：$e');
      try {
        await (player.platform as dynamic)?.setProperty('aid', 'auto');
      } catch (e2) {
        Log.w('MpvPlayerAdapter', '设置 aid 也失败（忽略）：$e2');
      }
    }
  }

  /// 等待主文件加载出时长；超时也继续（交给上层报错）。
  Future<void> _waitLoaded() async {
    final player = _player;
    if (player == null) return;
    if (player.state.duration > Duration.zero) return;
    try {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      Log.w('MpvPlayerAdapter', '等待主文件加载超时，仍尝试附加音轨');
    }
  }

  /// 处理 mpv 的错误：能换节点就换，换不了才上报给界面。
  Future<void> _handleError(String message) async {
    if (_disposed) return;
    Log.w('MpvPlayerAdapter', '通道 B 错误：$message');
    if (_opening) return; // 重开过程中的残留错误，忽略
    if (await _tryFailover(message)) return;
    if (!_errors.isClosed) _errors.add(message);
  }

  /// 尝试换候选节点。返回 true 表示已自行恢复，不必上报错误。
  ///
  /// 实测的失败模式（见 `BiliCdn`）：
  /// - 视频节点不可达 → `Failed to open <视频 URL>` / `tcp: ffurl_read ...`
  ///   → 此时 `_videoOk` 仍是 false，换下一个视频节点；
  /// - 视频通了、音频节点不可达 → `Failed to open <音频 URL>`
  ///   → 症状正是「有画面没声音」，换下一个音频节点（视频节点保持不变）。
  Future<bool> _tryFailover(String message) async {
    final audioUrl = _audioUrl;
    final looksLikeAudio = audioUrl != null &&
        message.contains(Uri.tryParse(audioUrl)?.host ?? '\u0000');

    if (looksLikeAudio && _audioIndex + 1 < _audioUrls.length) {
      _audioIndex++;
      Log.w(
        'MpvPlayerAdapter',
        '音频节点失败，换第 ${_audioIndex + 1}/${_audioUrls.length} 个：$_audioUrl',
      );
      await _openMedia();
      return true;
    }

    if (!looksLikeAudio && !_videoOk && _videoIndex + 1 < _videoUrls.length) {
      _videoIndex++;
      Log.w(
        'MpvPlayerAdapter',
        '视频节点失败，换第 ${_videoIndex + 1}/${_videoUrls.length} 个：$_videoUrl',
      );
      await _openMedia();
      return true;
    }

    return false;
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _player?.setVolume(_volume * 100);
  }

  /// 通道 B 的倍速 = mpv 的 `speed` 属性（`audio-pitch-correction` 默认开，
  /// 因此变速不变调，与通道 A 的听感一致）。
  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 4.0);
    await _player?.setRate(_speed);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _player?.dispose();
    await _position.close();
    await _playing.close();
    await _duration.close();
    await _completed.close();
  }

  @override
  Widget buildView(BuildContext context) {
    final controller = _videoController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Video(
          controller: controller,
          controls: NoVideoControls,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
