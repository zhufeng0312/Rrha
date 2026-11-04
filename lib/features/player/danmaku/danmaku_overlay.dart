import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'danmaku_engine.dart';

/// 弹幕渲染层。
///
/// 关键性能设计：把时钟作为 `CustomPainter` 的 `repaint` 监听对象，
/// 于是时间推进**只触发重绘**，不触发任何 widget 重建或布局。
/// 外层再用 `RepaintBoundary` 把弹幕层与视频层隔离。
class DanmakuOverlay extends StatelessWidget {
  const DanmakuOverlay({
    super.key,
    required this.engine,
    required this.clock,
    this.extraRepaint,
  });

  final DanmakuEngine engine;

  /// 当前播放位置（毫秒）。
  final ValueListenable<double> clock;

  /// 时钟之外的重绘触发源（弹幕装载完、切换弹幕设置时用）。
  ///
  /// 画家只在时钟推进时重绘，于是「装载完成」这类不经过时钟的变化会被拖到
  /// 下一次位置回调才可见（暂停状态下则永远不可见）。这里允许调用方补一个
  /// 通知源，仍然只触发重绘、不触发 widget 重建。
  final Listenable? extraRepaint;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _DanmakuPainter(
          engine: engine,
          clock: clock,
          extraRepaint: extraRepaint,
        ),
        size: Size.infinite,
        isComplex: true,
        willChange: true,
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.engine,
    required this.clock,
    Listenable? extraRepaint,
  })  : extraRepaint = extraRepaint,
        super(
          repaint: extraRepaint == null
              ? clock
              : Listenable.merge(<Listenable>[clock, extraRepaint]),
        );

  final DanmakuEngine engine;
  final ValueListenable<double> clock;
  final Listenable? extraRepaint;

  @override
  void paint(Canvas canvas, Size size) {
    engine.resize(size);
    engine.advanceTo(clock.value);
    engine.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.engine != engine ||
      oldDelegate.clock != clock ||
      oldDelegate.extraRepaint != extraRepaint;
}
