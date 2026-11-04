# Rrha 项目交接说明

> 面向：接手这个项目的人，或下一个 AI 会话。
> 目标：**只靠这份文档 + 仓库代码，就能把项目跑起来并知道去哪里改。**

最后更新：2026-11-04

---

## 1. 这是什么

Rrha 是一个 Android / Flutter 应用：把 **B 站 UP 主 + 微博博主**的内容聚合到统一时间线，
并在应用内观看 B 站视频（含弹幕与评论）、浏览图文、查看评论。

**路线已定型**：

```
App（带登录态）→ 平台官方 API        ← 当前实现
App → 公共 RSSHub 实例 → 平台        ← 已验证不可行，2026-10-22 整条链路已删除
```

不依赖任何第三方聚合服务，也不需要电脑常开。

---

## 2. 当前状态

### 2.1 已实现

| 能力 | 说明 |
| --- | --- |
| B 站扫码登录 | 二维码**本地生成**，凭据写入系统钥匙串，杀进程冷启动可恢复 |
| 统一时间线 | 「全部关注」（B 站+微博混排，游标分页）/「精选订阅」（逐源聚合）双模式，5 分钟缓存 + 已读标记 |
| B 站视频播放 | 双通道（ExoPlayer / libmpv），CDN 节点自动切换，清晰度切换、倍速、长按快进、进度记忆 |
| 弹幕 | 字号四档、透明度、同屏上限、关键词屏蔽、压力测试页（实测 83.6 fps） |
| 评论 | B 站主/子评论游标翻页 + 配图；微博评论（含子评论、多图） |
| 图片 | 九宫格、全屏预览（缩放/滑动）、保存相册 |
| 微博内容 | 原生数据源（`m.weibo.cn`），无需内置浏览器中转；视频卡片点击即播 |
| 离线 | 封面与图片磁盘缓存（LRU），飞行模式冷启动可浏览 |

### 2.2 关键指标

| 项 | 值 |
| --- | --- |
| 冷启动 | 682 ms（需求 ≤3 s） |
| 弹幕性能 | 83.6 fps（需求 ≥45 fps），最坏 62.7 fps |
| 测试 | `flutter test` 全通过（千级用例） |
| 静态检查 | `dart analyze` No issues found |

### 2.3 已知限制（如实标注，不是待办）

- 微博评论需登录态，风控触发时给可读提示，不伪造数据。
- 微博视频仅在能取到直链时可播，成功率不保证。
- 默认请求 720P，更高档位取决于账号权限。
- 需要登录（`-10403`）或已下架的稿件无法播放。

---

## 3. 目录结构

```
rrha/
├── lib/
│   ├── core/
│   │   ├── cache/           本地缓存（TTL 5 分钟）+ 图片磁盘缓存
│   │   ├── config/          全局常量（改参数看 app_config.dart）
│   │   ├── net/             Dio 配置、重试拦截器、统一错误模型
│   │   ├── storage/         ★ prefs（配置）+ secure_store（钥匙串）
│   │   └── utils/           日志、时间解析、BV 号、HTML 清洗
│   ├── data/
│   │   ├── bili/            ★ B 站客户端、WBI 签名、弹幕/评论解析、时间线源
│   │   ├── weibo/           微博客户端、解析、时间线源、评论
│   │   ├── models/          统一内容模型（ContentItem 是核心）
│   │   └── repo/            仓库层（时间线 / 视频 / 评论 / 订阅）
│   └── features/
│       ├── timeline/        时间线、卡片、详情页
│       ├── player/          ★ 播放页、双通道适配器、弹幕引擎
│       ├── comments/        评论区
│       ├── subscriptions/   订阅管理
│       └── settings/        设置
├── test/                    单元与组件测试（无网络依赖）
├── docs/                    交接与验收文档
├── tools/                   构建环境脚本 + 接口探针
└── android/                 平台壳
```

**★ 标记的是最该先看的文件。**

---

## 4. 外部依赖（不在仓库内）

| 组件 | 要求 |
| --- | --- |
| Flutter SDK | 3.47+ / Dart 3.13+，**必须纯 ASCII 路径**（见 §6.2） |
| JDK | 17+（AGP 9 要求） |
| Android SDK | `compileSdk 36`、build-tools 36 |
| Android NDK | AGP 9 在配置阶段就会校验，缺失直接失败 |
| Gradle | 9.x；国内网络需配镜像（见 §5.3） |

