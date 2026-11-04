# Bilibili 模块完善 + 界面优化：接手建议（Rrha）

> **面向**：新会话（负责「B 站模块补全 + 界面打磨」）  
> **生成**：2026-10-18，基于工程当前状态（App `0.2.1+4`，`flutter test` **434 全绿**，`dart analyze` 干净）  
> **工程**：`D:\Rrha`（Flutter 3.47.7 / Dart 3.13.5 / Android，包名 `com.rrha.rrha`，无 git 仓库）  
> **标注约定**：【已证实】= 在代码或真机上确认过，可直接当事实用；【待验证】= 方向性判断，**必须先验证再写代码**。

---

## 0. 一句话现状

**B 站链路已经能用了**：登录、关注导入、时间线（含分页/缓存/已读）、播放（双通道 + 自动换 CDN 节点）、弹幕（含字号/屏蔽/压力测试）、评论（含子评论翻页）、图片预览保存、封面磁盘缓存，全部在**荣耀 Magic8 Pro / Android 16** 上真机验证通过。

所以本轮的活**不是修 bug，是「补全 + 打磨」**：很多数据接口里已经拿到了，只是没显示；很多 B 站 App 里理所当然的操作，这里还没有入口。

---

## 0.5 本轮用户新增的四条要求，以及「哪些不是你的活」

用户 2026-10-18 追加了四条要求。**其中三条属于界面会话**，列在这里是为了让你别重复劳动、也别互相踩：

| # | 要求 | 归谁 | 说明 |
| --- | --- | --- | --- |
| 1 | 「全部关注」要显示 **B 站 + 微博**中我所有关注的人的内容；「精选订阅」= 我在订阅源里自己添加的博主 | **总设计 + 微博会话**（见 `docs/COLLAB_PLAN.md`） | B 站侧 `followings / followingFeed`（`feed/all`）**已实现**，缺的是微博关注列表与两路合并。你这边**不需要动**，只要别改坏 |
| 2 | 动态没有图片时**不显示媒体区** | **界面会话**（`docs/UI_HANDOFF.md` §1.3） | 改 `content_card.dart` |
| 3 | 卡片改用 B 站动态页式布局：**44px 头像 + 昵称/时间 + 全宽或九宫格媒体区** | **界面会话**（`docs/UI_HANDOFF.md` §1.2） | 改 `content_card.dart`；同时全 App 由深色切**亮色主题**（`main.dart`） |
| 4 | 点开「精选订阅」不要先闪「占位卡 + 转圈」 | **界面会话**（`docs/UI_HANDOFF.md` §4） | 根因在 `lib/providers.dart` 的 `setMode`，属跨模块公共文件 |

**所以你这一轮的 P0 就是 §3 里「数据已在手上、只差显示」的那几项**：统计行、简介、清晰度（清单已按用户 2026-10-18 的删减更新，照着 §10 的顺序走即可）。

> ⚠️ 协作铁律：`lib/features/timeline/content_card.dart`、`lib/providers.dart`、`lib/features/timeline/timeline_page.dart` 这三个文件**界面会话会改**。你若需要「播放页统计行」「卡片时长角标」之类的改动，要么先确认没人正在改它们，要么**新建独立文件**（如 `lib/widgets/video_stats_row.dart`）再引用——独立文件天然不冲突。

---

## 0.6 2026-10-19 新增需求（分配给你这个会话的）

用户又提了 6 条，其中 **2 条归 B 站/播放器会话**，其余归界面/微博。六条的总表见 `docs/COLLAB_PLAN.md` §5。

### N1 视频**长按无法快进**（用户原话）

**现状【已证实】**：`lib/features/player/player_page.dart` 的手势层（约 917-919 行）只注册了横向拖动：

```dart
onHorizontalDragStart: _onDragStart,
onHorizontalDragUpdate: _onHorizontalDrag,
onHorizontalDragEnd: _onDragEnd,
```

`_onHorizontalDrag` 是**拖动改播放位置**（等于拖进度条），**没有长按加速**；`RrhaPlayer` 抽象里也没有任何变速方法。

**要做的事**：

1. **给 `RrhaPlayer` 加速率能力**（`lib/features/player/player_adapter.dart`）：
   ```dart
   /// 播放倍速。1.0 = 原速。
   Future<void> setSpeed(double speed);
   ```
   - 通道 A：`VideoPlayerController.setPlaybackSpeed(speed)`；
   - 通道 B：`Player.setRate(speed)`（media_kit 公开 API，底层是 mpv 的 `speed`）；
   - **两条通道都要实现**——真机上 DASH 内容走通道 B 的比例不低。
