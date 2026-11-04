import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/danmaku_item.dart';
import '../../data/models/subscription.dart';
import '../../data/models/timeline_mode.dart';
import '../config/app_config.dart';
import '../utils/logger.dart';

/// 本地键值存储：订阅源、设置、已读标记。
///
/// 只放小体量数据（< 100KB），所以用 SharedPreferences 而不是数据库。
/// 所有读取都做了容错：损坏的 JSON 返回默认值并记日志，绝不崩溃。
class Prefs {
  Prefs._(this._sp);

  final SharedPreferences _sp;

  static const String _kSubscriptions = 'subscriptions';
  static const String _kDanmaku = 'danmaku_settings';
  static const String _kAnonFingerprint = 'use_anon_fingerprint';
  static const String _kForceChannelB = 'force_channel_b';
  static const String _kLastTimelineView = 'last_timeline_view_at';
  static const String _kSeenPrefix = 'seen_ids__';
  static const String _kTimelineMode = 'timeline_mode';
  static const String _kPreferredQn = 'preferred_qn';
  static const String _kPlaybackPositionPrefix = 'playback_pos__';
  static const String _kPlaybackSpeed = 'playback_speed';

  /// 冷启动路径上唯一的 await：SharedPreferences 本身很轻。
  static Future<Prefs> create() async {
    final sp = await SharedPreferences.getInstance();
    return Prefs._(sp);
  }

  // ------------------------------------------------------------ 订阅源

