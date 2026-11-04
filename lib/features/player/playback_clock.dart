import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../core/config/app_config.dart';

/// 播放时钟：把播放器「低频且有抖动」的位置回调，转换成每帧平滑推进的
/// 弹幕时间轴。
///
/// 为什么不能直接用播放器的 position？
/// video_player / media_kit 的位置回调间隔在 100ms~500ms 之间，直接拿它
/// 驱动弹幕会让弹幕以「一跳一跳」的节奏移动，肉眼非常明显。这里的做法是：
/// - 每次收到位置回调时记录锚点 (position, wallClock)；
/// - 每帧用墙钟外推 `position + (now - anchorWall)`；
/// - 偏差很小（<40ms）时不动，抑制回调抖动；
/// - 偏差中等时只校正一半；
/// - 偏差超过阈值（拖动进度条）时硬跳，并通知弹幕引擎重置。
class PlaybackClock {
  PlaybackClock({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

  /// 当前播放位置（毫秒，浮点）。弹幕层监听它。
  final ValueNotifier<double> positionMs = ValueNotifier<double>(0);

  Duration _anchorPosition = Duration.zero;
  DateTime _anchorWall = DateTime.now();
  bool _playing = false;

  /// 时钟外推倍速（1.0 = 原速）。
  ///
  /// 为什么必须与播放器倍速同步：位置回调间隔 100~500ms，两次回调之间靠
  /// 墙钟外推。倍速 2x 时若仍按 1x 外推，两帧之间弹幕只走一半，
  /// 与回调对其时又会被「偏差中等就校正一半」慢慢拉回 —— 表现是
  /// 「画面在 2x、弹幕明显慢半拍并持续抖动」（真机长按快进时的典型症状）。
  double _speed = 1.0;

  double get speed => _speed;

  /// 发生硬跳（seek / 大幅偏差）时回调。
  VoidCallback? onHardSeek;

  bool get isPlaying => _playing;

  Duration get anchorPosition => _anchorPosition;

  void _onTick(Duration _) {
    if (!_playing) return;
    positionMs.value = _predictedMs();
  }

  double _predictedMs() {
    if (!_playing) return _anchorPosition.inMilliseconds.toDouble();
    final elapsedUs =
        DateTime.now().difference(_anchorWall).inMicroseconds / 1000.0;
    return _anchorPosition.inMilliseconds + elapsedUs * _speed;
  }

  /// 设置外推倍速。
  ///
  /// **必须在倍速切换的那一刻先把锚点对齐到当前外推值**，否则切换瞬间的
  /// 位置会跳变（1.0x 外推了 1 秒后再切成 2.0x，旧锚点会让时间轴直接倒退）。
  void setSpeed(double speed) {
    final next = speed <= 0 ? 1.0 : speed;
    if (next == _speed) return;
    _anchorPosition =
        Duration(microseconds: (_predictedMs() * 1000).round());
    _anchorWall = DateTime.now();
    _speed = next;
  }

  /// 播放器上报位置。频率通常 2~10Hz。
  void onPosition(Duration position) {
    final actual = position.inMilliseconds.toDouble();
    final predicted = _predictedMs();
    final diff = actual - predicted;

    if (diff.abs() > AppConfig.positionJumpThresholdMs) {
      _anchorPosition = position;
      _anchorWall = DateTime.now();
      positionMs.value = actual;
      onHardSeek?.call();
      return;
    }

    if (diff.abs() > 40) {
      _anchorPosition =
          Duration(microseconds: ((predicted + diff * 0.5) * 1000).round());
      _anchorWall = DateTime.now();
    }
    // 偏差很小时保持外推值不变，避免弹幕抖动。
  }

  void setPlaying(bool playing) {
    if (_playing == playing) return;
    if (playing) {
      _anchorPosition =
          Duration(microseconds: (positionMs.value * 1000).round());
      _anchorWall = DateTime.now();
      _ticker.start();
    } else {
      _anchorPosition =
          Duration(microseconds: (positionMs.value * 1000).round());
      _ticker.stop();
    }
    _playing = playing;
  }

  /// 主动跳转（用户拖动进度条）。
  void seek(Duration to) {
    _anchorPosition = to;
    _anchorWall = DateTime.now();
    positionMs.value = to.inMilliseconds.toDouble();
    onHardSeek?.call();
  }

  void dispose() {
    _ticker.dispose();
    positionMs.dispose();
  }
}
