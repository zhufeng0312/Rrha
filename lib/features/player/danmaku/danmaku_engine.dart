import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/utils/logger.dart';
import '../../../data/models/danmaku_item.dart';

/// 弹幕轨道类型。
enum _LaneKind {
  scroll,
  reverse,
  top,
  bottom,
}

/// 一个可复用的渲染项（对象池成员）。
///
/// **性能要点**：弹幕渲染循环里绝不分配新对象。所有渲染项、TextPainter
/// 都从池/缓存里取，避免 500 条弹幕滚动时每帧产生大量 GC 压力。
class _RenderItem {
  DanmakuItem? item;
  TextPainter? painter;
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
  double emitMs = 0;
  int trackIndex = 0;
  _LaneKind lane = _LaneKind.scroll;
  bool active = false;

  void reset() {
    item = null;
    painter = null;
    x = 0;
    y = 0;
    width = 0;
    height = 0;
    emitMs = 0;
    trackIndex = 0;
    lane = _LaneKind.scroll;
    active = false;
  }
}

/// 一条轨道的占用状态。
class _Track {
  double availableAtMs = double.negativeInfinity;
  double y = 0;
}

/// TextPainter LRU 缓存。
///
/// 文本布局是弹幕渲染的最大开销，缓存命中后每帧只做一次位移 paint。
class _TextCache {
  _TextCache(this.capacity);

  final int capacity;
  final Map<String, TextPainter> _map = <String, TextPainter>{};
  final List<String> _lru = <String>[];

  int get length => _map.length;

  TextPainter get(String text, TextStyle style) {
    final key = '$text\u0000${style.fontSize}\u0000'
        '${style.fontWeight?.value}\u0000${style.color?.hashCode}';
    final hit = _map[key];
    if (hit != null) {
      _lru.remove(key);
      _lru.add(key);
      return hit;
    }

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    )..layout();

    _map[key] = painter;
    _lru.add(key);
    if (_lru.length > capacity) {
      final evicted = _lru.removeAt(0);
      _map.remove(evicted);
    }
    return painter;
  }

  void clear() {
    _map.clear();
    _lru.clear();
  }
}

/// 弹幕渲染引擎。
///
/// 设计要点（全部服务于「500 条同时滚动 ≥45fps」这个验收目标）：
/// 1. **零 widget 重建**：引擎只被 `CustomPainter.paint` 驱动，
///    时间变化通过 `ValueNotifier` + `repaint` 生效，不触发 build/layout。
/// 2. **对象池**：渲染项复用，渲染循环内不 new。
/// 3. **TextPainter LRU 缓存**：布局只做一次。
/// 4. **统一滚动速度**：同速下两条弹幕的相对位置恒定，于是「轨道何时可再次
///    发射」有闭式解 `t ≥ (width + gap) / v`，无需每帧做碰撞检测。
/// 5. **整体透明度用 saveLayer**：改文字颜色的 alpha 会让 TextPainter
///    缓存全部失效（每帧重新布局 500 条），这是最容易踩的性能坑。
class DanmakuEngine {
  DanmakuEngine({DanmakuSettings? settings})
      : _settings = settings ?? const DanmakuSettings();

  DanmakuSettings _settings;
  DanmakuSettings get settings => _settings;

  final List<DanmakuItem> _all = <DanmakuItem>[];
  int get totalCount => _all.length;

  final List<_RenderItem> _active = <_RenderItem>[];
  final List<_RenderItem> _pool = <_RenderItem>[];

  final Map<_LaneKind, List<_Track>> _tracks = <_LaneKind, List<_Track>>{};
  final _TextCache _textCache = _TextCache(AppConfig.danmakuTextCacheSize);

  List<String> _blocked = <String>[];

  double _canvasWidth = 0;
  double _canvasHeight = 0;
  double _lineHeight = AppConfig.danmakuBaseFontSize;
  double _scrollSpeed = 200; // px/s
  double _lastMs = 0;
  int _nextIndex = 0;
  bool _loaded = false;

  /// 每帧最多发射多少条：seek 之后避免一帧塞爆轨道。
  static const int _maxEmitPerFrame = 12;

  /// 迟到超过这个时间的弹幕直接丢弃，避免积压后集中爆发。
  static const double _lateThresholdMs = 1500;

  /// 固定弹幕（顶部/底部）在屏幕上停留的秒数。
  static const double _fixedDurationSeconds = 4.0;

  /// 轨道间最小间隙（像素）。
  static const double _trackGap = 8;

