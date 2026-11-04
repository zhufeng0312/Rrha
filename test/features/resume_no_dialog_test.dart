import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「进入视频不弹窗、默认继续播放」的**源码级**防腐测试。
///
/// ## 为什么用读源码这种笨办法
///
/// 2026-10-21 用户看真机截图后明确要求：进度恢复**不要弹窗**，直接继续播。
/// 这个要求很容易在后续改动里被「重新加回来」—— 因为它看起来是个很贴心的
/// 确认步骤，而且 §3.5 最早的方案本来就是弹窗（怕静默跳转让人以为视频坏了）。
///
/// 播放页依赖真实的 `videoRepoProvider`（网络 + 播放器），没法在单测里起
/// 一个完整页面去断言「有没有弹窗」。所以这里退一步：**直接检查源文件**。
/// 断言很朴素，但它能确定性地拦住一次回归，而回归的代价是用户每次都得多点一下。
void main() {
  final source = File('lib/features/player/player_page.dart').readAsStringSync();

  /// 取某个方法的方法体（按大括号配平截取）。
  String bodyOf(String signature) {
    final start = source.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature，测试需要同步更新');
    final braceStart = source.indexOf('{', start);
    var depth = 0;
    for (var i = braceStart; i < source.length; i++) {
      final c = source[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(braceStart, i + 1);
      }
    }
    fail('方法体不完整：$signature');
  }

  test('进度恢复方法里没有任何弹窗调用', () {
    final body = bodyOf('Future<void> _restorePlaybackPosition');

    for (final forbidden in <String>[
      'showDialog',
      'AlertDialog',
      'showModalBottomSheet',
      '继续播放？',
    ]) {
      expect(
        body.contains(forbidden),
        isFalse,
        reason: '用户明确要求「不要弹出这个弹窗，默认继续播放」，'
            '但 _restorePlaybackPosition 里又出现了 $forbidden',
      );
    }
  });

  test('进度恢复方法里确实调用了 seek（否则「默认继续」等于没做）', () {
    final body = bodyOf('Future<void> _restorePlaybackPosition');
    expect(
      body.contains('_seekTo(resume)'),
      isTrue,
      reason: '必须真的跳到上次位置，而不是只记日志',
    );
  });

  test('静默跳转必须配一条画面内提示（否则用户以为视频坏了）', () {
    final body = bodyOf('Future<void> _restorePlaybackPosition');
    expect(
      body.contains('_resumeHint'),
      isTrue,
      reason: '不弹窗之后，唯一的解释渠道就是画面里那条「已从 xx:xx 继续」',
    );
  });

  test('旧的弹窗入口 _maybeOfferResume 已彻底移除', () {
    expect(
      source.contains('_maybeOfferResume'),
      isFalse,
      reason: '旧方法留着就会被误用，调用点应统一指向 _restorePlaybackPosition',
    );
  });

  test('提示条 2.5 秒后自动消失（不能永久挡着画面）', () {
    final body = bodyOf('Future<void> _restorePlaybackPosition');
    expect(body.contains('Duration(milliseconds: 2500)'), isTrue);
    expect(
      body.contains('_resumeHint = null'),
      isTrue,
      reason: '计时器到点必须把它清掉',
    );
  });

  test('dispose 会取消提示计时器（避免 State 销毁后 setState）', () {
    final body = bodyOf('void dispose()');
    expect(body.contains('_resumeHintTimer?.cancel()'), isTrue);
  });
}
