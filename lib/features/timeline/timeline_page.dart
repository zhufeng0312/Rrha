import 'package:flutter/material.dart';
// `RenderSliverMultiBoxAdaptor` / `SliverMultiBoxAdaptorParentData` 在
// rendering 库里（material 不导出它们）。锚点定位要直接读 sliver 的布局结果。
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/app_error.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/content_item.dart';
import '../../data/models/subscription.dart';
import '../../data/models/timeline_mode.dart';
import '../../data/weibo/weibo_backend.dart';
import '../../data/weibo/weibo_web_urls.dart';
import '../../providers.dart';
import '../../widgets/error_view.dart';
import '../weibo/weibo_webview_page.dart';
import 'content_card.dart';
import 'content_opener.dart';
import 'weibo_facade_card.dart';

/// 统一时间线：聚合 Bilibili 与微博，按发布时间倒序。
///
/// 两种取数模式（见 [TimelineMode]，选择记在 Prefs 里）：
/// - **全部关注**（默认）：**一个混合信息流** —— B 站「我关注的动态流」
///   + 微博「我关注的人」的动态流，按发布时间倒序；两边各有自己的翻页游标
///   （B 站 offset / 微博 since_id），一侧到底另一侧仍可继续翻；
/// - **精选订阅**：按「订阅源 × 路由」逐个聚合（原有逻辑，保留不变）。
class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key});

  /// 需要显示占位卡的微博订阅 = 那些「本轮没拉到任何内容」的源。
  ///
  /// 为什么按 `itemCount` 而不是「有没有微博订阅」判断：微博现在有真实数据源
  /// （`WeiboTimelineSource`），拉到内容时列表里就是正常的微博卡片，再顶一张
  /// 「去浏览器看」的卡只会把内容压下去。占位卡退化成**兜底引导**：
  /// - 未登录 / 登录失效 → 引导去内置浏览器登录一次；
  /// - 其它原因导致 0 条 → 引导去内置浏览器直接看。
  ///
  /// 三种边界都在这里定：
  /// - `statuses` 里没有该源的键（本轮还没拉 / 刚切模式）→ **显示**占位卡
  ///   （否则首屏加载期间用户看不到任何入口）；
  /// - `itemCount > 0` → 不显示；
  /// - `itemCount == 0` → 显示。
  ///
  /// 抽成静态纯函数是为了能离线单测（不需要 pump 整个页面 + Riverpod）。
  /// ⚠️ **必须挂在 [TimelinePage] 上而不是 State 上**：单测直接调
  /// `TimelinePage.facadeSubsFor(state)`，挪进 State 会让它们全部编译失败。
  static List<Subscription> facadeSubsFor(TimelineState state) {
    // 「全部关注」模式不出占位卡：它的微博内容来自 `/feed/friends` 关注流，
    // 与「订阅源」不是一回事（那一半失败时由部分降级横幅提示，见
    // `_DegradedBanner`）。在这个模式挂「微博未登录」的卡会把「某个订阅源
    // 没拉到内容」和「关注流整体失败」混成同一种展示。
    if (state.mode.isPaged) return const <Subscription>[];

    return state.subscriptions.where((Subscription s) {
      if (s.platform != Platform.weibo) return false;
      // 微博只有一条路由（weiboUser），键的拼法与 `TimelineResult.statuses`
      // 完全一致：`{subscriptionId}#{routeKey}`。**必须**用 activeRoutes 而不是
      // 写死一条 —— 万一将来微博多出路由，这里会自然跟着扩展。
      for (final FeedRoute route in s.activeRoutes) {
        final SourceStatus? st = state.statuses['${s.id}#${route.key}'];
        if (st == null || st.itemCount == 0) return true;
      }
      return false;
    }).toList();
  }

  /// 占位卡的副标题：指向当前**真实情况**。
  ///
  /// 判断走 [SourceStatus.isAuthError]（由数据层把 `AppError.kind` 带上来），
  /// 不去 match 文案子串 —— 文案随时会改，子串判断会静默失效。
  static String facadeSubtitleFor(TimelineState state, Subscription sub) {
    for (final FeedRoute route in sub.activeRoutes) {
      final SourceStatus? st = state.statuses['${sub.id}#${route.key}'];
      if (st == null) continue;
      if (st.isAuthError) return WeiboCopy.facadeSubtitleAuth;
      if (st.itemCount == 0) return WeiboCopy.facadeSubtitleOpen;
    }
    // 无状态信息（本轮还没拉）：给「打开主页」这条最保守的引导。
    return WeiboCopy.facadeSubtitleOpen;
  }

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage> {
  /// 每个取数模式各用一个滚动控制器 —— **这就是「两个模式滚动互不影响」的全部实现**。
  ///
  /// 根因：`ListView` 在竖直方向默认 `primary: true`，会去认领所在 Route 的
  /// `PrimaryScrollController`，而它又是按「最近一层 Scaffold/Route」共享的。
  /// 于是两种模式（其实是同一个 `_body()` 里同一个 `ListView` 位置）会**共用
  /// 同一个 `ScrollPosition`**：在「全部关注」翻到一半切到「精选订阅」，
  /// 新列表一挂上去就继承了那个偏移，看起来就是「两边一起翻」。
  ///
  /// 修法两层，缺一不可：
  /// 1. 给 `ListView` 传 `controller`，把它从 PrimaryScrollController 上摘下来；
  /// 2. 给 `ListView` 一个随模式变化的 `key`，强制切换时**重建** Scrollable ——
  ///    否则 Element 复用会让旧 position 被新列表继续持有。
  ///
  /// 保留两个 controller 而不是每次切模式都新建：用户「切走再切回」时
  /// 应该回到自己那个模式原来的位置，这才是「互不影响」的完整含义。
  final Map<TimelineMode, ScrollController> _controllers =
      <TimelineMode, ScrollController>{};

  ScrollController _controllerFor(TimelineMode mode) =>
      _controllers.putIfAbsent(mode, ScrollController.new);

  /// 是否启用「翻页后视口锚定」。
  ///
  /// 默认 **false**（2026-10-26 真机结论）：锚点校正会让画面「闪一下」，
  /// 比「往下跳一点」更刺眼。改这个开关就能对比两种行为。
  ///
  /// 注意：`_captureAnchor` 在 `loadMore` 之前仍会被调用（记录成本极低），
  /// 只是不启用恢复。若彻底不用，可连带把两处调用一起删掉。
  static const bool _anchorEnabled = false;

  /// 翻页插入新条目后，把视口「钉」回用户正在看的那一条。
  ///
  /// ## 为什么必须手动做（真机缺陷 2026-10-25）
  ///
  /// 翻页**不是**往末尾追加（那会让时间线乱序，见
  /// [TimelineRepository.mergeContinuing]），新条目会插到列表中间，
  /// 已展示条目的下标整体后移。而 `ScrollPosition` 只记像素偏移，
  /// 同一个偏移此刻落到了**更靠前**的条目上 —— 视觉上就是
  /// 「翻完一页突然跳回 1 天前」。
  ///
  /// 实测结论：`findItemIndexCallback` / `findChildIndexCallback`
  /// **不补偿滚动偏移**（插入 5 条后四种组合的 offset 都停在原值）。
  /// 那两个回调只服务于 Element 复用，与视口锚定无关。
  ///
  /// ## ⚠️ 绝不要给卡片挂 GlobalKey（2026-10-26 真机事故）
  ///
  /// 早先的实现给每张卡一个 `GlobalKey`（id → key），再用 `_pruneKeys` 清理。
  /// 真机后果：**列表在翻页处「断层」、只剩微博内容，滚 N 条后闪一下才恢复**。
  ///
  /// 机制（已用测例复现）：`_pruneKeys` 删掉某 id 的 key 后，`_keyFor(id)` 会为
  /// 同一 id **再造一个新 GlobalKey**；此时旧 Element 还挂在树上，新旧 key 争用
  /// 同一条目 → 旧 Element 被整个丢弃重建。更糟的是锚点会通过那个「刚被换个
  /// 新实例」的 key 拿到**错误位置**，算出错误的校正量 → `jumpTo` 跳错地方 →
  /// 用户看到的就是「闪一下然后内容变了」。
  ///
  /// 因此：**卡片一律用 `ValueKey`**（不参与 Element 搬家，不会触发重建），
  /// 锚点改为从 sliver 直接读几何（见 [_screenTopOf]）。
  _TimelineAnchor? _anchor;

  /// 锚点定位专用 key —— 挂在 `ListView` 的**外层**（`KeyedSubtree`），
  /// 因为 `ListView` 自己的 `key` 已经被 `PageStorageKey` 占用。
  final GlobalKey _listKey = GlobalKey(debugLabel: 'timeline-list');

  /// 遍历列表的 sliver，回调每个「条目」child 的 `(itemId, screenTop)`。
  ///
  /// 直接读 `RenderSliverMultiBoxAdaptor` 的真实布局结果，不做任何估算
  /// （卡片高度不齐：正文 1~4 行、有无配图、九宫格行数，估算必然偏）。
  void _forEachRenderedItem(
    TimelineState state,
    int facadeCount,
    void Function(String id, double screenTop) visit,
  ) {
    final RenderObject? root = _listKey.currentContext?.findRenderObject();
    if (root == null) return;

    RenderSliverMultiBoxAdaptor? sliver;
    void find(RenderObject o) {
      if (sliver != null) return;
      if (o is RenderSliverMultiBoxAdaptor) {
        sliver = o;
        return;
      }
      o.visitChildren(find);
    }

    find(root);
    final RenderSliverMultiBoxAdaptor? s = sliver;
    if (s == null) return;

    RenderBox? child = s.firstChild;
    while (child != null) {
      final Object? pd = child.parentData;
      if (pd is SliverMultiBoxAdaptorParentData) {
        final int? childIndex = pd.index;
        // `ListView.separated` 的 child 是「条目 / 分隔条」交替，偶数为条目。
        if (childIndex != null && childIndex.isEven) {
          final int realIndex = childIndex ~/ 2 - facadeCount;
          if (realIndex >= 0 && realIndex < state.items.length) {
            visit(
              state.items[realIndex].id,
              child.localToGlobal(Offset.zero).dy,
            );
          }
        }
      }
      child = s.childAfter(child);
    }
  }

  /// 某个条目此刻在屏幕上的 y（不在已渲染范围内 → null）。
  double? _screenTopOf(String id, TimelineState state, int facadeCount) {
    double? found;
    _forEachRenderedItem(state, facadeCount, (String itemId, double top) {
      if (found == null && itemId == id) found = top;
    });
    return found;
  }

  /// 翻页请求发出**之前**调：记下视口顶部那条内容（id + 它在屏幕上的 y）。
  ///
  /// 必须在请求前抓 —— 拿到结果时列表已经重建，原始位置信息就没了。
  void _captureAnchor(TimelineState state) {
    final int facadeCount = TimelinePage.facadeSubsFor(state).length;
    String? bestId;
    double bestTop = 0;

    // 选「**已经越过视口顶边**（top <= 0）里最靠下的那条」，也就是用户
    // 正在读、且部分可见的那一条。
    //
    // 不能只用 `top.abs()` 找最接近 0 的：那会把「刚好露在视口底部一角的
    // 下一条」也当成候选（它的 top 可能是 +3，abs 比 -50 的那条更小），
    // 于是锚点钉在了用户还没读到的那条上，校正后画面会往上窜。
    double bestCrossedTop = double.negativeInfinity;
    double bestBelowTop = double.infinity;

    _forEachRenderedItem(state, facadeCount, (String id, double top) {
      if (top <= 0) {
        if (top > bestCrossedTop) {
          bestCrossedTop = top;
          bestId = id;
          bestTop = top;
        }
      } else if (top < bestBelowTop) {
        bestBelowTop = top;
      }
    });

    // 没有任何条目越过顶边（例如刚打开、列表还没滚动）→ 取最靠上的那条。
    if (bestId == null && bestBelowTop.isFinite) {
      _forEachRenderedItem(state, facadeCount, (String id, double top) {
        if (bestId == null || top < bestTop) {
          bestId = id;
          bestTop = top;
        }
      });
    }

    _anchor = bestId == null
        ? null
        : _TimelineAnchor(id: bestId!, screenTop: bestTop);
  }

  /// 数据更新后（post-frame），把锚点条目拽回它原来的屏幕位置。
  void _restoreAnchor(TimelineState state) {
    final _TimelineAnchor? anchor = _anchor;
    _anchor = null;
    if (anchor == null) return;

    // 锚点条目已经不在新列表里（换了一批内容 / 用户切了模式）→ 放弃。
    if (!state.items.any((ContentItem i) => i.id == anchor.id)) return;

    final int facadeCount = TimelinePage.facadeSubsFor(state).length;
    final double? now = _screenTopOf(anchor.id, state, facadeCount);
    // 锚点此刻不可见（被回收）→ 无从校正，保持现状比乱跳更安全。
    if (now == null) return;

    final double delta = now - anchor.screenTop;
    if (delta.abs() < 0.5) return;

    final ScrollController? c = _controllers[state.mode];
    if (c == null || !c.hasClients) return;

    // `delta > 0` 说明锚点整体下移了（上方插入了新条目）→ 偏移同步加上，
    // 那条内容才会停在原来的位置，用户感觉不到任何跳变。
    final double target = (c.offset + delta).clamp(
      c.position.minScrollExtent,
      c.position.maxScrollExtent,
    );
    if ((target - c.offset).abs() > 0.5) c.jumpTo(target);
  }

  @override
  void dispose() {
    for (final ScrollController c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 把当前模式的列表滚回顶部（点击底部「时间线」标签时调用）。
  ///
  /// 用 `animateTo` 而不是 `jumpTo`：几万像素的瞬移等于「闪一下」，
  /// 动画能让用户看清「回到顶部了」这个过程。动画时长刻意短（250ms），
  /// 避免和紧随其后的刷新抢帧。
  ///
  /// 已经在顶部时不重复动画（`offset <= 1` 直接返回），否则连点标签会
  /// 出现反复滚动的小抖动。
  void _scrollToTop() {
    final ScrollController? c = _controllers[ref.read(timelineProvider).mode];
    if (c == null || !c.hasClients) return;
    if (c.offset <= 1) return;
    c.animateTo(
      c.position.minScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(timelineProvider);
    final notifier = ref.read(timelineProvider.notifier);
    final busy = state.loading || state.refreshing;

    // 条目数变多 = 翻页插入了新内容 → 把视口锚回原来那一条。
    //
    // ⚠️ 2026-10-26 真机复查**已停用**：加了锚点校正后用户反馈「闪一下」更明显。
    // 原因是 `jumpTo` 在 `post-frame` 里改偏移，会与本帧的布局结果打架 ——
    // 用户先看到「按新数据布局的画面」，再看到「校正后的画面」，中间的差
    // 就是那次闪烁。保留代码与注释供以后参考，但默认不启用。
    //
    // 现在的做法：**什么都不做**。翻页插入新条目后视口会往下"跳"一点，
    // 但不会闪；这比闪一下再回正更不容易被察觉。
    //
    // 若要重新启用，请先把 `_anchorEnabled` 打开并真机对比。
    if (_anchorEnabled) {
      ref.listen<int>(
        timelineProvider.select((TimelineState s) => s.items.length),
        (int? prev, int next) {
          if (prev == null || next <= prev) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _restoreAnchor(ref.read(timelineProvider));
          });
        },
      );
    }

    // 「点底部时间线标签 → 回到顶部」（见 `timelineScrollToTopProvider`）。
    //
    // 刷新由 `HomeShell` 在本页发起，这里只管滚动：刷新会把 items 换成新的一批，
    // 若此刻还停在列表中间，用户会看到「内容突然从中间开始」。所以先回顶部。
    ref.listen<int>(
      timelineScrollToTopProvider,
      (int? prev, int next) {
        if (prev == null) return; // 首次注册，不响应
        _scrollToTop();
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('时间线'),
        actions: <Widget>[
          if (state.newCount > 0)
            TextButton(
              onPressed: () => notifier.markCurrentSeen(),
              child: Text('已读 ${state.newCount}'),
            ),
          IconButton(
            tooltip: '强制刷新（跳过 5 分钟缓存）',
            onPressed: busy ? null : () => notifier.refresh(force: true),
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      // 只保留「模式切换条 + （降级横幅）+ 列表」三层。
      //
      // 产品决策（2026-10-22）：原来列表上方还有一行「更新于 刚刚 · N 条 ·
      // N 个订阅源」，底部还有一条「B 站与微博内容均来自官方接口（需登录）」，
      // 两条都已按用户要求删除 —— 他们要的是「打开就是内容」，不要读小字。
      // 删除后 `state.lastUpdated` 仍由数据层维护（部分降级横幅、设置页的
      // 缓存时间还在用），只是时间线页面不再展示它。
      body: Column(
        children: <Widget>[
          _ModeSwitch(mode: state.mode, onChanged: notifier.setMode),
          if (state.partialFailure) _DegradedBanner(state: state),
          Expanded(child: _body(context, ref, state)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, TimelineState state) {
    // 占位卡**只在需要引导时**出现：该微博订阅本轮没拉到任何内容
    // （没有状态信息 = 还没拉过，或 itemCount == 0）。有真实卡片时不出现。
    // 判定逻辑抽成静态纯函数 `facadeSubsFor`，便于离线单测。
    final List<Subscription> facadeSubs = TimelinePage.facadeSubsFor(state);
    final int facadeCount = facadeSubs.length;
    final bool hasRealItems = state.items.isNotEmpty;

    if (state.loading && !hasRealItems && facadeCount == 0) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && !hasRealItems && facadeCount == 0) {
      return ErrorView(
        error: state.error!,
        onRetry: () => ref.read(timelineProvider.notifier).refresh(force: true),
      );
    }

    if (!hasRealItems && facadeCount == 0) {
      return EmptyView(
        message: state.emptyHint ?? '这些源最近没有新内容',
        icon: state.initialized ? Icons.inbox_rounded : Icons.hourglass_empty_rounded,
        action: FilledButton.icon(
          onPressed: () => ref.read(homeTabProvider.notifier).state = 1,
          icon: const Icon(Icons.add_rounded),
          label: const Text('去添加订阅源'),
        ),
      );
    }

    // 只有占位卡、没有真实内容时，在卡片后面补一句「下面确实没东西」，
    // 免得用户把空列表当成还在加载（这里刻意不用 EmptyView：那是整页空态，
    // 会把已经存在的占位卡一起顶掉）。
    final bool showNoContentHint = !hasRealItems && facadeCount > 0;
    final int itemCount =
        facadeCount + state.items.length + (showNoContentHint ? 1 : 0) + 1;

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(timelineProvider.notifier).refresh(force: true),
      // 触底自动续拉下一页。`loadMore()` 自带守卫（非分页模式 / 正在加载 /
      // 没有下一页时直接返回），所以滚动回调里可以放心地重复调用。
      //
      // ⚠️ 调 `loadMore()` **之前**先抓锚点：翻页会往列表中间插内容，
      // 拿到结果时旧位置信息已经没了（详见 [_captureAnchor]）。
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) {
            final TimelineState s = ref.read(timelineProvider);
            if (!s.loadingMore) _captureAnchor(s);
            ref.read(timelineProvider.notifier).loadMore();
          }
          return false;
        },
        // 锚点定位要用这个 key 找到列表的 RenderObject 去遍历 sliver。
        // 挂在 `ListView` **外层**：列表自己的 key 已被 `PageStorageKey` 占用。
        child: KeyedSubtree(
          key: _listKey,
          child: ListView.separated(
          // ⚠️ `key` + `controller` 是「两种模式滚动互不影响」的关键，两者都**不能删**：
          // - `controller:`（每个模式一个）：把列表从共享的 PrimaryScrollController
          //   上摘下来 —— 这是「切过去不继承旧偏移」的**根因修复**；
          // - `key: PageStorageKey(mode)`：切走时把该模式的偏移存进 PageStorage、
          //   切回来再恢复。没有它，controller 虽然隔离了，但新的 `ScrollPosition`
          //   仍然从 0 开始（切回来会跳回顶部）。
          // 详见 [_TimelinePageState._controllers] 的注释。
          key: PageStorageKey<TimelineMode>(state.mode),
          controller: _controllerFor(state.mode),
          // 不用 `findItemIndexCallback`：它**不补偿滚动偏移**（实测插入 5 条后
          // offset 停在原值），只管 Element 复用；而且它要求 key 能反查 id，
          // 逼着卡片挂 `GlobalKey` —— 那正是「断层 + 闪烁」的来源（见
          // [_captureAnchor] 的注释）。视口锚定由 [_captureAnchor]/[_restoreAnchor]
          // 从 sliver 读真实几何来完成。
          // 内容不足一屏时也要能下拉刷新。
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          itemCount: itemCount,
          // 卡片间距 8（规范 `space-y-2`）：12 会让白卡之间露出太宽的底色，
          // 看起来像「一张张独立的块」而不是一条动态流。
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            // 1) 顶部：每个「没有可用内容」的微博订阅一张占位卡。
            if (index < facadeCount) {
              final sub = facadeSubs[index];
              return WeiboFacadeCard(
                displayName: sub.displayName,
                uid: sub.uid,
                subtitle: TimelinePage.facadeSubtitleFor(state, sub),
                onOpen: () => _openWeiboProfile(context, sub),
              );
            }

            final int realIndex = index - facadeCount;

            // 2) 中间：真实条目。
            if (realIndex < state.items.length) {
              final item = state.items[realIndex];
              return ContentCard(
                // ⚠️ 必须用 `ValueKey`，**绝不能**用 `GlobalKey`（2026-10-26 事故）：
                // GlobalKey 参与 Element 的「搬家」，一旦 key 实例被替换（清理后
                // 重建），该条目就被判成「换了人」→ 整个丢弃重建，
                // 真机表现是「列表断层 → 滚几条 → 闪一下才恢复」。
                // 详见 [_captureAnchor] 的注释。
                key: ValueKey<String>(item.id),
                item: item,
                onTap: () => _openItem(context, item),
                // 计数值来自解析层（B 站 module_stat / 微博 *_count）。
                // 为 null 表示「接口没给」，卡片不渲染数字（不拿 0 冒充）。
                commentCount: item.commentCount,
                likeCount: item.likeCount,
                repostCount: item.repostCount,
              );
            }

            // 3) 占位卡之后的空态提示（首屏还在加载时换成一个小进度条，
            //    免得把「正在加载」说成「没有新内容」）。
            if (showNoContentHint && realIndex == state.items.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: state.loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          '这些源最近没有新内容',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              );
            }

            // 4) 末位：底部状态（加载下一页 / 到底了）。
            return _footer(state);
          },
          ),
        ),
      ),
    );
  }

  /// 底部状态：加载下一页 / 到底提示（只对分页模式有意义）。
  Widget _footer(TimelineState state) {
    if (!state.mode.isPaged) return const SizedBox.shrink();

    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: Text(
          state.followingHasMore ? '上滑加载更多' : '已经到底了',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ),
    );
  }

  /// 打开微博博主的移动端主页（内置浏览器）。
  void _openWeiboProfile(BuildContext context, Subscription sub) {
    final String url;
    try {
      // uid 必须是纯数字，否则 WeiboWebUrls 会抛 AppError（防止把用户输入
      // 直接拼进 URL 造成跳站）。这里接住它，退化成一句提示而不是崩溃。
      url = WeiboWebUrls.profile(sub.uid);
    } on AppError catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WeiboWebViewPage(url: url, title: sub.displayName),
      ),
    );
  }

  /// 打开一条内容。
  ///
  /// 分发规则**不在这里写**，统一交给 [ContentOpener]：早先这里和
  /// 卡片里的原动态块各写了一份，结果「转发的 B 站视频」从两个入口点进去
  /// 行为不同（能播 / 只看到封面）。规则只留一份，才不会再次走偏。
  void _openItem(BuildContext context, ContentItem item) {
    ContentOpener.open(context, item);
  }
}

