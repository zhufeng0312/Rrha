import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/cache_store.dart';
import '../../core/cache/image_cache_store.dart';
import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/logger.dart';
import '../../data/models/danmaku_item.dart';
import '../../data/models/subscription.dart';
import '../../providers.dart';
import '../../widgets/danmaku_font_scale_selector.dart';
import '../player/danmaku_stress_test_page.dart';
import '../player/player_page.dart';
import '../timeline/opus_detail_page.dart';
import 'bili_login_section.dart';
import 'log_page.dart';

/// 从用户输入里抽出 bvid。
///
/// 允许直接粘贴分享链接（`https://www.bilibili.com/video/BV1xxx?...`）：
/// 这是实际使用中最常见的形态，要求用户手动截出 BV 号只会制造麻烦。
/// 放在顶层是为了可单测（[SettingsPage] 的状态类是私有的）。
String? extractBvidFromInput(String raw) {
  final m = RegExp(r'BV[0-9A-Za-z]{10}').firstMatch(raw.trim());
  return m?.group(0);
}

/// 从用户输入里抽出 **opus 动态 id**（`bilibili.com/opus/1266…`）。
///
/// 与 [extractBvidFromInput] 分开判定：opus 链接里没有 BV 号，
/// 两者是**不同页面**（动态详情 vs 视频播放）。顺序上先判 BV、再判 opus，
/// 因为视频分享链接里偶尔会带 `?spm_id_from=` 之类含数字的参数。
String? extractOpusIdFromInput(String raw) {
  final m = RegExp(r'opus/(\d{6,})').firstMatch(raw.trim());
  return m?.group(1);
}

