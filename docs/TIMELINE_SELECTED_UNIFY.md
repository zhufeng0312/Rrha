# 「精选订阅」微博翻页修复 + 排列对齐「全部关注」—— 实施方案

> **面向**：接手实现的会话（数据层 / UI 层都可能是你）
> **生成**：2026-11-08　**更新**：2026-11-08（A 已完成，B 待做）
> **工程**：`D:\Rrha`　**版本管理**：git（远端 `github.com/zhufeng0312/Rrha`），
> 动手前先 `git status` 确认工作区干净，改完再提交。
> **性质**：设计方案 + 进度记录。**A 已落地，B 尚未实现**（见下方「完成度」）。
> **前置阅读**：`docs/UI_HANDOFF.md` §8.5（显示下界的来龙去脉，**必读**，否则会重走 4 条已被证伪的弯路）

> ### 结论先行
> 用户报的两件事**不在同一层**：
> - **「微博只显示近 10 天」= 取数 bug**（该源从不翻页）→ 改数据层（§0.6）→ **✅ 已完成**
> - **「卡片排列对齐全部关注」= 渲染层** → 两边组件**本来就是同一套**，
>   真正的差异是「精选订阅没有显示下界（floor）」→ **⏳ 未做**（§1 起）
>
> 换句话说：只改排列**解决不了**「拉不出来」；那个症状必须靠分页修复。好消息是微博分页
> 所需能力（`sinceId` / `nextSinceId` / 缓存键带游标）在数据源层**本来就有**，
> 缺的只是 repo 里几行接线。

---

## 完成度（2026-11-08 核对）

| 项 | 状态 | 证据 |
| --- | --- | --- |
| **A：微博分页接线** | ✅ **已完成** | `timeline_repo.dart:829` 已传 `sinceId`、`:859` 已返回 `nextCursor` |
| **A：翻页参数方向已验证** | ✅ 已按 `since_id` 实现 | 代码按 `since_id` 方向接线，`canPage` 守卫避免空转 |
| **B：floor 推广到 N 个源** | ⏳ **未做** | `timeline_floor.dart:64` 仍是 `Platform platform` 签名；`providers.dart` 无 `selectedPool` |

> **接手时请先复核上表**：如果 B 也做了，只需更新本文档状态；
> 如果只有 A 做完，从 §5 步骤 1 开始。

---

## 0. 问题拆解

用户反馈包含两个独立问题，分属不同层。**本文档初版只识别出了 B，漏掉了更严重的 A**，
下面是修正后的完整图景。

| | 问题 | 层 | 严重度 | 状态 |
| --- | --- | --- | --- | --- |
| **A** | 精选订阅的微博**只有第一页，永远翻不了页** | 取数（`timeline_repo`） | 🔴 P0（这就是「10 天前拉不出来」） | ✅ 已修 |
| **B** | 精选订阅**没有显示下界（floor）**，会出现「本该同时有却只有一侧」 | 排列（`providers`） | 🟡 P1 | ⏳ 待做 |

**A 必须修，B 顺势一起修。** 只修 B 不修 A，用户依然只能看到 10 天内的微博
（因为数据根本没拉下来）——「改用全部关注的排列方式」本身不能解决问题。

### A 的根因（已核实到代码行）

`lib/data/repo/timeline_repo.dart` 的 `_fetchWeibo` 原本长这样：

```dart
final res = await source.fetch(
  sub: task.subscription,
  route: task.route,
  forceRefresh: forceRefresh,
  // ← 没有传 sinceId
);
...
return _FetchOutcome(
  ...
  // ← 也没有返回 nextCursor
);
```

对比 B 站那一半（`_fetchBili`）：**既传了游标，也返回了 `nextCursor`**。

后果链：

```
_loadInternal 里 nextCursors 只收 o.nextCursor != null 的源
        ↓
微博源永远不产生 nextCursor
        ↓
selectCursors 里没有微博的键
        ↓
微博永远停在第一页，且被判定为「已到底」
```

**修复前的真机证据**（2026-11-08）：

- 设置页「数据源状态」：微博源恒显示 **10~11 条**且不再增长
  （同一页面上 B 站源显示「视频 20 条 / 动态 12 条」，说明 B 站翻页链是好的）；
