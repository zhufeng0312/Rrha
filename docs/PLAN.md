# Rrha —— 多平台博主内容聚合与播放器 · 实现计划（公共 RSSHub 原型验证版）

> 状态：待用户确认后进入编码  
> 日期：2026-10-11  
> 范围：Android 原型，验证「公共 RSSHub 订阅聚合 + B 站内置播放 + B 站弹幕 + B 站评论」

---

## 0. 先讲两个硬性阻塞（必须先决策）

### 0.1 本机没有构建工具链

实测结果（`Get-Command` / 常见路径探测）：

| 工具          | 结果                                                         |
| ----------- | ---------------------------------------------------------- |
| flutter     | 未安装（PATH 无、`C:\src\flutter`、`~\flutter`、`C:\flutter` 均不存在） |
| dart        | 未安装                                                        |
| adb         | 未安装                                                        |
| java        | 未安装（`C:\Program Files\Java`、`~\.jdks` 不存在）                 |
| Android SDK | 未安装（`%LOCALAPPDATA%\Android\Sdk` 不存在）                      |

后果：**我无法执行 `flutter pub get`、无法编译 APK、无法在任何设备上运行**。

### 0.2 本机 shell 完全没有外网

```
curl https://www.baidu.com                   -> 000
curl https://rsshub.app                      -> 000
curl https://api.bilibili.com/x/...          -> 000
curl https://registry.npmmirror.com          -> 000
Invoke-WebRequest https://www.baidu.com      -> 基础连接已经关闭: 接收时发生错误
```

连百度都不通，说明不是被墙，是本机出网链路本身不可用（无可用代理环境变量）。  
（对比：Harness 自身的 GitHub MCP 与 web_search 通道是通的，所以我能查资料、也能推送代码；但**子进程网络不可用**。）

后果：

- 无法拉取 pub 依赖 → 依赖版本只能按 pubspec 声明，由你在有网机器上 `pub get` 解析。
- 无法线上实测 RSSHub / B 站接口 → 本文档所有「接口现状」判断均标注为**待实测**，我按多通道降级来写代码，不假装已验证。
- 你列出的真机验收项（3 秒起播、45fps、冷启动 2 秒、1.5 秒渲染评论）**本轮无法由我实测**，只能交付可复现的测量方法。

---

## 1. 技术选型与理由

### 1.1 平台与框架

| 项    | 选型                               | 理由                                                                                                                                                                 |
| ---- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 框架   | **Flutter（保持你的指定）**              | 不换。理由：自定义弹幕层需要「原生视频 surface + Flutter 自绘 overlay」的混合栈，Flutter 的 `Texture`/`PlatformView` + `CustomPaint` 正好是这个模型；单代码库后续可延展 iOS。备选 React Native 在「自绘高刷叠加层」上开销更大，不换。 |
| 语言   | Dart（空安全）                        | 默认                                                                                                                                                                 |
| 最低版本 | Android 6.0 (API 23) / target 34 | 覆盖够广，且 ExoPlayer、mpv 均支持                                                                                                                                           |

### 1.2 依赖选型

| 能力          | 选型                                                     | 理由 / 备注                                                                                                                                                     |
| ----------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HTTP        | **dio**                                                | 你指定同类库；拦截器机制适合统一注入超时、UA、Referer、重试、缓存、错误映射                                                                                                                  |
| RSS/Atom 解析 | **dart_rss** + **xml**                                 | `dart_rss` 支持 RSS 2.0 / Atom / RDF，且在维护；`webfeed` 已多年无更新。**兜底**：`dart_rss` 抛错时用 `xml` 手工遍历 `<item>/<entry>`（B 站/微博路由的 CDATA 结构不总是标准），保证「解析失败不崩溃」            |
| 状态管理        | **Riverpod（flutter_riverpod）**                         | 理由：①`AsyncValue` 原生表达「加载/数据/错误」三态，正是本项目网络场景；②Provider 可组合、可 override，便于注入假数据做单测；③不依赖 BuildContext，Repository 层可纯 Dart 测试；④相比 Bloc 样板代码大幅减少，相比 GetX 无隐式全局状态。 |
| 播放器         | **双通道**：`video_player`（MP4 单流）/ **media_kit**（DASH 双流） | 见 1.3                                                                                                                                                       |
| 本地键值        | **shared_preferences**                                 | 订阅源列表与设置体量极小（< 100KB），不值得引 Isar/Hive                                                                                                                        |
| 安全存储        | **flutter_secure_storage**                             | Android Keystore。本轮无凭证，预留位（若后续允许用户填 Cookie）                                                                                                                 |
| 缓存目录        | **path_provider**                                      | 自写文件缓存                                                                                                                                                      |
| 摘要/签名       | **crypto**                                             | MD5（WBI 签名）                                                                                                                                                 |
| 解压          | **archive**                                            | B 站弹幕 deflate 解压                                                                                                                                            |
| 单测          | **flutter_test** + **mockito**/手写 Fake                 | WBI 签名向量、RSS fixture、弹幕解析、关键词过滤                                                                                                                             |
| 性能观测        | Flutter 自带 `flutter run --profile` + DevTools          | 见 6.3                                                                                                                                                       |

