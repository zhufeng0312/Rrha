# Rrha 真机验收报告

> **相关文档**：[HANDOVER.md](HANDOVER.md) —— 项目交接说明（当前状态、环境要求、
> 下一步计划）。本报告记录的是 **2026-10-14 真机验收**的结果与**已修复的 5 个缺陷**。
>
> 注意：本报告 §5.1「公共 RSSHub 不可用」的结论直接促成了后来的架构转向
> （改为「App 内登录 + 直连官方 API」），转向的可行性验证见 HANDOVER §2.2。

**验收设备**：华为 P40 Pro（`ELS-AN00`，Kirin 990，HarmonyOS 4.0.0 / Android 12 / API 31，arm64-v8a，1200×2640 @530dpi）
**验收版本**：profile 构建（`flutter build apk --profile`），Non-debuggable，性能读数有参考价值
**验收时间**：2026-10-14
**APK**：`build/app/outputs/flutter-apk/app-profile.apk`，137.6 MB（含 arm64 原生库）

> 为什么用 profile 而不是 debug：debug 模式走 JIT，弹幕与启动读数会失真数倍，
> 对「500 条 ≥45fps」「3 秒内起播」这两个验收项没有参考价值。

---

## 一、验收结论速览

| # | 验收项 | 需求 | 实测 | 结论 |
| --- | --- | --- | --- | --- |
| 1 | 冷启动 | ≤3 s | **682 ms**（三次：962 / 691 / 682） | ✅ 通过 |
| 2 | 弹幕 500 条帧率 | ≥45 fps | **83.6 fps**（默认字号）<br>**62.7 fps**（最坏情况） | ✅ 通过（修复后） |
| 3 | B 站视频内嵌播放 | 可播放 | **可播放**（自动回退通道 B） | ✅ 通过（修复后） |
| 4 | 弹幕加载与渲染 | 可加载渲染 | **3600 条加载并在屏上滚动** | ✅ 通过（修复后） |
| 5 | 评论：排序 | 热度/时间 | 两个 tab 均可切换生效 | ✅ 通过 |
| 6 | 评论：嵌套回复 | 可展开 | 「查看 N 条回复」可展开/收起 | ✅ 通过 |
| 7 | 评论：每页 ≥20 条 | ≥20 | 分页逻辑为 20/页；**实际条数受接口限制** | ⚠️ 见 §5 |
| 8 | 公共 RSSHub 取数 | 稳定可用 | **不可用**（403 挑战 / 502） | ❌ 不通过（环境限制）|
| 9 | 本地缓存 ≥5 min | ≥5 min | 代码为 5 min，**未做静置实测** | ⚠️ 见 §7 |
| 10 | 错误不崩溃 | 不崩溃 | 403/502/空/超时均有可读文案 | ✅ 通过 |

**单元测试**：160 个全部通过（原 154 + 本轮新增 6）
**静态检查**：`dart analyze` → `No issues found!`

---

## 二、核心验收项实测数据

### 2.1 冷启动

用 `adb shell am start -W` 测量（`TotalTime` 为 Activity 完全绘制耗时）：

| 次数 | TotalTime | WaitTime | LaunchState |
| --- | --- | --- | --- |
| 第 1 次（含首次初始化） | 962 ms | 980 ms | COLD |
| 第 2 次 | 691 ms | 695 ms | COLD |
| 第 3 次 | 682 ms | 688 ms | COLD |

**结论**：稳定在 ~0.7 s，对 3 s 的指标有约 4 倍余量。无 ANR、无崩溃。

### 2.2 弹幕帧率（本轮最大产出）

应用内置了「弹幕压力测试」页（设置 → 弹幕压力测试），用
`SchedulerBinding.addTimingsCallback` 统计 `FrameTiming.totalSpan`，实时显示帧率。

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| 默认字号（1.00x，同屏 41 条 / 11 轨道） | **8.7 fps** · 114.53 ms/帧 ❌ | **83.6 fps** · 11.97 ms/帧 ✅ |
| 最坏情况（0.50x 字号，同屏 72 条 / 23 轨道） | — | **62.7 fps** · 15.94 ms/帧 ✅ |