- 精选订阅滚到底，页脚显示「已经到底了」，底部直接是 **2020 年的置顶微博**。
  中间数年的正常微博一条都没有 —— 这不可能靠翻页走到，说明列表在第一页之后就断了。

---

## 0.5 原结论（仅在 A 修好后才成立）

**两边的卡片组件、列表组件、排序函数已经是同一套了，不需要动 UI。**
在 A 修好（微博能真正翻页）之后，剩下的差异只有一个：**「全部关注」有「显示下界（display floor）」，而「精选订阅」没有**。

所以 B 部分的实质是：

> 把 `TimelineFloor` 从「2 个平台桶」推广成「N 个源桶」，
> 让「精选订阅」也按同一套规则扣住「还没拉全的时间段」。

难度集中在**一处结构差异**：全部关注只有 2 个游标，精选订阅有 **N 个源、每个源各自一个游标**（真机实测：6 个订阅 = 10 条取数流）。水位从 2 个变成 10 个，「取最晚的那个」这个规则要重新论证。

---

## 0.6 【P0】修复 A：让精选订阅的微博真正能翻页

> ✅ **本节已实现（2026-11-08）**。下面是当时的分析与做法，保留作为**理解与复核依据**：
> 如果你要改这块代码，先读它，再核对 `timeline_repo.dart` 里 `_fetchWeibo` 的现状。

### 0.6.1 实际改的两处（`lib/data/repo/timeline_repo.dart`）

**① `_fetchWeibo` —— 把游标传进去、把下一页游标带出来**

```dart
final res = await source.fetch(
  sub: task.subscription,
  route: task.route,
  forceRefresh: forceRefresh,
  sinceId: task.cursor.sinceId,        // ← 新增
);
...
return _FetchOutcome(
  task: task,
  items: res.items,
  status: ...,
  emptyHint: res.emptyHint,
  nextCursor: canPage ? task.cursor.copyWith(sinceId: nextId) : null,  // ← 新增
);
```

**② `WeiboTimelineSource.fetch` 本来就支持 `sinceId` 并返回 `nextSinceId`**
—— 数据源层没改。这正是当初判断「改动量很小」的依据：能力早就实现了，只是没被调用。

### 0.6.2 翻页参数方向的验证（已解决，保留结论）

这个坑值得单独记：本项目在**关注流**（`/feed/friends`）上踩过完全相同的坑
（见 `weibo_api_client.dart:208-216`）：

> `since_id` = 「只要比这个 id **更新**的」→ 用于「看看有没有新微博」
> `max_id` = 「只要比这个 id **更旧**的」→ 这才是**向下翻页**
>
> 早先实现把服务端返回的 `since_id` 当作下一页游标传回去，于是第 2 页起
> 服务端恒返回 `{"statuses":[],"sinceId":null}`（0 条，HTTP 仍 200）。

个人时间线（`getIndex`）与关注流**语义不同**，所以实现时用 `canPage` 守卫：
只有当响应里确实给出了可用的下一页游标时才继续翻，否则判定为到底。
这样即使服务端行为变化，也只会「翻不动」，不会「每页都返回 0 条空转」。

> 若将来这个接口再变，用 `weibo_diagnostics.dart` 里的 `runPaging()` 复测
> （诊断入口由编译期常量控制，正式包默认关闭）。

### 0.6.3 缓存键必须跟着游标变

`WeiboTimelineSource._cacheKey`（:397）已经带 `since=$sinceId`，所以分页缓存不会互相顶掉。
**但要检查**：首屏和翻页用的 key 不同（`since=` 空 vs 有值），这是对的，不用改。

### 0.6.4 验收 A（不依赖 B）

- 任选一个微博源，滚到底后能继续加载出 **10 天前、1 个月前**的微博；
- 设置页「数据源状态」里该微博源的条数会随着翻页**增长**（不再恒定）；
- 日志出现 `loadMoreSelected 拉回 N 条 | ... | 剩余可翻源 M 个`，且 **M 包含微博的键**；
- 列表底部不再是「置顶微博」直接接「已经到底了」。

> 代码侧已按 §0.6.1 接线完成。**这几条真机判据建议在接手时再跑一遍确认**——
> 代码改对了不等于用户那边就拉到了（缓存、登录态、风控都可能让第 2 页拿不到数据）。

---

## 1. 先确认：什么已经一样了（别重复劳动）

