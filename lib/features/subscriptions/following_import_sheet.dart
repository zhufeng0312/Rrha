import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../data/models/bili_user.dart';
import '../../data/models/content_item.dart';
import '../../providers.dart';

/// 打开「从 B 站关注列表导入订阅」弹窗。
Future<void> showFollowingImportSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _FollowingImportSheet(),
  );
}

/// 从「我关注的 UP 主」批量导入订阅。
///
/// 两个刻意的设计：
/// - **默认只勾前几个**（[AppConfig.followingImportDefaultPicks]）：
///   关注几十上百人时「全部导入」会让每次刷新变成上百个请求，必然触发风控；
/// - 导入时把 **UP 名写进别名** —— 否则订阅列表里全是一串 `B 站 UP 12345`，
///   用户根本认不出哪个是哪个。
class _FollowingImportSheet extends ConsumerStatefulWidget {
  const _FollowingImportSheet();

  @override
  ConsumerState<_FollowingImportSheet> createState() =>
      _FollowingImportSheetState();
}

class _FollowingImportSheetState extends ConsumerState<_FollowingImportSheet> {
  final List<BiliUser> _users = <BiliUser>[];
  final Set<int> _selected = <int>{};

  bool _loading = true;
  bool _loadingMore = false;
  bool _importing = false;
  int _total = 0;
  AppError? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirstPage());
  }

  // ------------------------------------------------------------ 数据

  /// 拿到自己的 mid。
  ///
  /// 优先用钥匙串里存下的 mid（登录时 `/nav` 会给），避免多打一次接口；
  /// 老版本凭据可能没这个字段，那就问一次接口。
  Future<int> _resolveMid() async {
    final session = ref.read(biliLoginProvider).session;
    final mid = session?.mid;
    if (mid != null && mid > 0) return mid;
    return ref.read(biliClientProvider).currentMid();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final mid = await _resolveMid();
      final page =
          await ref.read(biliClientProvider).followings(mid: mid, pn: 1);
      if (!mounted) return;
      setState(() {
        _users
          ..clear()
          ..addAll(page.users);
        _total = page.total;
        _loading = false;
        _selected.addAll(
          page.users
              .take(AppConfig.followingImportDefaultPicks)
              .map((u) => u.mid),
        );
      });
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AppError(AppErrorKind.unknown, '加载关注列表失败：$e');
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final mid = await _resolveMid();
      final nextPage = (_users.length ~/ AppConfig.followingPageSize) + 1;
      final page = await ref
          .read(biliClientProvider)
          .followings(mid: mid, pn: nextPage);
      if (!mounted) return;
      setState(() {
        // 服务端翻页偶尔会返回重复项（热度/时间排序都可能），这里按 mid 去重。
        final known = _users.map((u) => u.mid).toSet();
        _users.addAll(page.users.where((u) => !known.contains(u.mid)));
        _total = page.total;
        _loadingMore = false;
      });
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = e;
      });
    }
  }

  Future<void> _import() async {
    if (_selected.isEmpty || _importing) return;
    setState(() {
      _importing = true;
      _error = null;
    });

    final notifier = ref.read(subscriptionsProvider.notifier);
    final picked = _users.where((u) => _selected.contains(u.mid)).toList();

    var ok = 0;
    String? firstError;
    for (final user in picked) {
      final res = await notifier.add(
        platform: Platform.bilibili,
        uid: user.uid,
        alias: user.displayName,
      );
      if (res.ok) {
        ok++;
      } else {
        firstError ??= res.error;
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          firstError == null
              ? '已导入 $ok 个订阅源，正在拉取内容…'
              : '已导入 $ok 个，${picked.length - ok} 个失败：$firstError',
        ),
      ),
    );
    if (ok > 0) {
      await ref.read(timelineProvider.notifier).refresh(force: true);
    }
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.78;

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '从 B 站关注列表导入',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  _total > 0
                      ? '共关注 $_total 人，已加载 ${_users.length} 人。'
                          '订阅越多人，每次刷新越慢，建议只挑常看的。'
                      : '订阅越多人，每次刷新越慢，建议只挑常看的。',
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Row(
              children: <Widget>[
                TextButton(
                  onPressed: _users.isEmpty
                      ? null
                      : () => setState(() {
                            if (_selected.length == _users.length) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(_users.map((u) => u.mid));
                            }
                          }),
                  child: Text(
                    _selected.length == _users.length && _users.isNotEmpty
                        ? '全不选'
                        : '全选',
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed:
                      _selected.isEmpty || _importing ? null : _import,
                  child: _importing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('导入选中的 ${_selected.length} 个'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final err = _error;
    if (err != null && _users.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                err.kind == AppErrorKind.auth
                    ? Icons.lock_outline
                    : Icons.error_outline,
                size: 40,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(err.message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadFirstPage,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_users.isEmpty) {
      return const Center(child: Text('关注列表是空的'));
    }

    return ListView.builder(
      itemCount: _users.length + 1,
      itemBuilder: (context, index) {
        if (index == _users.length) {
          return _footer();
        }
        final user = _users[index];
        return CheckboxListTile(
          value: _selected.contains(user.mid),
          onChanged: (v) => setState(() {
            if (v == true) {
              _selected.add(user.mid);
            } else {
              _selected.remove(user.mid);
            }
          }),
          dense: true,
          secondary: CircleAvatar(
            radius: 18,
            backgroundImage: user.avatarUrl == null
                ? null
                : NetworkImage(user.avatarUrl!),
            onBackgroundImageError: user.avatarUrl == null ? null : (_, __) {},
            child: user.avatarUrl == null
                ? const Icon(Icons.person_outline, size: 18)
                : null,
          ),
          title: Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  user.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (user.isVip) ...[
                const SizedBox(width: 6),
                const Icon(Icons.workspace_premium, size: 13, color: Colors.amber),
              ],
            ],
          ),
          subtitle: Text(
            _subtitleOf(user),
            style: const TextStyle(fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Widget _footer() {
    final hasMore = _users.length < _total;
    if (!hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text('已经到底了', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(onPressed: _loadMore, child: const Text('加载更多')),
      ),
    );
  }

  /// 副标题：认证信息与粉丝数**有什么显示什么**。
  ///
  /// 注意 `/x/relation/followings` **不返回粉丝数**（只有用户主页接口才给），
  /// 所以这里不能硬写「0 粉丝」—— 那等于替服务端编数据，
  /// 用户会以为这人真的没粉丝。
  static String _subtitleOf(BiliUser user) {
    final parts = <String>[
      if (user.isVerified) user.officialTitle!,
      if (user.fans > 0) _fans(user.fans),
    ];
    return parts.isEmpty ? 'UID ${user.mid}' : parts.join(' · ');
  }

  static String _fans(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)} 万粉丝';
    return '$n 粉丝';
  }
}
