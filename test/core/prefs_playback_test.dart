import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/config/app_config.dart';
import 'package:rrha/core/storage/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放偏好（清晰度 / 倍速 / 进度记忆）的持久化测试。
///
/// 这三项都是「用户设置了却悄悄失效」的典型位置：写错了不报错，
/// 只是下次进来又回到默认值，用户会以为「这功能根本没做」。
/// 所以每一条都要覆盖「写进去能读出来」+「缺省值正确」+「边界归一」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Prefs> fresh([Map<String, Object> seed = const <String, Object>{}]) async {
    SharedPreferences.setMockInitialValues(seed);
    return Prefs.create();
  }

  group('清晰度偏好', () {
    test('未设置时为 null（调用方据此回落到 AppConfig.preferredQuality）', () async {
      final p = await fresh();
      expect(p.preferredQn, isNull);
      expect(AppConfig.preferredQuality, 64, reason: '默认值仍是 720P');
    });

    test('设置后能读回同一个 qn', () async {
      final p = await fresh();
      await p.setPreferredQn(80);
      expect(p.preferredQn, 80);
    });

    test('新实例（模拟冷启动）依然读得到', () async {
      final p = await fresh();
      await p.setPreferredQn(112);

      // 直接重建 Prefs：SharedPreferences.getInstance 在 mock 下会读回同一份。
      final again = await Prefs.create();
      expect(again.preferredQn, 112);
    });

    test('可以改小（用户主动降清晰度）', () async {
      final p = await fresh();
      await p.setPreferredQn(112);
      await p.setPreferredQn(32);
      expect(p.preferredQn, 32);
    });
  });

  group('倍速偏好', () {
    test('未设置时为 1.0', () async {
      final p = await fresh();
      expect(p.playbackSpeed, 1.0);
    });

    test('非原速会存下来', () async {
      final p = await fresh();
      await p.setPlaybackSpeed(1.5);
      expect(p.playbackSpeed, 1.5);

      final again = await Prefs.create();
      expect(again.playbackSpeed, 1.5);
    });

    test('改回 1.0 时清除键（默认值不该占一个键）', () async {
      final p = await fresh();
      await p.setPlaybackSpeed(2.0);
      expect(p.playbackSpeed, 2.0);
      await p.setPlaybackSpeed(1.0);
      expect(p.playbackSpeed, 1.0);
    });

    test('超出档位的值被夹到 0.5 ~ 2.0', () async {
      final p = await fresh();
      await p.setPlaybackSpeed(9.9);
      expect(p.playbackSpeed, 2.0);
      await p.setPlaybackSpeed(0.01);
      expect(p.playbackSpeed, 0.5);
    });
  });

  group('播放进度记忆', () {
    test('没有记录时返回 null', () async {
      final p = await fresh();
      expect(p.playbackPositionMs('BV1xx@p1'), isNull);
    });

    test('写入后能读回毫秒数', () async {
      final p = await fresh();
      await p.setPlaybackPositionMs('BV1xx@p1', 125000);
      expect(p.playbackPositionMs('BV1xx@p1'), 125000);
    });

    test('不同分 P 互不干扰（键里带 p 号的原因）', () async {
      final p = await fresh();
      await p.setPlaybackPositionMs('BV1xx@p1', 60000);
      await p.setPlaybackPositionMs('BV1xx@p2', 90000);

      expect(p.playbackPositionMs('BV1xx@p1'), 60000);
      expect(p.playbackPositionMs('BV1xx@p2'), 90000);
    });

    test('不同视频互不干扰', () async {
      final p = await fresh();
      await p.setPlaybackPositionMs('BV1aa@p1', 30000);
      await p.setPlaybackPositionMs('BV1bb@p1', 40000);

      expect(p.playbackPositionMs('BV1aa@p1'), 30000);
      expect(p.playbackPositionMs('BV1bb@p1'), 40000);
    });

    test('0 与负数不写入（避免「继续播放」跳到 0）', () async {
      final p = await fresh();
      await p.setPlaybackPositionMs('BV1xx@p1', 0);
      await p.setPlaybackPositionMs('BV1xx@p1', -5);
      expect(p.playbackPositionMs('BV1xx@p1'), isNull);
    });

    test('清除后返回 null', () async {
      final p = await fresh();
      await p.setPlaybackPositionMs('BV1xx@p1', 50000);
      await p.clearPlaybackPosition('BV1xx@p1');
      expect(p.playbackPositionMs('BV1xx@p1'), isNull);
    });

    test('playbackPositions 汇总所有记录（供「继续观看」使用）', () async {
      final p = await fresh();
      await p.setPlaybackPositionMs('BV1aa@p1', 10000);
      await p.setPlaybackPositionMs('BV1bb@p2', 20000);

      final all = p.playbackPositions;
      expect(all['BV1aa@p1'], 10000);
      expect(all['BV1bb@p2'], 20000);
      expect(all.length, 2);
    });

    test('记录数上限 200：超出后不再无限增长', () async {
      final p = await fresh();
      // 写 210 条：上限机制会剪掉多余的。
      for (var i = 0; i < 210; i++) {
        await p.setPlaybackPositionMs('BV${i}_p1', 10000 + i);
      }
      expect(
        p.playbackPositions.length,
        lessThanOrEqualTo(200),
        reason: 'SharedPreferences 不是数据库，必须设上限',
      );
    });
  });

  group('与既有键互不影响', () {
    test('播放偏好不会碰订阅源 / 弹幕设置', () async {
      final p = await fresh();
      await p.setPreferredQn(80);
      await p.setPlaybackSpeed(1.5);
      await p.setPlaybackPositionMs('BV1xx@p1', 12345);

      // 这几个读的键与上面写的互不重叠，读出来必须是默认值。
      expect(p.subscriptions, isEmpty);
      expect(p.danmakuSettings.enabled, isTrue);
      expect(p.forceChannelB, isFalse);
      expect(p.timelineMode.key, isNotEmpty);
    });
  });
}