| 维度 | 全部关注 | 精选订阅 | 是否已一致 |
| --- | --- | --- | --- |
| 卡片组件 | `ContentCard` | `ContentCard` | ✅ **同一个** |
| 列表组件 | `ListView.separated` | 同 | ✅ **同一个 `itemBuilder`** |
| 卡片 key | `ValueKey<String>(item.id)` | 同 | ✅ 同 |
| 排序 | `mergeContinuing`（去重 + 稳定倒序） | 同 | ✅ 同 |
| 分页能力 | `loadMore()` → 2 个游标 | `loadMoreSelected()` → N 个游标 | ⚠️ **框架在，但微博这条支线是断的**（§0.6） |
| 微博翻页 | `/feed/friends` 用 `max_id` ✅ | `getIndex` **从不传 sinceId、从不返回 nextCursor** ❌ | ❌ **P0 缺陷** |
| 底部页脚 | `_footer()` | 同 | ✅ 同（2026-11-08 起） |
| 滚动隔离 | 每模式一个 `ScrollController` + `PageStorageKey` | 同 | ✅ 同 |
| **显示下界（floor）** | **有** | **无** | ❌ **唯一的差异** |

> 也就是说：**UI 侧一行都不用改**。请不要再动 `timeline_page.dart` 的 `itemBuilder`。

---

## 2. 差异到底表现成什么（用户看到的现象）

### 2.1 全部关注（有 floor）

```
[10-26 ... 10-24]  90 条 B 站 + 4 条微博    ← 两侧都已拉全，可信
[10-24 ... 09-02]  （被 floor 扣住，不显示）
```

用户滚到哪，看到的都是「两侧都完整」的区间。**不会出现「本该同时有、却只有一侧」**。

### 2.2 精选订阅（无 floor）

每个源各自翻页，谁拉得深谁就先把内容摊在列表里：

```
源 A（微博，一页 20 条跨 10 天）→ 已经翻到 09-02
源 B（B 站，一页 20 条跨 9 小时）→ 只到 10-24
```

合并排序后，9-02 → 10-24 那一段**只有源 A 的内容**，源 B 的还没拉到。
这正是「全部关注」模式里已经修好的那个缺陷 —— **在精选订阅里一模一样地重现了**。

> ⚠️ 注意：精选订阅的源密度差异**比全部关注更极端**。典型配置是
> 「若干微博源 + 若干 B 站源，每个 B 站源还挂 2 条路由」，因此取数流数量
> 通常是订阅源数的 1.5~2 倍；而不同流的发帖频率可以差几十倍
> （视频投稿 vs 微博碎碎念）。

---

## 3. 核心难点：水位从 2 个变成 N 个

### 3.1 现有实现为什么不能直接复用

`TimelineFloor.watermark()` 现在的签名是：

```dart
static DateTime? watermark({
  required Iterable<ContentItem> items,
  required Platform platform,      // ← 只有 bilibili / weibo 两桶
  required bool exhausted,
})
```

它按 **`item.platform`** 分组。全部关注里这正好对应「两个游标」，所以成立。

精选订阅里**一个平台会有多个源**（4 个 B 站源 = 4 个游标），按 platform 分组会把 4 个源的水位**混成一个**，导致：

> 只要 4 个 B 站源里有 1 个拉得深，另外 3 个拉得浅，
> 这个「混合水位」就会落在很浅的位置，把大量的内容错误地判成「可以显示」。

**所以必须改成按 `item.sourceId` 分组。**

### 3.2 关键概念：sourceId 的形态不同

这是**最容易踩的坑**，先看清楚：

| 模式 | `content.sourceId` 的实际值 | 粒度 |
| --- | --- | --- |
| 全部关注 | `{bilibili:following}#bilibiliDynamic` / `{weibo:friends}#weiboUser` | **只有 2 个值** |
| 精选订阅 | `bilibili:91647207` 这种（订阅源 id） | **每个订阅源一个** |

⚠️ **`sourceId` 不含路由（route）**。同一个 B 站 UP 的「视频」和「动态」两条路由，产出的 `ContentItem.sourceId` **是同一个值**。

代码出处（已核对）：