2. **播放页手势**：长按视频区 → 2.0x，松手恢复 1.0x，屏幕中央显示「2.0x 快进中」（复用 `_overlayIndicators()` 的样式）。
   - 与已有横向拖动共存：`onLongPressStart/End` 与 `onHorizontalDrag*` 可以同时注册；但**长按后又拖动**会状态错乱，建议 `_onDragStart` 里先判 `_longPressing` 直接 return。
3. **弹幕时钟要跟着倍速**：`PlaybackClock` 依赖 `position` 事件推进，倍速下外推窗口（`AppConfig.positionJumpThresholdMs` = 400ms）内的插值会偏慢，长按期间会出现「画面 2x、弹幕 1x」。**长按期间把时钟倍速同步**。
4. **音频变调**：mpv 默认 `audio-pitch-correction=yes`（变速不变调），ExoPlayer 也不变调，两条通道一致；不用写代码，但要听一遍确认。

**验收**：两条通道各测一次——长按画面明显加速、松手回原速、弹幕与画面仍对齐、音频不断（`dumpsys audio` 仍 `state:started`）。

### N2 **Bilibili 博主头像不显示**

**根因【已证实】**：B 站的解析层**从来没写过 `authorAvatar`**。

- `lib/data/bili/bili_content_parser.dart` 全文搜不到 `authorAvatar`（`fromUserVideo` / `_fromDynamic` / `_parseOrigin` 都没填）；
- 唯一填头像的是 `lib/data/bili/bili_models.dart:103` 的 `ownerAvatar: owner['face']`，但那是 **`videoInfo()` 的返回值**（播放页用），**时间线卡片不吃它**；
- 卡片侧读取是**正常**的（`content_card.dart` 用 `item.authorAvatar`，为空时画「姓名首字」占位圆），所以症状就是「B 站博主一律没头像，微博的有」。

**要做的事**：

1. **先探针确认字段路径**（`.env/` 下已有 `probe_feed_all.py` 等骨架可改）：
   - 动态流 `/x/promo/feed/all`：作者信息在 `modules.module_author.face`【待确认，以探针结果为准】；
   - UP 投稿 `/x/space/wbi/arc/search`：`data.list.vlist[].author / upic`【同上】；
2. 在 `fromUserVideo()` 与 `_fromDynamic()` 里读到 face 后填 `authorAvatar`；**转发原动态**（`_parseOrigin`）也要填，否则转发的原动态照样没头像；
3. **协议头**：B 站 `face` 常是 `http://`。按 `bili_content_parser.dart` 里对封面图现有的归一化方式处理（照抄，别自己写一套）；
4. **缓存**：时间线缓存的是**原始 JSON**，解析规则升级后旧缓存会自动重新解析出头像；但**必须冷启动验证**（进程内的旧 `ContentItem` 不会自动更新）。

**验收**：时间线里 B 站视频卡与动态卡都出现头像，微博卡不受影响；改前/改后截图对比。

> 这条只改**解析层**，**不要动 `content_item.dart`** 的字段定义（`authorAvatar` 早就有）。

---

## 1. 必读（按顺序，别跳）与「别碰」

### 1.1 必读

| 文件                                               | 看什么                  | 为什么                              |
| ------------------------------------------------ | -------------------- | -------------------------------- |
| `docs/HANDOVER.md` **§7.12～§7.14**               | 最近三轮播放器修复：黑屏、无声音、打不开 | 这三节把「播放链路为什么会坏」讲透了，你改播放页前必须知道    |
| `docs/HANDOVER.md` **§7.7～§7.11**                | 四轮缺陷修复 + 新机兼容        | 里面每一条都是真机撞出来的结论，避免你把「已修复的坑」重新踩一遍 |
| `lib/features/player/player_page.dart`（约 1200 行） | 加载编排的**唯一入口**        | 播放页所有失败都走 `_failLoad`，别另开一套      |
| `lib/features/player/player_adapter.dart`        | 双通道抽象                | 加新能力（倍速、清晰度）改这里，不要在页面里 if-else   |
| `lib/data/bili/bili_models.dart` → `BiliCdn`     | CDN 候选排序             | 详见第 5 节硬性契约                      |
| `README.md` 顶部「验证项」表                             | 当前验收基线               | 你交付时要往这张表加行                      |

