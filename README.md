# Rrha

多平台内容聚合与播放器（Android / Flutter）。

把 **Bilibili** 与 **微博** 的关注流聚合到一条时间线上，点开即可在原 App 内看视频、看弹幕、看评论、看图。
**App 内直接登录、直连平台官方接口**，不依赖任何第三方聚合服务。

<p align="center">
  <em>时间线 · 视频播放 + 弹幕 · 评论 · 图片九宫格</em>
</p>

---

## 这是什么

| 能做什么 | 说明 |
| --- | --- |
| **统一时间线** | 「全部关注」= B 站 + 微博里你关注的人发的内容，按时间倒序交错；「精选订阅」= 你手动添加的博主 |
| **B 站视频播放** | 双通道（ExoPlayer / libmpv），自动换 CDN 节点，支持清晰度切换、倍速、长按快进、进度记忆 |
| **弹幕** | 字号四档、透明度、同屏上限、屏蔽词、压力测试页 |
| **评论** | B 站主评论 / 子评论翻页，微博评论（图文完整展示） |
| **图片** | 九宫格、全屏预览（缩放/滑动）、保存到相册 |
| **离线友好** | 封面与图片磁盘缓存，飞行模式冷启动仍可浏览 |

**不需要**：RSSHub、自建服务器、电脑常开。

---

## 快速开始

### 环境要求

- Flutter **3.47+**（Dart 3.13+）、JDK 17
- Android SDK（`compileSdk 36`）

### 构建

```bash
flutter pub get
dart analyze          # 预期：No issues found
flutter test          # 预期：All tests passed
cd android && ./gradlew assembleProfile
# 产物：build/app/outputs/flutter-apk/app-profile.apk
```

### 安装

