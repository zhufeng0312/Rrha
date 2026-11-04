/// 弹幕显示模式。数值与 B 站一致（XML 与 protobuf 两套接口同义）。
enum DanmakuMode {
  /// 1：普通滚动（从右往左）。
  scroll(1),

  /// 4：底部固定。
  bottom(4),

  /// 5：顶部固定。
  top(5),

  /// 6：逆向滚动（从左往右）。
  reverse(6),

  /// 7：高级弹幕（需要脚本，本项目按普通滚动降级渲染）。
  advanced(7),

  /// 8：代码弹幕（不支持，直接丢弃）。
  code(8),

  unknown(0);

  const DanmakuMode(this.biliCode);

  /// B 站的数值码（XML 的 p[1] / protobuf 的 field 3）。
  ///
  /// 刻意不叫 `code`：枚举值 [DanmakuMode.code]（mode=8，代码弹幕）本身就是
  /// 静态成员，与同名实例字段并存会编译失败。
  final int biliCode;

  static DanmakuMode fromCode(int rawCode) {
    for (final m in DanmakuMode.values) {
      if (m.biliCode == rawCode) return m;
    }
    return DanmakuMode.unknown;
  }

  /// 代码弹幕不支持渲染；高级弹幕降级为滚动。
  bool get isRenderable => this != DanmakuMode.code && this != DanmakuMode.unknown;

  /// 需要做水平位移的模式。
  bool get isScrolling =>
      this == DanmakuMode.scroll ||
      this == DanmakuMode.reverse ||
      this == DanmakuMode.advanced;
}

/// 一条弹幕。
///
/// 刻意做成不可变值对象 + 由对象池复用的「渲染项」单独存在，
/// 避免在渲染循环里反复分配。
class DanmakuItem {
  const DanmakuItem({
    required this.progressMs,
    required this.mode,
    required this.fontSize,
    required this.color,
    required this.text,
    this.uidHash,
  });

  /// 相对视频起点的出现时间（毫秒）。
  final int progressMs;

  final DanmakuMode mode;

  /// 字号（B 站原始值，通常 18 / 25 / 36）。
  final int fontSize;

  /// 颜色，0xRRGGBB 或 0xAARRGGBB。
  final int color;

  final String text;

  final String? uidHash;

  /// 规范化为 ARGB。
  int get argbColor {
    if (color > 0xFFFFFF) return color;
    return 0xFF000000 | (color & 0xFFFFFF);
  }

  Duration get progress => Duration(milliseconds: progressMs);

  @override
  String toString() => 'DanmakuItem($progressMs, ${mode.name}, $text)';
}

/// 弹幕过滤与显示偏好（来自设置页）。
class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = true,
    this.opacity = 1.0,
    this.blockKeywords = const <String>[],
    this.maxOnScreen = 200,
    this.fontScale = 1.0,
    this.speedSeconds = 4.0,
  });

  final bool enabled;

  /// 透明度 0.1 ~ 1.0。
  final double opacity;

  /// 关键词屏蔽（不区分大小写）。
  final List<String> blockKeywords;

  /// 同屏上限。
  final int maxOnScreen;

  final double fontScale;

  /// 滚动弹幕穿过整屏所需秒数。
  final double speedSeconds;

  DanmakuSettings copyWith({
    bool? enabled,
    double? opacity,
    List<String>? blockKeywords,
    int? maxOnScreen,
    double? fontScale,
    double? speedSeconds,
  }) =>
      DanmakuSettings(
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        blockKeywords: blockKeywords ?? this.blockKeywords,
        maxOnScreen: maxOnScreen ?? this.maxOnScreen,
        fontScale: fontScale ?? this.fontScale,
        speedSeconds: speedSeconds ?? this.speedSeconds,
      );

  /// 是否应屏蔽该文本。
  ///
  /// 用一次预处理后的关键词列表做子串匹配；关键词量大时可换成
  /// Aho-Corasick（当前实现在 200 词以内是零分配开销的）。
  bool blocks(String text) {
    if (blockKeywords.isEmpty) return false;
    final lower = text.toLowerCase();
    for (final kw in blockKeywords) {
      if (kw.isEmpty) continue;
      if (lower.contains(kw)) return true;
    }
    return false;
  }

  /// 预小写化的关键词（由调用方缓存，避免每帧 toLowerCase）。
  List<String> get normalizedKeywords =>
      blockKeywords.map((k) => k.trim().toLowerCase()).where((k) => k.isNotEmpty).toList();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'opacity': opacity,
        'blockKeywords': blockKeywords,
        'maxOnScreen': maxOnScreen,
        'fontScale': fontScale,
        'speedSeconds': speedSeconds,
      };

  static DanmakuSettings fromJson(Map<String, dynamic> json) => DanmakuSettings(
        enabled: json['enabled'] as bool? ?? true,
        opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
        blockKeywords: (json['blockKeywords'] as List?)?.map((e) => '$e').toList() ??
            const <String>[],
        maxOnScreen: (json['maxOnScreen'] as num?)?.toInt() ?? 200,
        fontScale: (json['fontScale'] as num?)?.toDouble() ?? 1.0,
        speedSeconds: (json['speedSeconds'] as num?)?.toDouble() ?? 4.0,
      );
}