**不引入的东西**（降低风险）：不引 `webview_flutter`（微博视频不做页面抓取，见第 7、8 节）、不引第三方 dio 缓存拦截器（5 分钟 TTL 逻辑 30 行自写，可控且避免依赖版本冲突）。

### 1.3 播放器选型（关键决策）

B 站 playurl 有两种返回形态，决定了播放器方案：

- **durl（单文件 MP4）**：`fnval=1`。单 URL，`video_player`（Android ExoPlayer 硬解）性能最好、手势/全屏最省事。
- **DASH（音视频分离）**：`fnval=4048`。返回 `video[].baseUrl` + `audio[].baseUrl` 两条流，`video_player` **无法**直接播（它只吃单一 URL，不吃裸 DASH 分片流）。

因此：

| 通道    | 触发条件                | 播放器                                                         | 风险                                         |
| ----- | ------------------- | ----------------------------------------------------------- | ------------------------------------------ |
| A（首选） | playurl 返回非空 `durl` | `video_player`                                              | 未登录态下多半只给 360P/480P MP4（可接受，你已声明不承诺 1080P） |
| B（兜底） | 只有 DASH             | `media_kit`（libmpv），视频流为主 URL，音频流通过 mpv 的 `audio-file` 选项附加 | 双流同步依赖播放器；libmpv 会显著增大 APK 体积（约 +20–30MB）  |

选型理由：把最常见的「有 MP4」路径压在零额外体积的官方播放器上；只在必要时付出 media_kit 的体积代价。若你更在意**代码路径统一 / APK 体积无所谓**，可以改成「全量 media_kit」，我在问题清单里给了这个选项。

弹幕层与播放器解耦：视频由原生层渲染，弹幕是 Flutter 侧的 `CustomPaint` overlay，两者互不抢占（弹幕性能不依赖播放器实现）。

---

## 2. 模块拆分与数据流

### 2.1 目录结构

```
rrha/
  android/                         # Android 壳（minSdk 23, INTERNET 权限）
  docs/PLAN.md                     # 本文档
  lib/
    main.dart                      # 仅做必要初始化后 runApp（保证冷启动）
    app.dart                       # MaterialApp + 主题 + 路由
    core/
      config/app_config.dart       # 默认基地址、超时、TTL、上限常量
      net/dio_provider.dart        # Dio 实例工厂（超时/UA/Referer/重试/缓存拦截器）
      net/retry_interceptor.dart   # 指数退避重试（仅幂等 GET，最多 1 次）
      net/cache_interceptor.dart   # 5 分钟 TTL：命中直返，否则标记回写
      net/app_error.dart           # 统一错误模型 + 中文文案映射
      cache/cache_store.dart       # 文件缓存（key=URL hash，含时间戳、清空）
      storage/prefs.dart           # 订阅源/设置持久化
      storage/secure_store.dart    # 预留：钥匙串
      utils/bvid.dart              # 从各种链接提取 BV/av/uid
      utils/time_parse.dart        # RFC822/ISO8601/相对时间 → 统一 UTC
      utils/html_text.dart         # HTML → 纯文本、首个 img 提取
    data/
      models/content_item.dart     # 统一内容模型
      models/video_ref.dart        # VideoRef / DanmakuItem / Comment
      rss/rsshub_client.dart       # 拼接路由 + 拉取
      rss/rss_parser.dart          # dart_rss → 统一模型（含 xml 兜底）
      rss/rss_hub_routes.dart      # 路由模板与参数
      bili/bili_client.dart        # view / playurl / danmaku / reply（含 WBI）
      bili/wbi.dart                # WBI 签名（纯函数，可单测）
      bili/bili_codes.dart         # -352/-404/-10403 等错误码 → 中文
      bili/danmaku_parser.dart     # protobuf/deflate 与 XML 双解析
      weibo/weibo_client.dart      # 微博可做性探测 + 视频直链提取
      repo/subscription_repo.dart
      repo/timeline_repo.dart
      repo/video_repo.dart
      repo/comment_repo.dart
    features/
      subscriptions/               # 订阅源管理（增删、刷新、状态）
      timeline/                    # 统一时间线 + 新内容标记 + 下拉刷新
      player/                      # 播放页 + 弹幕引擎 + 手势 + 全屏
      comments/                    # 评论列表 + 排序 + 加载更多 + 楼中楼
      settings/                    # 基地址 / 数据源状态 / 清缓存 / 弹幕偏好
    widgets/                       # 通用错误卡片、重试按钮、封面占位、来源标签
  test/                            # 单测 + fixture（脱敏的 RSS 样本）
```

