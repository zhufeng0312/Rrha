import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/app_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/time_parse.dart';
import '../../data/models/content_item.dart';
import '../../data/models/subscription.dart';
import '../../data/weibo/weibo_backend.dart';
import '../../data/weibo/weibo_web_urls.dart';
import '../../providers.dart';
import '../../widgets/error_view.dart';
import '../../widgets/source_badge.dart';
import '../weibo/weibo_webview_page.dart';
import 'following_import_sheet.dart';

/// 订阅源管理：添加 / 删除 / 改别名 / 切换路由 / 查看每个源的状态。
class SubscriptionsPage extends ConsumerWidget {
  const SubscriptionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subscriptionsProvider);
    final timeline = ref.watch(timelineProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅源'),
        actions: <Widget>[
          IconButton(
            tooltip: '从 B 站关注列表导入',
            onPressed: () => showFollowingImportSheet(context, ref),
            icon: const Icon(Icons.group_add_outlined),
          ),
          IconButton(
            tooltip: '刷新全部',
            onPressed: timeline.loading || timeline.refreshing
                ? null
                : () => ref.read(timelineProvider.notifier).refresh(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // 显式给前景/背景色：M3 的 seed 派生色在亮色下把轮廓压到几乎看不见
        // （真机上「添加订阅」变成浅蓝底 + 浅蓝字），文案读不出来。
        backgroundColor: AppColors.biliBlue,
        foregroundColor: Colors.white,
        onPressed: () => showAddSubscriptionSheet(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加订阅'),
      ),
      body: subs.isEmpty
          ? EmptyView(
              message: '还没有订阅源。\n支持：B 站 UP 主的视频与动态、微博博主动态。',
              icon: Icons.subscriptions_outlined,
              action: FilledButton.icon(
                onPressed: () => showAddSubscriptionSheet(context, ref),
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加第一个订阅源'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: subs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _SubscriptionTile(
                subscription: subs[index],
                statuses: timeline.statuses,
              ),
            ),
    );
  }
}

class _SubscriptionTile extends ConsumerWidget {
  const _SubscriptionTile({required this.subscription, required this.statuses});

  final Subscription subscription;
  final Map<String, SourceStatus> statuses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final routeStatuses = <FeedRoute, SourceStatus>{};
    for (final route in subscription.activeRoutes) {
      final s = statuses['${subscription.id}#${route.key}'];
      if (s != null) routeStatuses[route] = s;
    }

    final errors = routeStatuses.values.where((s) => s.hasError).toList();
    final totalItems = routeStatuses.values.fold<int>(0, (sum, s) => sum + s.itemCount);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SourceBadge(platform: subscription.platform),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subscription.displayName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, size: 20),
                onSelected: (value) async {
                  switch (value) {
                    case 'alias':
                      await _editAlias(context, ref);
                      break;
                    case 'delete':
                      await _confirmDelete(context, ref);
                      break;
                  }
                },
                itemBuilder: (_) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'alias', child: Text('设置别名')),
                  PopupMenuItem<String>(value: 'delete', child: Text('删除订阅源')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'UID ${subscription.uid} · 添加于 ${TimeParse.humanize(subscription.addedAt)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: subscription.activeRoutes.map((route) {
              final status = routeStatuses[route];
              final ok = status != null && !status.hasError;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.page,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      status == null
                          ? Icons.help_outline_rounded
                          : (ok
                              ? Icons.check_circle_outline_rounded
                              : Icons.error_outline_rounded),
                      size: 13,
                      color: status == null
                          ? AppColors.textSecondary
                          : (ok ? AppColors.success : AppColors.warning),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      route.label,
                      style: const TextStyle(fontSize: 11),
                    ),
                    if (status != null && !status.hasError) ...<Widget>[
                      const SizedBox(width: 4),
                      Text(
                        '${status.itemCount}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
          if (errors.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            ErrorView(
              error: _firstError(errors.first),
              compact: true,
              onRetry: () =>
                  ref.read(timelineProvider.notifier).refresh(force: true),
            ),
          ] else if (routeStatuses.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              '共 $totalItems 条内容'
              '${routeStatuses.values.any((s) => s.fromCache) ? '（部分来自缓存）' : ''}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          // 微博内容不走 RSS：给一个直接进内置浏览器的入口。
          if (subscription.platform == Platform.weibo) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openInBrowser(context),
                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: const Text('在应用内浏览'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 微博订阅的「在应用内浏览」：用内置浏览器打开博主主页。
  ///
  /// [WeiboWebUrls.profile] 只接受纯数字 uid，脏数据会抛 [AppError]，
  /// 所以这里必须兜住 —— 不能因为一条历史脏订阅把 App 带崩。
  void _openInBrowser(BuildContext context) {
    final String url;
    try {
      url = WeiboWebUrls.profile(subscription.uid);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该订阅的 UID 不合法，无法打开')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WeiboWebViewPage(
          url: url,
          title: subscription.displayName,
        ),
      ),
    );
  }

  /// 状态里只存了错误文案，这里还原成只用于展示的 AppError。
  AppError _firstError(SourceStatus status) =>
      AppError(AppErrorKind.unknown, status.error ?? '未知错误', retryable: true);

  Future<void> _editAlias(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: subscription.alias ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置别名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：某某 UP 主',
            helperText: '留空则显示默认名称',
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
    await ref.read(subscriptionsProvider.notifier).updateAlias(subscription.id, result);
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定要删除「${subscription.displayName}」吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(subscriptionsProvider.notifier).remove(subscription.id);
    if (context.mounted) {
      await ref.read(timelineProvider.notifier).refresh();
    }
  }
}

// ---------------------------------------------------------------- 添加订阅

Future<void> showAddSubscriptionSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _AddSubscriptionSheet(),
  );
}

