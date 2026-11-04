import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../providers.dart';
import 'bili_login_controller.dart';

/// 设置页的「B 站账号」区块。
///
/// 未登录时是扫码入口；已登录时是账号摘要 + 退出按钮。
/// 摘要只展示 [BiliSession.maskedSummary]（末 4 位），**绝不回显完整凭据**。
class BiliLoginSection extends ConsumerWidget {
  const BiliLoginSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final login = ref.watch(biliLoginProvider);
    final session = login.session;

    if (session == null) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.account_circle_outlined, size: 18),
        title: const Text('B 站账号', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
          '未登录。扫码登录后可拉取「我关注的 UP 主」。\n'
          '凭据只写入系统钥匙串，不落本地文件、不进日志。',
          style: TextStyle(fontSize: 11, height: 1.4),
        ),
        trailing: FilledButton.tonal(
          onPressed: () => openBiliLoginDialog(context, ref),
          child: const Text('扫码登录'),
        ),
      );
    }

    final who = (session.uname?.isNotEmpty ?? false)
        ? session.uname!
        : 'uid ${session.dedeUserId}';
    final age = session.age;
    final ageText = age.inHours < 1
        ? '${age.inMinutes} 分钟前'
        : (age.inDays < 1 ? '${age.inHours} 小时前' : '${age.inDays} 天前');

    return ListTile(
      dense: true,
      leading: const Icon(Icons.account_circle_rounded, size: 18),
      title: const Text('B 站账号', style: TextStyle(fontSize: 13)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '已登录：$who · $ageText',
            style: const TextStyle(fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 2),
          Text(
            session.maskedSummary,
            style: TextStyle(
              fontSize: 10,
              height: 1.4,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (session.isStale)
            const Text(
              '⚠️ 登录已超过 7 天，若接口开始报错请重新扫码',
              style: TextStyle(fontSize: 10, height: 1.4, color: AppColors.warning),
            ),
        ],
      ),
      trailing: TextButton(
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          await ref.read(biliLoginProvider.notifier).logout();
          messenger.showSnackBar(
            const SnackBar(content: Text('已退出登录，凭据已从系统钥匙串删除')),
          );
        },
        child: const Text('退出'),
      ),
    );
  }
}

/// 打开扫码登录对话框。
///
/// 进入前先 `start()`（申请二维码并开始轮询），退出时统一 `cancel()` ——
/// 轮询定时器必须有人收尾，否则关了界面还在打接口。
Future<void> openBiliLoginDialog(BuildContext context, WidgetRef ref) async {
  await ref.read(biliLoginProvider.notifier).start();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _BiliLoginDialog(),
  );

  ref.read(biliLoginProvider.notifier).cancel();
}

class _BiliLoginDialog extends ConsumerWidget {
  const _BiliLoginDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final login = ref.watch(biliLoginProvider);

    // 登录成功 → 自动收尾。放在 listen 里而不是 build 里，避免 build 期间导航。
    ref.listen<LoginState>(biliLoginProvider, (prev, next) {
      if (next.phase == LoginPhase.success &&
          prev?.phase != LoginPhase.success) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录成功：${next.session?.uname ?? 'B 站账号'}')),
        );
      }
    });

    return AlertDialog(
      title: const Text('扫码登录 B 站'),
      content: SizedBox(width: 280, child: _content(context, ref, login)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (login.phase == LoginPhase.expired ||
            login.phase == LoginPhase.failed)
          FilledButton(
            onPressed: () => ref.read(biliLoginProvider.notifier).start(),
            child: const Text('重新生成'),
          ),
      ],
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, LoginState login) {
    switch (login.phase) {
      case LoginPhase.idle:
      case LoginPhase.loadingQr:
        return const _Busy(text: '正在申请二维码…');

      case LoginPhase.waiting:
      case LoginPhase.scanned:
        final ticket = login.ticket;
        if (ticket == null) return const _Busy(text: '正在申请二维码…');
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // ⚠️ 二维码**本地渲染**（qr_flutter），绝不经过任何在线服务；
            //    白底必须显式给，否则扫码器可能识别不出（亮色主题下也是白底，
            //    但这里不能依赖主题 —— 深色主题若被重新启用，这一段就会失效）。
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: ticket.url,
                size: 196,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              login.phase == LoginPhase.scanned
                  ? '已扫码，请在手机上点击「确认登录」'
                  : '请用 B 站手机客户端扫码',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: login.phase == LoginPhase.scanned
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '二维码约 180 秒后过期',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        );

      case LoginPhase.confirming:
        return const _Busy(text: '已扫码，正在确认身份并写入钥匙串…');

      case LoginPhase.expired:
        return const _Notice(
          icon: Icons.timer_off_outlined,
          title: '二维码已过期',
          detail: '请点「重新生成」再扫一次。',
        );

      case LoginPhase.failed:
        return _Notice(
          icon: Icons.error_outline,
          title: '登录失败',
          detail: login.error?.message ?? '未知原因',
        );

      case LoginPhase.success:
        return const _Busy(text: '登录成功');
    }
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
        ],
      );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 36),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ],
      );
}