### 2.2 数据流

```
[设置页] 基地址 ──┐
[订阅页] UID ────┴─> SubscriptionRepository ──> prefs（持久化）
                            │
                            ▼
                    TimelineRepository
                            │
         ┌──────────────────┴───────────────────┐
         ▼                                      ▼
  RssHubClient(/bilibili/user/video|dynamic)  RssHubClient(/weibo/user)
         │                                      │
         └────────> RssParser ──────────────────┘
                            │
                            ▼
                    List<ContentItem>（统一模型）
                            │
                            ▼
             合并 → 按 publishedAt 倒序 → 与本地 lastSeenId 比对打 isNew
                            │
                            ▼
                     TimelinePage（Riverpod AsyncNotifier）

点击条目
   │
   ├─ platform=bilibili & kind=video ──> VideoDetailPage(bvid)
   │        │
   │        ├─ BiliClient.view(bvid) ─> aid/cid/pages/stat
   │        ├─ BiliClient.playurl ────> durl | dash ─> 播放器（通道 A/B）
   │        ├─ BiliClient.danmaku ───> DanmakuEngine（与进度同步）
   │        └─ BiliClient.reply ─────> 评论区（分页/排序/楼中楼）
   │
   ├─ platform=bilibili & kind=dynamic ─> 动态详情（纯文本/图，无播放）
   └─ platform=weibo ──────────────────> 微博详情
            ├─ 能提取到视频直链 → 尝试播放（不承诺）
            ├─ 提取不到 → 「视频解析失败」+ 封面/正文
            └─ 评论 → 占位 UI（明确标注待实现）
```

### 2.3 模块 → 验收项对照

| 模块       | 交付内容                   | 你给的验收项                                  | 我能做的验证                  |
| -------- | ---------------------- | --------------------------------------- | ----------------------- |
| M1 订阅源管理 | 增删 UID、拉取解析、下拉刷新、新内容标记 | 10 秒内首次加载；最新 20 条倒序；显示来源/标题/封面/时间；失败不崩溃 | 单测 + fixture；真实网络需你环境实测 |
| M2 播放器   | B 站内置播放、手势、全屏、错误可读     | 3 秒起播；WBI 失败显示错误而非黑屏                    | 错误分支可用假响应单测；起播耗时需真机     |
| M3 弹幕    | 拉取、同步、开关/透明度/屏蔽、对象池    | 10 秒内出弹幕；开关有效；500 条 ≥45fps              | 引擎逻辑单测；帧率需真机 profile 模式 |
| M4 评论    | 列表/排序/加载更多/楼中楼/错误重试    | 20 条/页、1.5 秒渲染；加载更多可用；失败有重试             | 逻辑单测；耗时需真机              |
| M5 设置    | 基地址、源状态、清缓存、可读错误       | 换地址生效；清缓存后重新请求；错误可读                     | 全部可单测覆盖                 |

---

## 3. RSSHub 路由 → 统一内容模型：字段映射

### 3.1 路由表