  int get activeCount => _active.length;
  int get textCacheSize => _textCache.length;
  int get nextIndex => _nextIndex;

  // ---------------------------------------------------------------- 装载

  void load(List<DanmakuItem> items) {
    _all
      ..clear()
      ..addAll(items);
    _all.sort((a, b) => a.progressMs.compareTo(b.progressMs));
    _blocked = _settings.normalizedKeywords;
    _loaded = true;

    _releaseAll();
    for (final tracks in _tracks.values) {
      for (final t in tracks) {
        t.availableAtMs = double.negativeInfinity;
      }
    }
    // 从第一条开始，而不是走 seek 逻辑：seek 会跳过「正好等于当前时间」的弹幕，
    // 那样 progressMs == 0 的弹幕（视频开头的弹幕）会全部丢失。
    _lastMs = -1;
    _nextIndex = 0;

    Log.d('DanmakuEngine', '装载弹幕 ${_all.length} 条，屏蔽词 ${_blocked.length} 个');
  }

  void clear() {
    _all.clear();
    _releaseAll();
    _textCache.clear();
    _loaded = false;
    _nextIndex = 0;
  }

  bool get hasData => _all.isNotEmpty;

  void updateSettings(DanmakuSettings value) {
    final keywordsChanged = value.blockKeywords.length != _settings.blockKeywords.length ||
        !value.blockKeywords.every(_settings.blockKeywords.contains);
    final metricsChanged = value.fontScale != _settings.fontScale ||
        value.speedSeconds != _settings.speedSeconds;

    _settings = value;
    if (keywordsChanged) {
      _blocked = value.normalizedKeywords;
    }
    if (metricsChanged) {
      _textCache.clear();
      _rebuildTracks();
    }
  }

  // ---------------------------------------------------------------- 尺寸

  /// 画布尺寸变化时重建轨道（横竖屏切换、全屏切换都会触发）。
  void resize(Size size) {
    if (size.width == _canvasWidth && size.height == _canvasHeight) return;
    _canvasWidth = size.width;
    _canvasHeight = size.height;
    _rebuildTracks();
  }

  void _rebuildTracks() {
    _lineHeight = math.max(
      12.0,
      AppConfig.danmakuBaseFontSize * _settings.fontScale * 1.25,
    );

    // 统一速度：让一条弹幕在 speedSeconds 内大致穿过屏幕。
    _scrollSpeed = (_canvasWidth + 200) / math.max(0.5, _settings.speedSeconds);

    final scrollCount = math.max(1, (_canvasHeight * 0.88 / _lineHeight).floor());
    final fixedCount = math.max(1, math.min(4, scrollCount ~/ 4));

    _tracks[_LaneKind.scroll] = _buildTracks(scrollCount, (i) => i * _lineHeight);
    _tracks[_LaneKind.reverse] =
        _buildTracks(scrollCount, (i) => i * _lineHeight);
    _tracks[_LaneKind.top] = _buildTracks(
      fixedCount,
      (i) => _canvasHeight * 0.04 + i * _lineHeight,
    );
    _tracks[_LaneKind.bottom] = _buildTracks(
      fixedCount,
      (i) => _canvasHeight * 0.92 - (i + 1) * _lineHeight,
    );

    // 轨道变了，正在飞的弹幕的位置需要重算；简单起见直接释放。
    _releaseAll();
    _resetPlayback(_lastMs);
  }

  List<_Track> _buildTracks(int count, double Function(int) yOf) {
    final list = <_Track>[];
    for (var i = 0; i < count; i++) {
      list.add(_Track()..y = yOf(i));
    }
    return list;
  }

  // ---------------------------------------------------------------- 时间轴

  /// 跳到指定时间：清空在飞弹幕，用二分查找重定位下一条待发射弹幕。
  void seekTo(double ms) {
    _resetPlayback(ms);
  }

  void _resetPlayback(double ms) {
    _releaseAll();
    for (final tracks in _tracks.values) {
      for (final t in tracks) {
        t.availableAtMs = double.negativeInfinity;
      }
    }
    _lastMs = ms;
    _nextIndex = _lowerBound(ms);
  }