/// 「视口锚点」：翻页插入新条目后用来把视口钉回原处。
///
/// 只记**内容 id** 和它当时离屏幕顶部的像素位置，不记滚动偏移 ——
/// 插入新条目后偏移必须改变，否则用户看到的内容就换了。
class _TimelineAnchor {
  const _TimelineAnchor({required this.id, required this.screenTop});

  /// 锚点条目的 [ContentItem.id]（跨页稳定）。
  final String id;

  /// 抓取那一刻，该条目左上角在屏幕上的 y 坐标。
  final double screenTop;
}

/// 部分降级提示：有源失败但仍展示了内容。
class _DegradedBanner extends StatelessWidget {
  const _DegradedBanner({required this.state});

  final TimelineState state;

  @override
  Widget build(BuildContext context) {
    final failing = state.failingSourceCount;
    final parts = <String>[];
    if (failing > 0) parts.add('$failing 个源刷新失败');
    if (state.staleFallbackUsed) parts.add('部分数据来自缓存');

    return Material(
      // 亮色下用浅橙底 + 深橙字：`Colors.orange.withAlpha(0.14)` 在白底上
      // 几乎看不见，深橙又会糊成一条「报错条」。
      color: AppColors.warningTint,
      child: InkWell(
        onTap: () => _showDetails(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: <Widget>[
              const Icon(Icons.warning_amber_rounded,
                  size: 16, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  parts.join('，'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.warning,
                  ),
                ),
              ),
              const Text(
                '详情',
                style: TextStyle(fontSize: 12, color: AppColors.warning),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: <Widget>[
          const Text(
            '数据源状态',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...state.statuses.entries.map((e) {
            final status = e.value;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                status.hasError ? Icons.error_outline : Icons.check_circle_outline,
                color: status.hasError ? AppColors.warning : AppColors.success,
                size: 20,
              ),
              title: Text('${e.key}  ·  ${status.itemCount} 条'),
              subtitle: Text(
                status.hasError
                    ? status.error!
                    : '成功${status.fromCache ? '（${status.cachedAgeLabel ?? '缓存'}）' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// 取数模式切换。
///
/// 放在时间线顶部而不是设置页：这是「看什么内容」的即时选择，
/// 藏进设置页会让用户以为内容莫名变少了却找不到原因。
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final TimelineMode mode;
  final ValueChanged<TimelineMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SegmentedButton<TimelineMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll<TextStyle?>(
                  TextStyle(fontSize: 12),
                ),
              ),
              segments: TimelineMode.values
                  .map(
                    (m) => ButtonSegment<TimelineMode>(
                      value: m,
                      label: Text(m.label),
                    ),
                  )
                  .toList(),
              selected: <TimelineMode>{mode},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: '「全部关注」= B 站与微博里你关注的人，合成一条信息流（可翻页）；\n'
                '「精选订阅」= 按订阅源逐个聚合（含微博源）',
            child: Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 取数模式切换。