### 1.2 别碰（其它会话/历史决策的领地）

| 对象                                                                   | 原因                                          |
| -------------------------------------------------------------------- | ------------------------------------------- |
| `docs/WEIBO_HANDOFF.md`                                              | 由**另一个会话**维护（微博 432 结案结论）。要改先在对话里问。         |
| `lib/data/weibo/*`、`lib/features/weibo/*`                            | 微博已按用户决策**降级为内置 WebView**，不是待办缺陷。           |
| `android/app/src/main/AndroidManifest.xml` 里的 `EnableImpeller=false` | **必须保持关闭**。Impeller 开启时 libmpv 只出黑屏，这是实测结论。 |
| `MpvPlayerAdapter` 的 `hwdec: 'no'`                                   | 软解是刻意选择（换「一定能出画面」），不要「优化」成硬解后直接提交。          |

---

## 2. 当前 B 站模块能力清单（做什么 / 在哪）

### 2.1 数据层

| 能力                      | 入口                                                 | 状态                           |
| ----------------------- | -------------------------------------------------- | ---------------------------- |
| 视频信息（标题/UP/时长/统计/分P/简介） | `BiliClient.videoInfo`                             | ✅ 字段**全部解析了**，但界面只用了其中 4 个   |
| 播放地址（MP4 单流 / DASH）     | `BiliClient.playUrl(preferDash:)`                  | ✅ 含 PCDN 规避（见 5.1）           |
| 弹幕（双通道兜底）               | `BiliClient.danmaku`                               | ✅ 裸 deflate XML + 自动识别       |
| 主评论 / 子评论               | `BiliClient.comments` / `replies`                  | ✅ 游标分页、热度/时间排序               |
| 关注的人、关注流                | `BiliClient.followings` / `followingFeed`          | ✅ offset 游标分页                |
| UP 投稿 / UP 动态           | `BiliClient.userVideoItems` / `userDynamicItems`   | ✅ **已实现但界面没有入口**             |
| WBI 签名、buvid3 指纹        | `lib/data/bili/wbi.dart`、`BiliClient._ensureBuvid` | ✅ 所有 `wbi/` 接口自动带签名          |
| 缓存                      | `lib/data/repo/video_repo.dart`                    | 5 分钟 TTL；DASH 兜底结果**刻意不进缓存** |

### 2.2 界面层

| 页面             | 文件                                                          | 现状                                        |
| -------------- | ----------------------------------------------------------- | ----------------------------------------- |
| 时间线            | `lib/features/timeline/timeline_page.dart`（443 行）           | 全部关注 / 精选订阅双模式、下拉刷新、滚到底续拉、已读计数、降级横幅       |
| 卡片             | `lib/features/timeline/content_card.dart`（164 行）            | 来源徽标 + 标题 + 作者/时间 + 封面（带播放/多图/含原动态角标）     |
| 内容详情（B 站动态、微博） | `content_detail_page.dart`（611 行）                           | 图片九宫格、正文、原动态区块、评论                         |
| 播放页            | `player_page.dart`（1206 行）                                  | 16:9 视频 + 标题/元信息/分P chips + 评论            |
| 控制栏            | `player_controls_overlay.dart`                              | 返回、播放/暂停、时间、进度条、弹幕开关、弹幕设置、全屏              |
| 弹幕             | `danmaku/danmaku_engine.dart` + `danmaku_overlay.dart`      | 字号四档、透明度、同屏上限、滚动时长、屏蔽词、压力测试页              |
| 评论             | `comments/comment_section.dart` + `comment_controller.dart` | 主/子评论、排序、加载更多                             |
| 设置             | `settings_page.dart`（约 700 行）                               | 含「播放链路自检」「**按 BV 号打开**」「**强制通道 B**」三个诊断入口 |

---

## 3. 缺口清单（按「用户感知强度」排序）

> 下面每条都写了**改哪个文件**。凡是我加了【待验证】的，先做探针（见第 6 节）。

### P0 —— 数据已经在手里，只差显示（改动小、收益最大）

> ✅ **2026-10-21：本节 3.1 / 3.2 / 3.3 与下方 P1 的 3.4 / 3.5 / 3.6 已全部落地**，
> 真机证据见 `docs/HANDOVER.md` §7.23。下面的文字保留为「当初为什么这么改」的依据。