| 位置 | 写法 |
| --- | --- |
| `lib/data/bili/bili_content_parser.dart:82` / `:270` | `sourceId: sub.id` |
| `lib/data/weibo/weibo_parser.dart:109` | `sourceId: sub.id` |
| `lib/data/repo/timeline_repo.dart:392` / `:466` | 全部关注用 `followingSourceId` / `friendsSourceId` |

也就是说：解析层只拿到 `Subscription`，**拿不到 route**，所以 sourceId 天生不含路由。

这一点很关键：

- **游标**是按 `{subscriptionId}#{routeKey}` 存的（`SourceCursor` 的键，共 10 个）；
- **sourceId** 是 `{subscriptionId}`（共 6 个）。

**两者不是一一对应。** 下面的方案必须处理这个错位。

### 3.3 由此产生的一个必须做的决定

如果水位按 `sourceId`（6 个）算，而游标按 10 个算，会有一处不对齐：

> 同一个 UP 的「视频」路由已经翻到底、但「动态」路由还有 20 页，
> 那么该 sourceId 的水位该取哪个？

**推荐取「该 sourceId 下所有路由水位的较晚者」**，理由与 floor 的定义一致：
只要还有一条路由没拉全，这个源在这个时间段就是**不完整**的，不该显示。

即：

```text
W(sourceId) = max over routes of (该路由已加载的最旧时间)
             但若**所有**路由都 exhausted → W = null（不构成约束）
```

---

## 4. 推广后的规则（核心算法）

### 4.1 floor 的定义必须换一个说法

全部关注时的定义是「取两侧水位里**较晚**的那个」。推广到 N 个源后，这句话要变成：

> **floor = 所有「未耗尽」源的水位里，最晚的那个。**

直觉：floor 要往下推，就必须**每一个源都推到那里**。最晚的那个源就是瓶颈。

```text
W_i = 源 i 的覆盖水位（比它新的内容已全部加载）；已耗尽 = null（不构成约束）
floor = max{ W_i | W_i != null }
可见  = 时间 >= floor
缓冲  = 时间 <  floor
```

> 全部关注只是这个公式在 N=2 时的特例，所以**可以统一成同一份实现**。

### 4.2 三个必须保留的既有约束（别丢）

这三条是上一轮真机验证过的，推广时一条都不能破：

1. **floor 单调（只许变旧）**：`previousFloor` 夹取必须保留。
   否则某源水位异常「变新」时，已显示条目会凭空消失。
2. **耗尽 = 不构成约束**：某个源到底了，它对 floor 没有约束（更早的时间点它反正没内容了）。
3. **`hasReliableTime == false` 不参与水位计算**：它的 `sortKey` 会回落到抓取时间，会把 floor 顶到「现在」，导致整条时间线被隐藏。

### 4.3 新增的一条约束（精选订阅特有）

4. **没有任何条目的源不参与**：刚添加、还没拉到的源，`items` 里没有它的内容，
   算不出水位。若把它当成「水位 = 现在」，整条时间线会立刻被清空。
   → **跳过**（等价于 null）。

### 4.4 ⚠️ 一个必须想的退化场景

N 个源里，只要有**一个**源非常"干"（比如刚订阅的 UP，只有 2 条内容），
它的水位会立刻到底 → 变成 exhausted → 退出约束。

但如果它**没到底但内容很少**（比如一页只有 3 条、跨 2 个月），它的水位会很老，
于是 `floor = max(...)` 会被它**拉得很新**，导致大量内容被扣住。

**这不是 bug，是正确行为**（那个源在 2 个月内确实没有更新，那段区间它已经"完整"了）。
但**体验上会显得"列表很短"**。

**建议**：先按正确性实现，真机看效果；如果列表短得离谱，再考虑给
「单源条目极少」加一个豁免（例如该源条目 < 3 条时视为 exhausted）。
**但这属于产品决策，应先与维护者确认后再加**——它可能引入「不该显示的内容」。

---

## 5. 实现步骤（按顺序，每步都能独立验证）

### 步骤 1：把 `TimelineFloor` 推广成 N 个桶（**纯函数，先做这个**）

改 `lib/data/repo/timeline_floor.dart`，把 `platform` 换成 `sourceId`：

```dart
// 现状（按平台）
static DateTime? watermark({
  required Iterable<ContentItem> items,
  required Platform platform,
  required bool exhausted,
})

// 目标（按源）：exhausted 改为按 sourceId 查询
static DateTime? watermark({
  required Iterable<ContentItem> items,
  required String sourceId,
  required bool exhausted,
})
```

