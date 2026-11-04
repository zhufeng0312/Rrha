import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/settings_page.dart';
import '../features/subscriptions/subscriptions_page.dart';
import '../features/timeline/timeline_page.dart';
import '../providers.dart';

/// 底部导航外壳：时间线 / 订阅源 / 设置。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    // 首帧之后再发起网络请求：冷启动路径上不等待任何 IO。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(timelineProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(homeTabProvider);
    final newCount = ref.watch(timelineProvider).newCount;

    return Scaffold(
      body: IndexedStack(
        index: index,
        children: const <Widget>[
          TimelinePage(),
          SubscriptionsPage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) {
          // 点「时间线」标签（索引 0）时：即使**已经在该页**，也要回到顶部并刷新。
          // 这是移动端的通用手势预期（小红书/微博都这么做）。
          if (i == 0) {
            // 1) 发「回顶部」信号（计数器自增，保证每次都触发）。
            ref.read(timelineScrollToTopProvider.notifier).state++;
            // 2) 回到顶部后再刷新，让用户看到最新内容。
            ref.read(timelineProvider.notifier).refresh(force: true);
          }
          ref.read(homeTabProvider.notifier).state = i;
        },
        destinations: <Widget>[
          NavigationDestination(
            icon: Badge(
              isLabelVisible: newCount > 0,
              label: Text('$newCount'),
              child: const Icon(Icons.timeline_rounded),
            ),
            label: '时间线',
          ),
          const NavigationDestination(
            icon: Icon(Icons.subscriptions_outlined),
            selectedIcon: Icon(Icons.subscriptions_rounded),
            label: '订阅源',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