**3.1 播放页统计数字全是空的**　【已证实】

`BiliVideoInfo` 已经解析了 `likeCount / coinCount / favoriteCount / shareCount / replyCount / view / danmakuCount`，但 `player_page.dart` 的 `_lowerSection()`（约 733 行）只拼了 `view` 和 `danmakuCount`。

建议：元信息行改成一排图标+数字（点赞/投币/收藏/分享/评论），点评论数滚到评论区。**这一条几乎零风险，建议第一个做。**

**3.2 视频简介没地方看**　【已证实】

`BiliVideoInfo.description` 解析了但从未渲染。建议：标题下方可折叠简介（2 行 → 展开），空简介时不占位。

**3.3 清晰度不能选，qn 写死 64（720P）**　【已证实】

`PlayUrlResult.qualities`（`QualityOption(qn,label)`）**解析了但没有任何 UI**；`AppConfig.preferredQuality = 64` 写死（`lib/core/config/app_config.dart:113`）。

建议做法（注意顺序，别把播放搞崩）：

1. 播放页加一个「清晰度」按钮，列出 `_playUrl!.qualities`；
2. 选中后 `playUrl(qn: 新值, preferDash: 现有通道)` 重新取流 → 重建播放器；
3. **重建前记住 `position`，重开后 `seek` 回去**，否则用户选个清晰度就被踢回开头；
4. 记住用户选择（`Prefs` 加一个 `int preferredQn`），下次进视频直接用。

### P1 —— 播放体验（工作量中等）

**3.4 没有倍速**　【已证实】

`RrhaPlayer` 抽象里没有 `setSpeed`；两条通道的原生 API 都有（ExoPlayer `setPlaybackSpeed`、mpv `speed` 属性）。建议加 `setSpeed(double)` + 控制栏 0.5/0.75/1.0/1.25/1.5/2.0 菜单。

**3.5 退出再进从头开始（无进度记忆）**　【已证实】

`Prefs` 里没有任何播放进度键。建议：`onPause`/`dispose` 时写 `bvid+cid → positionMs`，进入时若存在则弹「上次看到 12:34，继续播放？」而不是静默跳转（静默跳转会让人以为视频坏了）。

> ✅ **2026-10-21 已实现，但交互与这里的建议不同**：先按本文档做了弹窗，
> 用户看真机截图后要求**「不要弹窗，默认继续播放」**，因此最终形态是
> **静默 seek 到上次位置 + 画面右上角 2.5 秒「已从 04:08 继续」角标**。
> 角标用非阻塞方式解决了「静默跳转让人以为坏了」这个原始顾虑。
> 详见 `docs/HANDOVER.md` §7.23 第六节。

**3.6 全屏时没有清晰度/倍速/分P 入口**　【已证实】

`build()` 里 `_fullscreen` 分支只渲染 `_playerStack`，控制栏是全屏版同一套。加菜单时注意：**全屏态下弹菜单不能触发控制栏自动隐藏**（`player_controls_controller.dart` 里有 `setPaused` 干预逻辑，读过再改）。

### P2 —— 发现与导航

**3.7 没有继续观看/历史**　【已证实】

和 3.5 同源：有了进度记忆，一个「继续观看」列表是自然延伸。

---

## 4. 界面优化建议（具体到文件）

### 4.1 先修「硬编码」，再谈美观

| 位置                     | 问题                                                                  | 建议                                                                                                            |
| ---------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `content_card.dart:27` | `color: const Color(0xFF1E1E1E)` **硬编码**                            | 换 `theme.colorScheme.surfaceContainerLow`。当前是 `ThemeMode.dark`（`main.dart:92`），硬编码值「恰好」接近所以看不出来——一旦将来支持亮色就会露馅 |
| 全局                     | 字号散落 `fontSize: 10 / 11 / 12 / 13 / 14` 硬编码，`_lowerSection` 一行里 5 种 | 抽一个 `AppText`（或直接用 `theme.textTheme.*`），**统一后再调视觉**，否则改一处崩一处                                                  |
| `player_page.dart:761` | 通道标签 `· 通道A(MP4 qn=64)` 混在元信息里                                      | 这是**开发者诊断信息**，和「UP 主 · 时长 · 播放数」挤一行会让人以为它是给用户看的。建议收进右上角菜单「播放信息」，或长按标题才显示                                      |

### 4.2 三个「一眼可见」的观感问题

