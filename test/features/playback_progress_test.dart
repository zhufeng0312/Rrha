import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/features/player/playback_progress.dart';

/// 播放进度记忆的**判定逻辑**单测。
///
/// ## 这一组测试的由来
///
/// 2026-10-21 真机验收「播放进度记忆」时，功能看起来完全没生效：
/// 播了半分钟、退出、再进来，没有「继续播放」弹窗。
///
/// 翻 App 内运行日志看到：
///     [PlayerPage] 保存播放进度失败（忽略）：Bad state:
///     Cannot use "ref" after the widget was disposed.
///
/// 根因是落盘发生在 `dispose()`，而那里 `ref` 已经失效；异常被 catch 吞成
/// 一行警告，界面上**看不出来**。修法是把 `Prefs` 提前缓存。
///
/// 这个事故的教训：这段逻辑必须有纯单测 —— 既覆盖「该存 / 该清 / 该跳过」的
/// 每一个分支，也覆盖「多短算浏览、多近算看完」这些边界值。
void main() {
  group('decide：该写盘时的判定', () {
    test('播放器未就绪（position 为 null）时跳过，绝不清掉旧记录', () {
      expect(
        PlaybackProgress.decide(position: null, duration: const Duration(minutes: 10)),
        PlaybackProgressAction.skip,
        reason: '初始化就失败时 position 恒为 0，写进去会覆盖掉用户真实的进度',
      );
    });

    test('刚点开就退出（≤3 秒）不记', () {
      expect(
        PlaybackProgress.decide(position: Duration.zero, duration: const Duration(minutes: 10)),
        PlaybackProgressAction.skip,
      );
      expect(
        PlaybackProgress.decide(
          position: const Duration(seconds: 3),
          duration: const Duration(minutes: 10),
        ),
        PlaybackProgressAction.skip,
      );
    });

    test('超过 3 秒开始记录', () {
      expect(
        PlaybackProgress.decide(
          position: const Duration(seconds: 4),
          duration: const Duration(minutes: 10),
        ),
        PlaybackProgressAction.save,
      );
    });

    test('中途退出记录当前位置', () {
      expect(
        PlaybackProgress.decide(
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 10),
        ),
        PlaybackProgressAction.save,
      );
    });

    test('看到结尾（剩余 ≤5 秒）改成清除记录', () {
      expect(
        PlaybackProgress.decide(
          position: const Duration(minutes: 9, seconds: 55),
          duration: const Duration(minutes: 10),
        ),
        PlaybackProgressAction.clear,
        reason: '看完了还记着进度，下次进来会问「继续播放吗」，很别扭',
      );
    });

    test('结尾边界：正好差 5 秒算看完', () {
      expect(
        PlaybackProgress.decide(
          position: const Duration(minutes: 9, seconds: 55),
          duration: const Duration(minutes: 10),
        ),
        PlaybackProgressAction.clear,
      );
      // 差 6 秒还没到「看完」，继续记录。
      expect(
        PlaybackProgress.decide(
          position: const Duration(minutes: 9, seconds: 54),
          duration: const Duration(minutes: 10),
        ),
        PlaybackProgressAction.save,
      );
    });

    test('总时长未知时按「记录」处理（不能因为算不出结尾就丢掉进度）', () {
      expect(
        PlaybackProgress.decide(
          position: const Duration(minutes: 5),
          duration: null,
        ),
        PlaybackProgressAction.save,
      );
      expect(
        PlaybackProgress.decide(
          position: const Duration(minutes: 5),
          duration: Duration.zero,
        ),
        PlaybackProgressAction.save,
        reason: 'duration 还没推上来时是 0，此时不能判定「看完了」',
      );
    });
  });

  // 语义变更（2026-10-21）：不再弹窗确认，而是**自动**跳到上次位置。
  // 这个判定的含义因此从「该不该弹窗」变成「该不该自动恢复」，
  // 但「多短算浏览、多近算看完」这些边界完全没变，所以用例原样保留。
  group('shouldOfferResume：该不该自动恢复进度', () {
    test('没有记录时不恢复', () {
      expect(
        PlaybackProgress.shouldOfferResume(savedMs: null, duration: null),
        isFalse,
      );
    });

    test('记录太短（<10 秒）不恢复（会打断用户）', () {
      expect(
        PlaybackProgress.shouldOfferResume(
          savedMs: 9000,
          duration: const Duration(minutes: 10),
        ),
        isFalse,
      );
    });

    test('记录够长就自动恢复', () {
      expect(
        PlaybackProgress.shouldOfferResume(
          savedMs: 60000,
          duration: const Duration(minutes: 10),
        ),
        isTrue,
      );
    });

    test('记录离结尾太近不恢复（上次其实看完了，只是没清干净）', () {
      expect(
        PlaybackProgress.shouldOfferResume(
          savedMs: 595000,
          duration: const Duration(minutes: 10),
        ),
        isFalse,
      );
    });

    test('总时长未知时仍恢复（有记录就跳，比静默从头播更符合预期）', () {
      expect(
        PlaybackProgress.shouldOfferResume(savedMs: 60000, duration: null),
        isTrue,
      );
    });

    test('10 秒边界：正好 10 秒就恢复', () {
      expect(
        PlaybackProgress.shouldOfferResume(savedMs: 10000, duration: null),
        isTrue,
      );
      expect(
        PlaybackProgress.shouldOfferResume(savedMs: 9999, duration: null),
        isFalse,
      );
    });
  });

  group('keyFor：存储键', () {
    test('bvid 与分 P 都进键', () {
      expect(PlaybackProgress.keyFor('BV1xx', 1), 'BV1xx@p1');
      expect(PlaybackProgress.keyFor('BV1xx', 3), 'BV1xx@p3');
    });

    test('不同分 P 是不同键（否则 P1/P2 会串进度）', () {
      expect(
        PlaybackProgress.keyFor('BV1xx', 1),
        isNot(PlaybackProgress.keyFor('BV1xx', 2)),
      );
    });

    test('不同视频是不同键', () {
      expect(
        PlaybackProgress.keyFor('BV1aa', 1),
        isNot(PlaybackProgress.keyFor('BV1bb', 1)),
      );
    });
  });

  group('常量与文案一致', () {
    test('阈值与手写注释里的数字一致（防止以后改值漏改注释）', () {
      expect(PlaybackProgress.minWatched, const Duration(seconds: 3));
      expect(PlaybackProgress.endMargin, const Duration(seconds: 5));
      expect(PlaybackProgress.minResumePrompt, const Duration(seconds: 10));
    });
  });
}