class _AddSubscriptionSheet extends ConsumerStatefulWidget {
  const _AddSubscriptionSheet();

  @override
  ConsumerState<_AddSubscriptionSheet> createState() =>
      _AddSubscriptionSheetState();
}

class _AddSubscriptionSheetState extends ConsumerState<_AddSubscriptionSheet> {
  Platform _platform = Platform.bilibili;
  final TextEditingController _uidController = TextEditingController();
  final TextEditingController _aliasController = TextEditingController();
  late Set<FeedRoute> _routes = FeedRoute.defaultsFor(_platform).toSet();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _uidController.dispose();
    _aliasController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('添加订阅源', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          SegmentedButton<Platform>(
            segments: const <ButtonSegment<Platform>>[
              ButtonSegment<Platform>(
                value: Platform.bilibili,
                label: Text('Bilibili'),
                icon: Icon(Icons.play_circle_outline_rounded, size: 16),
              ),
              ButtonSegment<Platform>(
                value: Platform.weibo,
                label: Text('微博'),
                icon: Icon(Icons.chat_bubble_outline_rounded, size: 16),
              ),
            ],
            selected: <Platform>{_platform},
            onSelectionChanged: (selection) {
              setState(() {
                _platform = selection.first;
                _routes = FeedRoute.defaultsFor(_platform).toSet();
                _error = null;
              });
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _uidController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _platform == Platform.bilibili ? 'B 站 UID' : '微博 UID',
              hintText: _platform == Platform.bilibili
                  ? '例如 2267573（空间页地址里的数字）'
                  : '例如 1234567890（主页地址里的数字）',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _aliasController,
            decoration: const InputDecoration(
              labelText: '别名（可选）',
              hintText: '方便自己在列表里辨认',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('拉取内容', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          ...FeedRoute.values
              .where((r) => r.platform == _platform)
              .map(
                (route) => CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _routes.contains(route),
                  title: Text(route.label),
                  // 微博不走 RSSHub：模板串（/weibo/user/:uid）对微博是误导，
                  // 换成一句说明。「拉取内容」勾选本身仍然保留。
                  subtitle: _platform == Platform.weibo
                      ? const Text(
                          '走微博官方接口，需先在 App 内登录微博',
                          style: TextStyle(fontSize: 11),
                        )
                      : Text(
                          route.template,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _routes.add(route);
                      } else {
                        _routes.remove(route);
                      }
                    });
                  },
                ),
              ),
          if (_platform == Platform.weibo) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '${WeiboCopy.statusPanelReason}；评论仍需在内置浏览器里看。'
              'UID 请填主页地址里的数字，例如 1782488734。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.warning,
                height: 1.4,
              ),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('添加并拉取'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await ref.read(subscriptionsProvider.notifier).add(
          platform: _platform,
          uid: _uidController.text,
          routes: _routes,
          alias: _aliasController.text,
        );

    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = result.error;
      });
      return;
    }

    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已添加，正在拉取内容…')),
    );
    // 立刻拉一次，让用户马上看到结果（失败也会有明确提示）。
    await ref.read(timelineProvider.notifier).refresh(force: true);
  }
}
