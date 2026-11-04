import 'package:flutter/material.dart';

import '../core/net/app_error.dart';

/// 统一错误视图：图标 + 中文文案 + 可选的诊断详情 + 重试按钮。
///
/// 需求要求「所有网络请求必须处理超时、403、429、空数据、解析失败，
/// 不允许崩溃」并且「错误都有用户可读提示」，所有失败路径最终都渲染到这里。
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.compact = false,
  });

  final AppError error;
  final VoidCallback? onRetry;

  /// 紧凑模式用于列表内的行内提示（例如评论区分页失败）。
  final bool compact;

  IconData get _icon {
    switch (error.kind) {
      case AppErrorKind.network:
        return Icons.wifi_off_rounded;
      case AppErrorKind.timeout:
        return Icons.hourglass_empty_rounded;
      case AppErrorKind.rateLimited:
        return Icons.speed_rounded;
      case AppErrorKind.forbidden:
        return Icons.block_rounded;
      case AppErrorKind.notFound:
        return Icons.search_off_rounded;
      case AppErrorKind.server:
        return Icons.cloud_off_rounded;
      case AppErrorKind.empty:
        return Icons.inbox_rounded;
      case AppErrorKind.parse:
        return Icons.bug_report_rounded;
      case AppErrorKind.auth:
        return Icons.lock_outline_rounded;
      case AppErrorKind.unsupported:
        return Icons.construction_rounded;
      case AppErrorKind.cancelled:
        return Icons.cancel_outlined;
      case AppErrorKind.unknown:
        return Icons.error_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (compact) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Icon(_icon, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error.message,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (onRetry != null && error.showRetry)
              TextButton(
                onPressed: onRetry,
                child: const Text('重试'),
              ),
          ],
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(_icon, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (error.detail != null) ...<Widget>[
              const SizedBox(height: 8),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    '诊断信息',
                    style: theme.textTheme.bodySmall,
                  ),
                  children: <Widget>[
                    SelectableText(
                      error.detail!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (onRetry != null && error.showRetry) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空状态（区别于错误）：没有订阅源、源没有新内容等。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_rounded,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