  /// 找到第一条 `progressMs > ms` 的弹幕下标。
  int _lowerBound(double ms) {
    var lo = 0;
    var hi = _all.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_all[mid].progressMs <= ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// 推进到 [ms]（毫秒）。由 `CustomPainter.paint` 每帧调用。
  void advanceTo(double ms) {
    if (!_loaded) return;

    // 大幅跳变（拖动进度条）视为 seek。
    final delta = ms - _lastMs;
    if (delta < -200 || delta > 1500) {
      _resetPlayback(ms);
      return;
    }
    _lastMs = ms;

    if (_settings.enabled) {
      _emitDue(ms);
    }
    _advanceActive(ms);
  }

  void _emitDue(double ms) {
    var emitted = 0;
    final maxOnScreen = _settings.maxOnScreen;

    while (_nextIndex < _all.length && _all[_nextIndex].progressMs <= ms) {
      final item = _all[_nextIndex++];

      if (_shouldSkip(item)) continue;

      // 迟到太多的弹幕直接丢弃。高密度场景下屏幕会持续处于满的状态，
      // 若不丢弃就会无限积压，之后集中爆发成「延迟弹幕墙」。
      if (ms - item.progressMs > _lateThresholdMs) continue;

      // 屏幕已满时丢弃这一条（B 站同样会丢弃）。
      // 这里刻意用 continue 而不是 break：一次卡顿不能让时间轴永久落后。
      if (_active.length >= maxOnScreen) continue;

      // 没有空闲轨道时同样丢弃，但绝不阻塞后续弹幕。
      if (!_emit(item, ms)) continue;

      emitted++;
      if (emitted >= _maxEmitPerFrame) break;
    }
  }

  bool _shouldSkip(DanmakuItem item) {
    if (!item.mode.isRenderable) return true;
    if (item.text.trim().isEmpty) return true;
    if (_blocked.isEmpty) return false;
    final lower = item.text.toLowerCase();
    for (final kw in _blocked) {
      if (lower.contains(kw)) return true;
    }
    return false;
  }

  bool _emit(DanmakuItem item, double ms) {
    final lane = _laneOf(item.mode);
    final style = _styleFor(item);
    final painter = _textCache.get(item.text, style);
    final width = painter.width;
    final height = painter.height;

    final track = _pickTrack(lane, ms, width);
    if (track == null) return false;

    final r = _obtain();
    r.item = item;
    r.painter = painter;
    r.width = width;
    r.height = height;
    r.lane = lane;
    r.emitMs = ms;
    r.y = track.y;

    switch (lane) {
      case _LaneKind.scroll:
        r.x = _canvasWidth;
      case _LaneKind.reverse:
        r.x = -width;
      case _LaneKind.top:
      case _LaneKind.bottom:
        r.x = (_canvasWidth - width) / 2;
    }
    r.active = true;
    _active.add(r);
    return true;
  }

  _LaneKind _laneOf(DanmakuMode mode) {
    switch (mode) {
      case DanmakuMode.top:
        return _LaneKind.top;
      case DanmakuMode.bottom:
        return _LaneKind.bottom;
      case DanmakuMode.reverse:
        return _LaneKind.reverse;
      case DanmakuMode.scroll:
      case DanmakuMode.advanced:
      case DanmakuMode.code:
      case DanmakuMode.unknown:
        return _LaneKind.scroll;
    }
  }

  /// 挑选空闲轨道：优先选「最早可用」的那条，让轨道分布更均匀。
  _Track? _pickTrack(_LaneKind lane, double ms, double width) {
    final tracks = _tracks[lane];
    if (tracks == null || tracks.isEmpty) return null;

    _Track? best;
    for (final t in tracks) {
      if (t.availableAtMs <= ms) {
        if (best == null || t.availableAtMs < best.availableAtMs) best = t;
      }
    }
    if (best == null) return null;

    switch (lane) {
      case _LaneKind.scroll:
      case _LaneKind.reverse:
        // 同速模型下：必须等上一条的尾部完全离开右边缘（并留出间隙）。
        best.availableAtMs = ms + (width + _trackGap) / _scrollSpeed * 1000;
      case _LaneKind.top:
      case _LaneKind.bottom:
        best.availableAtMs = ms + _fixedDurationSeconds * 1000;
    }
    return best;
  }

  void _advanceActive(double ms) {
    final elapsedScale = 1 / 1000.0;

    for (var i = 0; i < _active.length; i++) {
      final r = _active[i];
      if (!r.active) continue;

      final elapsed = (ms - r.emitMs) * elapsedScale;
      switch (r.lane) {
        case _LaneKind.scroll:
          r.x = _canvasWidth - _scrollSpeed * elapsed;
          if (r.x + r.width < 0) r.active = false;
        case _LaneKind.reverse:
          r.x = -r.width + _scrollSpeed * elapsed;
          if (r.x > _canvasWidth) r.active = false;
        case _LaneKind.top:
        case _LaneKind.bottom:
          if (elapsed > _fixedDurationSeconds) r.active = false;
      }
    }

    // 回收离场弹幕（倒序遍历避免索引错位）。
    for (var i = _active.length - 1; i >= 0; i--) {
      if (!_active[i].active) {
        _recycle(_active.removeAt(i));
      }
    }
  }

  // ---------------------------------------------------------------- 绘制

  void paint(Canvas canvas, Size size) {
    if (!_settings.enabled || _settings.opacity <= 0 || _active.isEmpty) return;

    final needsLayer = _settings.opacity < 0.999;
    if (needsLayer) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(0, 0, 0, _settings.opacity),
      );
    }