---

## 5. 从零跑起来

### 5.1 最短路径

```bash
flutter pub get
dart analyze            # 预期：No issues found!
flutter test            # 预期：All tests passed!
cd android && ./gradlew assembleProfile
# 产物：build/app/outputs/flutter-apk/app-profile.apk
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

Windows 上建议先 dot-source `tools/flutter-env.ps1`（见 §6）。

> ⚠️ 动过 `pubspec.yaml` 之后，`flutter test` 会强制联网跑 `pub get`。
> 网络不可达时必须改用 `flutter pub get --offline` + `flutter test --no-pub`。

### 5.2 验收要点

性能类指标（冷启动、帧率）**必须用 profile 包测**，debug 读数失真数倍。

### 5.3 `android/` 里的非标准改动（换机器需检查）

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `AndroidManifest.xml` | 补 `INTERNET` 权限 | 模板只在 debug/profile 声明，**release 不继承，会得到不能联网的 App** |
| `AndroidManifest.xml` | `EnableImpeller=false` | Impeller/Vulkan 下 libmpv 只出黑屏且不报错，见 §7.1 |
| `gradle-wrapper.properties` | `distributionUrl` 改国内镜像 | `services.gradle.org` 在部分网络下 TLS 直接中断 |
| `build.gradle.kts` / `settings.gradle.kts` | repositories 加阿里云镜像并优先 | `dl.google.com` 偶发握手失败，导致依赖下载随机中断 |
| `gradle.properties` | JVM 收紧为 `-Xmx3G` | 模板默认 8G，小内存机器必然失败 |
| `app/build.gradle.kts` | **保留** `ndkVersion = flutter.ndkVersion` | 不要删！AGP 9 配置阶段就会校验 |
| `local.properties` | 含本机绝对路径 | **已被 .gitignore 排除，换机器需重新生成** |

想改回官方源：删掉镜像行即可（各文件注释里写了官方地址）。

---

## 6. 已知的坑（换了环境一定会遇到）

### 6.1 `.ps1` 必须带 UTF-8 BOM，`.cmd` 必须纯 ASCII

PowerShell 读取**无 BOM 的 UTF-8** 时按系统 ANSI（GBK）解码，中文变乱码并破坏引号配对，
脚本解析失败——**而且连日志都不会生成**（解析先于 `Start-Transcript` 失败）。
`cmd.exe` 按 OEM 代码页读批处理，任何非 ASCII 字节都会损坏它。

写入 BOM：

```python
io.open(path, "w", encoding="utf-8-sig").write(content)
```

### 6.2 中文用户名会打断 Gradle 构建链

Java 属性实测：`sun.jnu.encoding = GBK`，导致 `user.home` 被解码成 `C:\Users\侷?`。

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| `FileNotFoundException ... .zip.lck` | Gradle 用损坏的 `user.home` 拼路径 | `GRADLE_USER_HOME` 设为纯 ASCII 目录 |
| Kotlin DSL 报 `Unresolved reference 'run'/'file'/'plugins'` | 脚本编译时 classpath 取不到，**看起来像语法错** | 同上 |

- **NTFS junction 不管用**：Gradle 会把 junction 规范化回中文真实路径，必须是真的 ASCII 目录。
- `impellerc` 在中文路径下找不到 `runtime_effect.glsl`，**Flutter SDK 也必须纯 ASCII**。

### 6.3 Flutter SDK 被打上 Low 完整性标签 → 所有 dart/flutter 命令失败

症状极具误导性：

```
Error: Flutter failed to write to a file at "...\.flutter_tool_state"
```

看起来像目录权限问题，但同目录用 PowerShell/cmd/node 都能写。

**根因**：SDK 目录带 `Low Mandatory Level` 完整性标签并继承给全部子对象。
Windows 规则是：从低完整性可执行文件启动的进程**自己也是低完整性**，于是写不了任何
Medium 完整性目录（项目目录、Temp、`C:\Users\Public` 全部 errno 5）。
唯一例外是同样带 Low 标签的 SDK 自身——所以看起来像「只有某几个路径不行」。

诊断与修复：

```powershell
icacls C:\flutter\bin\cache\dart-sdk\bin\dart.exe    # 看是否有 Low 标签
icacls C:\flutter /setintegritylevel Medium /T /C /Q # 递归修复
```

- 只改 `dart.exe` **不够**：它会拉起同目录的 `dartvm.exe`，标签要一起改；
- `C:\flutter\engine\src\**` 下大量 `Access is denied` **无碍**（引擎源码符号链接区，构建用不到）。

### 6.4 `flutter analyze` 可能崩（LSP 通道问题）

用等价的 `dart analyze` 代替。构建报文件被占用时，先停掉 Gradle daemon。

### 6.5 adb 看不见设备：ADB 接口的 MI_ 编号会变

设备管理器里 ADB Interface 状态正常，但 `adb devices` 全空，重启 server/撤销授权都无效。

**根因**：Windows 通用 `winusb.inf` **不写 `DeviceInterfaceGUIDs`**，而 `adb.exe` 只认
`{F72FE0D4-CBCB-407d-8814-9ED673D0DD6B}`。手机重新枚举后 ADB 接口可能从 `MI_01`
挪到 `MI_02`，旧的硬编码脚本就会报「找不到 ADB 接口」，极易误判成「手机没插」。

**解法**：用**按描述含 "ADB" 定位**的修复脚本，不要写死 `MI_` 编号。

> 设备管理器里 `HDB Interface` 报错是**正常的**（厂商助手通道，与 adb 无关），不要修。

### 6.6 构建/网络相关速查

- 国内网络：Gradle 用 `--offline`，pub 用 `--offline`，镜像见 §5.3；
- 代理对 Java 不生效，需 `-D` 系统属性或 `JAVA_TOOL_OPTIONS`；
- 真机排查**看 App 内「设置 → 运行日志」**（内存环形缓冲 200 条），
  profile 包的 `Log.d` 不进 logcat。

---

## 7. 实现要点与踩过的坑（结论表）

这一节是**历次真机调试的结论汇编**。过程记录已省略，只留「下次会再踩」的部分。
按主题而非时间排列。

### 7.1 播放链路

| 主题 | 结论 |
| --- | --- |
| **双通道设计** | 通道 A = `video_player`/ExoPlayer（MP4 单流）；通道 B = `media_kit`/libmpv（DASH 音视频分离）。抽象在 `player_adapter.dart` 的 `RrhaPlayer`，加新能力改这里，**不要在播放页里 if-else** |
| **任何失败必须走 `_failLoad`** | 它负责归类成可读文案、记 `stage/bvid/cid/channel/elapsed` 日志、区分可重试。绕过它就退回「黑屏无从下手」 |
| **播放器初始化必须带超时** | `initialize()` 可以长时间不返回；没有超时，`_loading` 永真 → 失败永远变不成错误。三道闸：12s / 20s / 45s，配套 `_loadGeneration` 代次丢弃迟到回调 |
| **错误视图在视频区要用紧凑版** | 完整版 `ErrorView` 会把「重试」按钮挤出 16:9 区域——真机表现为「有报错但点不到重试」 |
| **Impeller 必须关闭** | Impeller/Vulkan 下 libmpv 只出黑屏、**且不报任何错**。manifest 里 `EnableImpeller=false`，别改回去 |
| **`hwdec` 用 `no`（软解）** | `mediacodec`/`mediacodec-copy` 的 OES 纹理路径在部分新机上黑屏。软解换「一定能出画面」，代价是几个百分点 CPU |
| **流的订阅必须「补发当前值」** | 播放页是「先订阅、后 play()」，而 libmpv 在 `open()` 后就自动播放；错过那次事件会导致**按钮显示 ▶、弹幕一条不动**。用 `broadcast(onListen: _replay...)` |
| **控制栏文字颜色要显式写白** | 它叠在半透明黑渐变上，但若继承亮色主题的深色 → 看不清 |
| **`IgnorePointer` 是命门** | 控制栏的装饰渐变层必须 `IgnorePointer`，否则会吃掉全部点击（曾因此让单击/双击完全失效） |
| **手势层叠顺序** | 长按快进、横向拖动调速、单击显隐控制栏共存时，要注意「长按后又拖动」的状态错乱 |

### 7.2 B 站接口

| 主题 | 结论 |
| --- | --- |
| **WBI 签名** | 未登录时 `-352`/`-403`，带签名后 `code=0`。签名逻辑是纯函数，有黄金单测 |
| **CDN 节点必须排序** | B 站把 `baseUrl` **一律调度到 PCDN**（`*.edge.mountaintoys.cn:4483` 手机实测 HTTP=000 超时；`*.mcdn.bilivideo.cn:8082` 时通时不通），可达的 `upos-*` 标准 CDN **只在 `backupUrl` 里**。按「标准 CDN → 其它 → PCDN」排序并在失败时自动换节点 |
| **DASH 流强制校验 Referer** | 不带 Referer → 403，带 `Referer: https://www.bilibili.com/` → 200。必须同时设 `Media.httpHeaders` 与 mpv 的 `http-header-fields` |
| **`Media.extras` 是死代码** | media_kit 1.2.6 的 `open()` 从不读 `extras`，所以 `{'audio-file': url}` **完全无效**，且 mpv 不报错（症状：有画面没声音）。必须用 mpv 的 `audio-add <url> select` 挂外部音轨 |
| **MP4 坏了 ≠ 视频坏了** | `fnval=1` 与 `fnval=4048` 是两套独立调度。通道 A 失败时应**重新取 DASH**，而不是把同一个 URL 塞给 libmpv |
| **评论 `-403` 与风控无关** | 真因是 `pagination_str` 的**字节形态**：带空格 `{"offset": ""}` 必 `-403`，紧凑 `{"offset":""}`（Dart `jsonEncode` 的产物）正常返回 |
| **弹幕接口返回裸 deflate XML** | 不是历史文档说的 protobuf。`parseAuto` 自动识别；`dm/list.so` 与 `comment.bilibili.com/{cid}.xml` 同源 |
| **「0 条弹幕」不是错误** | 冷门稿件/UP 关闭弹幕确实为 0。要区分「接口成功返回空集」与「接口失败」 |
| **动态评论 oid 不能凑** | 用 `basic.comment_id_str` + `comment_type`（视频 1 / 图文 11 / 转发 17），拿动态 id 去凑只会 `-404` |
| **头像字段** | 时间线卡片的 `authorAvatar` 要由 `bili_content_parser.dart` 填，`videoInfo()` 的 `ownerAvatar` 卡片拿不到 |