```bash
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

> 首次启动需在 App 内登录：**B 站扫码登录**、**微博在内置浏览器里登录**（用于评论）。
> 未登录也能浏览，但接口会受限。

详细环境说明（含 Windows 中文用户名、Gradle 镜像等坑）见
[docs/HANDOVER.md §5](docs/HANDOVER.md) 与 [docs/ANDROID.md](docs/ANDROID.md)。

---

## 技术要点

- **零第三方聚合依赖**：B 站走 `api.bilibili.com`（含 WBI 签名），微博走 `m.weibo.cn`，均带用户登录态。
- **双播放通道**：MP4 单流用 `video_player`（ExoPlayer），DASH 音视频分离用 `media_kit`（libmpv + `audio-add` 外部音轨）。
- **CDN 自愈**：B 站把首选节点调度到常不可达的 PCDN，代码按「标准 CDN 优先」排序候选并在失败时自动换节点。
- **凭据只进系统钥匙串**，不落 SharedPreferences、不写日志。

---

## 已知限制（如实标注）

- 微博评论需登录态；风控触发时会给出可读提示，不伪造数据。
- 微博视频仅在能取到直链时可播，成功率不保证。
- 默认请求 720P（可在播放页切换更高档位，取决于账号权限）。
- 需要登录或已下架的稿件无法播放。

---

## 开发文档

| 文档 | 内容 |
| --- | --- |
| [docs/HANDOVER.md](docs/HANDOVER.md) | **主文档**：当前状态、环境、每一轮修复的完整记录 |
| [docs/COLLAB_PLAN.md](docs/COLLAB_PLAN.md) | 多会话协作分工与冲突控制 |
| [docs/BILI_HANDOFF.md](docs/BILI_HANDOFF.md) | B 站模块：能力清单、缺口、硬性契约 |
| [docs/WEIBO_HANDOFF.md](docs/WEIBO_HANDOFF.md) | 微博模块：接口探针与结论 |
| [docs/UI_HANDOFF.md](docs/UI_HANDOFF.md) | 界面规范与实现路线 |
| [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) | 真机验收报告 |

---

## 许可

[MIT](LICENSE)

> 本项目为个人学习作品，与 Bilibili、新浪微博官方无关。
> 使用时请遵守各平台的服务条款，不要用于批量抓取或商业分发。

---

<details>
<summary>📚 以下为项目内部开发档案（历史实测结论 / 决策记录 / 逐轮验收）</summary>


> **⚡ 接手这个项目请先读 [docs/HANDOVER.md](docs/HANDOVER.md)**  
> —— 含当前状态、环境要求（几个必踩的坑）、已修复项与下一步计划。
>
> **按模块接手请看**：先读 [docs/COLLAB_PLAN.md](docs/COLLAB_PLAN.md)（多会话分工与冲突控制），再按角色取用 [docs/UI_HANDOFF.md](docs/UI_HANDOFF.md)（界面/UI 优化）、[docs/BILI_HANDOFF.md](docs/BILI_HANDOFF.md)（B 站模块补全）、[docs/WEIBO_HANDOFF.md](docs/WEIBO_HANDOFF.md)（微博）。
>
> **本项目已完成架构转向（2026-10-22 彻底收尾）**：原先的「公共 RSSHub 聚合」路线
> 已验证不可行（实例全灭，且无法满足「电脑关机也能用」），现为
> **「App 内登录 + 直连平台官方接口」**。RSSHub 的客户端、解析器与设置项
> **已于 2026-10-22 整体移除** —— 它早在官方接口落地时就已成不可达死代码
> （详见 [HANDOVER §7.6](docs/HANDOVER.md)）。
> 下方「实测结论」「决策记录」里的 RSSHub 段落保留为**历史依据**，不再代表当前实现。

最初计划验证的四件事，结论如下：

| # | 验证项                   | 结论                                       |
| - | --------------------- | ---------------------------------------- |
| 1 | 公共 RSSHub 实例能否稳定拿到数据  | ❌ **不可用**（见下方「实测结论」）                     |
| 2 | RSS 能否解析成统一时间线        | ✅ 解析器已实现且有测试覆盖；但数据源不可用                   |
| 3 | B 站视频能否在 App 内播放并渲染弹幕 | ✅ **通过**（真机验证，弹幕 83.6 fps）               |
| 4 | B 站评论 / 微博可行性         | ⚠️ 评论应用内可用；**微博直连被风控（432）拦**，降级为 WebView |

---

## ✅ 验证状态

**这份代码已经过联网实测、真实编译与真机验收，不是「未编译的草稿」。**

| 验证项 | 结果 |
| --- | --- |
| `flutter pub get` | ✅ 依赖解析成功（Flutter 3.47.7 / Dart 3.13.5） |
| `dart analyze` | ✅ **No issues found** |
| `flutter test` | ✅ **全部通过**（千级用例，含登录、时间线、播放、弹幕、评论、图片） |
| 线上接口 | ✅ 已逐条实测，并按真实返回形态修正过代码 |
| 真机验收 | ✅ 两台机型（华为 P40 Pro / 荣耀 Magic8 Pro）均通过，见 [ACCEPTANCE.md](docs/ACCEPTANCE.md) |

> 详细的逐轮修复记录（每一轮的根因、修法、验证数据）保存在 git 历史与本文件的
> [开发档案](#-以下为项目内部开发档案) 区，按主题汇总的「踩坑结论表」见
> [docs/HANDOVER.md §7](docs/HANDOVER.md)。

真机关键结果：冷启动 **682 ms**、弹幕 **83.6 fps**（最坏情况 62.7 fps）、  
B 站播放与弹幕渲染与评论均通过。

> 注：「公共 RSSHub 实例不可用」是 2026-10 的历史验收结论。
> 该链路已于 2026-10-22 整体移除，项目现为纯官方接口架构（见 [HANDOVER §7.6](docs/HANDOVER.md)）。

> 编写环境有个特殊点：`flutter analyze` 走 LSP 通道，在受限沙箱里会崩，  
> 因此静态检查是用等价的 `dart analyze` 完成的。**在正常开发机上 `flutter analyze` 应照常可用。**

### 拿到代码后的第一步

`android/` 平台壳现在**已经生成并随工程提供**（含 `gradle-wrapper.jar` 与  
`local.properties` 之外的完整 Gradle 配置），所以不再需要先跑 `flutter create`：

```bash
cd rrha
flutter pub get
dart analyze      # 预期：No issues found
flutter test      # 预期：All tests passed!（1313 个）
```

构建前需要确认 `android/local.properties` 里的两个路径与你本机一致  
（该文件由 `flutter create` 生成且含本机绝对路径，通常已被 `.gitignore` 排除）：

```properties
sdk.dir=C:\\Android\\sdk
flutter.sdk=C:\\flutter
```

若路径不同，把它改成你自己的，或直接重新生成该文件。构建配置的**非标准改动**  
（腾讯云 Gradle 镜像、阿里云 Maven 镜像、JVM 内存收紧）都写在  
[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §6，并附了改回官方源的方法。  
平台壳的其它说明见 [docs/ANDROID.md](docs/ANDROID.md)。

---

## 🔬 实测结论（联网跑出来的，不是推测）

全部结论来自 [tools/](tools/) 下的探测脚本（用法见 [tools/README.md](tools/README.md)），可复现。  
最权威的一条写在最前面。

### 1. 公共 RSSHub 实例基本全灭 —— 本轮最重要的发现

官方文档（[docs.rsshub.app/zh/guide/instances](https://docs.rsshub.app/zh/guide/instances)）  
列出的 **19 个公共实例，实测只有 1 个能返回 RSS**：

| 结果                | 数量 | 代表                                                                     |
| ----------------- | -- | ---------------------------------------------------------------------- |
| ✅ 可用              | 1  | `https://rsshub-balancer.virworks.moe`                                 |
| ⛔ Cloudflare 人机校验 | 4  | **`rsshub.app`（官方）**、`isrss.com`、`rss.4040940.xyz`、`rsshub.cups.moe`   |
| ❌ 5xx             | 8  | `rsshub.rssforever.com`(503)、`rss.owo.nz`(502)、`rsshub.umzzz.com`(500) |
| ❌ TLS 中断          | 6  | `rsshub.pseudoyu.com`、`rsshub.henry.wang` 等                            |