| 平台       | 路由                            | 展示名    | 备注                                             |
| -------- | ----------------------------- | ------ | ---------------------------------------------- |
| Bilibili | `/bilibili/user/video/:uid`   | UP 主视频 | 追加 `?limit=20` 控制条数                            |
| Bilibili | `/bilibili/user/dynamic/:uid` | UP 主动态 | 同上                                             |
| 微博       | `/weibo/user/:uid`            | 博主主页   | **官方要求实例侧配置 `WEIBO_COOKIE`**，公共实例基本没有 → 见第 7 节 |

拼接规则：`{baseUrl}{route}`，其中 `baseUrl` 去除尾部 `/`、补上缺失的 `https://`；非法 URL 在设置页即时校验拒绝。

### 3.2 统一内容模型

```dart
class ContentItem {
  final String id;            // 稳定唯一键：'{platform}:{guid|bvid|statusId}'
  final Platform platform;    // bilibili | weibo
  final ContentKind kind;     // video | dynamic | article | repost | unknown
  final String sourceId;      // 订阅源 id（platform:uid）
  final String authorName;
  final String? authorId;
  final String? authorAvatar;
  final String title;
  final String summary;       // HTML 已转纯文本，限长
  final String? coverUrl;
  final DateTime publishedAt; // 统一 UTC；缺失时回落 fetchedAt 并打 deflatedTime 标记
  final String link;          // 原始条目链接
  final VideoRef? videoRef;   // 可播信息（B 站 bvid 等）
  final String rawGuid;
  final DateTime fetchedAt;
  final bool isNew;           // 客户端派生，不持久化到源
}
```

### 3.3 字段映射表

RSS 各路由的 `description` 结构不保证一致，因此解析器采用「结构化优先 + 通用兜底 + 原样保底」三级策略。下表中的路径以公开资料与历史样本为准，**编码时用 fixture 固化，首次联网后再校准**。

| 目标字段          | Bilibili 视频                                                       | Bilibili 动态                            | 微博                                                                                  |
| ------------- | ----------------------------------------------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------- |
| `title`       | `<title>` 视频标题                                                    | `<title>` 动态文本（常被截断）                   | `<title>` 微博正文（常被截断）                                                                |
| `link`        | `<link>` → `bilibili.com/video/BV...`                             | `<link>` → `t.bilibili.com/{id}` 或空间链接 | `<link>` → `weibo.com/{uid}/{statusId}`                                             |
| `publishedAt` | `<pubDate>`（RFC822）                                               | `<pubDate>`                            | `<pubDate>`                                                                         |
| `authorName`  | `<author>` 或 `<dc:creator>`                                       | 同左                                     | 同左                                                                                  |
| `coverUrl`    | 优先 `media:thumbnail`/`enclosure`；否则 `description` 内首个 `<img src>` | 同左（动态可能无封面，走占位图）                       | 同左（微博图多为 `wx*.sinaimg.cn`）                                                          |
| `summary`     | `description` 去 `<img>` 后 HTML→纯文本                                | 同左（可能含转发文本）                            | 同左                                                                                  |
| `id`          | `guid`，缺失则用 bvid                                                  | `guid`，缺失则用 link                       | `guid`，缺失则用 statusId                                                                |
| `videoRef`    | 从 `link` 正则提取 `BV[0-9A-Za-z]{10}`（找不到则尝试 `av(\d+)`）               | 通常无（动态内的视频另议）                          | 尝试从 `description` 正则提取 `https?://[^"'\s]*\.mp4[^"'\s]*` 或 `f.video.weibocdn.com` 链接 |
| `kind`        | 恒为 `video`                                                        | 按正文是否含转发标记判定 `dynamic`/`repost`        | 有视频链接 → `video`，否则 `dynamic`                                                        |

`ContentKind` 判定失败一律落 `unknown`，UI 按纯文本卡片渲染，绝不崩。

---

## 4. Bilibili WBI 签名实现方案

### 4.1 为什么必须做

`playurl`（`/x/player/wbi/playurl`）与评论接口在缺少有效 `w_rid`/`wts` 时会返回 `code: -352`（风控校验失败）。这就是你提到的 -352。

### 4.2 步骤

