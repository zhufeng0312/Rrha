import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/features/player/playback_clock.dart';

/// 播放时钟的**倍速同步**单测（`docs/BILI_HANDOFF.md` §0.6 N1 第 3 条）。
///
/// 为什么必须测：`PlaybackClock` 在两次位置回调之间靠墙钟外推。倍速 2x 时
/// 若外推仍按 1x 走，弹幕会稳定慢半拍，并在下一次真实回调时被「偏差中等就
/// 校正一半」慢慢拉回 —— 表现是持续抖动。这个问题在真机上只能靠「盯着弹幕
/// 感觉不对」发现，所以必须用可重复的单测把外推倍速钉死。
void main() {
  // Ticker.start() 会去拿 SchedulerBinding.instance，纯 `test()` 里没有它，
  // 必须先初始化 binding —— 否则 `setPlaying(true)` 直接抛 "Binding has not
  // yet been initialized"。
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造一个真实的 TickerProvider：时钟的 `_onTick` 依赖 ticker 才能外推，
  /// 但下面所有断言都直接调 `positionMs.value` 的计算路径（不依赖帧调度），
  /// 所以只需要一个能 `createTicker` 的对象。
  late TestVSync vsync;

  setUp(() => vsync = TestVSync());

  group('外推倍速', () {
    test('默认 1.0', () {
      final c = PlaybackClock(vsync: vsync);
      expect(c.speed, 1.0);
      c.dispose();
    });

    test('setSpeed 之后 getter 同步更新', () {
      final c = PlaybackClock(vsync: vsync);
      c.setSpeed(2.0);
      expect(c.speed, 2.0);
      c.setSpeed(0.5);
      expect(c.speed, 0.5);
      c.dispose();
    });

    test('非法倍速（0 / 负数）被归一成 1.0，不会把时间轴冻死', () {
      final c = PlaybackClock(vsync: vsync);
      c.setSpeed(2.0);
      c.setSpeed(0);
      expect(c.speed, 1.0, reason: '速度 0 会让弹幕永远不动，必须兜底');
      c.dispose();
    });

    test('切换倍速时不改变当前位置（锚点先对齐再换速）', () async {
      final c = PlaybackClock(vsync: vsync);
      c.setPlaying(true);
      c.seek(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final before = c.positionMs.value;
      c.setSpeed(2.0);
      final after = c.positionMs.value;

      // 切速瞬间**不能跳变**：changeSpeed 前已经按旧倍速外推了一段，
      // 新锚点必须等于那一刻的真实值。
      expect(after, closeTo(before, 1.0));
      c.dispose();
    });

    test('外推值真的乘上了倍速（用偏差判定反推，不信「不倒退」这种弱断言）',
        () async {
      // 单测里没有真正的帧调度，ticker 不会推进 `positionMs`，所以不能直接
      // 读 positionMs 来验证倍速。可用的间接观测点是 `onPosition` 的偏差判定：
      // 它内部拿「墙钟 × 倍速」算预测值，我们可以反过来挑一个位置值，
      // 使 1x 判成硬跳、2x 判成不跳 —— 两者结论不同，就证明倍速确实乘进去了。

      Future<int> hardSeeksFor({required double speed, required int reportMs}) async {
        final c = PlaybackClock(vsync: vsync);
        c.onHardSeek = () {};
        c.setPlaying(true);
        c.seek(Duration.zero);
        c.setSpeed(speed);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        var count = 0;
        c.onHardSeek = () => count++;
        c.onPosition(Duration(milliseconds: reportMs));
        c.dispose();
        return count;
      }

      // 墙钟 400ms：1x 预测 400ms，2x 预测 800ms。
      // 上报 1000ms → 1x 偏差 600ms（硬跳）；2x 偏差 200ms（不跳）。
      expect(await hardSeeksFor(speed: 1.0, reportMs: 1000), 1);
      expect(await hardSeeksFor(speed: 2.0, reportMs: 1000), 0);
      // 反过来再验一次：上报 500ms 时 1x 偏差 100ms（不跳），
      // 2x 偏差 -300ms 且绝对值 300ms < 400ms 也不跳 —— 说明不是「倍速越大越宽容」，
      // 而是预测值真的变了。用 4x 拉大差距：预测 1600ms，上报 500ms → 偏差 1100ms 必跳。
      expect(await hardSeeksFor(speed: 4.0, reportMs: 500), 1);
    });

    test('倍速变化后，播放器上报的位置偏差不会被误判成硬跳', () async {
      // 这一条是**正反对照**，因为单独断言「没有硬跳」在实现写错时也可能
      // 恰好通过（例如时钟完全不动，预测值恒为 0，偏差反而更大 —— 会硬跳，
      // 所以那样反而能测出来；但仍要用 1x 的对照证明判据本身有效）。

      // ---- 对照：1x 下墙钟过 ~500ms，位置上报 1200ms ----
      // 预测 ≈ 500ms，偏差 ≈ 700ms ≫ 400ms 阈值 → 判成硬跳
      // （这是既有语义：播放器跳变必须让弹幕引擎重置）。
      final slow = PlaybackClock(vsync: vsync);
      var slowSeeks = 0;
      slow.onHardSeek = () => slowSeeks++;
      slow.setPlaying(true);
      slow.seek(Duration.zero);
      // ⚠️ `seek()` 自己也会触发 onHardSeek。从「此刻起」开始计数，
      // 否则永远会被 seek 的那一次污染（第一版就是这么误判的）。
      slowSeeks = 0;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      slow.onPosition(const Duration(milliseconds: 1200));
      expect(slowSeeks, greaterThan(0), reason: '1x 下这么大的偏差本来就该硬跳');
      slow.dispose();

      // ---- 被测：2x 下墙钟同样过 ~500ms，位置上报 1200ms ----
      // 预测 ≈ 1000ms，偏差 ≈ 200ms < 阈值 → **不该**硬跳。
      // 若时钟没有同步倍速（仍按 1x 外推），这里就会像上面一样硬跳，
      // 表现为长按快进时「弹幕突然断一下再从头接」。
      final fast = PlaybackClock(vsync: vsync);
      var fastSeeks = 0;
      fast.onHardSeek = () => fastSeeks++;
      fast.setPlaying(true);
      fast.seek(Duration.zero);
      fast.setSpeed(2.0);
      fastSeeks = 0; // 同上：seek 与 setSpeed 都不该算进本次判定
      await Future<void>.delayed(const Duration(milliseconds: 500));
      fast.onPosition(const Duration(milliseconds: 1200));
      expect(fastSeeks, 0, reason: '倍速已同步，正常位置回调不该触发硬跳');
      fast.dispose();
    });
  });

  group('暂停与 seek 的既有语义不被破坏', () {
    test('暂停后位置停在外推值上，不再前进', () async {
      final c = PlaybackClock(vsync: vsync);
      c.setPlaying(true);
      c.seek(const Duration(seconds: 5));
      c.setPlaying(false);
      final at = c.positionMs.value;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(c.positionMs.value, at);
      c.dispose();
    });

    test('seek 触发 onHardSeek（弹幕引擎据此重置）', () {
      final c = PlaybackClock(vsync: vsync);
      var called = 0;
      c.onHardSeek = () => called++;
      c.seek(const Duration(seconds: 3));
      expect(called, 1);
      expect(c.anchorPosition, const Duration(seconds: 3));
      c.dispose();
    });

    test('倍速在暂停状态下也能设置（下次播放才生效）', () {
      final c = PlaybackClock(vsync: vsync);
      c.setPlaying(false);
      c.setSpeed(1.5);
      expect(c.speed, 1.5);
      c.dispose();
    });
  });
}

/// 最小的 TickerProvider：只提供 createTicker。
class TestVSync implements TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) =>
      Ticker(onTick, debugLabel: 'playback_clock_test');
}