1. **卡片没有时长角标**：`ContentItem` 没有 duration 字段，而 B 站动态 API 的 `duration_text`（如 `12:34`）是现成的。视频卡片右下角加时长，是最廉价的信息增益。【待验证：确认 `bili_content_parser.dart` 是否已丢弃该字段】
2. **没有骨架屏**：首屏刷新时是空白/转圈。用卡片形状的灰色占位，感知速度提升明显。
3. **滚到底没有「回到顶部」**：时间线上限 200 条（`AppConfig.timelineMaxItems`），滚到深处想回顶部只能狂滑。

### 4.3 播放页信息架构（建议重排）

现在：`16:9 视频` → `标题` → `一行元信息` → `分P chips` → `评论`。

建议：`16:9 视频` → `标题（可折叠简介）` → `UP 头像 + 名字 + 关注按钮` → `统计行（赞/币/藏/分享/评论）` → `分P chips` → `评论`。

理由：B 站本体就是这个顺序，用户肌肉记忆一致。**注意 `_lowerSection()` 现在把评论区放在 `Expanded` 里，头部是固定高度——加内容后小屏（如 6.1 寸）会挤，改之前先在那台荣耀上截图看一遍。**

### 4.4 空态/错误态

- 时间线的空态做得比较细（`timeline_page.dart` 里区分「只有占位卡」和「真的没内容」，还有降级横幅），**改动时别把这些分支弄平**。
- 评论区、搜索（如果做）需要同样区分三态：**加载中 / 真的没有 / 加载失败**。混用一句文案的代价是用户分不清该等还是该重试。
- 错误统一走 `widgets/error_view.dart`（已有 `compact` 模式，专为 16:9 视频区设计，别自己再写一个）。

---

## 5. 硬性契约（破了必出难查的诡异 bug）

### 5.1 CDN 节点顺序不能动

`BiliCdn.candidatesOf()` 把候选按「标准 CDN(0) → 其它(1) → PCDN(2)」排序，**这不是审美偏好，是实测结论**：

- `*.edge.mountaintoys.cn:4483`：手机 curl **HTTP=000 / 12 秒超时**；
- `*.mcdn.bilivideo.cn:8082`：时通时不通；
- `upos-sz-mirror*.bilivideo.com:443`：200，稳定。

**B 站的 `baseUrl` 一律是前两类**，可达的那条只在 `backupUrl` 里。任何「简化成只取 baseUrl」的改动都会立刻让一批视频打不开或没声音。

### 5.2 `Media.extras` 在本项目用的 media_kit 版本里是**死代码**

`Media.extras: {'audio-file': url}` **完全无效**（media_kit 1.2.6 的 `open()` 只做 `loadlist`，源码里从未消费 extras）。DASH 音频必须用 mpv 的 **`audio-add <url> select`** 命令挂成外部音轨，见 `MpvPlayerAdapter._attachAudio()`。这条已在代码注释里写死，**别「顺手改回去」**。

### 5.3 播放器的流必须「订阅即补发」

`RrhaPlayer.playingStream / durationStream / errorStream` 的三个 StreamController 用的是 `broadcast(onListen: _replay...)`。原因：播放页是「先订阅、后 play()」，libmpv 在 `open()` 后就自动播放，错过那次事件会导致**按钮显示 ▶、弹幕一条不动**。加新流时照抄这个模式。

### 5.4 任何播放失败必须走 `_failLoad` → `PlayerLoadFailure.map`

不要在新代码里直接 `setState(_error = ...)`。`_failLoad` 负责：归类成可读文案、记一条带 `stage/bvid/cid/channel/elapsed` 的日志、区分可重试。绕过它 = 又回到「黑屏无从下手」。

### 5.5 profile 构建里 `Log.d` 不进 logcat

`lib/core/utils/logger.dart` 只在 `kDebugMode` 打 `debugPrint`。真机排查**只能看 App 内「设置 → 运行日志」**（内存环形缓冲 200 条）。所以：**你打的每一行日志都要假设「会在 200 条后被挤掉」**，关键信息要短、要能定位。

---

## 6. 工作方法（本项目已验证有效的纪律）

### 6.1 先探针，后代码

接口类改动一律先写一次性 Python 探针放 `.env/`（该目录被 `.gitignore` 排除）。已有可复用脚本：

