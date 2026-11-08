# 微博模块接手建议（Rrha）

> 面向：新会话（负责「阶段 3：微博」）
> 生成：2026-10-17，基于当前工程状态与一次真实接口探测
> 工程：`D:\Rrha`（Flutter 3.47.7 / Android，包名 `com.rrha.rrha`，当前 `0.2.1+4`）
> 说明：**文中标注「已实测」的是本节附录里的真实探测结果；其余是方向性判断，必须自己验一遍再写代码。**

---

> ## ⚠️ 本文档已结案（2026-10-17，阶段 3 已交付）
>
> **核心悬念已有定论**：`m.weibo.cn/api/container/getIndex` 对游客态**恒返回 432**，且这不是
> 补几个请求头能解决的 —— 六级探针（L0 裸请求 / L1 游客票据 / L2 `st`+`XSRF` / L3 换接口族 /
> L4 HTML SSR / L5 App 接口）全部失败：
>
> - **WAF 层**：`containerid=107603*`（时间线）无论怎么补头都 **432**、响应体为空；
> - **业务层**：能穿透 WAF 的接口（`100505` 简介容器、`api.weibo.cn/2/...`）明确返回
>   `ok:-100` / `errno:-100`，**要求登录**；
> - `/u/<uid>` 被 302 到 **Sina Visitor System 的 JS 挑战页**，HTML 里没有预渲染数据；
> - 游客票据拿到的 `SUB` 落在 **`.weibo.com`**，与 `m.weibo.cn` 是**不同域**，根本不会送达。
>
> **最终方案**：按第 4 节「退路 4」——**降级为内置 WebView 打开**，已真机验证能渲染真实微博页面
> （某个公开博主的主页，能渲染出真实内容）。实现细节、探针原始数据、两个真机缺陷的修复过程，
> 全部记录在 **`docs/HANDOVER.md` §7.12**；本文档保留了当时的探测过程，作为**历史依据**。
>
> **2026-10-18 更新（推翻上面的悲观结论）**：登录态下接口**是可用的**。
> 用户在应用内 WebView 登录微博后，读取 `CookieManager.getCookie("https://m.weibo.cn")`，
> 用**普通 Dio 请求**打 `container/getIndex?containerid=107603<uid>` → **HTTP 200、11 条卡片**。
> 所以 432 的真正成因是**游客 cookie 域不匹配**（`SUB` 在 `.weibo.com`，到不了 `m.weibo.cn`），
> **不是** TLS 指纹或接口级封禁。详见 `docs/HANDOVER.md` §7.15 `十`。
> **2026-10-18 已完成**：微博已接成**原生数据源**（客户端/解析/时间线全部落地，真机验证通过），
> 见 `docs/HANDOVER.md` §7.17。评论仍走内置浏览器。
> 仍未取证：`page_info.media_info`（微博视频直链）**零样本**，解析器该分支为防御性实现；
> 微博「转发」条目缺一次真机点击取证（解析层有 4 条真实样本支撑）。

---

## 1. 先认清现状

- **B 站链路已完整可用**：登录、时间线、分页、播放、弹幕、评论、图片预览/保存、封面磁盘缓存、新机型兼容（详见 `docs/HANDOVER.md` §7.7～§7.11）。
- **微博侧基本从零开始**：`lib/data/weibo/weibo_client.dart` 只做了两件事 —— 从公共 RSSHub 读 RSS（该实例早已不可用）、一个「评论待实现」的诚实占位文案。微博数据与评论**从未真正跑通**。
- 因此微博模块 ≈「按现有架构重写数据层 + 复用现成 UI」。

## 2. 必读（按顺序，别跳）