### 7.3 微博

| 主题 | 结论 |
| --- | --- |
| **432 的真因是 cookie 域不匹配** | 游客票据下发的 `SUB` 落在 **`.weibo.com`**，而目标是 **`m.weibo.cn`**——根本不会送达。不是 TLS 指纹，也不是接口级封禁 |
| **必须走 `m.weibo.cn`** | `weibo.com/ajax/*` 需要登录态 + XSRF，风控更严 |
| **子评论可能内嵌且只有 2 条** | 不是 UI 截断，是接口本来就只给这么多；要完整展开需额外请求 |
| **视频直链零样本** | 解析器该分支为**防御性实现**，真机上没遇到过 `media_info` 有值的情况，不要假设能用 |
| **评论配图要单独解析** | `text` 里的图片是 HTML 片段，需提取 URL 后才能渲染 |

### 7.4 界面

| 主题 | 结论 |
| --- | --- |
| **亮色化是全域改动** | 散落的硬编码色值在深色下看不出问题，转亮就是「白底白字」。配色集中在 `lib/core/theme/app_colors.dart` |
| **黑底只留给沉浸式内容** | 视频区、全屏看图、压测页保持黑底，其余一律白底深字 |
| **列表项禁用 `Opacity`** | 会触发离屏合成，几十张卡片滚动必掉帧。半透明用 `Color.withValues(alpha:)` |
| **`ClipRRect` 只包图片本身** | 包整卡大面积内容会拖慢绘制 |
| **图片解码必须给 `cacheWidth`** | 9 张原图按原尺寸解码直接吃光内存，滚动时被系统杀 |
| **卡片点击要按内容类型分流** | 视频卡点封面应进播放页；若一律 `_openGallery`，用户点视频只能看到一张大图 |
| **验收要按「热区/浮层」逐个看** | 测「卡片能不能打开视频」时点文字区会漏掉封面被劫持；测「亮色下看不清」时只看画面会漏掉浮层文字 |