1. **取密钥**：`GET https://api.bilibili.com/x/web-interface/nav` → `data.wbi_img.img_url` / `sub_url`，各自取文件名去扩展名，拼接为 64 字符 `orig`。
   - 缓存到内存 + 文件，**TTL 12 小时**；同时提供「签名失败自动强刷一次密钥再重试」的补救路径（WBI 密钥会滚动更新）。
   - 注意：该接口即便未登录也会返回 `wbi_img`，无需登录态。
2. **混淆**：用社区公开的 64 位索引表 `mixinKeyEncTab`，`mixinKey = tab.map(i => orig[i]).take(32).join()`。
3. **签名**（纯函数，可单测）：
   - 参数按 key 字典序升序排列；
   - 每个 value 用 `Uri.encodeComponent` 后过滤掉 `!'()*` 五个字符（**这是最常见的踩坑点，不过滤会导致签名不匹配**）；
   - 拼成 `k1=v1&k2=v2...`；
   - `wts = DateTime.now().millisecondsSinceEpoch ~/ 1000`；
   - `w_rid = md5(query + mixinKey)`；
   - 最终 URL 追加 `wts` 与 `w_rid`。
4. **请求头**：真实浏览器 `User-Agent`、`Referer: https://www.bilibili.com/`、`Origin: https://www.bilibili.com`。缺 Referer 时接口常见 403。
5. **匿名设备指纹（buvid3）**：`GET /x/frontend/finger/spi` 拿 `b_3`/`b_4`，注入 Cookie。**说明**：这是 B 站下发的匿名设备标识，**不是用户账号凭证**，与「不硬编码 Cookie/Token」的约束不冲突；我会在设置页提供「匿名指纹开关」，关闭后若接口失败则明确提示原因。**绝不**要求或存储 SESSDATA 等账号凭证。


### 4.3 单测向量

`test/bili/wbi_test.dart`：固定 `orig` + 固定参数 + 冻结 `wts` → 断言 `w_rid` 等于预计算值；另加「value 含 `!()` 字符」的边界用例。这样即使 B 站改了混淆表，测试能第一时间暴露。

---

## 5. B 站视频播放与弹幕拉取流程

### 5.1 播放

```
bvid
 └─ GET /x/web-interface/view?bvid=（WBI）      → aid, cid, pages[], title, cover, owner, stat
     ├─ code != 0 → 按 bili_codes 映射中文错误（-404 稿件不可见 / -10403 需登录 / -403 权限）
     └─ 多 P 时提供选集（pages）
 └─ GET /x/player/wbi/playurl?bvid=&cid=&qn=64&fnver=0&fnval=1&fourk=1（WBI+Referer+buvid3）
     ├─ durl 非空 ──────> 通道 A：video_player 播 durl[0].url
     ├─ durl 为空 ──────> 改用 fnval=4048 再请求
     │                      └─ dash 非空 → 通道 B：media_kit（video.baseUrl + audio-file）
     └─ code = -352 ────> 强刷 WBI 密钥重试一次 → 仍失败则抛「B 站风控校验失败(352)」可读错误
```

清晰度策略：请求 `qn=64`（720P），实际以返回的最大可用 `accept_quality` 为准；用户可在播放页手动切（仅使用本次 playurl 已返回的地址，避免频繁签名请求）。**不承诺 1080P**。

错误可读性（对应你的验收项）：所有失败路径都产出 `AppError` → 播放页显示错误卡片 + 重试按钮，**绝不黑屏**。

### 5.2 弹幕

```
cid
 ├─ 通道 1（首选）GET https://api.bilibili.com/x/v1/dm/list.so?oid={cid}
 │      → 响应体为 deflate 压缩的 protobuf → archive 解压 → 手写 protobuf 字段读取
 │        （只取必要字段：进度 ms / 模式 / 字号 / 颜色 / 文本，避免引代码生成）
 ├─ 通道 2（兜底）GET https://comment.bilibili.com/{cid}.xml
 │      → 传统 <d p="进度,模式,字号,颜色,时间戳,池,uid,行号">文本</d>
 └─ 双通道都失败 → 弹幕层显示「弹幕加载失败」+ 重试，播放不受影响
```

**待实测标注**：B 站近两年持续收紧弹幕接口，通道 1/2 的可用性（是否需 wbi、是否 412）**我无法在本机验证**，因此实现为双通道 + 可插拔，并在首次联网运行时输出诊断结果到设置页「数据源状态」。