| 文件 | 看什么 |
| --- | --- |
| `docs/HANDOVER.md` **§3**、**§7.2** | 微博的原始设计意图、「阶段 3」的定义（原计划就是 WebView 登录提取 Cookie → 试 API） |
| `docs/HANDOVER.md` **§7.7～§7.11** | 四轮缺陷修复里「猜错就踩」的实测结论、当前新机环境 |
| `lib/data/bili/bili_timeline_source.dart` | **照着它写 `WeiboTimelineSource`**：缓存策略、登录态校验位置、按页缓存原始 JSON |
| `lib/data/repo/timeline_repo.dart` + `lib/providers.dart` | 平台分派点，微博分支接这里 |
| `lib/data/models/content_item.dart` | 统一模型（已含 `Platform.weibo`、`images`、`origin`、`videoRef.directVideoUrl`） |
| `lib/features/comments/comment_section.dart` | 现状：**B 站专用**，接微博评论前必须抽象（见第 5 节） |

## 3. 测试对象

**指定一个固定的微博 UID 作为测试对象**（具体值由维护者本地指定，不进仓库）。

- 需要在 App 内**浏览微博内容时优先订阅**该博主；
- **测试动态（图文）与视频时，优先使用该博主的内容**；
- 造测试数据、截图取证、写文档示例，都以它为准，避免每轮换对象导致结论不可比。

> 本次探测对该 UID 的结论见附录：`/api/container/getIndex`（取用户时间线）返回 **432**，而 `/api/config`、`/api/statuses/show` 返回 **200**。也就是说「先解决怎么拿到这个博主的时间线」是接手后的第一道坎。

## 4. 接口选型：优先 `m.weibo.cn`，别碰 `weibo.com/ajax/*`

| 目标 | 建议路线 | 依据 |
| --- | --- | --- |
| 游客身份 | `passport.weibo.com/visitor/genvisitor`（POST，`cb`+`fp`）→ 拿 `tid` → `passport.weibo.com/visitor/visitor?a=incarnate&t=<tid>&w=2&c=095&cb=cross_domain&from=weibo` | **已实测可用**：`tid` 拿到、`SUB`/`SUBP`/`SVB`/`SRT`/`SRF` 均写入 Cookie |
| 指定博主时间线 | `m.weibo.cn/api/container/getIndex?type=uid&value=<uid>&containerid=107603<uid>` | **已实测 432（被拦）**；需继续试 `X-XSRF-TOKEN`（由 `SUB` 解码得到）、`st` 参数，或换接口 |
| 单条详情 / 长文 | `m.weibo.cn/api/statuses/show?id=<mid>`、`m.weibo.cn/statuses/extend?id=` | **已实测 200**（`show` 可用；`extend` 未测） |
| 评论 | `m.weibo.cn/comments/hotflow?id=<mid>&mid=<mid>&max_id_type=0` | 未测（游客 Cookie 应可用，带 `max_id` 游标） |
| 图片 | `pics[].large.url`，形如 `//wx1.sinaimg.cn/...` | 协议相对，必须过 `BiliUser.normalizeImageUrl()` 转 https |
| 视频 | `page_info.media_info.stream_url` 等 | 填 `VideoRef.directVideoUrl`，播放走现成的 `SimpleVideoPage` |
| `weibo.com/ajax/statuses/mymblog` | 不推荐 | **已实测 403**（需要登录态） |

**重要架构判断：先只做「按 UID 订阅某个博主」，不做「关注流」。**
关注流需要登录态 Cookie（`SUB` 登录版）+ `XSRF-TOKEN`，风控最狠；而「订阅某博主」只需游客 Cookie，且与项目现有「订阅源聚合」模型天然一致。关注流留到二期。

**如果时间线接口怎么都打不通**，退路按优先级：
1. 给请求补 `X-XSRF-TOKEN`（微博惯例：`base64(SUB)` 后取特定片段）+ `/api/config` 返回的 `st`；
2. 换 `m.weibo.cn/api/statuses/user_timeline` 等老接口；
3. 换移动端 v2：`api.weibo.cn/2/statuses/user_timeline`（需 `from`/`c`/`s` 等 App 参数）；
4. 最后才走原计划的 **WebView 登录** 提取登录态 Cookie（注意微博登录常见验证码/滑块风控）。