`split()` 相应改成接收**一组源的耗尽状态**：

```dart
static TimelineFloorSplit split({
  required List<ContentItem> all,
  required Set<String> exhaustedSourceIds,   // 已耗尽 → 不约束
  DateTime? previousFloor,
})
```

内部改为：先按 `sourceId` 分组求各自最旧时间，再取全局最大值。

> ⚠️ **兼容性**：全部关注调用方（`providers.dart` 的 `_refreshFollowing` / `loadMore`）
> 必须同步改。全部关注只有 2 个 sourceId，传入相应的 exhausted 集合即可，
> **行为应当完全不变** —— 这是你的回归基准：改完之后
> `test/features/timeline_floor_paging_test.dart` 必须**原样全绿**。

### 步骤 2：算「哪些 sourceId 已耗尽」

需要一份 `sourceId → 是否所有路由都到底` 的映射。

- **精选订阅**：从 `state.selectedCursors`（键 `{subId}#{routeKey}`）+ `_prefs.subscriptions`
  推导：某订阅的所有 activeRoutes 都不在 `selectedCursors` 里 → 该 sourceId 耗尽。
- **全部关注**：用现有的 `biliEnded` / `weiboEnded` 映射成两个 sourceId。

建议写成一个纯函数放到 `timeline_floor.dart`，便于单测：

```dart
static Set<String> exhaustedSources({
  required List<Subscription> subscriptions,
  required Set<String> liveRouteKeys,   // 还有下一页的路由
})
```

### 步骤 3：精选订阅接入（`providers.dart`）

两处要改，**结构完全对照全部关注的写法**：

**3a. `_refreshSubscriptions()`**（`lib/providers.dart:866`）
现在直接 `items: page.items`，要改成：

```dart
final split = TimelineFloor.split(
  all: page.items,                        // loadPage 已返回严格倒序
  exhaustedSourceIds: ...,                // 步骤 2
);
state = TimelineState(
  ...
  items: split.visible,
  displayFloor: split.floor,
  selectedPool: page.items,               // ← 新增，对照 followingPool
  bufferedCount: split.buffered.length,
  ...
);
```

**3b. `loadMoreSelected()`**（`lib/providers.dart:950`）
现在用 `state.items` 合并，**必须改成用全量池**（这是 floor 能正确推进的前提）：

```dart
// 现状
final merged = TimelineRepository.mergeContinuing(state.items, page.items);

// 改成
final merged = TimelineRepository.mergeContinuing(
  state.selectedCursors.isEmpty ? state.items : state.selectedPool,
  page.items,
);
final split = TimelineFloor.split(
  all: merged,
  exhaustedSourceIds: ...,
  previousFloor: state.displayFloor,
);
state = state.copyWith(
  items: split.visible,
  selectedPool: merged,
  displayFloor: split.floor,
  bufferedCount: split.buffered.length,
  selectedCursors: page.nextCursors,
);
```

> ⚠️ **为什么必须用 pool**：`items` 只有可见那部分。若用它合并，
> 会被扣住的条目会被当成"没加载过"，于是 floor 无法推进、还会重复请求。
> 这个坑在全部关注里已经踩过一次（见 `TimelineState.followingPool` 的注释）。

### 步骤 4：`TimelineState` 加字段

```dart
final List<ContentItem>? selectedPool;   // 参照 followingPool
```

`displayFloor` / `bufferedCount` **复用现有字段**（两种模式不会同时活跃）。
`copyWith` 记得带上 `selectedPool`（`followingPool` 就是漏过，别再漏）。

另外 `allLoaded` getter 现在只认 `followingPool`，要按 mode 分派：

```dart
List<ContentItem> get allLoaded => mode == TimelineMode.selectedSubscriptions
    ? (selectedPool ?? items)
    : (followingPool ?? items);
```

### 步骤 5：已读标记要连池一起清（**别漏**）

`markCurrentSeen()` / `clearSeenMarks()` 现在清 `followingPool`。
加上 `selectedPool`，否则被扣住的条目晚些放出来时会带着「新」角标——
用户明明已经点过「已读」。这个 bug 在全部关注里已经修过一次。