**提升约 9.6 倍**，两种场景都远超 45 fps。

**根因**：弹幕文字样式里用了 `Shadow(blurRadius: 2.5)`。逐条文本做高斯模糊
需要离屏合成，成本随条数线性放大 —— 以 8.7 fps / 54 条折算约 **2.3 ms/条**，
正是模糊填充率的量级。改为零模糊的偏移阴影（`Shadow(offset: Offset(1.5, 1.5))`）
后，绘制退化为「同一段文本多画一遍」，保留描边观感但完全避开模糊。

**关于「500 条」的口径**：屏幕上实际同时存在的条数由
`画布高度 ÷ 行高(字号×1.25) ≈ 14 条滚动轨道` 决定，轨道占满后按 B 站行为丢弃。
因此 500 条是**弹幕流总量**而非同屏条数。为避免只测一个宽松场景，压力测试页
新增了**字号滑杆**（0.5x ~ 1.5x）用于逼近最坏情况 —— 上面的 62.7 fps 就是
把轨道数逼到 23 条时测出来的。

### 2.3 B 站播放 / 弹幕 / 评论

自检入口：设置 → **播放链路自检**（固定 BV 号直连播放页，不经过 RSSHub）。

| 链路 | 结果 | 证据 |
| --- | --- | --- |
| 视频元数据 | ✅ | 标题 / UP主 / 时长 / 播放量 / 弹幕数正确 |
| WBI 签名 | ✅ | `view` 接口正常返回，说明签名被 B 站接受 |
| 视频播放 | ✅ | 画面渲染，进度推进 `00:14 / 24:38`、`01:34 / 29:54` |
| 弹幕加载 | ✅ | 角标显示「弹幕 3600」 |
| 弹幕渲染 | ✅ | 屏上可见《通缉令》《遥想公瑾当年》「我做了个很长的梦」等滚动弹幕 |
| 评论列表 | ✅ | 头像 / 用户名 / 内容 / 时间 / 点赞数完整 |
| 评论排序 | ✅ | 「热度 / 时间」两个 tab |
| 嵌套回复 | ✅ | 「查看 23 条回复」「收起回复」可展开 |

---

## 三、已修复项清单

本轮真机验收共发现并修复 **5 个缺陷**，其中 2 个是会导致崩溃或完全不可用的严重问题。

### 修复 1（严重）｜弹幕帧率只有 8.7 fps，远低于 45 fps 验收线

- **文件**：`lib/features/player/danmaku/danmaku_engine.dart` `_styleFor()`
- **现象**：500 条弹幕压力测试仅 8.7 fps / 114.53 ms 每帧，同屏仅约 54 条
- **根因**：`Shadow(blurRadius: 2.5)` 让每条弹幕都触发高斯模糊离屏合成
- **修复**：改为零模糊偏移阴影 `Shadow(color: Color(0xCC000000), offset: Offset(1.5, 1.5))`
- **效果**：8.7 fps → **83.6 fps**（默认字号）、**62.7 fps**（最坏情况）
- **回归保护**：代码注释明确写了「不要改回带 blurRadius 的阴影，除非先复测压力测试页帧率」

### 修复 2（严重）｜华为设备上视频完全无法播放

- **文件**：`lib/features/player/player_page.dart` `_preparePlayer()`、`lib/features/player/player_adapter.dart`
- **现象**：`PlatformException(VideoError, … MediaCodecVideoRenderer error)`
- **日志根因**：
  ```
  Decoder init failed: OMX.hisi.video.decoder.avc
    Format(video/avc, avc1.640028, 1280x720, 30fps)  ← format_supported=YES
  Caused by: java.lang.IllegalStateException
      at android.media.MediaCodec.native_stop(Native Method)
      at AsynchronousMediaCodecAdapter.release(...)
  ```
  格式本身被判定为可用，但海思硬件解码器与 ExoPlayer 异步 MediaCodec 适配器
  在 `native_stop` 处抛异常。**这是设备/ROM 层缺陷，应用侧无法通过参数绕开。**