## 5. 必须做的架构改造（绕不开）

1. **`CommentSection` 目前是 B 站专用**（入参 `oid`/`type`/`upMid`，翻页依赖紧凑 JSON 的 `pagination_str`）。
   接微博评论前应抽出 `CommentSource` 接口（`loadPage(cursor)` / `loadReplies(rootId, cursor)`），
   B 站与微博各实现一份，UI 只认接口。
   **禁止**在组件里加 `if (platform == weibo)` 分支。
2. `timeline_repo.dart` 的平台分派、`Prefs` 的订阅持久化、`timeline_page._openItem()` 的跳转分派，都要补微博分支。
3. 微博的 `Subscription` 用 `uid` 字符串即可（模型已支持），`FeedRoute` 需评估是否加微博路由。

## 6. 可直接复用的资产（别重造）

| 已有 | 复用方式 |
| --- | --- |
| `lib/widgets/photo_grid.dart` | 微博多图直接填 `ContentItem.images` 即可，九宫格现成 |
| `lib/features/gallery/image_gallery_page.dart` | 全屏预览、页码、保存到相册现成 |
| `lib/widgets/cached_image.dart` | 统一图片入口（磁盘缓存 + Referer/UA） |
| `ContentItem.origin` | 微博转发（`retweeted_status`）映射成它，详情页「原动态区块」现成 |
| `lib/core/utils/id_hash.dart` | **id 契约**：用 `https://m.weibo.cn/status/<mid>` 这类稳定形态做 hash 输入 |
| `lib/core/cache/cache_store.dart` | 缓存**原始 JSON**（不是解析后模型），解析规则升级后旧缓存仍可用 |
| `lib/features/player/simple_video_page.dart` | 微博视频播放（B 站的 `PlayerPage` 只认 bvid，别硬套） |

## 7. 硬性契约（破了就会出现难查的诡异 bug）

- **`id` 跨刷新稳定**：否则整条时间线会被标成「新」。用状态 URL 做 hash 输入。
- **凭证只进系统钥匙串**：走 `lib/core/storage/secure_store.dart`，不得写 SharedPreferences / 日志 / 源码（`HANDOVER §8`）。
- **时间解析**：微博 `created_at` 形如 `Thu Oct 16 20:00:00 +0800 2026`（英文月份），
  `lib/core/utils/time_parse.dart` 需补这个分支；解析不出来就 `hasReliableTime = false`
  如实降级，**不要伪造时间**。
- **图片 URL 归一化**：`//wx1.sinaimg.cn/...` 必须转 https。
- **视频防盗链**：微博 CDN 需要 `Referer: https://weibo.com/`，且直链带时效签名 ——
  `SimpleVideoPage` 已支持传 referer，播放成功率如实标注、不要承诺。
- **不要把登录/游客态塞进 provider**：会让 provider 重建、时间线被清空。登录检查放进
  `Source.fetch()`（这是 B 站侧踩过的坑）。

## 8. 推进顺序（探针优先，别一上来写 Flutter 代码）

