import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/config/app_config.dart';
import '../../data/models/danmaku_item.dart';
import 'danmaku/danmaku_engine.dart';
import 'danmaku/danmaku_overlay.dart';
import 'playback_clock.dart';

/// 弹幕压力测试页。
///
/// 需求验收目标是「500 条弹幕同时滚动时帧率不低于 45fps」。
/// 与其让人手工造数据，不如内置一个可复现的测试入口：
/// 注入 500 条合成弹幕循环滚动，并实时显示帧耗时与估算帧率。
///
/// **重要**：必须在 `flutter run --profile`（或 release）下测量，
/// debug 模式的 JIT 会让帧率严重失真，读数没有参考价值。
class DanmakuStressTestPage extends StatefulWidget {
  const DanmakuStressTestPage({super.key});

  @override
  State<DanmakuStressTestPage> createState() => _DanmakuStressTestPageState();
}

class _DanmakuStressTestPageState extends State<DanmakuStressTestPage>
    with SingleTickerProviderStateMixin {
  static const int _loopDurationMs = 20000;

  /// 压力测试的循环时长（毫秒）。
  ///
  /// 用 20 秒压缩 500 条，是为了让「在飞」尽可能贴近轨道容量：
  /// 若拉长到 60 秒，发射间隔变宽，同屏条数会显著低于引擎上限，
  /// 测出来的帧率就偏乐观、失去压力测试的意义。
  /// 数值越小越接近最坏情况。

  late final PlaybackClock _clock;
  final DanmakuEngine _engine = DanmakuEngine();

  final ValueNotifier<double> _frameMs = ValueNotifier<double>(0);
  final ValueNotifier<double> _fps = ValueNotifier<double>(0);
  final ValueNotifier<String> _diagnostics = ValueNotifier<String>('');

  final List<double> _frameTimes = <double>[];

  Timer? _reportTimer;
  Timer? _loopTimer;

  int _count = AppConfig.danmakuHardLimit;

  /// 字号缩放。
  ///
  /// 存在的意义是「测最坏情况」：同屏能容纳多少条弹幕由
  /// 画布高度 ÷ 行高(字号×1.25) 决定，字号越小轨道越多、同屏越挤。
  /// 只测默认字号会得到一个偏宽松的结论，所以这里让它可调。
  double _fontScale = 1.0;

  void _applySettings() {
    _engine.updateSettings(
      DanmakuSettings(
        maxOnScreen: AppConfig.danmakuHardLimit,
        fontScale: _fontScale,
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    _clock = PlaybackClock(vsync: this);
    _clock.onHardSeek = () => _engine.seekTo(_clock.positionMs.value);

    _start();

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _reportTimer = Timer.periodic(const Duration(seconds: 1), (_) => _report());
    _loopTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_clock.positionMs.value > _loopDurationMs) {
        _clock.seek(Duration.zero);
      }
    });
  }

  void _start() {
    _applySettings();
    _engine.load(
      buildSyntheticDanmaku(count: _count, durationMs: _loopDurationMs),
    );
    _clock.seek(Duration.zero);
    _engine.seekTo(0);
    _clock.setPlaying(true);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frameTimes.add(t.totalSpan.inMicroseconds / 1000.0);
    }
    while (_frameTimes.length > 120) {
      _frameTimes.removeAt(0);
    }
  }

  void _report() {
    if (!mounted || _frameTimes.isEmpty) return;
    var sum = 0.0;
    for (final v in _frameTimes) {
      sum += v;
    }
    final avg = sum / _frameTimes.length;
    _frameMs.value = avg;
    _fps.value = avg > 0 ? 1000 / avg : 0;
    _diagnostics.value = _engine.diagnostics;
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _reportTimer?.cancel();
    _loopTimer?.cancel();
    _clock.dispose();
    _engine.clear();
    _frameMs.dispose();
    _fps.dispose();
    _diagnostics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('弹幕压力测试'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新开始',
            onPressed: () {
              _frameTimes.clear();
              _start();
            },
            icon: const Icon(Icons.restart_alt_rounded),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Container(color: const Color(0xFF141414)),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DanmakuOverlay(
                      engine: _engine,
                      clock: _clock.positionMs,
                    ),
                  ),
                ),
              ],
            ),
          ),
          RepaintBoundary(child: _statsPanel()),
        ],
      ),
    );
  }

  Widget _statsPanel() {
    return Container(
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ValueListenableBuilder<double>(
                valueListenable: _fps,
                builder: (context, fps, _) {
                  final ok = fps >= 45;
                  return Row(
                    children: <Widget>[
                      Icon(
                        ok ? Icons.check_circle_rounded : Icons.error_rounded,
                        size: 18,
                        color: ok ? Colors.greenAccent : Colors.orangeAccent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${fps.toStringAsFixed(1)} fps',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: ok ? Colors.greenAccent : Colors.orangeAccent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '（验收线 45fps）',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  );
                },
              ),
              const Spacer(),
              ValueListenableBuilder<double>(
                valueListenable: _frameMs,
                builder: (context, ms, _) => Text(
                  '平均帧耗时 ${ms.toStringAsFixed(2)} ms',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<String>(
            valueListenable: _diagnostics,
            builder: (context, text, _) => Text(
              text,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              const Text('注入条数', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 12),
              Expanded(
                child: Slider(
                  value: _count.toDouble(),
                  min: 100,
                  max: AppConfig.danmakuHardLimit.toDouble(),
                  divisions: 8,
                  label: '$_count',
                  onChanged: (v) => setState(() => _count = v.round()),
                  onChangeEnd: (_) {
                    _frameTimes.clear();
                    _start();
                  },
                ),
              ),
              Text('$_count', style: const TextStyle(fontSize: 12)),
            ],
          ),
          Row(
            children: <Widget>[
              const Text('字号', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 12),
              Expanded(
                child: Slider(
                  value: _fontScale,
                  min: 0.5,
                  max: 1.5,
                  divisions: 4,
                  label: '${_fontScale.toStringAsFixed(2)}x',
                  onChanged: (v) => setState(() => _fontScale = v),
                  onChangeEnd: (_) {
                    _frameTimes.clear();
                    _start();
                  },
                ),
              ),
              Text('${_fontScale.toStringAsFixed(2)}x',
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
          const Text(
            '字号越小同屏轨道越多、越挤，用来逼近最坏情况。'
            '「在飞」是当前同屏实际条数：轨道占满后按 B 站行为丢弃，'
            '所以 500 条是流量总量而非同屏条数。',
            style: TextStyle(fontSize: 10, color: Colors.grey, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            '测量前请确认：① 用 flutter run --profile 启动（debug 读数无意义）；'
            '② 已连接真机；③ 页面稳定 10 秒后再读上方数字。',
            style: TextStyle(fontSize: 10, color: Colors.orangeAccent, height: 1.5),
          ),
        ],
      ),
    );
  }
}