### 5.3 弹幕渲染与同步

- **同步时钟**：播放器 position 回调通常 100ms 级，直接用它驱动会让弹幕抖动。做法：记录 `(position, DateTime)` 锚点，每帧用 `wallClock` 外推 `renderTime = anchor.position + (now - anchor.wall)`；锚点更新时做 100ms 内的平滑收敛（超出阈值才硬跳，例如拖动进度条）。拖动/暂停时重设锚点。
- **性能架构**（这是 45fps 的关键，与播放器无关）：
  1. `RepaintBoundary` 隔离弹幕层，视频层不受弹幕重绘影响；
  2. 每帧重绘由 `ValueNotifier<double>`（时钟）驱动 `CustomPainter.repaint`，**不触发任何 widget rebuild / setState**；
  3. **对象池**：`DanmakuRenderItem` 预分配复用，激活数组 + 索引，避免每帧 GC；提交队列同样复用；
  4. **TextPainter 缓存**：文本布局是最大开销，按 `(文本, 字号, 粗体)` 做 LRU 缓存（上限 600 条）；命中后每帧只做位移 `paint`；
  5. **轨道调度**：按屏高/行高计算 N 条固定轨道（滚动型 4 秒穿过屏宽），维护每条轨道的「可再次发射时间」，避免重叠；同屏活跃上限可配（默认 200，上限 500）；
  6. **透明度**：用弹幕层 `saveLayer` 的整体 `Paint.alpha` 实现，**不改文字颜色**（改颜色会让 TextPainter 缓存全部失效——这是最容易踩的性能坑）；
  7. **关键词屏蔽**：加载后即过滤 + 屏蔽词变更时重建；使用简单 Aho-Corasick 或关键词 Set 前缀匹配（词量大时升 Aho-Corasick）。
- **验收测量方法**（你在有环境的机器上执行，两条都必须满足）：
  1. **必须 `flutter run --profile`**（debug 模式帧率不可信，JIT 会拖垮结论）；
  2. 打开 DevTools → Performance，或用内置帧率 HUD，播放一段弹幕密集视频（或注入 500 条测试弹幕的调试开关，我会在设置页放「弹幕压力测试」按钮），观察 UI 线程帧耗时 < 22ms（45fps 预算）。
  - 我会在设置页加「弹幕压力测试」，一键注入 500 条合成弹幕，便于你自己复现验收。

---

## 6. B 站评论接口方案

### 6.1 接口

| 用途 | 接口 | 参数要点 |
| --- | --- | --- |
| 主评论列表 | `/x/v2/reply/wbi/main` | `oid=aid`、`type=1`、`mode`（2=按时间，3=按热度）、`ps=20`、`pagination_str`（游标，来自上次响应的 `cursor.pagination_reply.next_offset`） |
| 楼中楼 | `/x/v2/reply/reply` | `oid`、`root`（主评论 rpid）、`type=1`、`ps=10`、`pn` |

两者均走 WBI 签名 + Referer + buvid3；返回 `data.replies[]`、`data.cursor.is_end`、`data.top_replies`。

### 6.2 实现要点

- 每页 20 条（`ps=20`），用游标翻页（不是 `pn` 递增，新接口用 `pagination_str`）。
- 排序切换 = 重置游标 + 重新请求（`mode` 变化）。
- 楼中楼懒加载：点击「查看 N 条回复」才请求，展开后内联渲染。
- 空列表 / `is_end` → 显示「没有更多评论了」。
- 失败 → 错误卡片 + 重试按钮（直接满足你的模块 4 验收项）。
- 渲染：列表项用 `ListView.builder` + 固定高度占位 + 头像懒加载 + `cacheExtent` 调优，目标 1.5 秒内首屏渲染（真机验证）。

### 6.3 必须标注的风险

**无登录态下 B 站评论接口近年风控收紧**：可能返回 `-352`、返回空 `replies`（只给 `top_replies`）、或要求 `buvid3`+`bili_ticket`。我**不承诺「每次都能拿到 20 条」**。
- 若实测发现必须登录态才能稳定取评论：我会如实告知，并把评论功能标注为「需要用户提供 Cookie（存入系统钥匙串）」，**绝不偷偷硬编码凭证**，也绝不用假数据填充。

---

## 7. 微博：可行性判断（不伪造）

