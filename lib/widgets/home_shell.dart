import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/settings_page.dart';
import '../features/subscriptions/subscriptions_page.dart';
import '../features/timeline/timeline_page.dart';
import '../providers.dart';

/// 底部导航外壳：时间线 / 订阅源 / 设置，且三个界面可**左右滑动切换**。
///
/// ## 需求（2026-11-08 用户原话）
///
/// 1. > 「如果我处于全部关注这一栏，我向右滑动会翻到精选订阅，继续向右翻动会
///      到达订阅源这一界面，再向右翻会到达设置界面。各个界面之间可以通过左右
///      翻动实现切换」
/// 2. > 「如果我没有处于时间线界面（比如正处于订阅源和设置界面），我点击右下角
///      时间线的时候界面只会跳转到时间线界面而不会刷新。只有处于时间线界面的时候
///      （处于全部关注和精选订阅都可以）点击右下角的时间线才会开始刷新」
///
/// ## 为什么 `PageView` 用 `NeverScrollableScrollPhysics`
///
/// 时间线页内部已经有**纵向**列表，而且它自己还要用横向手势切换
/// 「全部关注 / 精选订阅」两种模式。如果外层 `PageView` 也用默认的手势，
/// 两级横向滚动会抢同一个 gesture arena：
/// Flutter 只把它交给命中测试最内层的那一个，外层从此**再也翻不动**
/// （真机表现：在时间线页怎么左右滑都到不了订阅源）。
///
/// 所以这里把外层手势**关掉**，改成显式驱动：
/// - 时间线页滑到「精选订阅」再往右 → 回调 [_goTo] 让外层前进一页；
/// - 订阅源 / 设置两页没有横向可滚的东西，用 [GestureDetector] 直接接手势；
/// - 底部导航栏点击 → [_goTo]。
///
/// 三条入口最后都落到同一个 `_goTo`，行为一致、没有「哪种方式切换会有不同副作用」。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// 外层三页：0 时间线 / 1 订阅源 / 2 设置。
  late final PageController _pageController;

  /// 一页的切换动画时长。与 iOS 的分页手感接近，也足够短。
  static const Duration _pageDuration = Duration(milliseconds: 260);

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: ref.read(homeTabProvider));

    // 首帧之后再发起网络请求：冷启动路径上不等待任何 IO。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(timelineProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 切到第 [i] 页。**点导航栏**与**左右滑动**共用这一条路径。
  void _goTo(int i) {
    final int target = i.clamp(0, 2);
    final int current = ref.read(homeTabProvider);
    if (target == current) return;
    if (!_pageController.hasClients) {
      ref.read(homeTabProvider.notifier).state = target;
      return;
    }
    _pageController.animateToPage(
      target,
      duration: _pageDuration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // provider → 控制器：底部导航栏被点时把 PageView 同步过去。
    // **刷新不在这里做**，由点击分支显式触发（见需求 2 的说明）。
    ref.listen<int>(homeTabProvider, (int? prev, int next) {
      if (!_pageController.hasClients) return;
      final double? page = _pageController.page;
      if (page != null && page.round() == next) return;
      _pageController.animateToPage(
        next,
        duration: _pageDuration,
        curve: Curves.easeOutCubic,
      );
    });

    final index = ref.watch(homeTabProvider);
    final newCount = ref.watch(timelineProvider).newCount;

    return Scaffold(
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        onPageChanged: (int i) {
          if (ref.read(homeTabProvider) != i) {
            ref.read(homeTabProvider.notifier).state = i;
          }
        },
        children: <Widget>[
          // 时间线：内部两种模式自己翻；翻到「精选订阅」再往右时回调这里，
          // 让外层页面前进到「订阅源」。
          TimelinePage(
            onSwipePastEnd: (int direction) {
              // direction > 0 = 想看右边那一页（订阅源）。
              _goTo(index + direction);
            },
          ),
          // 订阅源 / 设置：没有横向可滚内容，直接接管横向手势。
          _SwipeablePage(
            onSwipe: (int direction) => _goTo(index + direction),
            child: const SubscriptionsPage(),
          ),
          _SwipeablePage(
            onSwipe: (int direction) => _goTo(index + direction),
            child: const SettingsPage(),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) {
          // 需求 2：只有在**时间线页上**点「时间线」才刷新。
          //
          // `index == 0` 就代表「此刻正处在时间线界面」（它的两种模式都在这一页里），
          // 所以在订阅源/设置页点「时间线」时只会跳过去，不发任何刷新请求。
          final bool alreadyOnTimeline = index == 0;
          if (i == 0 && alreadyOnTimeline) {
            // 1) 发「回顶部」信号（计数器自增，保证每次都触发）。
            ref.read(timelineScrollToTopProvider.notifier).state++;
            // 2) 回到顶部后再刷新，让用户看到最新内容。
            ref.read(timelineProvider.notifier).refresh(force: true);
            return;
          }
          _goTo(i);
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

/// 给「没有横向滚动」的整页套一层横向手势。
///
/// 只认 `onHorizontalDragEnd`（松手时才切页）：`onUpdate` 会让页面跟着手指
/// 平移，但内容本身没有联动位移，看起来像「拖了一下白屏」，不如松手直接切。
///
/// 触发阈值 40px：太灵敏会让「点按卡片」被误判成滑动。
class _SwipeablePage extends StatelessWidget {
  const _SwipeablePage({required this.onSwipe, required this.child});

  /// 参数：-1 = 想看左边那页，+1 = 想看右边那页。
  final ValueChanged<int> onSwipe;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // `behavior: translucent` 让子树的点击照样能拿到事件，
      // 我们只多接一份横向拖动。
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (DragEndDetails d) {
        final double v = d.primaryVelocity ?? 0;
        if (v.abs() < 120) return; // 快速轻扫才切，避免误触
        // 手指往左滑（velocity < 0）= 想看右边那页。
        onSwipe(v < 0 ? 1 : -1);
      },
      child: child,
    );
  }
}