1. **先写 Python 探针**（放 `D:\Rrha\.env\`，属 gitignore 区）。第一件事就是让
   `/api/container/getIndex` 对目标 UID 返回 200 —— 这是全模块的地基。
2. 拿到真实响应后，**打印结构与字段名/类型**（`cards[].mblog` 的 `text`/`pics`/`retweeted_status`/`page_info`/`created_at`），
   不要只看一眼 200 就动手。
3. 把结论固化成一张「字段实测表」写进 `HANDOVER`（§7.7/§7.8 有范例）。
4. 然后才写 Dart，顺序：`WeiboClient`（只做 IO）→ `WeiboParser`（只做映射）→
   `WeiboTimelineSource`（缓存 + 组装）→ `CommentSource` 实现 → UI 接线。
5. 每步都跑门槛（见第 9 节）。

## 9. 环境与门槛速查

```powershell
# 每条命令前
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. D:\Rrha\tools\flutter-env.ps1
```

| 项 | 值 |
| --- | --- |
| 构建 | `cd D:\Rrha\android; .\gradlew.bat assembleProfile --offline`（**务必带 `--offline`**，否则可能长时间卡在依赖解析） |
| 静态检查 | `dart analyze` → 必须 `No issues found!` |
| 单测 | `flutter test` → **基线 384 个，只增不删**（既有断言若必须改，要在报告里说明原因） |
| adb | `C:\Android\sdk\platform-tools\adb.exe`，设备序列号 **`<你的设备序列号>`**（荣耀 Magic8 Pro / Android 16） |
| 探针 Python | `<Python 解释器路径>`（PATH 里的 `python` 是商店存根，不能用） |
| ⚠️ 不要改回去 | `AndroidManifest.xml` 里的 `EnableImpeller=false` 是为修 libmpv 黑屏加的 |
| 代理 | `127.0.0.1:7897` 只用于构建/依赖；**探针访问微博建议直连** |
| 目录纪律 | 不碰 `D:\Rrha` 之外的文件（尤其 `C:\flutter`）；本工程无 git 仓库，不做 git 操作 |

## 10. 本项目已踩过、你在微博这边极易再踩的坑

| 坑 | 教训 |
| --- | --- |
| 猜接口字段 | `pagination_str` 必须紧凑 JSON、动态评论 `oid` 不是动态 id、图片在 `opus.pics[].url` 而非 `src` —— 每一个「想当然」都花了真机调试才纠正 |
| 解析只取一张封面 | 模型已有 `images`/`origin`，别再只取第一张、别丢掉转发原内容 |
| 启动时序 | 登录态恢复在首帧之后完成，首刷会以「未登录」跑空一次 → 参照 `main.dart` 的 `_LoginBootstrap` |
| 把登录态塞进 provider | 会重建 provider、清空时间线 |
| 用 dump/日志验证交互行为 | 自动化观测会被「自动隐藏」之类的兜底掩盖；要能区分因果再下结论 |
| 版本号 | 只改 `pubspec.yaml` **不生效**！`android/local.properties` 的 `flutter.versionName/Code` 才决定 APK 版本 |
| 无障碍节点 bounds | 滚出视野的卡片 bounds 会被裁剪得很小，别误判成「卡片塌陷」 |

## 11. 两条红线

1. **不要退回去用公共 RSSHub 取微博**（实例不可用，而且这正是本项目要摆脱的依赖）。
2. **未验证的能力不要写进 UI 文案**：宁可写「接口没有提供」，也不伪造「能看评论 / 能播放」。
   微博评论区在真正跑通之前，保持现有那句诚实的占位文案。

---

## 附录：本次接口实测原始记录（2026-10-17）

测试对象为某个已登录的微博 UID；客户端分别是 Python `urllib`（OpenSSL）与 `curl 8.22`（Schannel），**两者结果一致**，因此可排除「TLS 指纹差异」这一解释。

| # | 请求 | 结果 |
| --- | --- | --- |
| 1 | `GET https://m.weibo.cn/`（首页） | **200**（拿到 `WEIBOCN_FROM` cookie） |
| 2 | `POST https://passport.weibo.com/visitor/genvisitor`（`cb=gen_callback&fp={"os":"1",...}`） | **200** → `{"retcode":20000000,"msg":"succ","data":{"tid":"01ASvUpv...","new_tid":true}}` ✅ 游客票据可获取 |
| 3 | `GET https://passport.weibo.com/visitor/visitor?a=incarnate&t=<tid>&w=2&c=095&cb=cross_domain&from=weibo` | **200** → Set-Cookie 写入 `SUB` / `SUBP` / `SVB` / `SRT` / `SRF` ✅ 游客身份建立成功 |
| 4 | `GET https://m.weibo.cn/api/container/getIndex?type=uid&value=<uid>&containerid=107603<uid>`（带游客 Cookie + `Referer`/`X-Requested-With`/`MWeibo-Pwa`） | **432**，响应体为空 ❌（被拦，**这是当前主要阻塞点**） |
| 5 | 同上，但 `containerid=102803`（热门流，不涉 UID） | **432** ❌ → 说明是**该接口级别**的风控，不是「这个博主」的问题 |
| 6 | `GET https://m.weibo.cn/api/config` | **200** → `{"data":{"login":false,"st":"3b161a",...}}` ✅ 注意到了 `st` 令牌与 `login:false` |
| 7 | `GET https://m.weibo.cn/api/statuses/show?id=5000000000000000`（假 id） | **200**（接口可用，只是数据不存在）✅ |
| 8 | `GET https://weibo.com/ajax/statuses/mymblog?uid=<uid>&page=1&feature=0` | **403** ❌（需要登录态） |

