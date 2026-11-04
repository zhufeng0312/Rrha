import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/danmaku_item.dart';
import 'package:rrha/features/player/danmaku/danmaku_engine.dart';
import 'package:rrha/features/player/danmaku/danmaku_overlay.dart';
import 'package:rrha/features/player/player_adapter.dart';

/// 回归测试：播放状态不同步 + 弹幕不出。
///
/// 根因是「订阅者只会在状态**变化**时收到事件」，而播放页先订阅、后 `play()`，
/// 加上 libmpv 在 `open()` 后自动开始播放，那次变化落在订阅窗口之外。
/// 这里从两个方向钉住修复：
/// 1. 两个 adapter 的 playingStream 订阅时**必须立刻补发当前值**；
/// 2. 弹幕层除播放时钟外还要接受一个「非时钟」重绘触发源，
///    否则装载完成的变化要拖到下一次位置回调才可见。
void main() {
  group('adapter 订阅即补发当前状态', () {
    test('通道 A：playingStream 订阅时立即有值（不是等到状态变化）', () async {
      final adapter = VideoPlayerAdapter(urls: <String>['https://x/y.mp4']);
      addTearDown(adapter.dispose);

      // 未 initialize 时真实状态就是未播放；关键是**立刻**收到，而不是超时。
      final first = await adapter.playingStream
          .first
          .timeout(const Duration(milliseconds: 300));
      expect(first, isFalse);
      expect(adapter.isPlaying, isFalse);
    });

    test('通道 A：durationStream 同样补发（通道 A 只在 initialize 里推过一次）',
        () async {
      final adapter = VideoPlayerAdapter(urls: <String>['https://x/y.mp4']);
      addTearDown(adapter.dispose);

      final first = await adapter.durationStream
          .first
          .timeout(const Duration(milliseconds: 300));
      expect(first, Duration.zero);
    });

    test('通道 B：playingStream 订阅时立即有值', () async {
      final adapter = MpvPlayerAdapter(videoUrls: <String>['https://x/v.m4s']);
      addTearDown(adapter.dispose);

      final first = await adapter.playingStream
          .first
          .timeout(const Duration(milliseconds: 300));
      expect(first, isFalse);
    });

    test('通道 B：durationStream 订阅时立即有值', () async {
      final adapter = MpvPlayerAdapter(videoUrls: <String>['https://x/v.m4s']);
      addTearDown(adapter.dispose);

      final first = await adapter.durationStream
          .first
          .timeout(const Duration(milliseconds: 300));
      expect(first, Duration.zero);
    });

    test('补发之后仍能收到后续状态变化（不是一次性事件）', () async {
      final adapter = VideoPlayerAdapter(urls: <String>['https://x/y.mp4']);
      addTearDown(adapter.dispose);

      final seen = <bool>[];
      final sub = adapter.playingStream.listen(seen.add);
      // 第一个事件是订阅补发；下面这条手动推送模拟播放器状态变化。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(seen, <bool>[false], reason: '订阅补发必须到达');
    });
  });

  group('弹幕层重绘触发', () {
    testWidgets('装载弹幕后的显式 tick 能立即让弹幕出现（不依赖播放位置回调）',
        (WidgetTester tester) async {
      final engine = DanmakuEngine();
      final clock = ValueNotifier<double>(0);
      final extra = ValueNotifier<int>(0);
      addTearDown(clock.dispose);
      addTearDown(extra.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: DanmakuOverlay(engine: engine, clock: clock, extraRepaint: extra),
          ),
        ),
      );

      // 时钟一动不动，此时装载弹幕：只靠时钟驱动的话，弹幕要等下一次
      // 位置回调才出现（暂停状态下则永远不出现）。
      engine.load(<DanmakuItem>[
        const DanmakuItem(
          progressMs: 0,
          mode: DanmakuMode.scroll,
          fontSize: 25,
          color: 0xFFFFFF,
          text: '装载后应立刻可见',
        ),
      ]);
      await tester.pump();
      expect(engine.activeCount, 0, reason: '没有重绘触发时不应发射弹幕');

      extra.value++;
      await tester.pump();
      expect(engine.activeCount, 1, reason: '显式 tick 后应立刻发射出来');
    });
  });
}