### 步骤 6：`setMode` 快照

`_rememberSnapshot()` 存的是整个 `TimelineState`，所以 `selectedPool` / `displayFloor`
会跟着走，**理论上不用改**。但请验证一次：
「精选订阅翻 3 页 → 切到全部关注 → 切回」之后，列表还是 3 页、顺序不变。

### 步骤 7：占位卡与 floor 互不影响（确认一下，不用改）

精选订阅特有「微博占位卡」（`TimelinePage.facadeSubsFor`），它渲染在列表**最前面**，
占用 `itemCount` 的头部若干个位置：

```dart
final int itemCount =
    facadeCount + state.items.length + (showNoContentHint ? 1 : 0) + 1;
```

它由 `state.statuses` 的 `itemCount` 决定，**与 `items` / `displayFloor` 无关**。
floor 只影响 `state.items` 的内容，`facadeCount` 用 `statuses` 判断 —— 两者正交，**不用改**。

但要注意一个连带反应：占位卡的判据是 `st.itemCount == 0`（本轮该源 0 条）。
**接入 floor 后，如果某个源的内容全被扣进缓冲**，它的 `status.itemCount` 仍然是
**原始拉回条数**（不是可见条数），所以占位卡**不会**误显示。
→ 实现时**不要**把 `status.itemCount` 改成 `split.visible` 的统计值。

---

## 6. 测试要求

### 6.1 必须保留的回归

```powershell
flutter test test/features/timeline_floor_paging_test.dart   # 必须原样全绿
flutter test test/data/timeline_floor_test.dart              # 按新签名调整后全绿
```

这两份是全部关注的正确性基线。**如果你改完它们不绿了，说明你破坏了已有行为。**

### 6.2 必须新增的测试

新建 `test/features/timeline_floor_selected_test.dart`，至少覆盖：

| # | 断言 | 为什么 |
| --- | --- | --- |
| 1 | 多源（≥4 个源、密度差 10 倍）时，可见列表严格按时间倒序 | 基本正确性 |
| 2 | **每轮翻页后，已显示的条目必须是新列表的前缀** | 这条 = 「不会闪烁」的形式化表述，与全部关注同一条 |
| 3 | 某个源到底后，它不再拖住 floor（允许出现真实的纯单源段） | 对应 §4.2 第 2 条 |
| 4 | 只翻了一部分源时，floor 由**最晚**的那个源决定 | 核心算法 |
| 5 | 所有源都到底 → floor 变 null，缓冲全部放出 | 收尾正确 |
| 6 | 缓冲条目在 floor 推进后出现，**不额外发请求** | 池机制生效 |
| 7 | `selectedPool` 里的条目在 `markCurrentSeen` 后不带「新」角标 | 步骤 5 |

> 写测试时**只挂 `TimelinePage`，不要挂 `HomeShell`** —— 后者会抛
> `ListTile ... ink splashes may be invisible` 断言（既有问题，见 `UI_HANDOFF.md` §8.5.8）。

---

## 7. 真机验收

```powershell
# 构建环境（Windows；其它平台只需确保 flutter / adb 可用）
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. .\tools\flutter-env.ps1

dart analyze                  # 必须 No issues found
flutter test                  # 必须全绿
cd android; .\gradlew.bat assembleProfile --offline
adb install -r build\app\outputs\flutter-apk\app-profile.apk
```

**判据**：

1. 切到「精选订阅」，滚到底多次，观察**日志**（App 内「设置 → 右上角运行日志」）：
   应当出现与全部关注同格式的行，`floor` **单调后退**、`可见` **只增不减**、`缓冲` **稳定在某个量级**。
   > 建议照抄全部关注那行日志的格式，方便对比：
   > `loadMore#N ... | 池 X 条 | floor=... 可见=X 缓冲=Y`
2. 截图交叉验证：相邻卡片的相对时间**严格递减**，不允许出现「往下滚反而更新」。
3. 重点看「只有单一平台」的长段是否**只出现在该源确实没内容的时间段**
   （即那个源已 exhausted，或它在这个区间真的没发）。
4. 回归：切模式来回 3 次，两个模式的列表内容和滚动位置互不影响。

---

## 8. 风险与「不要做」清单