**由此得到的判断**：

- ✅ 游客 Cookie 链路（第 2、3 步）**可以复用**，新会话不必重新摸索；
- ✅ API 层整体可达（第 6、7 步 200），**不是 IP 全封**；
- ❌ 唯一被拦的是 `container/getIndex`（取「某博主的微博列表」）—— 而它恰好是本模块最核心的接口；
- 👉 下一步优先级：给第 4 步的请求补 `X-XSRF-TOKEN`（由 `SUB` 解码）与第 6 步拿到的 `st`，再不行就按第 4 节的退路 2→3→4 依次试。

**探针脚本建议位置**：`D:\Rrha\.env\probe_weibo_*.py`（gitignore 区，不进交付物）。

---

## 12. 2026-10-18 用户新增要求：「全部关注」模式要包含微博

> 本轮用户明确了时间线两种模式的语义。**这一节是新增功能，不是缺陷修复**。
> 分工与冲突控制见 `docs/COLLAB_PLAN.md`：微博侧取数归你，`timeline_repo` / `providers` 的合并归总设计会话。

### 12.1 要求原文（整理后）

| 模式 | 用户期望的内容 |
| --- | --- |
| **全部关注** | **B 站 + 微博**里「我所有关注的人」发的内容（一个信息流） |
| **精选订阅** | 我在「订阅源」里**自己手动添加**的博主发的内容 |

### 12.2 现状与差距【已证实】

- **B 站侧已实现**：`TimelineMode.allFollowing` 走 `/x/promo/feed/all`（一次请求 20 条 + offset 游标），见 `lib/data/bili/bili_timeline_source.dart`。
- **微博侧没有「全部关注」**：`providers.dart` 里 `_refreshFollowing()` **只调 B 站**；
  `timeline_page.dart:60-64` 甚至有一行注释明说「全部关注不含微博」，并给用户一句小字提示。
- 微博侧**目前只有「按 uid 取某个博主的时间线」**（`WeiboTimelineSource.fetch` →
  `containerid=107603<uid>`），**没有「我的关注列表」也没有「关注动态流」**。

所以差距是两个接口，不是一个 UI 改动。

### 12.3 必须先做的探针（别先写代码）

这两条是**新接口**，接入前一律先探针取证（脚本放 `.env/`）：

| # | 目标 | 候选 | 要回答的问题 |
| --- | --- | --- | --- |
| P1 | **我的关注列表** | `m.weibo.cn/api/container/getIndex?containerid=231093_-_selffollowed` | 带登录 cookie 时是否 200？返回结构里 uid/昵称/头像在哪？能否分页？ |
| P2 | **关注动态流**（一次拿回所有关注人的最新动态） | ① `containerid=102803` 系列是否其实能按关注筛选<br>② `weibo.com/ajax/statuses/followfeed`（需登录）<br>③ `m.weibo.cn` 首页「关注」tab 对应的 containerid | **能不能一次请求拿回「我关注的人」的混合时间流**？这是可行性关键 |

