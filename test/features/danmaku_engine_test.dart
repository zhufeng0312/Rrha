import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/config/app_config.dart';
import 'package:rrha/data/models/danmaku_item.dart';
import 'package:rrha/features/player/danmaku/danmaku_engine.dart';

List<DanmakuItem> _items(int count, {int spacingMs = 20, String prefix = '弹幕'}) =>
    List<DanmakuItem>.generate(
      count,
      (i) => DanmakuItem(
        progressMs: i * spacingMs,
        mode: DanmakuMode.scroll,
        fontSize: 25,
        color: 0xFFFFFF,
        text: '$prefix $i',
      ),
    );

/// 以 60fps 推进引擎。
void _run(DanmakuEngine engine, double fromMs, double toMs) {
  for (var ms = fromMs; ms < toMs; ms += 16.67) {
    engine.advanceTo(ms);
  }
}

void main() {
  // TextPainter.layout 需要绑定初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未装载时推进不抛异常', () {
    final engine = DanmakuEngine();
    engine.resize(const Size(800, 450));
    expect(() => engine.advanceTo(100), returnsNormally);
    expect(engine.activeCount, 0);
    expect(engine.hasData, isFalse);
  });

  test('关键词屏蔽（不区分大小写）', () {
    final engine = DanmakuEngine(
      settings: const DanmakuSettings(blockKeywords: <String>['屏蔽']),
    );
    engine.resize(const Size(800, 450));
    engine.load(<DanmakuItem>[
      const DanmakuItem(
        progressMs: 0,
        mode: DanmakuMode.scroll,
        fontSize: 25,
        color: 0xFFFFFF,
        text: '这条会被屏蔽掉',
      ),
      const DanmakuItem(
        progressMs: 0,
        mode: DanmakuMode.scroll,
        fontSize: 25,
        color: 0xFFFFFF,
        text: '正常弹幕',
      ),
    ]);
    engine.advanceTo(16);
    expect(engine.activeCount, 1);
  });

  test('代码弹幕不渲染', () {
    final engine = DanmakuEngine();
    engine.resize(const Size(800, 450));
    engine.load(<DanmakuItem>[
      const DanmakuItem(
        progressMs: 0,
        mode: DanmakuMode.code,
        fontSize: 25,
        color: 0xFFFFFF,
        text: 'code',
      ),
      const DanmakuItem(
        progressMs: 0,
        mode: DanmakuMode.scroll,
        fontSize: 25,
        color: 0xFFFFFF,
        text: 'normal',
      ),
    ]);
    engine.advanceTo(16);
    expect(engine.activeCount, 1);
  });

  test('关闭弹幕时不发射', () {
    final engine = DanmakuEngine(
      settings: const DanmakuSettings(enabled: false),
    );
    engine.resize(const Size(800, 450));
    engine.load(_items(50, spacingMs: 10));
    _run(engine, 0, 1000);
    expect(engine.activeCount, 0);
  });

  test('同屏数量始终不超过上限', () {
    final engine = DanmakuEngine(
      settings: const DanmakuSettings(maxOnScreen: 50),
    );
    engine.resize(const Size(800, 450));
    engine.load(_items(500, spacingMs: 5));

    for (var ms = 0.0; ms < 5000; ms += 16.67) {
      engine.advanceTo(ms);
      expect(engine.activeCount, lessThanOrEqualTo(50));
    }
  });

  test('500 条弹幕全程推进：轨道会回收，全部弹幕都会被处理', () {
    final engine = DanmakuEngine(
      settings: const DanmakuSettings(maxOnScreen: 200),
    );
    engine.resize(const Size(800, 450));
    engine.load(_items(AppConfig.danmakuHardLimit, spacingMs: 100));

    _run(engine, 0, 60000);

    expect(engine.activeCount, lessThanOrEqualTo(200));
    expect(engine.nextIndex, AppConfig.danmakuHardLimit);
  });

  test('seek 清空在飞弹幕并重定位到新位置之后', () {
    final engine = DanmakuEngine();
    engine.resize(const Size(800, 450));
    engine.load(_items(200, spacingMs: 50));

    _run(engine, 0, 2000);
    expect(engine.activeCount, greaterThan(0));

    engine.seekTo(9000);
    expect(engine.activeCount, 0, reason: 'seek 必须清空在飞弹幕');

    engine.advanceTo(9060);
    expect(engine.activeCount, greaterThan(0));
  });

  test('大幅跳变被识别为 seek（不把过去 20 秒的弹幕一次性倒出来）', () {
    final engine = DanmakuEngine();
    engine.resize(const Size(800, 450));
    engine.load(_items(1000, spacingMs: 20));

    engine.advanceTo(0);
    // 跳到 10 秒后：应重置而不是补发 500 条。
    engine.advanceTo(10000);
    expect(engine.activeCount, lessThanOrEqualTo(50));
  });

  test('尺寸变化会重建轨道（横竖屏 / 全屏切换）', () {
    final engine = DanmakuEngine();
    engine.resize(const Size(800, 450));
    engine.load(_items(1000, spacingMs: 10));

    _run(engine, 0, 3000);
    expect(engine.activeCount, greaterThan(0));

    engine.resize(const Size(1600, 900));
    expect(engine.activeCount, 0);

    _run(engine, 3010, 6000);
    expect(engine.activeCount, greaterThan(0));
  });

  test('TextPainter 缓存不超过上限（不泄漏）', () {
    final engine = DanmakuEngine(
      settings: const DanmakuSettings(maxOnScreen: 500),
    );
    engine.resize(const Size(800, 450));
    engine.load(_items(2000, spacingMs: 5, prefix: '唯一文本'));

    _run(engine, 0, 60000);

    expect(
      engine.textCacheSize,
      lessThanOrEqualTo(AppConfig.danmakuTextCacheSize),
    );
  });

  test('诊断信息包含关键计数', () {
    final engine = DanmakuEngine();
    engine.resize(const Size(800, 450));
    engine.load(_items(10));
    engine.advanceTo(16);
    expect(engine.diagnostics, contains('总弹幕'));
    expect(engine.diagnostics, contains('文本缓存'));
  });

  group('合成弹幕生成器', () {
    test('数量正确且时间递增', () {
      final list = buildSyntheticDanmaku(count: 500, durationMs: 20000);
      expect(list.length, 500);
      for (var i = 1; i < list.length; i++) {
        expect(
          list[i].progressMs >= list[i - 1].progressMs,
          isTrue,
        );
      }
    });

    test('默认条数等于验收目标 500', () {
      expect(
        buildSyntheticDanmaku().length,
        AppConfig.danmakuHardLimit,
      );
    });

    test('确定性输出（同一 seed 结果一致，便于复现验收）', () {
      final a = buildSyntheticDanmaku(count: 50);
      final b = buildSyntheticDanmaku(count: 50);
      expect(
        a.map((e) => e.text).toList(),
        b.map((e) => e.text).toList(),
      );
    });
  });
}
