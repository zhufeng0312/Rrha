import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/logger.dart';

/// 运行日志页。
///
/// 在真机上排查「公共实例到底返回了什么」时，这是唯一不依赖 adb 的手段，
/// 所以日志会保留在内存环形缓冲里并支持一键复制。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  @override
  Widget build(BuildContext context) {
    final lines = Log.recent.reversed.toList();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: () {
              Log.clear();
              setState(() {});
            },
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: lines.isEmpty
          ? const Center(child: Text('还没有日志'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = lines[index];
                final isError = line.contains('[E]');
                final isWarn = line.contains('[W]');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SelectableText(
                    line,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.4,
                      color: isError
                          ? theme.colorScheme.error
                          : (isWarn ? AppColors.warning : AppColors.textPrimary),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