> ⚠️ **绝对不要**用「关注列表 × 逐个拉时间线」来实现——关注 100 人就是 100 个请求，必然触发风控，且首屏要等十几秒。

### 12.4 如果 P2 找不到可用接口（很可能）

**备选方案（推荐直接按这个做，成本最低）**：

> 「全部关注」的微博部分 = **把订阅源里所有微博博主的内容合并进来**，与 B 站 `feed/all` 按发布时间归并排序。

理由与代价：
- 用户实际使用时，**关注的博主基本都会加进订阅源**，两者高度重合，观感上接近诉求；
- 复用现成的逐源聚合（`_refreshSubscriptions`）即可，不需要新接口；
- **必须如实告知**：这不是「微博官方关注流」，而是「你订阅的微博博主的最新内容」。UI 上不要写成「微博关注动态」，避免误导（本项目红线：见 §11 第 2 条「未验证的能力不要写进 UI 文案」）。

若 P1 能拿到关注列表，也可以反向做：**把关注列表与订阅源做差集**，提示用户「还有 12 个关注的人没加进订阅源」，一键批量添加——比直接抓关注流更稳，也更符合「精选订阅=我手动加的博主」的语义。

### 12.5 合并点在哪（跨模块，需协调）

| 文件 | 谁改 | 改什么 |
| --- | --- | --- |
| `lib/data/repo/timeline_repo.dart` → `loadFollowing()` | **总设计会话** | B 站 feed 与微博结果合并 + 按时间倒序 + 去重 |
| `lib/providers.dart` → `_refreshFollowing()` | **总设计会话** | 同上，状态写回 |
| `lib/data/weibo/weibo_timeline_source.dart` | **本会话（微博）** | 新增「关注列表」或「关注流」取数能力 |
| `lib/features/timeline/timeline_page.dart:63` 的 `_WeiboModeHint` | **界面会话** | 合并实现后这行提示要改文案或删除 |

**不要在 `providers.dart` / `timeline_repo.dart` 里各写一套合并逻辑**——那是本项目踩过的「同一份数据两个地方算」的坑。合并函数放一处（建议 `TimelineMerger.merge(...)` 纯函数，便于单测）。

### 12.6 验收标准

- 全部关注模式首屏同时出现 **B 站视频** 与 **微博动态** 卡片，且**严格按发布时间倒序**；
- 两种模式互切时内容**各自独立**（不串台）；
- 微博取数失败时**只降级微博部分**（B 站照常显示 + 一行可读提示），不能整页变红；
- 有单测覆盖「双源合并 + 去重 + 排序」（纯函数，无需网络）。

---

## 13. 2026-10-19 新增需求：「微博没评论」

> 用户新提 6 条，其中 **1 条归微博会话**（另外 5 条在 `docs/BILI_HANDOFF.md` §0.6 与 `docs/UI_HANDOFF.md`）。总表见 `docs/COLLAB_PLAN.md` §5。

### 13.1 现状【已证实】

微博内容在 App 内**没有任何评论列表**，而且是有意为之：

| 位置 | 现状 |
| --- | --- |
| `lib/features/timeline/content_detail_page.dart:478-540` 的 `_CommentSection` | `item.platform == weibo` 时**直接返回占位**：一行说明 + 「在应用内查看这条微博」按钮（跳 `WeiboWebViewPage`） |
| `lib/data/weibo/weibo_client.dart:18-20` | 注释写明「App 内**不做**评论列表，公开接口 `/ajax/statuses/buildComments` 需要访客 Cookie + `XSRF-TOKEN`，风控频繁」 |
| `lib/data/repo/comment_repo.dart:51` | `weiboCommentPlaceholder` 文案常量 |

也就是说：这不是 bug，是**当初主动降级**。用户现在要求补上。

