import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/features/player/player_load_failure.dart';

/// 「黑屏必须变成可读错误」这条需求的回归测试。
///
/// 真机上播放失败依赖网络、风控、解码器与设备，很难稳定复现；
/// 但「什么异常显示什么文案、给不给重试、诊断信息里有没有
/// bvid/cid/阶段」是纯逻辑，必须钉住。
void main() {
  group('PlayerLoadFailure.map', () {
    test('超时 -> 明确说「超时」，而不是笼统的解析失败', () {
      final e = PlayerLoadFailure.map(
        stage: PlayerLoadStage.initChannelB,
        error: TimeoutException('init', const Duration(seconds: 20)),
        bvid: 'BV1xx411c7mD',
        cid: 123456,
      );

      expect(e.kind, AppErrorKind.timeout);
      expect(e.message, contains('超时'));
      expect(e.message, contains('通道 B')); // 阶段要出现在文案里
      expect(e.retryable, isTrue);
      expect(e.showRetry, isTrue);
      expect(e.detail, contains('bvid=BV1xx411c7mD'));
      expect(e.detail, contains('cid=123456'));
    });

    test('通道初始化失败 -> 文案是「视频解析失败」', () {
      final e = PlayerLoadFailure.map(
        stage: PlayerLoadStage.initChannelA,
        error: Exception('ExoPlaybackException: Source error'),
        bvid: 'BV1xx411c7mD',
        cid: 42,
      );

      expect(e.kind, AppErrorKind.parse);
      expect(e.message, contains('视频解析失败'));
      expect(e.showRetry, isTrue);
      // 原始异常必须留在诊断信息里，否则日志无法定位
      expect(e.detail, contains('Source error'));
    });

    test('AppError 原样透传分类与业务码，并补上播放上下文', () {
      const original = AppError(
        AppErrorKind.auth,
        'B 站风控拦截（HTTP 412），已自动重试',
        detail: 'GET /x/player/wbi/playurl -> HTTP 412',
        statusCode: 412,
        retryable: true,
      );

      final e = PlayerLoadFailure.map(
        stage: PlayerLoadStage.playUrl,
        error: original,
        bvid: 'BV1xx411c7mD',
        cid: 7,
        channel: 'A',
      );

      expect(e.kind, AppErrorKind.auth);
      expect(e.message, original.message);
      expect(e.statusCode, 412);
      expect(e.retryable, isTrue);
      // 原 detail 与播放上下文都要保留
      expect(e.detail, contains('HTTP 412'));
      expect(e.detail, contains('阶段=播放地址'));
      expect(e.detail, contains('bvid=BV1xx411c7mD'));
      expect(e.detail, contains('通道=A'));
    });

    test('其它阶段的未知异常 -> 可读文案 + 阶段名 + 重试', () {
      final e = PlayerLoadFailure.map(
        stage: PlayerLoadStage.videoInfo,
        error: StateError('boom'),
        bvid: 'BV1xx411c7mD',
      );

      expect(e.kind, AppErrorKind.unknown);
      expect(e.message, contains('视频信息'));
      expect(e.showRetry, isTrue);
      expect(e.detail, contains('boom'));
    });
  });

  group('PlayerLoadFailure.logLine', () {
    test('日志行必须带 stage/bvid/cid/耗时，便于定位', () {
      final line = PlayerLoadFailure.logLine(
        stage: PlayerLoadStage.initChannelB,
        bvid: 'BV1xx411c7mD',
        cid: 999,
        channel: 'B(libmpv)',
        error: 'TimeoutException',
        elapsedMs: 20034,
      );

      expect(line, contains('stage=initChannelB'));
      expect(line, contains('bvid=BV1xx411c7mD'));
      expect(line, contains('cid=999'));
      expect(line, contains('channel=B(libmpv)'));
      expect(line, contains('elapsed=20034ms'));
      expect(line, contains('TimeoutException'));
    });

    test('可选字段为空时不产生多余片段', () {
      final line = PlayerLoadFailure.logLine(
        stage: PlayerLoadStage.videoInfo,
        bvid: 'BV1xx411c7mD',
      );
      expect(line, contains('bvid=BV1xx411c7mD'));
      expect(line, isNot(contains('cid=')));
      expect(line, isNot(contains('elapsed=')));
    });
  });
}