| 脚本                                  | 用途                                 |
| ----------------------------------- | ---------------------------------- |
| `.env/probe_playurl.py <bvid>`      | playurl 返回形态 + URL 可达性             |
| `.env/probe_cdn_hosts.py <bvid>...` | 每个流的 baseUrl/backupUrl 域名与 HEAD 状态 |
| `.env/dump_urls.py <bvid>`          | 导出候选 URL 供真机 curl 对比               |
| `.env/ndtap.py "<文本>" [--tap]`      | uiautomator 按文本定位/点击               |

**桌面网络与手机网络结论可能相反**（PCDN 就是典型：桌面全超时、手机部分可达）。要判断「手机上能不能通」，就用 `adb shell curl`，别用电脑的 curl 代替。

### 6.2 「修好了」的标准（不许自证）

本项目历史上被「我改了所以应该好了」坑过多次。验收必须：

| 声称   | 必须有证据                                                                                                                           |
| ---- | ------------------------------------------------------------------------------------------------------------------------------- |
| 画面正常 | 两次 `screencap` 的**帧差 + 平均亮度**（纯黑 = 亮度 0）                                                                                        |
| 有声音  | `adb shell dumpsys audio \| grep state:started` 且 `u/pid:<AppUid>` 命中；能区分后端（`AudioTrack` = 通道 A，`OpenSL ES AudioPlayer` = 通道 B） |
| 交互生效 | `Δt < 3s` 前后截图对比（区分「真的隐藏了」和「自动隐藏了」）                                                                                             |
| 接口可用 | 探针原始 JSON + HTTP 状态码                                                                                                            |


### 6.3 一次只改一处

改完立刻：`dart analyze` → `flutter test` → `assembleProfile` → `adb install -r` → 真机复现。

**不要攒一批改动再一起验证**——播放链路耦合度高，攒一起出错时无法二分定位。

### 6.4 文档同步

每轮交付时更新：

- `docs/HANDOVER.md` 追加 `### 7.x`（现象 → 排查 → 根因 → 修法 → **真机验证表**）；
- `README.md` 顶部「验证项」表加一行；
- 测试数量变化时同步表里的数字。

---

## 7. 环境与门槛速查

### 7.1 构建环境（每条命令前都要）

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. D:\Rrha\tools\flutter-env.ps1
```

它会设置 `FLUTTER_ROOT / JAVA_HOME / GRADLE_USER_HOME / PUB_CACHE / HTTPS_PROXY`，并做环境自检。  
**`GRADLE_USER_HOME` 必须落在纯 ASCII 路径**（本机用户名含中文，否则 Gradle 会崩成一堆「Unresolved reference」）——这个坑已经用 `tools/flutter-env.ps1` 兜住了，别绕过它直接跑 `gradlew`。

### 7.2 三条门槛命令

```powershell
dart analyze lib test              # 必须 No issues found
flutter test                       # 必须 All tests passed!（当前 434）
cd android; .\gradlew.bat assembleProfile --offline
adb install -r build\app\outputs\apk\profile\app-profile.apk
```

`flutter analyze` 在受限沙箱里会走 LSP 崩溃，**用等价的 `dart analyze`**。

### 7.3 真机

| 项       | 值                                                                              |
| ------- | ------------------------------------------------------------------------------ |
| 设备      | HONOR Magic8 Pro（`BKQ-AN10`），Android 16 / MagicOS 10.0.0.108，1256×2808 @560dpi |
| serial  | `<你的设备序列号>`                                                             |
| adb     | `C:\Android\sdk\platform-tools\adb.exe`                                        |
| 首次连不上设备 | 先管理员跑 `C:\Android\fix-adb-guid.cmd`（补 DeviceInterfaceGUIDs），再 `adb devices`    |

常用命令：

```bash
ADB="C:/Android/sdk/platform-tools/adb.exe"
"$ADB" shell am force-stop com.rrha.rrha
"$ADB" shell monkey -p com.rrha.rrha -c android.intent.category.LAUNCHER 1
"$ADB" exec-out screencap -p > tools/shots/xxx.png
"$ADB" shell dumpsys audio | grep state:started
```

```

> `MSYS_NO_PATHCONV=1` 在 git-bash 里推送 `/data/local/tmp/...` 这类路径时是**必须的**，否则路径会被改写成 Windows 形式。
> 沙箱可能在两次调用之间杀掉 adb daemon（对一次性命令无害）。

### 7.4 快速打开任意视频