### 7.5 数据与状态

| 主题 | 结论 |
| --- | --- |
| **登录态不能决定 provider 存不存在** | 否则登录动作会连带重建时间线 provider，已加载内容被清空（表现为「登录之后反而变空」） |
| **两种时间线模式要分开存快照** | 切模式时若不清空 `items`，两种模式的 `sourceId` 语义不同，会导致已读标记与去重失效；正确做法是**按模式各存一份快照**，切回来先渲染快照再静默刷新 |
| **缓存原始 JSON，不缓存模型** | 解析规则升级后旧缓存仍可用 |
| **切清晰度要记住播放位置** | 重建播放器后不 `seek` 回去，用户会被踢回开头 |
| **`playurl` 缓存键要含 `qn`** | 漏了它会导致「切清晰度点了没反应」 |
| **进度落盘不要放在 `dispose()` 里用 `ref`** | 会抛 `Cannot use "ref" after the widget was disposed`，功能静默失效 |

### 7.6 关于 RSSHub（已删除）

2026-10-22 整条链路移除。原因不是「不好用」，而是**它从官方接口落地那天起就是不可达死代码**：
`Platform` 只有 `bilibili`/`weibo` 两个值，`_fetchOne()` 前两个分支已把它们全部 return，
第三个「拼 RSSHub 路由拉 XML」的分支从未执行。公共实例本身也早已全部不可用。