  List<Subscription> get subscriptions {
    final raw = _sp.getString(_kSubscriptions);
    if (raw == null || raw.isEmpty) return const <Subscription>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Subscription>[];
      final result = <Subscription>[];
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          final sub = Subscription.fromJson(entry);
          if (sub != null) result.add(sub);
        }
      }
      return result;
    } catch (e) {
      Log.w('Prefs', '订阅源 JSON 损坏，已忽略：$e');
      return const <Subscription>[];
    }
  }

  Future<void> setSubscriptions(List<Subscription> subs) async {
    try {
      final raw = jsonEncode(subs.map((s) => s.toJson()).toList());
      await _sp.setString(_kSubscriptions, raw);
    } catch (e, st) {
      Log.e('Prefs', '保存订阅源失败', e, st);
    }
  }

  Future<void> addSubscription(Subscription sub) async {
    final list = List<Subscription>.from(subscriptions);
    list.removeWhere((s) => s.id == sub.id);
    list.add(sub);
    await setSubscriptions(list);
  }

  Future<void> removeSubscription(String id) async {
    final list = List<Subscription>.from(subscriptions)..removeWhere((s) => s.id == id);
    await setSubscriptions(list);
    await _sp.remove('$_kSeenPrefix$id');
  }

  // ------------------------------------------------------------ 已读标记

  /// 某订阅源已见的条目 id（用于「新内容」标记，不做系统推送）。
  Set<String> seenIds(String sourceId) {
    final list = _sp.getStringList('$_kSeenPrefix$sourceId');
    if (list == null) return <String>{};
    return list.toSet();
  }

  Future<void> setSeenIds(String sourceId, Set<String> ids) async {
    var list = ids.toList();
    // 只保留最近的若干条，避免无限膨胀。
    if (list.length > AppConfig.seenIdsPerSource) {
      list = list.sublist(list.length - AppConfig.seenIdsPerSource);
    }
    await _sp.setStringList('$_kSeenPrefix$sourceId', list);
  }

  Future<void> clearSeenIds() async {
    final keys = _sp.getKeys().where((k) => k.startsWith(_kSeenPrefix)).toList();
    for (final k in keys) {
      await _sp.remove(k);
    }
  }

  /// 上次查看时间线的时间（用于「要不要提示有新内容」）。
  DateTime? get lastTimelineViewAt {
    final raw = _sp.getString(_kLastTimelineView);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastTimelineViewAt(DateTime dt) async {
    await _sp.setString(_kLastTimelineView, dt.toUtc().toIso8601String());
  }

  // ------------------------------------------------------------ 弹幕偏好

  DanmakuSettings get danmakuSettings {
    final raw = _sp.getString(_kDanmaku);
    if (raw == null || raw.isEmpty) return const DanmakuSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const DanmakuSettings();
      return DanmakuSettings.fromJson(decoded);
    } catch (e) {
      Log.w('Prefs', '弹幕设置 JSON 损坏，已回落默认值：$e');
      return const DanmakuSettings();
    }
  }

  Future<void> setDanmakuSettings(DanmakuSettings settings) async {
    try {
      await _sp.setString(_kDanmaku, jsonEncode(settings.toJson()));
    } catch (e, st) {
      Log.e('Prefs', '保存弹幕设置失败', e, st);
    }
  }

  // ------------------------------------------------------------ 其他开关

  /// 是否在请求中附带匿名设备指纹（buvid3）。关闭后 B 站风控会更严。
  bool get useAnonymousFingerprint => _sp.getBool(_kAnonFingerprint) ?? true;

  Future<void> setUseAnonymousFingerprint(bool value) async {
    await _sp.setBool(_kAnonFingerprint, value);
  }

  /// 是否强制走通道 B（libmpv）播放。
  ///
  /// 存在的理由不是「用户偏好」，而是**可诊断性**：通道 B 是通道 A 失败时的
  /// 兜底路径，正常情况下几乎不会被走到，「有画面没声音」这类问题就没法在
  /// 真机上复现。打开这个开关即跳过通道 A，直接用 DASH + libmpv 播放。
  bool get forceChannelB => _sp.getBool(_kForceChannelB) ?? false;

  Future<void> setForceChannelB(bool value) async {
    await _sp.setBool(_kForceChannelB, value);
  }

  // ------------------------------------------------------------ 时间线模式

  /// 时间线取数模式（默认「全部关注」，见 [TimelineMode]）。
  ///
  /// 存的是 [TimelineMode.key] 而不是 index：以后往枚举中间插一个模式时，
  /// index 会漂移，用户的选择就会莫名跳到另一个模式上。
  TimelineMode get timelineMode =>
      TimelineMode.fromKey(_sp.getString(_kTimelineMode));

  Future<void> setTimelineMode(TimelineMode mode) async {
    await _sp.setString(_kTimelineMode, mode.key);
  }

  // ------------------------------------------------------------ 播放偏好

  /// 用户选过的清晰度（qn）。null = 从未选过，按 [AppConfig.preferredQuality] 请求。
  ///
  /// 为什么存 qn 而不是「第几个清晰度」：`support_formats` 的顺序与
  /// 可用项随账号权限变化（有的视频根本没有 1080P），下标会漂移，
  /// 存 qn 才能在「这个视频没有该档」时正确地降级到更低一档。
  int? get preferredQn => _sp.getInt(_kPreferredQn);

  Future<void> setPreferredQn(int qn) async {
    await _sp.setInt(_kPreferredQn, qn);
  }

  /// 上次使用的倍速（1.0 = 原速）。
  ///
  /// 存全局而不是按视频：倍速是「我今天想快点看完」的偏好，不是内容属性。
  double get playbackSpeed => _sp.getDouble(_kPlaybackSpeed) ?? 1.0;

  Future<void> setPlaybackSpeed(double speed) async {
    final v = speed.clamp(0.5, 2.0);
    if (v == 1.0) {
      await _sp.remove(_kPlaybackSpeed);
    } else {
      await _sp.setDouble(_kPlaybackSpeed, v);
    }
  }

  /// 读取某条流（bvid + cid）上次的播放位置（毫秒）。null = 没有记录。
  int? playbackPositionMs(String key) {
    final v = _sp.getInt('$_kPlaybackPositionPrefix$key');
    if (v == null || v <= 0) return null;
    return v;
  }

  /// 记录播放位置。
  ///
  /// **只保留最近 [_kPlaybackPositionKeep] 条**：SharedPreferences 不是数据库，
  /// 无限追加会让每次读取都变慢（且 Android 上它整份读进内存）。
  Future<void> setPlaybackPositionMs(String key, int ms) async {
    if (ms <= 0) return;
    await _sp.setInt('$_kPlaybackPositionPrefix$key', ms);
    await _trimPlaybackPositions();
  }

  Future<void> clearPlaybackPosition(String key) async {
    await _sp.remove('$_kPlaybackPositionPrefix$key');
  }

  /// 给「继续观看」用的最近播放记录（新的在前）。
  ///
  /// 返回 `key → 毫秒`，按写入顺序无法从 SharedPreferences 得知，
  /// 所以这里排序依据是「值里存的进度」——调用方真正需要的
  /// 「最近看过哪些」由播放页在写入时保证 key 只有一条，顺序由 UI 另行维护。
  Map<String, int> get playbackPositions {
    final out = <String, int>{};
    for (final k in _sp.getKeys()) {
      if (!k.startsWith(_kPlaybackPositionPrefix)) continue;
      final v = _sp.getInt(k);
      if (v == null || v <= 0) continue;
      out[k.substring(_kPlaybackPositionPrefix.length)] = v;
    }
    return out;
  }

  /// 最多保留多少条播放位置记录。
  static const int _kPlaybackPositionKeep = 200;

  Future<void> _trimPlaybackPositions() async {
    final keys = _sp
        .getKeys()
        .where((k) => k.startsWith(_kPlaybackPositionPrefix))
        .toList();
    if (keys.length <= _kPlaybackPositionKeep) return;
    // SharedPreferences 不保留写入顺序，这里按 key 剪掉最早的几条只是上限保护，
    // 不是 LRU —— 真正的取舍是「别无限增长」，不是「留哪一条」。
    final drop = keys.length - _kPlaybackPositionKeep;
    for (var i = 0; i < drop; i++) {
      await _sp.remove(keys[i]);
    }
  }
}