- **修复**：复用工程既有的双通道设计 —— 通道 A（ExoPlayer）初始化失败时，
  自动回退到通道 B（libmpv）。libmpv 自带解码实现、不依赖系统 MediaCodec。
  新增 `createMpvFallbackFor()`；界面标签如实显示「通道B(libmpv 回退 qn=…)」，
  避免显示「通道A」误导排查。
- **效果**：视频正常播放并推进进度
- **说明**：这不是降级妥协，双通道本来就是为此设计的，缺的只是失败自动切换

### 修复 3（严重）｜明文 XML 会让解析器试图分配 25 GB 内存

- **文件**：`lib/data/bili/danmaku_parser.dart` `maybeInflate()`
- **发现方式**：写单元测试时，未压缩的 XML 输入直接把测试进程打爆：
  ```
  Shell: Exhausted heap space, trying to allocate 25769738272 bytes.
  [D][DanmakuParser] raw-deflate 解压失败（继续尝试其它方式）：Out of Memory
  ```
  该用例跑了近 3 分钟才失败。
- **根因**：`maybeInflate()` 无条件把输入丢给裸 deflate 解压器。
  明文 XML 的开头字节（`<?xml`）会被解析成荒谬的 deflate 长度字段。
- **真实触发条件**：CDN/中间层漏发 `Content-Encoding` 时会直接返回明文 XML，
  此时应用会 OOM 崩溃 —— 直接违反「解析失败不得崩溃」的需求。
- **修复**：新增 `_looksLikeText()` 做前置短路（首 16 字节全可打印、
  或以 `<` / UTF-8 BOM+`<` 开头即判定为明文），命中则跳过解压。
- **效果**：OOM 消除；相关测试从「跑 3 分钟失败」变为瞬时通过

### 修复 4｜0 条弹幕被误报为「弹幕加载失败」

- **文件**：`lib/data/bili/bili_client.dart` `danmaku()`
- **现象**：播放页左上角常驻红色「弹幕加载失败」+ 重试按钮，但弹幕本就不存在
- **根因**：视频没有弹幕时，两个接口都返回 HTTP 200 + 141 B 的**合法空 XML 骨架**：
  ```xml
  <?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com</chatserver>
  <chatid>34866269840</chatid><mission>0</mission><maxlimit>3000</maxlimit>…</i>
  ```
  旧实现把「解析成功但 0 条」也计入 failures，最终抛 `AppErrorKind.empty`
  （文案「弹幕加载失败」）。
- **修复**：区分「接口成功返回空集」与「接口失败」。只要有一条通道成功
  完成了请求+解析，0 条就是真实结果（返回空列表，UI 显示 0 弹幕）；
  两条通道都请求/解析失败才抛错。
- **回归测试**：新增 `test/bili/danmaku_empty_test.dart`（6 个用例）锁定契约

### 修复 5｜release 包完全没有网络权限

- **文件**：`android/app/src/main/AndroidManifest.xml`
- **问题**：`flutter create` 只在 `src/debug` 与 `src/profile` 的 manifest 里声明
  `INTERNET`（那是给 hot reload 用的），**release 包不会继承**。
  直接构建 release 会得到一个完全无法联网的 App。
- **修复**：在 main manifest 显式声明 `INTERNET` 与 `ACCESS_NETWORK_STATE`

---

## 四、为通过验收而做的改动

以下改动不是修 bug，而是让「不可验证的东西变得可验证」。

### 4.1 设置页新增「播放链路自检」入口（**新增 UI，需要你确认是否保留**）