    for (var i = 0; i < _active.length; i++) {
      final r = _active[i];
      final painter = r.painter;
      if (painter == null) continue;
      painter.paint(canvas, Offset(r.x, r.y));
    }

    if (needsLayer) canvas.restore();
  }

  TextStyle _styleFor(DanmakuItem item) {
    return TextStyle(
      fontSize: math.max(10.0, item.fontSize * _settings.fontScale),
      color: Color(item.argbColor),
      fontWeight: FontWeight.w500,
      height: 1.0,
      // 【实机性能修复 · 2026-10-14】
      // 原先这里是 `Shadow(blurRadius: 2.5)`。在华为 P40 Pro（Kirin 990）
      // profile 包上实测：压力测试注入 500 条时只有 8.7fps（115ms/帧），
      // 而屏幕上实际在飞的仅约 50 条 —— 折算每条文本 2.3ms，这个量级只可能
      // 来自「逐条文本的高斯模糊离屏合成」：blurRadius 让每个 TextPainter 都
      // 要单独走一次模糊采样，条目数直接乘到填充率上。
      //
      // 改成 blurRadius 为 0 的偏移阴影后，绘制退化为「同一段文本多画一遍」，
      // 完全避开模糊，同时仍保留描边感与可读性。
      // 注意：不要改回带 blurRadius 的阴影，除非先复测压力测试页帧率。
      shadows: const <Shadow>[
        Shadow(color: Color(0xCC000000), offset: Offset(1.5, 1.5)),
      ],
    );
  }

  // ---------------------------------------------------------------- 对象池

  _RenderItem _obtain() => _pool.isNotEmpty ? _pool.removeLast() : _RenderItem();

  void _recycle(_RenderItem item) {
    item.reset();
    if (_pool.length < AppConfig.danmakuHardLimit + 64) {
      _pool.add(item);
    }
  }

  void _releaseAll() {
    for (final r in _active) {
      _recycle(r);
    }
    _active.clear();
  }

  /// 诊断信息（压力测试页展示）。
  String get diagnostics =>
      '总弹幕 ${_all.length} · 在飞 ${_active.length} · 池 ${_pool.length} · '
      '文本缓存 ${_textCache.length}/${AppConfig.danmakuTextCacheSize} · '
      '轨道 ${_tracks[_LaneKind.scroll]?.length ?? 0}';
}

/// 生成压力测试用的合成弹幕。
///
/// 需求验收目标是「500 条弹幕同时滚动时帧率不低于 45fps」，
/// 这里提供可复现的注入手段，而不是让人手搓测试数据。
List<DanmakuItem> buildSyntheticDanmaku({
  int count = AppConfig.danmakuHardLimit,
  int durationMs = 60000,
}) {
  const samples = <String>[
    '前方高能',
    '这个转场太丝滑了',
    'awsl',
    '学会了学会了',
    '第 3 遍',
    'BGM 是什么',
    '这也太强了吧',
    '来啦来啦',
    '哈哈哈哈哈哈',
    '爷青回',
    '这波操作可以',
    '支持一下',
    '第一次看到这种',
    '泪目',
    '弹幕护体',
    '确实如此',
  ];

  final rnd = math.Random(20261011);
  final items = <DanmakuItem>[];
  for (var i = 0; i < count; i++) {
    final text = samples[rnd.nextInt(samples.length)];
    items.add(
      DanmakuItem(
        progressMs: (durationMs * i / count).round(),
        mode: i % 17 == 0 ? DanmakuMode.top : DanmakuMode.scroll,
        fontSize: 25,
        color: i % 9 == 0 ? 0xFFFF6699 : 0xFFFFFF,
        text: text,
      ),
    );
  }
  return items;
}
