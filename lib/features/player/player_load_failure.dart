import 'dart:async';

import '../../core/net/app_error.dart';

/// 播放页加载的各个阶段。
///
/// 为什么要把阶段显式建模：真机上「黑屏」可能来自四个完全不同的地方
/// （取视频信息 / 取播放地址 / 初始化播放器 / 启动播放），而它们的
/// 用户可读文案与排查手段都不一样。只报一句「加载失败」等于没说。
enum PlayerLoadStage {
  videoInfo('视频信息'),
  playUrl('播放地址'),
  initChannelA('通道 A（MP4）初始化'),
  initChannelB('通道 B（libmpv）初始化'),
  startPlayback('启动播放');

  const PlayerLoadStage(this.label);

  /// 面向用户与日志的阶段名。
  final String label;
}

/// 把「失败阶段 + 原始异常 + 播放上下文」映射成可读的 [AppError]。
///
/// 为什么抽成纯函数：播放失败依赖网络、风控、解码器与设备，很难在真机上
/// 稳定复现；但「什么异常该显示什么文案、该不该给重试按钮」是纯逻辑，
/// 必须能用单测钉住，否则下次又只能靠猜。
class PlayerLoadFailure {
  PlayerLoadFailure._();

  /// [channel] 用于区分是通道 A 还是通道 B 出的问题（回退链路上很关键）。
  static AppError map({
    required PlayerLoadStage stage,
    required Object error,
    required String bvid,
    int? cid,
    String? channel,
  }) {
    final context = StringBuffer()
      ..write('阶段=${stage.label}')
      ..write(' bvid=$bvid');
    if (cid != null) context.write(' cid=$cid');
    if (channel != null) context.write(' 通道=$channel');

    // 1) 已经是 AppError：保留它的分类与业务码（412/风控/超时等文案都是
    //    在网络层精心写过的），只把播放上下文拼进 detail 方便排查。
    if (error is AppError) {
      return AppError(
        error.kind,
        error.message,
        detail: '${error.detail == null ? '' : '${error.detail}\n'}$context',
        statusCode: error.statusCode,
        bizCode: error.bizCode,
        retryable: error.retryable,
      );
    }

    // 2) 超时：用户看到的必须是「超时」，而不是「解析失败」。
    if (error is TimeoutException) {
      return AppError(
        AppErrorKind.timeout,
        '加载超时（${stage.label}），请重试',
        detail: '$context\n超时阈值=${error.duration?.inSeconds ?? '?'}s',
        retryable: true,
      );
    }

    // 3) 初始化播放器失败：这就是用户口中的「黑屏 / 解析失败」。
    if (stage == PlayerLoadStage.initChannelA ||
        stage == PlayerLoadStage.initChannelB) {
      return AppError(
        AppErrorKind.parse,
        '视频解析失败（${stage.label}未能初始化播放器）',
        detail: '$context\n原始错误：$error',
        retryable: true,
      );
    }

    // 4) 其它：仍然给出可读文案 + 真正的原因，不允许只显示黑屏。
    return AppError(
      AppErrorKind.unknown,
      '视频加载失败（${stage.label}）',
      detail: '$context\n原始错误：$error',
      retryable: true,
    );
  }

  /// 供日志使用的一行摘要（明确带上 bvid / cid / 阶段，便于事后定位）。
  static String logLine({
    required PlayerLoadStage stage,
    required String bvid,
    int? cid,
    String? channel,
    Object? error,
    int? elapsedMs,
  }) {
    final b = StringBuffer('stage=${stage.name}(${stage.label}) bvid=$bvid');
    if (cid != null) b.write(' cid=$cid');
    if (channel != null) b.write(' channel=$channel');
    if (elapsedMs != null) b.write(' elapsed=${elapsedMs}ms');
    if (error != null) b.write(' error=$error');
    return b.toString();
  }
}