- **文件**：`lib/features/settings/settings_page.dart`
- **动机**：播放页在正常路径下只能从**时间线卡片**进入，而时间线依赖 RSSHub。
  公共实例不可用时，播放/弹幕/评论这三条链路**完全测不到** —— 本轮就卡在这里。
- **做法**：设置页增加一个 ListTile，用固定 BV 号直接打开播放页。
  当前指向 `BV1QmpE6aEA7`（排行榜榜首，3.9 万条弹幕），
  便于同时验证「播放」与「弹幕渲染」。
- **如果你不希望产品里保留这个入口，删掉该 ListTile + 常量 + import 即可。**

### 4.2 弹幕压力测试页新增字号滑杆

- **文件**：`lib/features/player/danmaku_stress_test_page.dart`
- **动机**：只测默认字号会得到偏宽松的结论。字号决定轨道数，轨道数决定同屏密度。
- **做法**：新增 0.5x ~ 1.5x 滑杆 + 说明文字，可逼近最坏情况。

---

## 五、未通过 / 受限项（诚实标注）

### 5.1 ❌ 公共 RSSHub 实例不可用（本轮无法在应用侧解决）

这是**环境限制，不是代码缺陷**，且本轮做了对照实验来证明：

| 实例 | 电脑端（经代理） | 手机端（直连） |
| --- | --- | --- |
| `rsshub.app` | **403** + Cloudflare `Just a moment...` 挑战页 | DNS 解析失败 |
| `rsshub-balancer.virworks.moe` | **200**，33155 B 完整 RSS | **502xx** |

- 电脑端同一个实例、同一条路由 `/bilibili/user/video/2267573` 返回 200 + 完整 RSS，
  手机端却报 502 → 证明**实例本身是好的**，问题在手机的网络路径。
- 手机到该实例所在 Cloudflare IP 的 ping 有 **50% 丢包、350 ms** 延迟，
  链路质量很差。
- 尝试给手机设全局 HTTP 代理指向电脑（`10.42.181.89:7897`）**无效** ——
  因为 **Dart 的 `HttpClient` 不读 Android 系统代理设置**（只有 OkHttp 会读）。
  该方案已放弃，未在代码中保留任何残余改动。

**结论**：与上一轮 README 的实测结论一致 —— **公共 RSSHub 无法稳定提供数据，
必须自建实例**。应用侧的降级表现是合格的：给出「实例返回服务器错误（502xx），
请稍后重试或更换实例」+ 重试按钮，**未崩溃**。

### 5.2 ⚠️ 评论条数受 B 站接口限制

- 需求是「评论 ≥20 条/页」，分页逻辑确实是 20 条/页（`AppConfig.commentPageSize = 20`）。
- 但 **无登录态下 B 站只返回少量主评论**：本轮两个测试稿件的界面分别显示
  「评论 3」，且其中一条还带「查看 23 条回复」。
- 界面上的「评论 N」是**已加载条数**（`displayCount`），不是稿件评论总数。
- 这与 README 既有结论一致（§5「B 站评论：无登录态可用，但数据受限」）。
- **要真正验收「≥20 条/页」，需要一个评论数足够多且接口愿意返回的稿件，
  或提供登录态。** 本轮未能构造出该条件，如实记录。

### 5.3 ⚠️ 微博链路未做真机验证

- 微博路由要求实例侧配置 `WEIBO_COOKIE`，公共实例普遍不可用（本轮实测 403）。
- 因此微博订阅、微博评论在本轮**没有真实数据可测**，不做通过性声明。

---

## 六、构建环境问题（首次构建踩坑记录）

本工程原本**完全无法构建**，原因是本机开发环境的三个特殊点。这些都已解决，
记录在此以便换机器时快速复现。

### 6.1 中文用户名导致 JVM 路径损坏（最隐蔽的一个）