### 13.2 先探针，别先写 UI

微博评论有**两个已知候选接口**，风控强度不同，必须先测出一条能稳定跑通的：

| # | 候选 | 需要什么 | 要回答的问题 |
| --- | --- | --- | --- |
| C1 | `https://m.weibo.cn/comments/hotflow?id=<mid>&mid=<mid>&max_id=<cursor>` | `m.weibo.cn` 的登录 Cookie（**App 已有全局通道 `WeiboCookieSource`，可直接复用**） | 带真实登录 Cookie 时是否 200？`data.data[]` 里的字段（text/user/screen_name/avatar/like_counts）？`max_id` 游标形态？连续翻 3 页会不会 432？ |
| C2 | `https://weibo.com/ajax/statuses/buildComments?is_reload=1&id=<mid>&flow=0` | `weibo.com` 域 Cookie + `XSRF-TOKEN`（**与 C1 不同域**，当前 App 没有这条通道） | 大概率拿不到 → 除非有独立价值，否则别走 |

**建议先测 C1**：`WeiboCookieSource` 已有「全局通道读 `m.weibo.cn` cookie」的能力（`lib/core/net/weibo_cookie_source.dart`，注释里写明了 WebView per-view 与全局通道的区别），复用成本最低。

> ⚠️ 探针务必用**真实登录态**，不要用游客票据——微博评论接口对游客**恒定拦截**，用游客测得「432」会得出错误结论（本项目在 `getIndex` 上已经踩过一次，花了六级探针才定性）。

### 13.3 接入点（照 B 站评论的现成结构做）

现有评论栈是 **B 站专用**，要先抽象再接入：

| 文件 | 现状 | 要改成 |
| --- | --- | --- |
| `lib/features/comments/comment_controller.dart` | 只认 B 站 oid/type | 抽出「按内容取一页评论」的接口，B 站/微博各实现一个 |
| `lib/features/comments/comment_section.dart` | 只认 B 站 | 按 `item.platform` 分派；**UI 结构（翻页、排序、子评论折叠）尽量复用，不要复制一份** |
| `lib/data/repo/comment_repo.dart` | 只有 B 站 | 加微博分支；`weiboCommentPlaceholder` 保留但改为「取数失败/未登录」时的兜底文案 |
| `lib/data/models/comment.dart` | 字段按 B 站设计 | 微博字段不完全对应（无 `rpid`、无子评论两级），**用可空字段 + 默认值**，不要为微博再造一个模型 |

**子评论**：微博 `hotflow` 的二级评论在 `data.data[].comments[]` 里（首屏内嵌），与 B 站的「分页拉子评论」不同。微博这边**直接展示内嵌的一层回复**即可，别强行套 B 站的两级翻页。

### 13.4 风险与红线

1. **风控**：评论接口比时间线接口敏感得多。**必须做**：失败时给可读文案 + 重试，绝不整页白屏；**不要**在列表页预取评论（只在详情页用户主动滚动到评论区时才请求）。
2. **未登录**：未登录时评论区显示「登录后查看评论」+ 一个入口，**不要**伪造数据。
3. **不许为了跑通而绕过风控**（例如伪造 `X-XSRF-TOKEN`、批量换 UA 重试）——这条在 `docs/WEIBO_HANDOFF.md` 第 11 节红线里已经写明。
4. **验收要贴原始响应**：探针输出的 JSON 片段 + HTTP 状态码，写进交付报告；「能显示了」不算证据。

### 13.5 验收标准

- 打开任意微博详情页 → 评论区显示**真实评论**（用户名、头像、内容、时间、点赞数）；
- 连续下拉 3 页不触发 432（或触发时给出「微博限制了评论读取，请稍后重试」的可读提示）；
- 未登录态显示登录引导，不假装有数据；
- B 站评论区的行为**一个字都不变**（回归：`BV*` 视频详情页评论仍能翻页）。