/// 设置页：实例地址、数据源状态、缓存、弹幕偏好、关于与限制说明。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 「播放链路自检」用的固定稿件。
  ///
  /// 取排行榜榜首（弹幕量约 3.8 万条），目的是让自检同时覆盖
  /// 「弹幕真的渲染出来」这一环 —— 用 0 弹幕的稿件只能验证到
  /// 「不误报错误」，验证不了渲染。
  static const String _selfCheckBvid = 'BV1QmpE6aEA7';

  /// 「按 BV 号打开」：App 内没有搜索框，这是打开指定稿件的唯一入口。
  ///
  /// 同时接受 opus 动态链接（`bilibili.com/opus/<id>`）—— 用户真正会复制的
  /// 是浏览器地址栏那一整条，要求他先分辨「这是视频还是动态」只会制造麻烦。
  Future<void> _openByBvid() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('按 BV 号 / 动态链接打开'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'BV1xxxxxxxxx 或 bilibili.com/opus/...',
            helperText: '可直接粘贴整条分享链接，会自动识别 BV 号或动态',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    if (!mounted || input == null) return;

    // 先判动态：opus 链接里没有 BV 号，`extractBvidFromInput` 必然返回 null，
    // 先判 BV 会让这类输入直接落到「没认出」。
    final opusId = extractOpusIdFromInput(input);
    if (opusId != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OpusDetailPage(opusId: opusId),
        ),
      );
      return;
    }

    final bvid = extractBvidFromInput(input);
    if (bvid == null) {
      if (input.trim().isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没认出 BV 号或动态链接，请检查输入')),
        );
      }
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PlayerPage(bvid: bvid)),
    );
  }

  CacheStats _cacheStats = CacheStats.empty;
  ImageCacheStats _imageCacheStats = ImageCacheStats.empty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCacheStats());
  }

  Future<void> _loadCacheStats() async {
    final stats = await ref.read(cacheStoreProvider).stats();
    final imageStats = await ref.read(imageCacheStoreProvider).stats();
    if (mounted) {
      setState(() {
        _cacheStats = stats;
        _imageCacheStats = imageStats;
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final subscriptions = ref.watch(subscriptionsProvider);
    final timeline = ref.watch(timelineProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: <Widget>[
          IconButton(
            tooltip: '运行日志',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LogPage()),
            ),
            icon: const Icon(Icons.receipt_long_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: <Widget>[
          // -------------------------------------------------- 数据源状态
          _section(context, '数据源状态'),
          _card(
            children: <Widget>[
              if (subscriptions.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('还没有订阅源', style: TextStyle(fontSize: 12)),
                )
              else
                ...subscriptions.map((sub) {
                  final routeStatuses = <FeedRoute, SourceStatus>{};
                  for (final route in sub.activeRoutes) {
                    final s = timeline.statuses['${sub.id}#${route.key}'];
                    if (s != null) routeStatuses[route] = s;
                  }
                  final errors =
                      routeStatuses.values.where((s) => s.hasError).toList();
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      errors.isEmpty
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: errors.isEmpty
                          ? AppColors.success
                          : AppColors.warning,
                    ),
                    title: Text(
                      sub.displayName,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      errors.isEmpty
                          ? routeStatuses.entries
                              .map((e) =>
                                  '${e.key.label} ${e.value.itemCount} 条'
                                  '${e.value.fromCache ? '（${e.value.cachedAgeLabel ?? '缓存'}）' : ''}')
                              .join(' · ')
                          : errors.first.error!,
                      style: const TextStyle(fontSize: 11),
                    ),
                  );
                }),
            ],
          ),

          // -------------------------------------------------- 缓存
          _section(context, '缓存'),
          _card(
            children: <Widget>[
              ListTile(
                dense: true,
                leading: const Icon(Icons.sd_storage_outlined, size: 18),
                // 名称不能再叫「RSS 缓存」：RSSHub 已移除，这里存的是 B 站与
                // 微博官方接口的原始响应（目录名仍叫 rss_cache，只是不让用户看见）。
                title: const Text('接口缓存', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  '${_cacheStats.entries} 个条目 · ${_cacheStats.humanSize} · TTL 5 分钟',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: TextButton(
                  onPressed: _clearCache,
                  child: const Text('清除'),
                ),
              ),
              const Divider(height: 1),
              // 图片缓存与接口缓存刻意分开列、分开清：
              // 清接口缓存是为了「强制重新拉数据」，清图片缓存是为了「腾空间」，
              // 两者的使用时机完全不同，合并成一个按钮迟早会误伤一边。
              ListTile(
                dense: true,
                leading: const Icon(Icons.image_outlined, size: 18),
                title: const Text('图片缓存', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  '${_imageCacheStats.entries} 张 · ${_imageCacheStats.humanSize}'
                  ' · 上限 200MB / 1000 张（LRU）',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: TextButton(
                  onPressed: _clearImageCache,
                  child: const Text('清除'),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.done_all_rounded, size: 18),
                title: const Text('已读标记', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '清除后所有内容都会被当作「没见过」，不影响内容本身',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: TextButton(
                  onPressed: () async {
                    await ref.read(timelineProvider.notifier).clearSeenMarks();
                    _snack('已清除已读标记');
                  },
                  child: const Text('清除'),
                ),
              ),
            ],
          ),

          // -------------------------------------------------- 弹幕
          _section(context, '弹幕'),
          _card(
            children: <Widget>[
              SwitchListTile(
                dense: true,
                value: settings.danmaku.enabled,
                onChanged: (v) => _updateDanmaku(settings.danmaku.copyWith(enabled: v)),
                title: const Text('显示弹幕', style: TextStyle(fontSize: 13)),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: DanmakuFontScaleSelector(
                  value: settings.danmaku.fontScale,
                  onChanged: (v) => _updateDanmaku(
                    settings.danmaku.copyWith(fontScale: v),
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '透明度 ${(settings.danmaku.opacity * 100).round()}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Slider(
                      value: settings.danmaku.opacity.clamp(0.1, 1.0),
                      min: 0.1,
                      max: 1.0,
                      divisions: 18,
                      label: '${(settings.danmaku.opacity * 100).round()}%',
                      onChanged: (v) => _updateDanmaku(
                        settings.danmaku.copyWith(opacity: v),
                      ),
                    ),
                    Text(
                      '同屏上限 ${settings.danmaku.maxOnScreen} 条',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Slider(
                      value: settings.danmaku.maxOnScreen
                          .clamp(50, AppConfig.danmakuHardLimit)
                          .toDouble(),
                      min: 50,
                      max: AppConfig.danmakuHardLimit.toDouble(),
                      divisions: 9,
                      label: '${settings.danmaku.maxOnScreen}',
                      onChanged: (v) => _updateDanmaku(
                        settings.danmaku.copyWith(maxOnScreen: v.round()),
                      ),
                    ),
                    Text(
                      '滚动时长 ${settings.danmaku.speedSeconds.toStringAsFixed(1)} 秒/屏',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Slider(
                      value: settings.danmaku.speedSeconds.clamp(2.0, 8.0),
                      min: 2.0,
                      max: 8.0,
                      divisions: 12,
                      label: settings.danmaku.speedSeconds.toStringAsFixed(1),
                      onChanged: (v) => _updateDanmaku(
                        settings.danmaku.copyWith(speedSeconds: v),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.block_rounded, size: 18),
                title: const Text('关键词屏蔽', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  settings.danmaku.blockKeywords.isEmpty
                      ? '未设置（点击添加，多个词用逗号分隔）'
                      : settings.danmaku.blockKeywords.join('、'),
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () => _editBlockedKeywords(settings.danmaku),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.speed_rounded, size: 18),
                title: const Text('弹幕压力测试', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '注入 500 条弹幕并显示实时帧率（需在 profile/release 下测量才有意义）',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DanmakuStressTestPage(),
                  ),
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                dense: true,
                value: settings.forceChannelB,
                onChanged: (v) async {
                  await ref.read(settingsProvider.notifier).setForceChannelB(v);
                },
                title: const Text(
                  '强制通道 B（libmpv）',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: const Text(
                  '跳过通道 A，直接用 DASH + libmpv 播放。'
                  '通道 B 平时只在通道 A 失败时才走到，'
                  '出问题时靠它复现（如「有画面没声音」）。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
              const Divider(height: 1),
              // 与「弹幕压力测试」同样的思路：给需要验收的能力留一个可复现入口。
              // 播放/弹幕/评论走的是 B 站官方接口，与 RSSHub 无关；但正常路径
              // 只能从时间线卡片进入，而时间线依赖 RSSHub。公共实例不稳定时
              // 这条链路就完全测不到，所以这里提供一个不依赖 RSSHub 的直连入口。
              ListTile(
                dense: true,
                leading: const Icon(Icons.play_circle_outline_rounded, size: 18),
                title: const Text('播放链路自检', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '用固定 BV 号直接打开播放页，单独验证「播放 + 弹幕 + 评论」',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PlayerPage(bvid: _selfCheckBvid),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.video_library_outlined, size: 18),
                title: const Text('按 BV 号 / 动态链接打开', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '输入或粘贴 bvid、分享链接或 opus 动态链接，'
                  '分别进播放页 / 动态详情页。App 内没有搜索框',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: _openByBvid,
              ),
            ],
          ),

          // -------------------------------------------------- 隐私与诊断
          _section(context, '隐私与诊断'),
          _card(
            children: <Widget>[
              SwitchListTile(
                dense: true,
                value: settings.useAnonymousFingerprint,
                onChanged: (v) async {
                  await ref
                      .read(settingsProvider.notifier)
                      .setUseAnonymousFingerprint(v);
                },
                title: const Text('匿名设备指纹', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  '使用 B 站下发的匿名标识（buvid3）以降低风控概率。'
                  '这不是账号凭证，关闭后 B 站接口更容易返回 -352。',
                  style: TextStyle(fontSize: 11, height: 1.4),
                ),
              ),
              const Divider(height: 1),
              // 阶段 1：真正的扫码登录入口（凭据只写入系统钥匙串）。
              const BiliLoginSection(),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.badge_outlined, size: 18),
                title: const Text('WBI 签名状态', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  ref.watch(biliClientProvider).keyStatus,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),

          // -------------------------------------------------- 关于与限制
          _section(context, '关于与已知限制'),
          _card(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Rrha · B 站与微博内容聚合播放器\n'
                  'B 站与微博均直连官方接口（需登录），不依赖任何第三方聚合服务。',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '已知限制（如实标注）',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '· 微博动态：走官方接口，需先在 App 内登录微博（未登录会提示登录）\n'
                      '· 微博评论：App 内不拉取，通过内置浏览器查看\n'
                      '· 微博视频：仅在能拿到直链时才能尝试播放，成功率不保证\n'
                      '· B 站评论：无登录态下可能被风控（-352）或只返回部分评论\n'
                      '· 清晰度：默认请求 720P，可在播放页切换\n'
                      '· 需要登录（-10403）或已下架的稿件无法播放\n'
                      '· 视频流走 B 站 CDN，个别节点不可达时会自动换节点重试\n'
                      '· 弹幕接口双通道：可用性依赖 B 站策略，失败时不影响播放',
                      style: TextStyle(fontSize: 11, height: 1.6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 交互

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );

  Widget _card({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      );

  Future<void> _clearCache() async {
    try {
      await ref.read(cacheStoreProvider).clear();
      await _loadCacheStats();
      _snack('缓存已清除，下次刷新会重新请求');
    } on Object catch (e) {
      _snack('清除缓存失败：$e');
    }
  }

  Future<void> _clearImageCache() async {
    try {
      await ref.read(imageCacheStoreProvider).clear();
      await _loadCacheStats();
      _snack('图片缓存已清除，封面会在下次显示时重新下载');
    } on Object catch (e) {
      _snack('清除图片缓存失败：$e');
    }
  }

  Future<void> _updateDanmaku(DanmakuSettings value) async {
    await ref.read(settingsProvider.notifier).setDanmaku(value);
  }

  Future<void> _editBlockedKeywords(DanmakuSettings current) async {
    final controller = TextEditingController(
      text: current.blockKeywords.join('，'),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关键词屏蔽'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '多个关键词用逗号或空格分隔，例如：\n前方高能，打卡',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;

    final keywords = result
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    await _updateDanmaku(current.copyWith(blockKeywords: keywords));
  }
}

/// 供设置页底部展示诊断快照（可复制给开发者排查）。
String buildDiagnosticSnapshot({required AppError? lastError}) {
  final buffer = StringBuffer()
    ..writeln('Rrha 诊断快照 ${DateTime.now().toIso8601String()}')
    ..writeln('最后错误：${lastError ?? '无'}')
    ..writeln('--- 最近日志 ---');
  for (final line in Log.recent) {
    buffer.writeln(line);
  }
  return buffer.toString();
}

/// 便捷复制（日志页使用）。
Future<void> copyToClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));