Java 属性实测：
```
file.encoding    = UTF-8
native.encoding  = GBK
sun.jnu.encoding = GBK          ← 关键
user.home        = C:\Users\???  ← 已损坏，中文用户名被 GBK 错误解码
```

Gradle 用损坏的 `user.home` 拼路径，直接 `FileNotFoundException`；
即使绕过，Kotlin DSL 脚本编译也会因 classpath 取不到而报一堆
`Unresolved reference 'run' / 'file' / 'plugins'`（看起来像脚本语法错，实为环境错）。

**解法**：把 Gradle 相关目录全部放到**纯 ASCII 路径**：
- `GRADLE_USER_HOME=C:\gradle-home`
- `-Djava.io.tmpdir=C:\gradle-home\tmp`

注意：**NTFS junction 不够**（`C:\rrha-ws` → 中文真实路径），
Gradle 会规范化回真实路径，仍然失败。必须是真的 ASCII 目录。

`server` 侧另有坑：`flutter pub get` / `dart pub get` 在**工作区之外**的目录
会因文件沙箱被拒（`OS Error 拒绝访问, errno = 5`），所以 Dart 的
`TEMP`/`APPDATA`/`PUB_CACHE` 仍留在工作区内即可，只有 JVM 相关必须 ASCII。

### 6.2 `services.gradle.org` 在本网络不可达

- 现象：`javax.net.ssl.SSLHandshakeException: Remote host terminated the handshake`
- 特点：**配代理也无效**（`JAVA_TOOL_OPTIONS` 已被 JVM 正确拾取，日志有回显），
  该域名本身被阻断。
- 实测：`mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip` → **200，0.10 s**
- **修复**：`gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl`
  改为腾讯云镜像（注释里保留了改回官方源的写法）。

### 6.3 部分 Maven 依赖会随机 TLS 中断

- 现象：构建跑到 270 个任务时，`flutter_secure_storage:extractProfileAnnotations`
  因 `play-sdk-proto-32.1.0.jar` 下载失败而中断：
  `Remote host terminated the handshake`（`dl.google.com`）
- **修复**：`android/build.gradle.kts` 与 `android/settings.gradle.kts` 的
  repositories 加入阿里云镜像并置于**优先**位置，官方源保留兜底。
  实测 `maven.aliyun.com/repository/google` 取同一 jar 直连 **0.17 s**。
- 加镜像后构建稳定：`BUILD SUCCESSFUL in 2m 51s`（首次全量）/ 40~60 s（增量）

### 6.4 其他

- **内存**：本机总 15.7 GB、构建时可用常只有 3~4 GB。Flutter 模板默认
  `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G` 过大，
  已在 `android/gradle.properties` 收紧为 `-Xmx3G -XX:MaxMetaspaceSize=1G`，
  并补 `kotlin.daemon.jvmargs=-Xmx1G`。
- **NDK**：`ndkVersion = flutter.ndkVersion` **不能删**。AGP 9 在配置阶段就校验
  NDK 完整性，缺失会以 `[CXX1101] did not have a source.properties file` 失败。
  AGP 会自动安装 NDK r28c（28.2.13676358，约 2.1 GB）。
- **`test/widget_test.dart`**：`flutter create` 会生成一个引用 `MyApp` 的模板测试，
  与本工程不符，会导致测试套件编译失败 —— 已删除。

---

## 七、未完成的验收项

| 项 | 状态 | 原因 |
| --- | --- | --- |
| 本地缓存 ≥5 min | **未实测** | 需要静置 5 分钟后再刷新对比，本轮时间用在了排查上面几个阻塞项。代码层已配置 `AppConfig.rssCacheTtl = 5 min`，且有 stale-while-error 降级 |
| 时间线聚合（B站+微博） | **未实测** | 依赖 RSSHub，实例不可用（§5.1） |
| 评论 ≥20 条/页 | **部分验证** | 分页逻辑正确，但接口无登录态下不返回足够条数（§5.2） |
| 微博播放/评论 | **未验证** | 无可用实例（§5.3） |
| 500 条同屏（而非流量总量） | **口径已澄清** | 受轨道数物理限制，已通过字号滑杆逼近最坏情况（§2.2） |