App 内：**设置 → 按 BV 号打开**（支持直接粘贴整条分享链接，会自动提取 BV 号）。
诊断通道 B 时：设置 → **强制通道 B（libmpv）** 开关 —— 因为通道 B 平时只在通道 A 失败时才走到，不开这个开关**根本复现不了通道 B 的问题**。用完记得关掉。

---

## 8. 已知坑（B 站侧，都是实机撞出来的）

| 坑 | 症状 | 结论 |
| --- | --- | --- |
| PCDN 节点 | 打不开 / 有画面没声音 | 见 5.1，候选排序 + 换节点 |
| `Media.extras` | 有画面、无声音、**mpv 零报错** | 见 5.2，改用 `audio-add` |
| DASH 需 Referer | 403 | 全局 `http-header-fields` 已设，别删 |
| playurl 的 `fnval=1` 与 `4048` 是两个独立的调度 | MP4 坏了但 DASH 是好的 | 通道 A 失败时**重新取 DASH**，别复用同一个 URL |
| 弹幕接口返回裸 deflate XML | 解析失败 | `parseAuto` 已处理，历史文档说 protobuf 是过时的 |
| `comment.bilibili.com/{cid}.xml` 与 `dm/list.so` 同源 | — | 双通道任取其一即可 |
| 评论 `-403` | — | 与出口 IP 风控**无关**，是 `pagination_str` 字节形态问题，App 侧已正确处理 |
| 微博接口 | 恒 432 | **不是缺陷**，已降级为内置浏览器 |
| adb 连点 BACK | 直接退到桌面 | 手势验证时注意别连按 |

---

## 9. 红线

1. **凭据只进系统钥匙串**（`lib/core/storage/bili_credential_store.dart`），不得写入 SharedPreferences / 日志 / 源码；`BiliSession` 刻意不实现 `toString()`，只暴露末 4 位。
2. **不加依赖前先问用户**。本项目历史上优先零依赖方案（图片缓存、封面缓存都是手写的）；确有必要（如保存相册的 `gal`）也必须先说清代价。
3. **不许宣称「已验证」而没有证据**（见 6.2）。宁可写「未取证」。
4. **不要为了让指标好看而伪造数据**：微博视频直链解析失败时，代码里就是明写「视频解析失败」的诚实占位，请保持这个风格。
5. 改 `android/` 下任何东西前，先确认不会把 `EnableImpeller=false` 弄掉。

---

## 10. 建议的推进顺序

> ⚠️ **2026-10-21 更新：第 1~4 步（3.1～3.6 + N1 + 进度记忆）已全部完成并经真机验证**，
> 详见 `docs/HANDOVER.md` §7.23。本节清单保留作历史记录；**未完成的只剩 3.7「继续观看」**
> （它依赖的进度数据本轮已经落到 `Prefs.playbackPositions`，可以直接接着做）。
>
> 同时记两个本轮撞出来的接口事实（别再当 bug 查）：
> 1. `arc/search` 的 `vlist[]` **没有 `upic`/`face` 字段**，投稿卡片缺头像不是解析漏了，是接口没给；
> 2. 清晰度清单**只有 DASH 形态是全的**（`fnval=1` 只给 2 档、`fnval=4048` 给 5 档）。

> 2026-10-18 用户已删减缺口清单，**以下顺序对应当前保留的 3.1～3.7**。

1. **P0 三件（都不碰播放链路，风险≈0）**：统计行（3.1）→ 简介（3.2）→ 卡片时长角标（见 `docs/UI_HANDOFF.md` §3，该项归界面会话）。
2. **清晰度（3.3）**：要动 `RrhaPlayer` 抽象 + 重建播放器，**做完立刻用 6.2 的方法在两条通道上各验一遍**（换清晰度后最容易出「黑屏但进度在走」）。
3. **倍速（3.4）** + **全屏菜单（3.6）**：同一批 UI 改动一起做。
4. **进度记忆（3.5）** → 自然延伸出「继续观看」（3.7）。
5. 原 P2/P3（搜索、相关推荐、点赞/投币/收藏、发弹幕）**已在清单中移除**，不要再加回来，除非用户重新提出。

---

*本文档由负责播放链路修复的会话整理。文中所有「已证实」项都可以在 `docs/HANDOVER.md` §7.7～§7.14 找到对应实验记录；所有「待验证」项请当作假设处理。三条并行工作线的分工见 `docs/COLLAB_PLAN.md`。*