**落到代码上的三处改动**：

- `RssHubClient.looksLikeCloudflareChallenge()` 识别挑战页，给出  
  「该实例被 Cloudflare 人机校验拦截，App 无法通过，请在设置中更换实例」，  
  而不是笼统的「403 拒绝访问」；
- `AppConfig.knownInstances` 内置实测可用的实例，设置页做成一键填入的 chip；
- 默认值仍按需求保留官方 `https://rsshub.app`，但**它当前不可用**。

**所以「能否通过公共 RSSHub 实例稳定拿到数据」的答案是：不能。**  
长期使用必须自建实例，或用带容错的转发层（社区有  
[rsshub-never-die](https://github.com/CaoMeiYouRen/rsshub-never-die) 这类多实例代理）。

### 2. WBI 签名：算法正确性已被 B 站接口验证

用 Python **独立复刻**了 `wbi.dart` 的算法（同一张混淆表、同样的 `!'()*` 过滤与排序），  
签名后的请求被 B 站接受：

```
GET /x/web-interface/view  →  {"code":0,"message":"OK"}
aid=117416285765897  cid=42625207701
```

同时确认：**未登录时 `nav` 返回 `code:-101`，但 `data.wbi_img` 仍然存在**  
—— `BiliClient._refreshKeys` 正是按这个行为写的，实测完全吻合。

### 3. playurl：双通道设计成立

| 请求           | 结果                                                                                 |
| ------------ | ---------------------------------------------------------------------------------- |
| `fnval=1`    | `durl` 有 1 条 ✅ → 通道 A（`video_player`）                                              |
| `fnval=4048` | `dash.video=6 / dash.audio=3`，codecid `[7,12,13]`，qn `[16,32]` → 通道 B（`media_kit`） |

`support_formats` 的字段名（`quality` + `new_description`）与解析代码一致。

### 4. 弹幕接口形态已变 —— 实测抓出两个致命 bug

```
/x/v1/dm/list.so?oid=<cid>
  content-encoding: deflate
  首字节 cc bd 5b 6f                      ← 不是 zlib 的 0x78
  裸 deflate 解压后 → "<?xml version=..."  ← 不是 protobuf！
  <d p="4.39000,5,25,16707842,...">一上来就没绷住</d>
                            ↑ p[0] 是浮点秒，不是整数毫秒
```

- **bug 1**：`int.tryParse("4.39000")` 返回 null → **每一条弹幕都被静默跳过**；
- **bug 2**：接口现在返回**裸 deflate 压缩的 XML**，老实现却按 protobuf 解析；  
  且 `comment.bilibili.com/{cid}.xml` 与它**同源**（字节完全一致）。

修法：取字节 → 依次尝试 zlib / gzip / **裸 deflate** → 按内容自动识别  
XML 或 protobuf（`DanmakuParser.parseAuto`）。

> 记一个坑：**不要给裸 deflate 手工补 zlib 头**。zlib 尾部的 Adler-32 是对  
> *解压后*数据算的，解压前无法预知 —— 实测必然报 `incorrect data check`。  
> 正确做法是用 `archive` 的 `Inflate`。

### 5. B 站评论：无登录态可用，但数据受限

```
GET /x/v2/reply/wbi/main  →  code = 0
replies = 3  top_replies = 1  is_end = True
```

**接口可用、签名被接受**，但请求 `ps=20` 时只回 3 条且 `is_end=true`。  
这正是代码里标注的「不承诺必出 20 条」的真实现象，UI 会如实展示而不是伪造。

### 6. 微博路由

未单独复测，处理不变：需要实例侧配置 `WEIBO_COOKIE`，公共实例拿不到数据时给出明确文案。

---

## 1. 环境要求

| 项        | 要求                                                 |
| -------- | -------------------------------------------------- |
| Flutter  | ≥ 3.24；**实测通过版本 3.47.7（Dart 3.13.5）**              |
| Dart SDK | ≥ 3.5                                              |
| Android  | minSdk 23（受 media_kit / ExoPlayer 约束）、targetSdk 34 |
| 真机       | 用于验收测量；模拟器无法反映真实帧率                                 |

---

## 2. 架构

```
lib/
  main.dart                     冷启动路径：只 await SharedPreferences
  providers.dart                Riverpod 依赖图（客户端 / 仓库 / 设置 / 时间线）
  core/
    config/app_config.dart      全部常量（TTL、超时、弹幕参数、上限）
    net/
      app_error.dart            统一错误模型 + 中文文案 + HTTP 映射
      retry_interceptor.dart    只对幂等 GET 的 5xx/超时做指数退避重试
      dio_provider.dart         单个 Dio：B 站 API（RSS 拉取用的第二个已移除）
    cache/cache_store.dart      文件 + 内存双层缓存，TTL 5 分钟
    storage/prefs.dart          订阅源、设置、已读标记
    storage/secure_store.dart   钥匙串封装（本轮无凭证，仅提供契约）
    utils/                      bvid 提取 / 时间解析 / HTML 处理 / 并发限制 / 日志
  data/
    models/                     ContentItem（统一模型）、Subscription、Danmaku、Comment
    bili/wbi.dart               WBI 签名（纯函数，有黄金单测）
    bili/bili_client.dart       view / playurl / 弹幕双通道 / 评论
    bili/bili_timeline_source.dart  关注流 / UP 投稿与动态（官方接口 + 原始 JSON 缓存）
    bili/bili_content_parser.dart   动态 JSON → ContentItem
    bili/danmaku_parser.dart    protobuf(deflate) 与 XML 双解析
    bili/comment_parser.dart    评论 JSON → 模型（游标分页）
    weibo/                      官方接口客户端 / 解析 / 时间线源 / 评论
    repo/                       订阅源 / 时间线 / 视频 / 评论 仓库
  features/
    timeline/                   统一时间线 + 详情页
    subscriptions/              订阅源管理
    player/                     播放页 + 双通道适配器 + 弹幕引擎 + 压力测试页
    comments/                   评论区（排序 / 游标分页 / 楼中楼）
    settings/                   数据源状态 / 缓存 / 弹幕 / 诊断入口 / 日志
  widgets/                      通用错误视图、空态、来源标签、封面容错
test/                           单元测试（无网络依赖）
```

### 数据流

```
设置(基地址) + 订阅(UID)
        ↓
TimelineRepository ── 按「订阅源 × 路由」展开任务，并发上限 3
        ↓
RssHubClient（5 分钟缓存）→ RssParser → List<ContentItem>
        ↓
合并 / 按发布时间倒序 / 与本地已读 id 比对打 isNew
        ↓
TimelinePage ──点击──> PlayerPage(bvid) 或 ContentDetailPage
                          ├ view → aid/cid
                          ├ playurl → 通道A(MP4) / 通道B(DASH)
                          ├ 弹幕（proto / XML 双通道）→ DanmakuEngine
                          └ 评论（游标分页 + 楼中楼）
```

---

## 3. 关键实现说明

### 3.1 WBI 签名（B 站 -352 的根因）

`lib/data/bili/wbi.dart`：

1. `GET /x/web-interface/nav` → `wbi_img.img_url/sub_url` 各取文件名 → 64 字符 `orig`  
   （**未登录时该接口返回 `code:-101`，但 `data.wbi_img` 仍然存在**，代码对此做了特殊处理）；
2. 按公开混淆表取 `mixinKey`（32 字符）；
3. 参数按 key 升序，值先剔除 `!'()*` 再 URL 编码，拼成 query；
4. `w_rid = md5(query + mixinKey)`。

命中的坑都已处理：**值必须过滤 `!'()*`**（否则签名必然不匹配）、  
**请求必须带 `Referer: https://www.bilibili.com/`**、  
**`-352` 时强刷一次密钥再重试**（密钥会滚动更新）。

`test/bili/wbi_test.dart` 里有一个**黄金断言**：混淆表必须是 0..63 的排列，  
且 `mixinKey('a'*32, 'b'*32)` 必须等于手算值 `bbaabaaababaababbababbabaaaababa`。  
B 站一旦改算法，这个测试会立刻失败。

### 3.2 双通道播放器

B 站 `playurl` 有两种返回形态，决定了必须双通道：

| 通道 | 触发                      | 播放器                       | 说明                                |
| -- | ----------------------- | ------------------------- | --------------------------------- |
| A  | `durl` 非空（`fnval=1`）    | `video_player`（ExoPlayer） | 单文件 MP4，零额外体积，硬解性能最好              |
| B  | 只有 `dash`（`fnval=4048`） | `media_kit`（libmpv）       | 音视频分离流，音频通过 mpv 的 `audio-file` 附加 |

`createPlayerFor()` 是唯一的分叉点，播放页对后端无感。

### 3.3 弹幕性能（对应「500 条 ≥45fps」）

`lib/features/player/danmaku/danmaku_engine.dart`：

- **零 widget 重建**：时钟是 `ValueNotifier`，通过 `CustomPainter(repaint: clock)`  
  驱动，时间推进只触发重绘；外层 `RepaintBoundary` 与视频层隔离；
- **对象池**：渲染项与提交队列复用，渲染循环内不 `new`；
- **TextPainter LRU 缓存**（600 条）：文本布局是最大开销，命中后每帧只做位移 paint；
- **统一滚动速度**：同速下两条弹幕相对位置恒定，「轨道何时可再次发射」有闭式解  
  `t ≥ (width + gap) / v`，不需要每帧做碰撞检测；
- **透明度用 `saveLayer` 整体 alpha**：改文字颜色的 alpha 会让 TextPainter  
  缓存全部失效（每帧重新布局 500 条），这是最容易踩的性能坑。

**验收测量**：设置页 → 弹幕 → 「弹幕压力测试」，注入 500 条并显示实时帧率。  
必须用 `flutter run --profile`，debug 模式读数没有意义。

### 3.4 弹幕与播放进度同步

播放器的位置回调只有 2~~10Hz，直接驱动会让弹幕一跳一跳。  
`lib/features/player/playback_clock.dart` 的做法是：记录锚点 `(position, wallClock)`，  
每帧用墙钟外推；偏差 <40ms 不动（抑制抖动）、40ms~~400ms 只校正一半、

> 400ms 判定为拖动进度条并硬跳（同时通知弹幕引擎重置）。

### 3.5 缓存与降级

- TTL **5 分钟**（`AppConfig.rssCacheTtl`），TTL 内直接命中不发请求；
- 请求失败时用**过期缓存**顶上（stale-while-error），并在 UI 打「数据来自缓存」角标；
- 403 不重试（重试无意义），429 不立即重试（只会加重限流），  
  5xx / 超时 / 连接错误才做一次指数退避重试；
- 单个源失败不影响其它源，时间线顶部显示「N 个源刷新失败」+ 详情入口。

---

## 4. 与原计划的偏离（以及理由）

| 计划                           | 实际                       | 理由                                                                                                         |
| ---------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------- |
| 用 `dart_rss` 解析 RSS          | 改用 `xml` + 自写映射          | RSSHub 输出大量扩展命名空间（`media:` / `dc:` / `weibo:`）与非标准 CDATA；直接遍历 XML 树更可控，也能对每个字段单独兜底。`xml` 是最成熟的 XML 库，风险更低。 |
| `net/cache_interceptor.dart` | 缓存放进 `RssHubClient` 显式读写 | 拦截器里的缓存难以单测，也无法表达「请求失败时用过期缓存顶上」这个降级语义；显式读写更清晰。                                                             |
| 手势调节系统亮度                     | 应用内亮度遮罩                  | 避免申请 `WRITE_SETTINGS` 权限。多数播放器（含 B 站）也是这个做法。                                                               |
| 未提及                          | 新增「弹幕压力测试」页              | 需求给了 45fps 的量化验收标准，必须提供可复现的测量手段，而不是让人手搓数据。                                                                 |

---

## 5. 诚实标注：本轮明确不承诺的能力

这些不是「没写完」，而是**在公共实例原型阶段确实做不到**，代码里也不会假装实现：

| 能力             | 状态              | 原因                                                                                                                                                                                  |
| -------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 微博动态聚合         | **公共实例上大概率不可用** | RSSHub 的 `/weibo/user/:uid` 要求实例侧配置 `WEIBO_COOKIE`（微博访客接口已被封，社区大量反馈 432/空数据）。`rsshub.app` 是共享实例，不会带你的 Cookie。绕过它等于破解微博风控，属明确不做。<br />处理：源卡片显示「该实例未配置微博 Cookie」，并允许在设置页把微博源单独指向自备实例。 |
| 微博视频内置播放       | **不承诺**         | RSS 描述里不保证带直链；即便提取到，微博 CDN 直链带时效签名与防盗链。代码做「尽力提取 + 尝试播放」，失败时明确显示「视频解析失败」，不伪造。                                                                                                        |
| 微博评论           | **本轮不做**        | 公开接口需要访客 Cookie + `XSRF-TOKEN`，风控频繁。用占位 UI 验证布局，文案写明「待后续实现」。                                                                                                                        |
| B 站评论「必出 20 条」 | **不承诺**         | 无登录态下评论接口可能返回 `-352`，或只返回 `top_replies`。代码如实展示错误 + 重试按钮，**绝不用假数据填充**。                                                                                                               |
| 1080P          | **不承诺**         | 未登录态 `playurl` 通常不给高码率；默认请求 720P（`qn=64`）。                                                                                                                                          |
| 全部视频可播         | **不承诺**         | 付费 / 仅登录（-10403）/ 已下架（-404）会明确报错。                                                                                                                                                   |
| 弹幕接口稳定性        | **已实测并修正**      | 实测该接口返回的是**裸 deflate 压缩的 XML**，不再是历史文档里的 protobuf。代码已按真实形态重写（`parseAuto` 自动识别），并加了对应的 fixture 测试。B 站仍可能再变，所以解析保持可插拔。                                                                |
| 真机验收数据         | **未实测**         | 见文首说明：编写环境无 Flutter、无外网。提供了可复现的测量方法。                                                                                                                                                |


**另外两个必须知道的行为**：

1. **非功能性约束**：UI 中固定展示「数据来源为公共 RSSHub 实例，可能不稳定」；
2. **合规与凭据**：App **不硬编码、不内置**任何账号 Cookie/Token/密码。  
   阶段 1 起用户可**自己扫码登录 B 站**（见 [docs/HANDOVER.md](docs/HANDOVER.md) §7.5），  
   凭据只写入**系统钥匙串**（`lib/core/storage/bili_credential_store.dart`），  
   退出登录即删除，界面只显示脱敏摘要（末 4 位）。  
   唯一的匿名 Cookie 是 B 站下发的**匿名设备指纹 `buvid3`**（不是凭证），可在设置页关闭。

---

## 6. 验收测量方法（真机）

> **本节已于 2026-10-14 在华为 P40 Pro 上执行完毕，实测数据见  
> [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。** 下表保留为复核清单。

| 验收项                                | 怎么测                                                                  | 实测结果                     |
| ---------------------------------- | -------------------------------------------------------------------- | ------------------------ |
| 添加 1 个 B 站 + 1 个微博 UID，10 秒内完成首次加载 | 添加订阅后观察时间线；失败会显示明确错误而不是转圈                                            | ⚠️ 受 RSSHub 限制失败（错误提示正常） |
| 时间线展示最新 20 条、倒序、显示来源/标题/封面/时间      | 直接观察；来源标签固定显示 `Bilibili` / `微博`                                      | ⚠️ 同上                    |
| 点击 B 站视频 3 秒内起播                    | 用秒表；播放页信息行显示「通道A(MP4 qn=…)」/「通道B(DASH …)」，回退时显示「通道B(libmpv 回退 qn=…)」 | ✅ 通过                     |
| WBI 失败显示可读错误而非黑屏                   | 设置页关闭「匿名设备指纹」后更容易复现 -352，观察错误卡片                                      | ✅ 签名正常（`view` 接口 code=0） |
| 弹幕 10 秒内出现且同步                      | 直接观察                                                                 | ✅ 通过（3600 条）             |
| 500 条弹幕 ≥45fps                     | 设置 → 弹幕 → 弹幕压力测试；**必须 profile/release**，稳定 10 秒后读数                   | ✅ **83.6 fps**（最坏 62.7）  |
| 评论 20 条/页、1.5 秒渲染                  | 观察评论区分页与加载耗时                                                         | ⚠️ 分页逻辑正确，无登录态下接口不返回足量   |
| 冷启动 ≤2 秒                           | `adb shell am start -W -n com.rrha.rrha/.MainActivity` 看 `TotalTime` | ✅ **682 ms**             |
| 修改基地址后下次刷新使用新地址                    | 设置页改地址 → 保存 → 回时间线下拉刷新                                               | 未单独复测                    |
| 清除缓存后重新请求                          | 设置 → 缓存 → 清除，观察「RSS 缓存」条目数归零，下次刷新重新请求                                | 未单独复测                    |

### 第一次联网时请先跑这份清单

上表里的每一项背后都依赖线上接口，而它们的实际形态**我无法在无网环境验证**。  
[docs/LIVE\_CHECK.md](docs/LIVE_CHECK.md) 把每个接口拆成了可执行的 curl 步骤。  
**这些步骤已在 2026-10-11 全部跑过一遍**（结论见本文「实测结论」节），  
保留它作为后续复核清单 —— 接口一旦再变，先跑这份清单定位，再补 fixture 测试。  
每个接口都给出预期返回、失败判读，以及「要改哪个文件」。

顺序建议：先确认 RSSHub 的 B 站路由（第 1~~2 节），再确认 B 站 WBI 与 playurl（第 4~~5 节），  
最后确认弹幕与评论（第 6~7 节）。微博路由（第 3 节）预计失败，那是预期行为。

---

## 7. 单元测试

```bash
flutter test
```

覆盖（全部离线，不需要网络）：

| 文件                                           | 覆盖点                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------- |
| `test/bili/wbi_test.dart`                    | 混淆表排列性、mixinKey 黄金值、`!'()*` 过滤、参数排序、nav 提取密钥                        |
| `test/bili/danmaku_parser_test.dart`         | protobuf（含 zlib 压缩路径）与 XML 双解析、损坏数据不崩、屏蔽词                           |
| `test/bili/comment_parser_test.dart`         | 评论列表/置顶/游标解析、UP 标记、字符串数字兼容、楼中楼分页                                    |
| `test/rss/rss_parser_test.dart`              | B 站视频/动态、微博、Atom 的字段映射、封面优先级、id 稳定性、错误页诊断                           |
| `test/core/utils_test.dart`                  | HTML→文本、实体解码、RFC822/ISO 时间解析、BV/UID 提取、并发限制                         |
| `test/core/app_error_test.dart`              | 429/403/404/5xx 文案与可重试性、DioException 映射                             |
| `test/data/bili_models_test.dart`            | playurl 的 durl/dash 选择策略与兜底                                         |
| `test/data/models_test.dart`                 | 统一模型 JSON 往返、派生属性、订阅与路由、弹幕模式与颜色                                     |
| `test/features/danmaku_engine_test.dart`     | 屏蔽、同屏上限、seek 重置、轨道回收、缓存上限、合成数据确定性                                   |
| `test/features/comment_controller_test.dart` | 首屏/加载更多/排序切换/楼中楼展开与失败重试、**动态评论的 oid/type 透传**                       |
| `test/bili/comment_pagination_test.dart`     | `pagination_str` 包装形态（裸游标 → `{"offset":"..."}`）、**产物不含空格**、解析层只存裸游标 |
| `test/bili/bili_risk_retry_test.dart`        | 风控判定：业务码 -352/-412 **与 HTTP 412**、其它错误不误触发重刷密钥                      |
| `test/bili/following_feed_test.dart`         | 关注流的游标/`has_more`/`update_num` 解析（含**字符串形态**与 19 位大整数边界）、到底判定       |
| `test/features/player_sync_test.dart`        | 两个 adapter 的 `playingStream` **订阅即补发当前值**、弹幕层的非时钟重绘触发               |
| `test/features/timeline_paging_test.dart`    | 一页 20 条 + 游标翻页、去重、到底不再请求、**模式切换重置列表**与 Prefs 持久化                    |

---

## 8. 明确不做（与需求一致）

自部署 RSSHub、系统级推送、离线缓存下载、多账号管理、应用商店发布、  
微博视频与微博评论的强承诺、1080P 强承诺。

---

## 9. 后续接续方案

- **微博**：自部署 RSSHub 并配置 `WEIBO_COOKIE`（RSSHub 官方推荐做法），  
  在设置页把「微博源专属实例」指向它即可，客户端代码无需改动。
- **B 站评论需要登录态**：若实测确认必须登录才能稳定取评论，  
  下一步是允许用户粘贴 Cookie 并写入 `SecureStore`（钥匙串封装已就位），  
  **不会**硬编码任何凭证。
- **弹幕接口变更**：`DanmakuParser` 是纯函数且有可插拔的双通道，  
  新增通道只需在 `BiliClient.danmaku()` 里加一路并补 fixture 测试。

</details>