| 别做 | 原因 |
| --- | --- |
| ❌ 不要改 `timeline_page.dart` 的 `itemBuilder` | 两边已经共用，改了会同时影响两个模式 |
| ❌ 不要重新引入 `GlobalKey`、`_pruneKeys`、`findChildIndexCallback`、viewport anchor | 4 条全部被真机证伪，见 `UI_HANDOFF.md` §8.5.3 |
| ❌ 不要「固定时间窗拉取」（如每次拉 6 小时） | 两个接口都没有时间范围参数，且密度比决定了会镜像成「只有 B 站」；详见 §8.5.6 |
| ❌ 不要按 `platform` 而不是 `sourceId` 分组 | 见 §3.1，会把多源水位错误地混成一个 |
| ❌ 不要在 `loadMoreSelected` 里用 `state.items` 合并 | 见步骤 3b，floor 将永远推不动 |
| ❌ 不要自己给「单源条目极少」加豁免 | 见 §4.4，属产品决策，需先与维护者确认 |
| ⚠️ 不要只翻「水位落后」的那部分源（省请求） | 已在全部关注里试过并回滚：被跳过的源水位冻住 → floor 卡死 → 滚到底卡住 |

### 8.1 一个**可以**考虑的优化（但先别做）

精选订阅有 N 个源，每轮 `loadMoreSelected` 会**同时翻所有还没到底的源**（10 个请求）。
加了 floor 之后，这些内容大部分会进缓冲，请求量看起来"浪费"。

但这与全部关注同理：**两侧/多源都翻是保证 floor 能推进的唯一稳妥方式**。
省请求会让某个源水位冻住。先按正确性实现，请求量的问题留到用户抱怨时再谈。

---

## 9. 交付清单

### A（P0）

- [x] `_fetchWeibo` 已传 `sinceId`、已返回 `nextCursor`
- [x] 翻页参数方向按 `since_id` 实现，并用 `canPage` 守卫防止空转
- [ ] 真机：微博源能加载出 10 天前 / 1 个月前的微博（**建议提交前再确认一次**）
- [ ] 真机：设置页微博源条数随翻页增长（不再恒定）
- [ ] 列表底部不再出现「置顶微博 → 已经到底了」

### B（P1，排列对齐）

- [ ] `lib/data/repo/timeline_floor.dart` 已推广为按 `sourceId` 分组
- [ ] `providers.dart`：`_refreshFollowing` / `loadMore` 已同步（行为不变）
- [ ] `providers.dart`：`_refreshSubscriptions` / `loadMoreSelected` 已接入 floor
- [ ] `TimelineState` 新增 `selectedPool`，`allLoaded` 按 mode 分派
- [ ] `markCurrentSeen` / `clearSeenMarks` 连 `selectedPool` 一起清
- [ ] `test/data/timeline_floor_test.dart` 按新签名更新并全绿
- [ ] `test/features/timeline_floor_paging_test.dart` **原样全绿**（证明没破坏全部关注）
- [ ] 新增 `test/features/timeline_floor_selected_test.dart`（≥7 条）
- [ ] `dart analyze` → No issues found
- [ ] `flutter test` → 全绿
- [ ] `assembleProfile --offline` → BUILD SUCCESSFUL
- [ ] 真机：日志里 floor 单调、可见只增不减；截图时间严格递减
- [ ] 真机：切模式来回 3 次，两模式互不影响

---

## 10. 实现要点小结

**这个任务的本质不是「加个 floor」，而是「把 floor 从 2 桶推广成 N 桶」。**
推广过程中最容易错的三件事，按出错概率排序：

1. **按 platform 分组**（应该按 sourceId）—— 会让缺陷静默消失一部分，看起来「好多了」但没真修好；
2. **用 `items` 而不是 `pool` 合并** —— floor 永远推不动，列表滚几页就卡死；
3. **漏掉 pool 的已读清理** —— 延迟出现的条目带着「新」角标。

第 1 条尤其危险，因为**测不出来**：它不会报错，只会让扣留变少。
所以测试里那条「floor 由最晚的源决定」（§6.2 第 4 条）**必须写**。

---

*相关文档：`docs/UI_HANDOFF.md` §8.5（显示下界完整来龙去脉）、`docs/COLLAB_PLAN.md`（领地表，`providers.dart` / `timeline_repo.dart` 默认归总设计会话，动前请确认）。*