`TimelineRepository._fetchOne()` 现在是穷尽 `switch`——将来新增平台时编译器会直接报错，
不会再出现「悄悄掉进某条没人认识的兜底路径」。

---

## 8. 安全约定（重要）

1. **任何 Cookie / Token 只能写入系统钥匙串**，不得写入 SharedPreferences、日志或源码。
   App 侧唯一入口是 `lib/core/storage/bili_credential_store.dart`；
   `BiliSession` 刻意**不实现 `toString()`**，对外只暴露 `maskedSummary`（末 4 位）。
2. `.gitignore` 已排除 `**/session.json`、`**/cookies.json` 等凭据文件名。
3. 登录凭据的边界：只存在设备钥匙串（Android Keystore）；只在内存中拼进请求头；
   不进日志、不进异常 detail；退出登录立即删除。
4. 探针脚本的凭据在**项目外**（`tools/` 下的脚本从外部路径读取），
   **不要复制进工作区**。
5. 登录二维码**必须本地生成**。**绝不能用在线二维码服务**——那等于把登录入口交给第三方。
6. **不要为了「跑通」而绕过平台风控**（伪造 token、批量换 UA 重试等）。

---

## 9. 开发文档索引

| 文档 | 内容 |
| --- | --- |
| [ACCEPTANCE.md](ACCEPTANCE.md) | 真机验收报告 |
| [COLLAB_PLAN.md](COLLAB_PLAN.md) | 多会话协作分工与冲突控制 |
| [BILI_HANDOFF.md](BILI_HANDOFF.md) | B 站模块：能力清单、缺口优先级、硬性契约 |
| [WEIBO_HANDOFF.md](WEIBO_HANDOFF.md) | 微博模块：接口探针与结案结论 |
| [UI_HANDOFF.md](UI_HANDOFF.md) | 界面规范（亮色主题、卡片排版）与实现路线 |
| [ANDROID.md](ANDROID.md) | 平台壳说明 |
| [LIVE_CHECK.md](LIVE_CHECK.md) | 线上接口复核清单 |

---

## 10. 接手后建议的动作顺序

1. 读本文件 + [README](../README.md)，跑 `dart analyze` / `flutter test` 确认基线；
2. 按 §6 检查环境（中文路径、SDK 完整性、adb），**这几条不通过后面全是白折腾**；
3. 想做功能 → 先看对应模块的 `*_HANDOFF.md`（里面写了哪些字段现成可用、哪些是坑）；
4. 改完必须跑三条门槛 + **真机验证**：UI 改动截图，数据改动贴探针原始响应。
   「我改了所以应该好了」在本项目历史上被证明不可靠。