### 7.1 微博动态聚合：**公共实例上大概率不可用**

- RSSHub 的 `/weibo/user/:uid` 路由，官方要求实例侧配置 `WEIBO_COOKIE`（微博未登录访客接口已被封，社区 issue 大量反馈 `432`/空数据/`502`）。
- `rsshub.app` 是公开共享实例，**不会**带你个人的微博 Cookie；因此该路由对公共实例基本是「返回错误或空 feed」。
- **这不是我能通过代码绕过的**（绕过 = 破解微博风控，明确在做之外）。

处理方式（诚实降级）：
1. UI 上微博源卡片显示明确状态：「该实例未配置微博 Cookie，微博源当前不可用」，而不是转圈或假数据；
2. 设置页允许把微博源单独指向「另一个实例地址」（例如你自备的、配置了 Cookie 的实例）；
3. 文档与设置页注明：微博数据需自备 RSSHub 实例（本轮不做自部署，但允许填地址）；
4. 若某实例恰好能返回数据，解析路径与 B 站完全共用（同一 `RssParser`），无需额外代码。

### 7.2 微博视频：**原型阶段不可承诺内置播放**

- RSSHub 微博条目里通常只有图片和跳转链接，**不保证**含直链 mp4。
- 我会做「尽力尝试」：正则从描述里提取 `f.video.weibocdn.com`/`*.mp4` 直链 → 尝试用播放器播（带 `Referer: https://weibo.com`）。微博 CDN 直链有时效签名与防盗链，**成功率不保证**。
- 提取不到或播放失败 → 显示封面 + 正文 + 「视频解析失败」提示（这是你允许的原型阶段行为）。
- **后续方案**（本轮不做，仅记录）：自部署 RSSHub + 微博 Cookie；或在设置页允许用户粘贴 Cookie 存入钥匙串后走接口直取。

### 7.3 微博评论：**本轮明确不做，标为「待后续实现」**

- 公开接口 `/ajax/statuses/buildComments` 需要访客 Cookie + `XSRF-TOKEN`，且风控频繁；不做。
- 用占位 UI 验证布局（骨架屏 + 「微博评论待后续实现」文案）。

---

## 8. 公共 RSSHub 降级方案

### 8.1 错误分类与处理

| 情形 | 判定 | 处理 |
| --- | --- | --- |
| 403 | 实例拒绝/需 Cookie（微博路由典型） | 不重试（重试无意义）；提示「公共实例拒绝访问，请更换实例」；若该源有缓存则展示缓存并加「可能过期」角标 |
| 429 | 限流 | 不立即重试；提示「公共 RSSHub 实例限流，请稍后重试或更换实例」（用你指定的文案）；展示缓存 |
| 5xx / 连接失败 / 超时 | 实例不稳 | 指数退避重试 1 次（起始 1.5s，仅 GET）；仍失败 → 缓存 → 错误卡片 |
| 200 但无 `<item>` | 空数据 | 若 body 含错误关键字（如 `Error`/`cookie`/`未配置`）→ 归因为「实例侧未配置该路由」；否则提示「该源暂无内容」。两种情况都不当作成功缓存 |
| XML 解析异常 | 解析失败 | 保底：记录原始 body 摘要到「数据源状态」页便于排查；UI 提示「内容解析失败」；不崩溃 |
| DNS/TLS 失败 | 网络 | 提示「网络不可用，请检查连接」 |
| 超时 | — | 连接 8s / 接收 15s（可配），超时归入网络错误 |

### 8.2 缓存策略

- 存储：`cache/rss/<sha1(url)>.json`，内容含 `body`、`fetchedAt`、`url`。
- TTL **5 分钟**（满足你的硬约束）：TTL 内直接命中不发请求；TTL 外先请求，失败才回落缓存（stale-while-error）。
- 手动「下拉刷新」= 强制跳过 TTL。
- 设置页「清除缓存」删除整个 `cache/` 目录 + 内存层，之后下次刷新必定重新请求。
- 设置页显示每个源的：上次成功时间、上次错误、命中缓存与否。

### 8.3 实例可换性

- 设置页文本框修改基地址（校验 scheme/host），保存后**下次刷新立即生效**（Provider 依赖基地址，改动即失效重建）。
- 提供「测试连接」按钮：对基地址请求一个轻量路由，展示 HTTP 状态与耗时，便于你判断实例健康度。
- 时间线/设置页固定展示声明：**「数据来源为公共 RSSHub 实例，可能不稳定」**（满足你的非功能要求）。