---

## 八、改动文件总览

### 源码（7 个文件修改）

| 文件 | 改动 |
| --- | --- |
| `lib/features/player/danmaku/danmaku_engine.dart` | 修复 1：模糊阴影 → 偏移阴影 |
| `lib/features/player/player_page.dart` | 修复 2：通道回退；标签如实标注 |
| `lib/features/player/player_adapter.dart` | 修复 2：新增 `createMpvFallbackFor()` |
| `lib/data/bili/danmaku_parser.dart` | 修复 3：明文短路，防 OOM |
| `lib/data/bili/bili_client.dart` | 修复 4：空弹幕不算失败 |
| `lib/features/player/danmaku_stress_test_page.dart` | §4.2：字号滑杆 |
| `lib/features/settings/settings_page.dart` | §4.1：播放链路自检入口 |

### 测试（1 个新增）

| 文件 | 内容 |
| --- | --- |
| `test/bili/danmaku_empty_test.dart` | **新增** 6 个用例，锁定「空弹幕不是错误」契约 |

### 构建配置（由 `flutter create` 生成后按 §6 调整）

| 文件 | 改动 |
| --- | --- |
| `android/app/src/main/AndroidManifest.xml` | 修复 5：补 `INTERNET` 权限 |
| `android/gradle/wrapper/gradle-wrapper.properties` | §6.2：腾讯云 Gradle 镜像 |
| `android/build.gradle.kts` | §6.3：阿里云 Maven 镜像 |
| `android/settings.gradle.kts` | §6.3：阿里云 Maven 镜像 |
| `android/gradle.properties` | §6.4：JVM 内存收紧 |
| `android/app/build.gradle.kts` | §6.4：保留 `ndkVersion`（模板原样）+ 说明注释 |

---

## 九、复现验收的完整命令

```bash
# 环境（本机特殊，见 §6.1）
export JAVA_HOME=/c/jdk
export GRADLE_USER_HOME=/c/gradle-home          # 必须纯 ASCII
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=C:\gradle-home\tmp"

cd rrha
flutter pub get
dart analyze                     # 预期：No issues found!
flutter test                     # 预期：All tests passed!（160 个）

# 构建 profile 包（性能验收必须用 profile/release）
cd android && ./gradlew assembleProfile
adb install -r ../build/app/outputs/flutter-apk/app-profile.apk

# 冷启动测量
adb shell am start -W -n com.rrha.rrha/.MainActivity     # 看 TotalTime

# 弹幕帧率：App 内 设置 → 弹幕压力测试，稳定 10 s 后读数
# 播放链路：App 内 设置 → 播放链路自检
```

---

## 十、结论

**能通过验收的部分**：冷启动（682 ms）、弹幕帧率（83.6 / 62.7 fps）、
B 站播放（含华为机型回退）、弹幕加载渲染（3600 条）、评论展示与排序与嵌套回复、
错误降级不崩溃。160 个单元测试通过，静态检查零问题。

**不能通过的部分**：**公共 RSSHub 实例不可用** —— 这是本轮最关键的结论，
且与上一轮一致。它不是代码能修的，**必须自建 RSSHub 实例**才能让订阅聚合
这条主链路真正跑起来。这一条我在上一轮就已明确说明，本轮用「电脑端 200 /
手机端 502」的对照实验再次确认。

**需要你决定的事**：
1. 设置页的「播放链路自检」入口是否保留（§4.1）？
2. 是否要我继续补做「5 分钟缓存」与「评论 ≥20 条/页」的验收（§7）？
3. 是否需要我给出自建 RSSHub 的最小部署步骤，好让订阅聚合链路真正可验收？