---

## 9. 风险点与无法实现的功能标注

### 9.1 明确标注为「本轮不承诺 / 不可行」

| 项 | 结论 | 依据 |
| --- | --- | --- |
| 微博动态聚合（公共实例） | **大概率不可用**，UI 明确提示 + 允许换实例 | RSSHub 微博路由需 `WEIBO_COOKIE`，公共实例不提供 |
| 微博视频内置播放 | **不承诺**；尽力提取直链，失败显示「视频解析失败」 | 依赖 RSS 描述是否含直链 + CDN 防盗链 |
| 微博评论 | **待后续实现**，本轮占位 UI | 接口需访客 Cookie + XSRF，风控不稳 |
| B 站评论条数保证 | **不承诺「必出 20 条」**；可能仅热门评论或返回 -352 | 无登录态风控收紧 |
| 1080P | **不承诺**，默认取可播（约 720P 或更低） | 未登录态 playurl 通常不给高码率 |
| 全部 B 站视频可播 | **不承诺**；付费/仅登录/已删除稿件（-10403/-404）会明确报错 | 接口本身限制 |
| 弹幕接口稳定性 | 双通道 + 失败提示，可用性**待联网实测** | B 站弹幕接口持续收紧 |
| 真机验收数据 | **本轮我无法实测**（无工具链、无外网）；交付测量方法 + 压力测试按钮 | 见第 0 节 |
| 依赖版本号 | 不锁死具体版本，由你环境 `pub get` 解析（我无法联网核对 pub.dev） | — |

### 9.2 其他风险

1. **WBI 混淆表变更**：签名算法是逆向实现，B 站随时可能调整 → 已做「强刷密钥重试」+ 单测向量锁定，便于快速定位。
2. **弹幕接口变更**：双通道设计 + 可插拔解析器。
3. **media_kit 体积**：通道 B 会使 APK 显著增大；可改为「仅在线安装」或全量 media_kit（见问题清单）。
4. **合规**：不使用、不存储任何账号凭证；仅使用匿名设备指纹（可关闭）；不绕过风控、不做无限重试。
5. **法律/条款**：RSSHub 为第三方开源项目，公共实例为共享资源，频繁请求可能影响他人；5 分钟缓存 + 每次刷新串行 + 失败退避即为对此的约束。

### 9.3 本轮明确不做（与你一致）

自部署 RSSHub、系统推送、离线缓存下载、多账号、应用商店发布、微博视频/评论强承诺、1080P 强承诺。

---

## 10. 编码里程碑

| 里程碑 | 内容 | 完成判据 |
| --- | --- | --- |
| M0 | 工程骨架、核心层（Dio/缓存/错误模型/存储）、单测框架 | `flutter test` 全绿（对核心纯逻辑） |
| M1 | 订阅源管理 + RSS 解析 + 统一模型 + 时间线 | 单测覆盖映射与异常；fixture 驱动 |
| M2 | WBI + view + playurl + 播放器双通道 + 错误可读 | WBI 单测全绿；错误分支单测覆盖 |
| M3 | 弹幕拉取/解析/引擎/设置项 + 压力测试开关 | 引擎逻辑单测；帧率待真机 |
| M4 | 评论（分页/排序/楼中楼/重试） | 逻辑单测 |
| M5 | 设置页 + 数据源状态 + 清缓存 + 关于声明 + 收尾 | 设置相关全部单测 |

每个里程碑结束时我会告诉你「哪些能证明、哪些必须你上真机验证」，不含糊。

---

## 11. 需要你拍板的问题

1. **构建环境**：本机无 Flutter/Android SDK 且无外网。是先只交付源码（你在别的机器上构建），还是先解决本机网络并安装工具链？
2. **微博源预期**：接受「公共实例上微博源大概率不可用 + 明确提示 + 可换实例」这个诚实降级吗？
3. **播放器**：双通道（默认，APK 较小）还是全量 media_kit（代码路径统一，APK 大 20–30MB）？
4. **是否需要我把工程推送到你的 GitHub**（zhufeng0312）以便在有网机器上 clone 构建？
