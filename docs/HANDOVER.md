# Rrha 项目交接说明

> 本文档面向「接手这个项目的人（或下一个 AI 会话）」。  
> 目标：**在全新工作区里，只靠这份文档就能把项目跑起来并知道下一步做什么。**

最后更新：2026-10-15（新工作区跑通全部自检；§7.4 评论 `-403` 悬案已定论；新增 §6.4 环境坑）

---

## 1. 这是什么

Rrha 是一个 Android / Flutter 应用，把 **B 站 UP 主 + 微博博主**的内容聚合到统一时间线，  
并支持在应用内观看 B 站视频（含弹幕与评论）。

**当前正在经历一次架构转向**（见 §7）：

```
旧路线：App → 公共 RSSHub 实例 → 平台        ← 已验证不可行，放弃
新路线：App（带登录态）→ 平台官方 API          ← 阶段 0 已验证可行，待实现
```

---

## 2. 当前状态总览

### 2.1 已完成并通过真机验证

| 能力         | 状态                         | 证据                |
| ---------- | -------------------------- | ----------------- |
| 冷启动        | ✅ 682 ms（需求 ≤3 s）          | 华为 P40 Pro 实测三次取样 |
| 弹幕性能       | ✅ **83.6 fps**（需求 ≥45 fps） | 压力测试页，500 条注入     |
| 弹幕性能（最坏情况） | ✅ 62.7 fps                 | 0.5x 字号、同屏 72 条   |
| B 站视频播放    | ✅ 可播放                      | 含华为机型通道回退         |
| 弹幕加载与渲染    | ✅ 3600 条滚动                 | 高弹幕量稿件实测          |
| 评论展示       | ✅ 排序 + 嵌套回复                | 真机截图              |
| 单元测试       | ✅ 160 个全通过                 | `flutter test`    |
| 静态检查       | ✅ No issues found          | `dart analyze`    |

细节见 [ACCEPTANCE.md](ACCEPTANCE.md)。

### 2.2 阶段 0 可行性验证结论（2026-10-14）

针对「App 内登录 + 直连官方 API」这条新路线，已用真实登录态逐条验证：

| 验证项         | 结果                       | 说明                                                                                                                                                                                    |
| ----------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B 站扫码登录闭环   | ✅ **通过**                 | `/qrcode/generate` → 本地生成二维码 → `/qrcode/poll` 轮询 → 成功拿到 `SESSDATA` / `bili_jct` / `DedeUserID`                                                                                        |
| 关注列表        | ✅ **通过**                 | `/x/relation/followings` 返回 `code=0`，实测拉到 74 个关注                                                                                                                                      |
| WBI 签名      | ✅ **通过**                 | 未登录时 `-352`/`-403`，带签名后 `code=0`                                                                                                                                                      |
| UP 主视频列表    | ✅ 通过                     | `/x/space/wbi/arc/search` 返回 10 条                                                                                                                                                     |
| UP 主动态      | ✅ 通过                     | `/x/polymer/web-dynamic/v1/feed/space` 返回 12 条                                                                                                                                        |
| 用户信息        | ✅ 通过                     | `/x/space/wbi/acc/info`                                                                                                                                                               |
| 观看历史 / 稍后再看 | ✅ 通过                     | `/x/web-interface/history/cursor`、`/x/v2/history/toview`                                                                                                                              |
| **评论**      | ✅ **已定论**（2026-10-15 复测） | 应用内可用这点没问题；但脚本复现的 `-403` **不是 IP 风控** —— 直连与代理结果完全一致。真正的原因是 `pagination_str` 的**字节形态**：带空格 `{"offset": ""}` 必 `-403`，紧凑 `{"offset":""}`（正是 Dart `jsonEncode` 的产物）正常返回 18~20 条。详见 §7.4 |
| **微博**      | ❌ **直连被拦**               | `m.weibo.cn` API 返回 **HTTP 432**（微博风控码），连匿名公开主页时间线都拦。已按你的决定：**降级为内置 WebView 打开**                                                                                                      |

### 2.3 已知不可行（不是代码问题）

**公共 RSSHub 实例不可用**，对照实验证据：

| 实例                             | 电脑端（经代理）             | 手机端（直连）  |
| ------------------------------ | -------------------- | -------- |
| `rsshub.app`                   | 403 + Cloudflare 挑战页 | DNS 解析失败 |
| `rsshub-balancer.virworks.moe` | 200 + 完整 RSS         | 502xx    |

且 RSSHub 的 `/bilibili/followings/*`（「我关注的 UP 主」）路由**本身也需要服务端配置  
`BILIBILI_COOKIE`**，实测公共实例返回 502。所以 **RSSHub 既解决不了「电脑关机可用」，  
也免除不了登录态需求** —— 这是放弃它作为主路径的直接原因。

---

## 3. 目录结构

```
rrha/
├── lib/                        源码（50 个 Dart 文件，约 300 KB）
│   ├── core/                   基础设施
│   │   ├── cache/              本地缓存（TTL 5 分钟 + stale-while-error）
│   │   ├── config/app_config.dart   全局常量（改参数看这里）
│   │   ├── net/                Dio 配置、重试拦截器、统一错误模型
│   │   ├── storage/
│   │   │   ├── prefs.dart          SharedPreferences 封装
│   │   │   └── secure_store.dart   ★ 系统钥匙串封装，登录凭据只能走这里
│   │   └── utils/              日志、时间解析、BV 号处理、HTML 清洗
│   ├── data/                   数据层
│   │   ├── bili/               ★ B 站客户端（WBI 签名、弹幕双通道、评论解析）
│   │   ├── rss/                RSSHub 客户端 + RSS 解析（保留为「按 UID 订阅」补充）
│   │   ├── weibo/              微博客户端
│   │   ├── models/             统一内容模型
│   │   └── repo/               仓库层（时间线 / 视频 / 评论 / 订阅）
│   └── features/               界面层
│       ├── timeline/           时间线、内容卡片、详情页
│       ├── player/             ★ 播放页、双通道适配器、弹幕引擎
│       │   └── danmaku/        弹幕引擎与渲染层（性能已优化）
│       ├── comments/           评论区
│       ├── subscriptions/      订阅管理
│       └── settings/           设置页
├── test/                       11 个测试文件，160 个用例
├── docs/
│   ├── ACCEPTANCE.md           ★ 真机验收报告（含已修复项清单）
│   ├── HANDOVER.md             ← 本文件
│   ├── ANDROID.md              平台壳说明
│   ├── LIVE_CHECK.md           线上接口复核清单（可执行的 curl 步骤）
│   └── PLAN.md                 最初的实施方案
├── tools/                      开发与验证脚本
│   ├── flutter-env.ps1         ★ 构建环境脚本（dot-source 使用）
│   ├── probe_bili_login.py     ★ 阶段 0：扫码登录验证
│   ├── probe_bili_capabilities.py  ★ 阶段 0：登录态能力验证
│   ├── probe_danmaku.py        弹幕接口探测
│   ├── probe_instances.py      RSSHub 实例探测
│   ├── live_probe.py           线上接口批量探测
│   └── netcheck.py             网络连通性检查
├── android/                    平台壳（`flutter create` 生成后按 §5.3 调整）
├── dist/                       已验收的 APK（137 MB，见 §5.4）
├── .env/                       构建缓存（脚本自动创建，已被 .gitignore 排除）
├── pubspec.yaml                依赖声明
├── .gitignore                  ★ 已按本项目实际情况补齐（见 §6.1）
└── README.md                   项目总览与实测结论
```

**★ 标记的是交接时最该先看的文件。**

---

## 4. 外部依赖（不在项目内）

项目本身只有约 600 KB 源码，但构建依赖以下**项目外**的组件。  
换机器时这些都要重新准备：

| 组件          | 本机路径                               | 版本                                                                | 说明                      |
| ----------- | ---------------------------------- | ----------------------------------------------------------------- | ----------------------- |
| Flutter SDK | `C:\flutter`                       | 3.47.7 stable / Dart 3.13.5                                       | **必须纯 ASCII 路径**，见 §6.2 |
| JDK         | `C:\jdk`                           | Temurin 21.0.12.1+1 LTS                                           | AGP 9 要求 JDK 17+        |
| Android SDK | `C:\Android\sdk`                   | platform-tools 37.0.1 / platforms;android-36 / build-tools;36.0.0 |                         |
| Android NDK | `C:\Android\sdk\ndk\28.2.13676358` | r28c，约 2.1 GB                                                     | AGP 9 在配置阶段就会校验，缺失直接失败  |
| Gradle 发行版  | `C:\gradle-home\wrapper\dists`     | Gradle 9.3.1                                                      | 已从腾讯云镜像下载好              |
| 运行环境        | Node 24 / Python 3                 | —                                                                 | 仅 `tools/` 下的探测脚本需要     |

---

## 5. 从零跑起来

### 5.1 最短路径

```powershell
# 1) 进入项目
Set-Location <新工作区>\rrha

# 2) 加载构建环境（会自动探测项目根，并做环境体检）
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. .\tools\flutter-env.ps1

# 3) 拉依赖
flutter pub get

# 4) 自检
dart analyze      # 预期：No issues found!
flutter test      # 预期：All tests passed!（160 个）

# 5) 构建（性能验收必须用 profile，debug 读数会失真数倍）
cd android
.\gradlew.bat assembleProfile
# 产物：build\app\outputs\flutter-apk\app-profile.apk
```

### 5.2 装到真机

```powershell
adb install -r build\app\outputs\flutter-apk\app-profile.apk
adb shell am start -W -n com.rrha.rrha/.MainActivity   # TotalTime 即冷启动耗时
```

### 5.3 `android/` 里的非标准改动（换机器需检查）

这些不是 Flutter 模板的默认值，每处都对应一个实际踩到的坑：

| 文件                                            | 改动                                       | 原因                                                                           |
| --------------------------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------- |
| `app/src/main/AndroidManifest.xml`            | 补 `INTERNET` 权限                          | 模板只在 debug/profile 里声明，**release 包不会继承，会得到一个不能联网的 App**                      |
| `gradle/wrapper/gradle-wrapper.properties`    | `distributionUrl` 改腾讯云镜像                 | `services.gradle.org` 在本网络不可达，**配代理也无效**（TLS 握手被直接中断）                        |
| `build.gradle.kts`<br />`settings.gradle.kts` | repositories 加阿里云镜像并置于优先                 | `dl.google.com` 会偶发 `Remote host terminated the handshake`，导致随机依赖下载失败而中断整个构建 |
| `gradle.properties`                           | JVM 参数收紧为 `-Xmx3G`                       | 模板默认 `-Xmx8G`，本机总内存 15.7 GB、构建时可用常只有 3~4 GB                                  |
| `app/build.gradle.kts`                        | **保留** `ndkVersion = flutter.ndkVersion` | 不要删！AGP 9 配置阶段就校验 NDK                                                        |
| `local.properties`                            | 含本机绝对路径                                  | **已被 .gitignore 排除，换机器请重新生成**                                                |

想改回官方源：把镜像行删掉即可（各文件注释里写了官方地址）。

### 5.4 关于 `dist/` 里的 APK

| 文件                                      | 说明                                              |
| --------------------------------------- | ----------------------------------------------- |
| `rrha-0.1.0-profile-arm64.apk`（137 MB）  | **旧架构**（公共 RSSHub 原型）的验收版本，2026-10-14 通过真机验收    |
| `rrha-0.1.0-stage1-profile.apk`（118 MB） | **当前版本**：含阶段 1（扫码登录 + 凭据入钥匙串），2026-10-15 通过真机验证 |

留着是为了：任何人在任何环境都能直接装上验证，不必先配好整套构建链。

两者都被 `.gitignore` 排除（二进制不适合版本管理），需要时可重新构建：

```bash
cd android && gradlew.bat assembleProfile
```

---

## 6. 已知的坑（换了环境一定会遇到）

### 6.1 PowerShell 脚本必须带 UTF-8 BOM

本项目的 `.ps1` 里写了中文注释。PowerShell 读取**无 BOM 的 UTF-8** 时会按系统 ANSI  
代码页（GBK）解码，中文变乱码并破坏字符串引号配对，脚本直接解析失败：

```
Write-Host "`n鐜妫€鏌ラ€氳繃銆? -ForegroundColor Green
字符串缺少终止符: "
```

**`tools/flutter-env.ps1` 已写入 BOM**。如果你新增 `.ps1`，记得也加：

```python
io.open(path, "w", encoding="utf-8-sig").write(content)   # utf-8-sig 即带 BOM
```

### 6.2 中文用户名会打断 Gradle 构建链

这是本项目最隐蔽的一个坑。Java 属性实测：

```
file.encoding    = UTF-8
sun.jnu.encoding = GBK          ← 关键
user.home        = C:\Users\侷?  ← 已损坏
```

后果与解法：

| 现象                                                         | 原因                              | 解法                               |
| ---------------------------------------------------------- | ------------------------------- | -------------------------------- |
| `FileNotFoundException ... .zip.lck`                       | Gradle 用损坏的 `user.home` 拼路径     | 设 `GRADLE_USER_HOME` 到纯 ASCII 目录 |
| Kotlin DSL 报 `Unresolved reference 'run'/'file'/'plugins'` | 脚本编译时 classpath 取不到，**看起来像语法错** | 同上                               |

⚠️ **NTFS junction 不管用**：Gradle 会把 junction 规范化回中文真实路径。必须是真的  
ASCII 目录。`tools/flutter-env.ps1` 已把 `GRADLE_USER_HOME` 固定为 `C:\gradle-home`。

另外 `impellerc` 在中文路径下会找不到 `flutter/runtime_effect.glsl`，所以 **Flutter SDK  
也必须放纯 ASCII 路径**。

### 6.3 其他

- `flutter analyze` 在某些受限环境会崩（LSP 通道问题），用等价的 `dart analyze` 代替
- 构建前若报文件被占用，先 `Get-Process java | Stop-Process -Force` 停掉 Gradle daemon

### 6.4 ★ Flutter SDK 被打上 Low 完整性标签 → **所有** dart / flutter 命令都会失败

2026-10-15 在新工作区实测踩到，症状极具误导性：

```
Error: Flutter failed to write to a file at
  "D:\Rrha\.env\appdata\.flutter_tool_state". The flutter tool cannot access
  the file or directory.
```

看起来像「目录权限不足」，但同一个目录用 PowerShell / cmd / node 都能正常写入。

**真正的根因**：`C:\flutter` 被打上了 `Mandatory Label\Low Mandatory Level`  
完整性标签，并且**继承给它的全部子对象**。Windows 的规则是：从带 Low IL 标签的  
可执行文件启动的进程**自己也是低完整性**，于是写不了任何 Medium 完整性目录  
（项目目录、`C:\Windows\Temp`、`C:\Users\Public` 全部 errno 5 拒绝访问）。  
唯一的例外是同样带 Low 标签的 `C:\flutter` 自身 —— 所以现象看起来像  
「只有某几个路径不行」，很容易误判成杀软或沙箱策略。

诊断（两步就够）：

```powershell
# 1) 看可执行文件有没有 Low 标签
icacls C:\flutter\bin\cache\dart-sdk\bin\dart.exe
#    有问题的形态：... Mandatory Label\Low Mandatory Level:(I)(NW)

# 2) 让 dart 自报进程令牌：脚本里跑 Process.runSync('whoami', ['/groups'])
#    低完整性会显示：Mandatory Label\Low Mandatory Level  S-1-16-4096
#    正常应为：      Mandatory Label\Medium Mandatory Level  S-1-16-8192
```

**修复**（不需要管理员权限，实测通过）：

```powershell
icacls C:\flutter /setintegritylevel Medium /T /C /Q
# 只修 dart-sdk 也可以：1154 个文件不到 1 秒
icacls C:\flutter\bin\cache\dart-sdk /setintegritylevel Medium /T /C /Q
```

两个要点：

- **只改 `dart.exe` 不够**：dart 进程实际会拉起同目录的 `dartvm.exe`，  
  它的标签也要一起改 —— 所以直接递归改整个目录最省事；
- `C:\flutter\engine\src\**` 下约 2.3 万个文件会报 `Access is denied`，  
  **那部分无碍**（引擎源码的符号链接区），构建链用不到，不用管。

修好后 `flutter pub get` / `dart analyze` / `flutter test` 立即恢复正常。  
顺带说明：`java.exe` 实测**没有** Low 标签，所以 Gradle / Android 侧一直是好的 ——  
这个坑只会以「Dart 相关命令全灭」的形态出现。

> 换机器时如果又出现同样症状，先跑上面第 1 步，十有八九是同一个原因。

### 6.5 ★ 改过 `pubspec.yaml` 版本号之后，`flutter test` 会强制联网并失败

2026-10-17 阶段 3 出包后实测踩到：

```
Downloading packages...
Connection terminated during handshake
Failed to update packages.
[exit code: 1]
```

**原因**：`flutter test` / `flutter build` 内部会检查 `pubspec.yaml` 与 `.dart_tool/package_config.json`
的时间戳；一旦发现 `pubspec.yaml` 更新（哪怕只改 `version:`），就**自动跑一次 `pub get`**。
而本机的 `pub.dev` 直连与代理**都不可达**（实测返回 000），于是握手失败。

**解法**（按顺序试）：

```powershell
# 1) 先用本地 pub 缓存把依赖解析好（不需要网络）
flutter pub get --offline        # 预期：Got dependencies!

# 2) 之后所有测试/构建命令都加 --no-pub，跳过工具自己的联网解析
flutter test --no-pub            # 预期：All tests passed!
```

`gradlew assembleProfile --offline` 不受此影响（它走 Gradle 缓存，不碰 pub.dev）。

> 记法：**本工程只要动过 `pubspec.yaml`，就一律用 `--no-pub` / `--offline`**。

---

### 6.6 ★ adb 看不见设备：ADB 接口的 MI_ 编号会变，旧修复脚本会失灵

2026-10-19 实测踩到，症状与 §6.1 无关、也与「驱动没装」无关：

```
设备管理器里 ADB Interface 正常（Status OK，绑 winusb.inf）
但 adb devices 列表全空，重启 adb server / 撤销授权重插 均无效
```

**根因**：Windows 用通用 `winusb.inf` 给该接口装驱动，而通用 INF **不写 `DeviceInterfaceGUIDs`**。
`adb.exe` 只认两枚 GUID（反汇编确认）：`{F72FE0D4-CBCB-407d-8814-9ED673D0DD6B}`
与 `{A5DCBF10-…}`，后者只注册在复合设备父节点上、打不开 ADB 接口。
所以补的就是前者。

**这次的新情况**：手机重新枚举后，ADB 接口从 **`MI_01` 挪到了 `MI_02`**
（`MI_01` 变成了「USB 大容量存储设备」）。

| 接口 | GUID 注册 |
| --- | --- |
| `MI_01`（历史，现在是大容量存储） | 有 `f72fe0d4` ✅（上次修复留下的） |
| **`MI_02`（当前 ADB 接口）** | **缺 `f72fe0d4`** ❌ → adb 枚举不到 |

旧的 `C:\Androidix-adb-guid.ps1` **硬编码了 `MI_01`**，于是直接报
`ADB INTERFACE NOT FOUND` 退出 —— 而真正的 ADB 接口好好挂在新编号上，极易误判成「手机没插」。

**解法**：用 `C:\Androidix-adb-guid-auto.cmd`（右键以管理员身份运行）。
它**按「描述含 ADB」定位**，不写死 MI_ 编号，插拔换口都适用；写入后重启设备节点并打印 `adb devices`。

> ⚠️ 两个编码坑（本次实际翻车两次）：
> 1. `.ps1` **必须 UTF-8 with BOM** —— 否则 PowerShell 5.1 按 GBK 解码中文注释，
>    报 `表达式或语句中包含意外的标记 "}"`，且**连日志都不会生成**（解析先于 `Start-Transcript` 失败）。这就是 §6.1。
> 2. `.cmd` **必须纯 ASCII** —— `cmd.exe` 按 OEM 代码页读批处理，任何非 ASCII 字节都会损坏它。

**自查命令（不用管理员）**：

```powershell
# 1) 找 ADB 接口的真实 MI_ 编号
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_339B&PID_107D&MI_*' } |
  Select-Object Status,FriendlyName,InstanceId

# 2) 看该接口有没有 f72fe0d4（少它就是本节的病）
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses' | ForEach-Object {
  $g=$_.PSChildName
  Get-ChildItem $_.PSPath | Where-Object { $_.PSChildName -match '(?i)PID_107D&MI_0[0-9]' } | ForEach-Object { $g }
}
```

> 顺带一句：设备管理器里 **`HDB Interface` 报错是正常的**（荣耀助手通道，与 adb 无关），不要修它。

---

## 7. 下一步：架构转向（已确认方向）

### 7.1 要做什么

把数据来源从「RSSHub 聚合」改为「**App 内登录 + 直连平台官方接口**」。  
这样才能满足两个新要求：**电脑关机也能用**（不依赖任何服务器）、**能看自己关注的博主**。

### 7.2 分阶段计划

| 阶段 | 内容                                                          | 状态                                  |
| -- | ----------------------------------------------------------- | ----------------------------------- |
| 0  | 可行性验证                                                       | ✅ 已完成（见 §2.2）                       |
| 1  | 账号体系：B 站扫码登录 + 凭据存钥匙串 + 登录态管理                               | ✅ **已完成并通过真机验证**（2026-10-15，见 §7.5） |
| 2  | 关注列表 → 时间线（复用现有 `ContentItem` 模型与 UI）                       | ✅ **已完成并通过真机验证**（2026-10-15，见 §7.6） |
| 3  | 微博：**接口被风控拦截，已降级为内置 WebView 打开**（原计划的「试 API」已用六级探针证伪） | ✅ **已完成并通过真机验证**（2026-10-17，见 §7.15） |
| 4  | 真机验收：**关电脑、拔数据线，App 依然完整可用** | ✅ **已完成**（2026-10-18，用户实操确认，见 §7.16） |

### 7.3 实现要点

- **凭据存储只能走 `lib/core/storage/secure_store.dart`**（Android Keystore）。  
  该文件的类注释已经写明了这条约定：严禁落到 SharedPreferences、日志或代码里。
- **B 站扫码登录**已有可参考的验证脚本：`tools/probe_bili_login.py`（含完整轮询状态机：  
  `86101` 未扫码 / `86090` 已扫待确认 / `86038` 过期 / `0` 成功）。
- **WBI 签名** Dart 侧已实现于 `lib/data/bili/wbi.dart`，Python 参考实现见  
  `tools/probe_bili_capabilities.py`。
- `lib/data/rss/` **不要删** —— 按你的决定保留为「按 UID 订阅」的补充能力。
- 上一轮为绕过 RSSHub 而在设置页加的「播放链路自检」入口，新架构下可以移除了。


### 7.4 评论接口 `-403`：已复测，结论如下（2026-10-15）

**结论：与出口 IP 风控无关。** 直连与代理的结果**完全一致**；真正的分界是  
`pagination_str` 的**字节形态**：

| `pagination_str` 取值                                 | 结果                                                     |
| --------------------------------------------------- | ------------------------------------------------------ |
| `{"offset": ""}`（Python `json.dumps` 默认，**带一个空格**）  | ❌ `code=-403 访问权限不足`                                   |
| `{"offset":""}`（紧凑 —— **正是 Dart `jsonEncode` 的产物**） | ✅ `code=0`，18~20 条，且带 `next_offset`                    |
| 空字符串 / 完全不传该参数                                      | ✅ `code=0`，但 `is_end=true` 且**没有** `next_offset`（无法分页） |

这正好解释了原来的矛盾：**应用内可用**（Dart `jsonEncode` 产出紧凑形态），  
而**脚本必失败**（`json.dumps` 默认在 `:` 后插入空格）。

复测脚本：`tools/probe_comment_retest.py`（`--popular` 可自动挑评论最多的热门视频）。

**顺带查清第二个坑：`next_offset` 的值不一定会推进。**  
实测（3743 条评论的热门视频，mode=3 热度与 mode=2 时间**都一样**）：  
连续三页每页都是 20 条**全新**内容、0 重复，但**三页返回的 `next_offset` 完全相同**。

因此：

- **不能**用「`next_offset` 与上一页相同」判定分页结束 —— 那会误判成「已到底」；
- 是否到底**只能**看 `cursor.is_end`；
- 好消息：`CommentParser.parseMain`（`lib/data/bili/comment_parser.dart`）与  
  `CommentController.loadMore`（`lib/features/comments/comment_controller.dart`）  
  走的正是「用 `is_end` 判结束 + 把 `next_offset` 当游标」这条路径，  
  **与新发现的行为一致，无需改动**。

### 7.5 阶段 1 实现记录（2026-10-15）

代码已落地在 `D:\Rrha`：`dart analyze` 无告警、`flutter test` **186 个全通过**  
（比原来多 26 个用例）。**唯一还没做的是真机扫码验证**（需要手机配合）。

| 层    | 文件                                                 | 职责                                                                                                                          |
| ---- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| 模型   | `lib/data/models/bili_session.dart`                | 会话（`SESSDATA` / `bili_jct` / `DedeUserID` / `DedeUserID__ckMd5` / `refresh_token`）＋ 脱敏摘要；**刻意不覆盖 `toString()`**，免得哪天被顺手打进日志 |
| 凭据存取 | `lib/core/storage/bili_credential_store.dart`      | 凭据的**唯一**落点：只写 `SecureStore`（钥匙串），版本化键名 `bili_session_v1`；日志只报字节数                                                           |
| 登录协议 | `lib/data/bili/bili_login.dart`                    | `generate` / `poll` / `confirm`；状态码映射与 `Set-Cookie` 解析都做成**纯静态函数**，可离线单测                                                    |
| 状态机  | `lib/features/settings/bili_login_controller.dart` | 轮询（2 s 一次、180 s 过期）、确认身份、落库、登出；`cancel()` 负责收尾定时器                                                                           |
| 界面   | `lib/features/settings/bili_login_section.dart`    | 设置页「B 站账号」区块 + 扫码对话框（`qr_flutter` **本地**渲染，白底）                                                                              |
| 接线   | `lib/providers.dart`、`lib/main.dart`               | 登录态变化 → `BiliClient.setAccountCookie()`；`restore()` 放在**首帧之后**，不进冷启动路径                                                      |

依赖新增：`qr_flutter: ^4.1.0`（含纯 Dart 的 `qr`）。

#### 三个容易踩的点（都已处理，动这块之前先看）

1. **凭据不在 body 里**。`poll` 成功时 body 只有 `code` 与 `refresh_token`，  
   真正的凭据靠 **`Set-Cookie` 响应头**下发。只读 body 会得到「登录成功却没有凭据」。
2. **状态码在 `data.code`，不是外层 `code`**。外层 `code` 只表示「接口本身正常返回」，  
   只读外层会永远看到成功。`stateFromCode()` 专门吃 `data.code`。
3. **二维码必须本地渲染**（`qr_flutter`），且**深色主题下必须给白底** ——  
   否则手机扫不出来，还容易被误判成「二维码内容不对」。

#### 验证结果（2026-10-15，华为 P40 Pro / ELS-AN00 实测通过）

```bash
flutter test                                  # 186 passed
cd android && gradlew.bat assembleProfile     # BUILD SUCCESSFUL in 2m 7s
adb install -r build\app\outputs\flutter-apk\app-profile.apk
```

| 验证项      | 结果                                                                                                         |
| -------- | ---------------------------------------------------------------------------------------------------------- |
| 冷启动      | ✅ **679 ms**（`am start -W` 的 `TotalTime`）                                                                  |
| 二维码生成    | ✅ App 内**本地**渲染，白底可扫（截图 `tools/shots/stage1-login-qr.png`）                                                 |
| 扫码登录闭环   | ✅ 手机 B 站客户端扫码 → 界面显示「已登录：<账号昵称> · 0 分钟前」                                                                      |
| **凭据存储** | ✅ **杀进程后冷启动，登录态自动恢复**（截图 `tools/shots/stage1-settings-account.png`）—— 这同时说明凭据确实走的是钥匙串，不是 SharedPreferences |
| 脱敏展示     | ✅ 只显示 `SESSDATA ****IIEC · bili_jct ****a130`，完整值不外露                                                       |

**尚未实测的两项（如实标注）**：

- **登出**：会清掉已建立的登录态、需要重新扫码，因此没有在验收里触发；  
  逻辑上它只是 `BiliCredentialStore.clear()` + 重置内存态。
- ~~`BiliClient` 带 Cookie 的真机端到端证据~~ → **已在阶段 2 确认**：  
  B 站官方接口能返回 `code=0` 并把内容渲染出来（未登录时必然 `-403`/`-352`），  
  详见 §7.6。

### 7.6 阶段 2 实现记录（2026-10-15，真机验证通过）

**B 站订阅已切到官方接口**，不再依赖公共 RSSHub 实例（那些实例基本全灭）；  
微博源与自建实例路径保持原样，互不影响。

| 层    | 文件                                                       | 职责                                                                                    |
| ---- | -------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 模型   | `lib/data/models/bili_user.dart`                         | `BiliUser`（关注列表 / 主页两种 JSON 形态）+ `BiliFollowingPage`；图片地址统一补成 https                   |
| 接口   | `lib/data/bili/bili_client.dart`                         | `followings()`（**不需要 WBI 签名**）、`userVideoItems()`、`userDynamicItems()`、`currentMid()` |
| 解析   | `lib/data/bili/bili_content_parser.dart`                 | 官方 JSON → `ContentItem`（投稿 + 动态两条路径，动态按类型降级不丢条目）                                      |
| 数据源  | `lib/data/bili/bili_timeline_source.dart`                | 带 5 分钟缓存，复用 `CacheStore` 且**缓存原始 JSON**（解析规则升级后旧缓存仍可用）                                |
| 分派   | `lib/data/repo/timeline_repo.dart`                       | B 站走官方接口，其余走 RSSHub                                                                   |
| 界面   | `lib/features/subscriptions/following_import_sheet.dart` | 「从关注列表导入订阅」弹窗：默认只勾前 5 个，导入时把 UP 名写进别名                                                 |
| 公共工具 | `lib/core/utils/id_hash.dart`                            | 抽出 id 算法 —— **RSS 与官方两条路必须产出同一个 id**                                                  |

依赖无新增。测试从 186 增至 **209**（新增 23 个，覆盖字段映射、id 一致性、去重与动态降级）。

#### 真机验证（华为 P40 Pro / ELS-AN00）

| 验证项        | 结果                                                                               |
| ---------- | -------------------------------------------------------------------------------- |
| **关注列表接口** | ✅ **共 74 人**（与阶段 0 脚本实测的 74 完全一致）→ `/x/relation/followings` 返回 `code=0`          |
| **导入订阅**   | ✅ 勾选 5 个导入成功，订阅页出现 `w咸瑜` / `明日方舟` / `一般路过三花猫` …，**别名是 UP 名**而非 `B 站 UP 91647207` |
| 时间线多源聚合    | ✅ **151 条 · 6 个订阅源**（投稿 + 动态，按 id 去重）                                            |
| 卡片渲染       | ✅ 视频与图文动态都正确显示标题/正文、封面、作者、精确时间（41 分钟前 / 4 小时前）                                   |
| Cookie 注入  | ✅ 官方接口未登录必然 `-403`/`-352`，能拿到 `code=0` 就说明 Cookie 确实带上了                          |

截图（`tools/shots/`）：`stage2-import-sheet.png`（74 人关注列表）、  
`stage2-imported-sources.png`（导入后的订阅源）、`stage2-timeline-multi.png`（6 源 151 条）、  
`stage2-timeline-dedup.png`（去重前后的对比）、`stage2-applog.png`（App 内日志页）。  
服务端形态复核脚本：`tools/probe_stage2_fetch.py`。

#### 踩到并修掉的四个坑（都很隐蔽，改这块之前先看）

1. **登录态就绪后必须补刷一次时间线。**  
   冷启动时钥匙串是**首帧之后**才读完的，首轮刷新跑在「看起来还没登录」的时刻，  
   于是时间线一直挂着「需要先登录」。修法：`_LoginBootstrap` 在 `restore()` 完成后  
   主动 `refresh(silent: true)`（`lib/main.dart`）。  
   定位靠的是 **App 自己的内存日志页**（设置页右上角图标）：它显示只有一条 `BiliLogin`  
   记录、**完全没有 `BiliTimelineSource` 的拉取日志**，一眼就看出「刷新根本没跑第二次」。
2. **别让「登录态」决定数据源对象存不存在。**  
   最初 `biliTimelineSourceProvider` 在未登录时返回 `null`，结果登录动作会连锁重建  
   `timelineRepoProvider` → 时间线 notifier 被重建 → **已加载内容被清空**。  
   现在登录判断挪到 `BiliTimelineSource.fetch()` 内部，且 `TimelineNotifier` 改为  
   **每次 refresh 现取仓库**（不再 `watch`），从根上断开这条连锁。
3. **同一条视频会从两条路进来。**  
   「投稿列表」与「动态流（`major.archive`）」拿到的是同一个视频；若各自算 id，  
   时间线会出现两张一模一样的卡片 —— 首测 32 条里就有 20 条是重复的。  
   修法：视频类动态一律用**视频链接**做 id 输入，与投稿路径合一（有回归测试守着）。
4. **图文动态的正文在 `major.opus.summary.text`，不在 `desc.text`。**  
   新版动态（opus 形态）改了正文位置，不回退这一层的话，纯图文动态会  
   **整片退化成「（无标题）」**（真机 151 条里有十几条如此）。  
   另外纯图片动态本来就没有文字，标题如实标成 `[图片]` —— 但**判空必须看原始字段**，  
   否则「兜底后的标题恒非空」会让垃圾条目永远丢不掉（这条是被单测抓出来的）。

#### 后续可做的（不属于阶段 2）

- 关注的 UP 主有 74 人，目前默认只勾前 5 个导入；如果将来要支持大批量，  
  需要考虑更细的刷新策略（分批、错峰、按需刷新），否则必然触发风控。
- 个别卡片不显示发布时间（源里 `created`/`pub_ts` 缺失），  
  已按 `hasReliableTime=false` 如实降级，没有伪造时间。

---

### 7.7 一轮缺陷修复记录（2026-10-16，真机验证通过）

> 命名说明：本轮**不占用 §7.2 的阶段编号** —— 阶段 3 仍指「微博」（见 §10 第 6 条）。

本轮是**五项针对性修复**（不是新功能），每项都先复现、再改代码、再真机复核。  
测试从 209 增至 **261**（新增 52 个，全部离线）。

| # | 症状                                             | 根因                                                                                                                                                                                      | 修法                                                                                                                                                                                 |
| - | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | 评论区首屏 20 条正常，点「加载更多」报 `请求参数有误（-400）`           | 解析层把 `cursor.pagination_reply.next_offset` 的**裸游标串**存进 `nextCursor`，而 `comments()` 又把它**原样当作 `pagination_str`** 发出；B 站只接受 `{"offset":"..."}` JSON                                       | 包装收敛到**唯一一处** `BiliClient.paginationStr()`；解析层只存裸值；顺带清掉「旧接口 `cursor.next` 伪造成 `{"offset":""}`」的兼容分支（那等于每页都拉第一页）                                                                    |
| 2 | 评论区偶发 `请求失败（HTTP 412）`                         | HTTP 412 走的是 `_unwrap()` 的 `status >= 400` 分支（**响应里没有业务 JSON**，`bizCode` 为 null），而「强刷 WBI 密钥重试一次」只判业务码 -352/-412，于是这类 412 既不重试、文案也落进泛化分支                                                | 抽出 `BiliClient.isRiskFailure()` 把 **HTTP 412** 与业务码一起纳入重试条件；`AppError.fromStatus` 增加 412 专属文案与可重试语义                                                                                |
| 3 | 打开视频：画面已在播放、左下角却显示 ▶，且**一条弹幕都没有**；第一次点击执行的是暂停  | 两个 adapter 的 `playingStream` 是普通 `StreamController`，**订阅时不补发当前值**；而播放页「先订阅、后 `play()`」，且 libmpv 在 `open()` 后就自动播放 —— 那次状态变化落在订阅窗口之外，`_playing` 永远停在 false（`PlaybackClock` 因此不推进 → 弹幕不动） | `player_page._bindPlayer()` 订阅后**主动对齐一次真实状态**；两个 adapter 改用 `StreamController.broadcast(onListen:)` 补发当前值与时长；弹幕层新增「非时钟重绘触发」（装载完成 / 切换设置立刻生效）；播放结束时连时钟一起停                           |
| 4 | 动态详情页写死「B 站动态本身不带评论接口入口」                       | 该假设是错的：动态有评论区，只是 `oid`/`type` 与视频不同                                                                                                                                                     | 实测后**按动态自己声明的 `basic.comment_id_str` / `basic.comment_type`** 取参数（见下），`ContentItem` 增 `commentOid`/`commentType`，`comments()`/`replies()`/仓库/控制器/评论区组件全链路透传 `type`，详情页接真实评论区（内嵌模式） |
| 5 | 一次刷新 = 订阅源数 × 路由数 个请求（6 源 = 12 个），合并后一次挂 151 条 | 逐源聚合没有分页概念，且请求数随关注人数线性增长                                                                                                                                                                | 新增 `TimelineMode`（Prefs 持久化）：**「全部关注」（默认）**&#x7528; `/x/polymer/web-dynamic/v1/feed/all` 一次拉 20 条 + offset 游标，滚到底续拉；**「精选订阅」保留原逻辑**（含微博源）；分页按页缓存原始 JSON（含游标），TTL 5 分钟              |

#### 三个必须记住的实测结论（都是「猜错了就会踩」的类型）

1. **`pagination_str` 只有一种合法形态，且不能有空格。**  
   `{"offset":""}`（紧凑）正常；写成 `{"offset": ""}`（带空格）会被判 `-403`；  
   直接把裸游标串发出去是 `-400 请求参数有误`。  
   所以全工程**只有 `BiliClient.paginationStr()` 一处**负责包装，单测里专门断言产物不含空格。
2. **动态评论的 `oid` 不是动态 id。**  
   动态 JSON 的 `basic` 段直接给出了正确入口，三类各不相同（脚本 `.env/probe_dynamic_basic.py` 实测）：
   | 动态类型                         | `comment_id_str`        | `comment_type` |
   | ---------------------------- | ----------------------- | -------------- |
   | 视频投稿动态（`DYNAMIC_TYPE_AV`）    | 视频 **aid**              | `1`            |
   | 图文动态（`DYNAMIC_TYPE_DRAW`）    | **图片/opus id**（≠ 动态 id） | `11`           |
   | 转发动态（`DYNAMIC_TYPE_FORWARD`） | 动态 **id_str**           | `17`           |
   拿「动态 id + type=17」去请求图文动态只会得到 `-404 啥都木有`（最初就是这么猜的，被脚本否掉）。  
   `basic` 缺失时才回退到「id_str + 17」。
3. **关注流 `feed/all` 的字段类型并不统一。**  
   `offset` 是**纯数字字符串**（19 位大整数，如 `"1259324277086224400"`），  
   `update_num` 是**字符串** `"0"`，只有 `has_more` 是真正的 bool。  
   按 JSON 类型硬转会抛 `type 'String' is not a subtype of type 'num?'` ——  
   真机第一次装上就是这样整页报「刷新失败」的（脚本 `.env/probe_feed_types.py` 确认）。  
   另外 offset 是 19 位整数，**绝不能过 double**（53 位有效位），必须原样回传。

#### 「全部关注」的 `sourceId` 设计

已读标记按 `sourceId` 分组存 Prefs，而 `sourceId` 又由 `ContentItem` 带出。  
关注流不属于任何一条订阅，因此造了一个**虚拟源**：

```dart
// lib/data/bili/bili_timeline_source.dart
static const String followingSourceId = 'bilibili:following';
static final Subscription followingSubscription = Subscription(
  platform: Platform.bilibili, uid: 'following', ..., addedAt: DateTime.utc(2026, 1, 1));
```

关键是它**与页码、游标无关且跨刷新不变**：一旦让它跟着分页变化，  
每翻一页都会被当成「一个新源」，已读集合永远是空的 —— 表现为满屏「新」角标。  
`uid` 特意用 `'following'`（不是数字 mid），避免与真实 UP 撞 id。

#### 真机验证（华为 P40 Pro / ELS-AN00）

| 任务 | 操作                                                  | 结果                                                                                                                                               | 截图（`tools/shots/`）                                                                                                      |
| -- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| 1  | 打开视频 → 评论区滚到底                                       | ✅ 首屏 **评论 20** 条（含楼中楼）→ 滚到底自动续拉后 **评论 59**，**不再出现 -400**                                                                                         | `fix-1-comment-first-page-20.png`、`fix-1-comment-loadmore-59.png`                                                       |
| 1  | 服务端对照（脚本 `.env/probe_comment_paging.py`，同一 oid 打三次） | ✅ 第一页 `{"offset":""}` → `code=0`；第二页 `{"offset":"<裸游标>"}` → **`code=0`、20 条、与第一页 0 重复**；第二页裸游标（旧行为）→ **`code=-400 请求错误`**                        | 终端输出（见本节说明）                                                                                                             |
| 2  | 打开视频 → 评论区                                          | ✅ 显示 **「B 站风控拦截（HTTP 412），已自动重试」**（旧版只会显示泛化的「请求失败（HTTP 412）」）；App 内日志页同时留下 `命中风控（HTTP 412），强刷 WBI 密钥后重试一次` + `WBI 密钥已更新`                         | `fix-2-412-message.png`、`fix-2-412-retry-log.png`                                                                       |
| 3  | 打开任意视频（`w咸瑜` 的 18:07 视频）                            | ✅ **打开即播放**（进度 00:07/18:07 自行走动）、**弹幕立刻滚动**（屏上多条 + 角标「弹幕 492」）、按钮显示 **⏸**；点一下 → 进度停在 00:13、按钮变 ▶、弹幕静止（两张连续截图字节完全一致）；再点一下 → 进度继续 00:19、按钮回 ⏸、弹幕继续 | `fix-3-playing-danmaku.png`、`fix-3-paused-state.png`、`fix-3-resumed-state.png`                                          |
| 4  | 时间线打开一条图文动态（明日方舟 SideStory）                         | ✅ 详情页显示真实评论区（飞羽终化雪 / 老钉_无底洞之胃 381 赞 …，含楼中楼），底部出现「加载更多」；点它后追加出第二页评论（自由星球 / 赛坎 456 赞 …）                                                            | `fix-4-dynamic-comments.png`、`fix-4-dynamic-loadmore.png`                                                               |
| 5  | 时间线（默认「全部关注」）                                       | ✅ 首屏 **20 条**、模式切换条可见、底部「更新于 刚刚 · 20 条 · 全部关注（1 个请求/页）」；连续滚到底后条目数 **20 → 99 → 199 条**（分页持续推进、无重复卡片）；切到「精选订阅」得到 **151 条 · 6 个订阅源**（旧逻辑回归通过）       | `fix-5-mode-switch.png`、`fix-5-timeline-first-page-20.png`、`fix-5-timeline-paged-199.png`、`fix-5-selected-mode-151.png` |

> ⚠️ 排查期间用脚本密集请求评论接口，把账号打进了 B 站的 412 冷却（`request was banned`），  
> App 侧因此一度整片显示 412 —— 这**恰好**成了任务 2 的真机素材（旧版只会显示泛化文案）。  
> 冷却结束后 App 与脚本都恢复正常，上表的 1/4 两项就是冷却后复测的结果。

#### 复现/复核脚本（都在 `.env/` 下，不属于项目源码）

| 脚本                               | 用途                                                         |
| -------------------------------- | ---------------------------------------------------------- |
| `.env/probe_comment_paging.py`   | 评论翻页的**服务端对照**：正确包装第二页 `code=0` 且不重复、裸游标 `-400`            |
| `.env/probe_dynamic_comment.py`  | 试探动态评论的 `type`（17/11/1）是否可用                                |
| `.env/probe_dynamic_basic.py`    | dump 动态 `basic` 段，定位 `comment_id_str`/`comment_type` 的真实取值 |
| `.env/probe_dynamic_comment2.py` | 用 `basic` 声明的参数验证动态评论可翻页、并**复现裸游标 -400**                   |
| `.env/probe_feed_types.py`       | 确认 `feed/all` 的 `offset`/`update_num`/`has_more` 的 JSON 类型 |

#### 本轮踩到并修掉的坑（都属于「不改就一定踩」）

1. **评论翻页的包装必须唯一。** 解析层、仓库层任何一处再包一次，  
   都会得到 `{"offset":"{\"offset\":\"...\"}"}` 这种双层形态（同样 -400）。
2. **HTTP 412 与业务码 -412 是两回事。** 前者响应里没有 JSON，  
   `bizCode` 为 null；只判业务码的代码在真机上表现为「偶发且无法自愈」。  
   顺带把这类 412 的文案改成能说明「已经重试过」，否则用户只能干等。
3. **「订阅时补发当前值」是播放器适配器的硬约束。**  
   `playingStream` / `durationStream` 都必须在 `onListen` 里补发，  
   否则「先订阅后 play」的调用顺序、以及 libmpv 的自动播放，都会让界面卡在初始状态。
4. **弹幕层只被播放时钟驱动重绘。** 于是「弹幕装载完成」这类不经过时钟的变化  
   会拖到下一次位置回调才可见（暂停时则永远不可见）—— 现在用一个显式的  
   `extraRepaint` 通知源补上，仍然是「只重绘、不重建 widget」。
5. **关注流的字段类型不能按 JSON 硬转**（见上文结论 3），  
   而且 `offset` 必须按字符串原样回传。

---


### 7.8 一轮缺陷修复（第二轮）记录（2026-10-16，真机验证通过）

> 命名说明：本轮**不占用 §7.2 的阶段编号** —— 阶段 3 仍指「微博」（见 §10 第 6 条）。

本轮是**三项针对性修复**（图片不能点开 / 多图只显示第一张 / 转发看不到原动态），  
每项都先复现、再改代码、再真机复核。测试从 261 增至 **312**（新增 51 个，全部离线）。

| # | 症状                        | 根因                                                                                         | 修法                                                                                                                                   |
| - | ------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| 1 | 点动态里的图片没有任何反应             | 详情页只有一个 `AspectRatio` + `CoverImage`，**没有任何手势**；全工程也没有全屏预览页                                | 新建 `lib/features/gallery/image_gallery_page.dart`：黑底 + `PageView` + 每页 `InteractiveViewer`（双指缩放/拖动）+ 双击 1x↔2.5x + 页码 `i / n` + 保存到相册 |
| 2 | 一条动态有多张图时只显示第一张           | 解析层只取 `pics[0]` / `items[0]` 当 `coverUrl`，其余图片**在解析阶段就被丢掉了**；`ContentItem` 里根本没有「全部图片」这个概念 | `ContentItem` 新增 `images`（全部图片）；解析层新增 `_extractImages` 一次取全；详情页把单个 16:9 封面换成九宫格 `PhotoGrid`                                          |
| 3 | 转发类动态只显示转发者文字，被转发的原动态完全缺失 | 解析层**只读主动态的 `modules`**，`orig` 段从未被解析；`ContentItem` 里也没有承载原动态的字段                           | `ContentItem` 新增 `origin`（只展开一层）；解析层新增 `_parseOrigin` 递归复用 `fromDynamic`；详情页新增「原动态」预览区块 + 「查看原动态」独立页                                 |

#### 三个必须记住的实测结论（都是「猜错了就取不到图」的类型）

抓取脚本 `.env/probe_media_repost.py` 与 `.env/probe_media_repost2.py`，  
抓 `feed/all` 连翻 **6 页共 121 条**真实动态，结论如下：

| 事实             | 实测值                                                                                                                 | 猜错的后果                                                             |
| -------------- | ------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| 图片列表的位置与字段名    | **`major.opus.pics[]`**，元素字段是 `url` / `width` / `height` / `size` / `live_url` / `aigc` / `warning` —— **不是 `src`** | 照抄旧代码的 `src` 会一条图都取不到（表现为「动态全都没有图」）                               |
| 旧形态            | `major.draw.items[]`，元素字段才是 `src`（本批出现 **0 次**，但仍要兼容）                                                               | 只在旧形态上生效的代码看似正常，实际永远不走                                            |
| 多图分布           | `{1:34, 2:2, 3:1, 5:1, 7:4, 8:1, 9:1}`，**最多 9 张**                                                                   | 只按「1 张」设计会漏掉真实存在的大批多图                                             |
| 图片 URL 的协议     | 服务端给的是明文 **`http://i0.hdslb.com/...`**                                                                              | 不过 `BiliUser.normalizeImageUrl()` 转 https，Android 9+ 默认禁明文 → 直接裂图 |
| 转发动态占比         | **36 / 121 条**，`orig` **从未缺失**（0 条非 dict）                                                                           | 以为 `orig` 常常缺失就不会认真测                                              |
| `orig.type` 分布 | `DYNAMIC_TYPE_AV` 31、`DYNAMIC_TYPE_DRAW` 4、`DYNAMIC_TYPE_ARTICLE` 1                                                 | 只处理图文原动态会漏掉 31/36 的视频原动态                                          |
| `orig` 的结构     | 与主动态**完全同形**：同样有 `basic` / `id_str` / `modules` / 甚至嵌套 `orig`                                                       | 另写一套字段映射等于把 bug 抄两遍                                               |
| ⚠️ 原动态的评论入口    | `orig.basic.comment_id_str` 是**空串**、`comment_type` 是 **0**                                                          | 原动态拿不到评论入口 → 原动态独立页**不要做评论区**，直接用详情页既有的「接口没有给出这条内容的评论入口」兜底文案      |
| ⚠️ 原动态的正文位置    | `orig.modules.module_dynamic.desc.text` 可能为 **None**（图文原动态正文在 `major.opus.summary.text`）                            | 不复用主解析里那条兜底逻辑，原动态区块会只剩一张图、一个字都没有                                  |
| 时间线缓存的内容       | 存的是**原始 JSON**（不是解析后的模型）                                                                                            | 解析规则升级后旧缓存仍能出图 —— **不要清缓存、不要改缓存格式**                               |

#### 两个实现上的关键决定

1. **`images` 与 `coverUrl` 并存，而不是把 `coverUrl` 换成 `images.first` 的计算属性。**  
   时间线卡片、既有测试、大量布局都直接读 `coverUrl`；把它钉死成  
   「`images.first`，没有图时为 null」就能让卡片侧**零改动**，  
   只需解析层保证两者同时填。两者语义若不一致，症状是「卡片有图、详情页没图」。
2. **`origin` 只存一层（depth 上限 1），且自引用判定必须用裸 `id_str`，不能用 `ContentItem.id`。**  
   这是**单测撞出来的坑**：视频类动态的 `id` 是用 bvid 链接算的（为了跟投稿列表去重），  
   于是「转发了别人发的同一个视频」时主动态与原动态的 `id` **完全相同** ——  
   用 `id` 比较会把这种**完全正常的**转发误判成自引用、把原动态整块静默丢掉。  
   `id_str` 标识的是**动态本身**，只有服务端真的回填错误时才两边相同。  
   （`test/bili/bili_content_parser_test.dart` 里有一条专门盯这个的用例。）

#### 新增依赖

**只有 `gal: ^2.3.3`**（保存到系统相册）。刻意**不引入** `photo_view` 等其它依赖 ——  
缩放/翻页用 Flutter 自带的 `InteractiveViewer` + `PageView` 就够，  
缩略图内存问题用 `cacheWidth` 解决（9 张 1080p 原图按原尺寸解码 ≈ 36 MB，必被系统杀）。

保存流程：用现有 `biliDioProvider` **下载到 `path_provider` 的临时目录文件**  
（带 `Referer`，否则 B 站图床 403），再 `Gal.putImage(path, album: 'Rrha')`，  
用完删临时文件。**刻意不用 `putImageBytes`**：大图整块读进内存再往方法通道塞，  
低端机上很容易 OOM 或超时。Android 10+ 走 MediaStore 无需权限；  
旧版本先 `Gal.hasAccess()` → `Gal.requestAccess()`，被拒时给出可读原因（**不假装成功**）。  
`AndroidManifest.xml` 增加了 `WRITE_EXTERNAL_STORAGE`（`maxSdkVersion="28"`）。

#### 手势协调（「放大后想拖图却翻页」的根因）

`PageView` 与 `InteractiveViewer` **都要吃水平拖动事件**。做法：监听  
`TransformationController`，`scale > 1.01` 时把 `PageView.physics` 换成  
`NeverScrollableScrollPhysics`（此时水平手势全部交给 `InteractiveViewer` 去拖图），  
缩回 1x 时恢复。阈值取 **1.01 而不是 1.0**，是为了躲开捏合回弹时浮点数的 0.9999。

#### 真机验证（华为 P40 Pro / ELS-AN00）

| 任务  | 操作                                              | 结果                                                                                                                                    | 截图（`tools/shots/`）                      |
| --- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 2   | 时间线「精选订阅」找到 **Warma 2026-09-12 的 9 图动态** → 打开详情 | ✅ **九宫格 3×3 完整展示全部 9 张**（此前只显示第 1 张）                                                                                                  | `fix-6-09-nicegrid-detail.png`          |
| 2+1 | 点九宫格**第 5 张** → 全屏预览                            | ✅ 打开的就是第 5 张，页码 **`5 / 9`**（不是从第 1 张开始）                                                                                               | `fix-6-10-gallery-5of9.png`             |
| 1   | 预览页向左滑                                          | ✅ 切到第 6 张，页码 **`6 / 9`**                                                                                                              | `fix-6-11-gallery-swipe-6of9.png`       |
| 1   | 预览页双击                                           | ✅ 放大到 **2.5x**（图文明显放大、四周被裁切）                                                                                                          | `fix-6-12-gallery-zoomed.png`           |
| 1   | **放大状态下**再左右拖                                   | ✅ **拖的是图片**（画面平移、页码仍是 `6 / 9`）——证明手势协调生效，没有误翻页                                                                                        | `fix-6-13-zoomed-pan.png`               |
| 1   | 点「保存到相册」                                        | ✅ SnackBar 显示 **「已保存到相册（相册 → Rrha）」**；`adb shell content query` 佐证系统媒体库出现两条 `relative_path=Pictures/Rrha/`、`_display_name=rrha_*.jpg` | `fix-6-08-save-album.png`               |
| 1   | **连续进出预览页 5 次**                                 | ✅ 5 次都正常打开/关闭，`logcat` 过滤 `flutter\|Exception\|FATAL\|ANR` **无任何输出**                                                                  | `fix-6-15-gallery-cycle5.png`           |
| 3   | 时间线打开**明日方舟的转发动态**                              | ✅ 转发者正文与**原动态区块**视觉上分区明确（外框 + 更深底色 + 左上角「原动态」标签），区块内有原动态作者 `机核GCORES`、时间 `2026-10-16 14:00`、正文摘要（3 行截断）、首图缩略、**「共 1 张图片」**            | `fix-6-05-repost-detail.png`            |
| 3   | 点「查看原动态」                                        | ✅ 进入**原动态独立页**：标题栏 `原动态 · Bilibili · 动态`、正文**全文**、图片可点                                                                                | `fix-6-06-origin-detail.png`            |
| 3   | 在原动态独立页点图片                                      | ✅ 打开全屏预览，页码 `1 / 1`，底部「保存到相册」可用                                                                                                       | `fix-6-07-origin-gallery.png`           |
| 回归  | 时间线「精选订阅」                                       | ✅ **151 条 · 6 个订阅源**；转发卡片右上角出现 **「含原动态」** 角标                                                                                          | `fix-6-04-selected.png`                 |
| 回归  | 打开任意视频（§7.7 任务 3 复测）                            | ✅ **打开即播放**（进度自行走到 `00:42 / 26:55`）、**弹幕在滚**（角标「弹幕 889」、屏幕上多条）、按钮显示 ⏸；评论区照样渲染（首屏 20 条 + 楼中楼）                                          | `fix-6-18-video-danmaku-regression.png` |

> ⚠️ **排查期间又撞上一次 HTTP 412 冷却**（重新安装 APK 后立刻刷新，6 个源里有 5 个返回 412）。  
> 这**反而是 §7.7 任务 2 的回归证据**：「数据源状态」面板逐条显示  
> **「B 站风控拦截（HTTP 412），已自动重试」** 而不是泛化的「请求失败」，  
> 且**没有**继续刷接口（等冷却后单条视频与评论都恢复正常）。  
> 见 `fix-6-17-expired-source.png`。按 §7.8 的要求**没有连续重试刷接口**。

> ⚠️ **未能取证的两项，如实记录**（不是通过，也不是失败）：
>
> 1. **3 图动态的九宫格**：3 图样本（`OyashiroDev` 2026-09-13、`Nestopi` 2026-10-04）  
>    所属 UP **不在**当前已订阅列表里，而这台设备上「添加订阅」弹窗的  
>    「添加并拉取」按钮被系统导航区遮挡、`adb input tap` 反复未能命中，  
>    「从关注列表导入」的面板又要滚过 50+ 人才能勾到目标。  
>    三列网格的渲染已由离线 widget 测试覆盖（3/5/6/7/8/9 张均断言三列、  
>    2/4 张断言两列、1 张断言单列且限高），**真机 3 图与 9 图为同一套代码路径**。
> 2. **原动态是视频时的播放页**：`明日方舟` 这条转发的原动态是图文，  
>    当页没有「播放原视频」入口；要找视频型原动态需要在时间线里翻到  
>    更早的转发条目（本次未翻到）。  
>    「原动态是视频」的解析已由离线测试覆盖（`origin.videoRef.bvid` 断言正确），  
>    按钮的跳转目标是既有的 `PlayerPage`（其可播性在 §7.7 任务 3 已验证过）。

#### 上一轮（§7.7）五项修复的回归结果

| 上一轮的修复                 | 本轮复测         | 结果                                                                                                     |
| ---------------------- | ------------ | ------------------------------------------------------------------------------------------------------ |
| 1 评论翻页                 | 打开视频 → 滚到底   | ✅ 首屏 **评论 20**（含楼中楼）→ 续拉后出现 `冬川闲人二代目`/`订做美味鱼卷`/`白开是水不是猫` 等第二屏评论，**无 -400**                             |
| 2 HTTP 412 专属文案 + 自动重试 | 重装 APK 后立刻刷新 | ✅ 逐条显示 **「B 站风控拦截（HTTP 412），已自动重试」**（见上文说明与 `fix-6-17-expired-source.png`）                             |
| 3 打开视频即播放 + 弹幕滚动       | 打开 Warma 视频  | ✅ 进度自行走动、弹幕滚动、按钮为 ⏸（`fix-6-18-video-danmaku-regression.png`）                                           |
| 4 B 站动态能看评论            | 打开转发动态详情     | ✅ 评论区正常渲染（`评论 20` + 热度/时间切换 + 楼中楼）                                                                     |
| 5 时间线「全部关注」分页 / 模式切换   | 两种模式来回切      | ✅ 冷启动首屏 **「更新于 刚刚 · 20 条 · 全部关注（1 个请求/页）」**；切到「精选订阅」得到 151 条 · 6 源；再切回来正常。本轮的 412 冷却只影响**逐源**拉取，不影响关注流 |

#### 复现/复核脚本（都在 `.env/` 下，不属于项目源码）

| 脚本                            | 用途                                                       |
| ----------------------------- | -------------------------------------------------------- |
| `.env/probe_media_repost.py`  | 首轮抓取：确认图片在 `opus.pics[].url` 而不是 `draw.items[].src`      |
| `.env/probe_media_repost2.py` | 连翻 6 页共 121 条：图片张数分布、转发的 `orig` 结构、原动态的 `comment_id_str` |
| `.env/probe_find_targets.py`  | 按关注列表逐个 UP 找「9 图 / 3 图 / 转发带图 / 转发带视频」动态，输出 mid，供真机快速定位  |
| `.env/probe_check_9pic.py`    | 确认目标动态是否落在 App 会拉取的那一页（最新 20 条）里                         |

#### 本轮踩到并修掉的坑（都属于「不改就一定踩」）

1. **`orig` 的自引用判定不能用算法产物 `id`**（见上文「两个关键决定」第 2 条）。
2. **`major.draw` 变量在重构后成了未使用局部变量** —— `dart analyze` 会拦，  
   说明「优先 opus、兜底 draw」的逻辑确实收敛到 `_extractImages` 一处了。
3. **`Image.network` 带 `cacheWidth` 后 provider 是 `ResizeImage(NetworkImage)`**，  
   测试里 `w.image is NetworkImage` 会一张都匹配不到 ——  
   取值前必须剥掉 `ResizeImage` 包装。
4. **`InteractiveViewer` 没有 `onDoubleTapDown`**（它只处理缩放/平移），  
   双击手势必须挂在它**外面**的 `GestureDetector` 上，挂里面收不到事件。
5. **测试辅助函数的默认 id 会互相撞车**：造「转发 + 原动态」样本时，  
   两边的默认 `id_str` 相同会被自引用保护整条丢掉，表现为一堆看似无关的断言失败。

---


### 7.9 一轮缺陷修复（第三轮）记录（2026-10-16，真机验证通过）

> 命名说明：本轮**不占用 §7.2 的阶段编号** —— 阶段 3 仍指「微博」（见 §10 第 6 条）。

本轮是**三项针对性修复**（弹幕字号不可调 / 控制栏无法隐藏 / 封面滚回重新加载），  
每项都先复现、再改代码、再真机复核。测试从 312 增至 **370**（新增 58 个，全部离线）。

| # | 症状              | 根因                                                                                                                                                                                                        | 修法                                                                                                                                             |
| - | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | 弹幕字号固定，改不了      | 底层**全都已存在**（`DanmakuSettings.fontScale`、引擎 `fontSize * fontScale`、`ref.listen` 实时生效链路、Prefs 持久化），**只缺 UI** —— 播放器面板与设置页都没有字号入口                                                                            | 新建 `lib/widgets/danmaku_font_scale_selector.dart`（四档 ChoiceChip）；在播放器 `_DanmakuSettingsSheet`（compact）与设置页弹幕段各接一次；写入走既有 `copyWith(fontScale:)` |
| 2 | 控制栏一直显示、点不掉     | **不是「单击没实现」**（`onTap` 一直在），而是 `_syncFromPlayer()` 把播放状态绑到了自动隐藏上：`_controls.setPaused(!playing)` 让**暂停/加载态 = 永远不隐藏**。叠加 `onTap`/`onDoubleTap` 共存导致单击要等约 300ms 判定窗口，用户以为没反应又点一下 → 被判成双击 → 暂停/继续 → 控制栏就此永久挂住 | 见下面「问题 2 的实测根因」整段                                                                                                                              |
| 3 | 封面滚走再滚回就重新加载、闪灰 | 全工程只有裸 `Image.network`，**完全没有磁盘缓存**。Flutter 自带 `ImageCache` 上限 1000 张 / 100MB，一条 9 图动态加前后几条卡片就能挤爆，逐出后只能重新联网                                                                                               | 见下面「问题 3」整段                                                                                                                                    |

#### 问题 2 的实测根因（本轮最费劲的一处，必须记住）

把三种假设逐一排除后的结论：

1. **`onTap` 一直都在，而且真的会触发** —— 复现时把单击与双击分开验证，  
   确认 `toggle()` 被调用、可见性翻转、控制栏确实出现。  
   所&#x4EE5;**「单击切换没实现」这个最初的假设是错的**。
2. **真正的病灶是「暂停 = 永不隐藏」。** 原实现里  
   `PlayerControlsController.setPaused(true)` 会**取消计时器**（本意是「暂停时让用户安心看画面」），  
   而 `_syncFromPlayer()` 每次播放状态变化都会调它 —— 视频处于暂停/加载态时，  
   控制栏再也不会自动隐藏，永久遮住画面。
3. **300ms 判定窗口把用户推进了死循环。** `onTap` 与 `onDoubleTap` 共存时，  
   单击必须等双击判定超时（Flutter 内部约 300ms，**不可配**）。  
   用户点一下看没反应 → 再点一下 → 两次落进同一个判定窗口 → 被判成双击 → 暂停/继续  
   → 视频进入暂停态 → 控制栏永久显示。**「点不掉」这个体感的完整闭环就在这里。**

修法（三件）：

- **暂停不再阻止自动隐藏**（`setPaused` 改成显式空实现，并把「为什么推翻这条规则」写进类注释）；
- 新增 **3 秒自动隐藏**，任何交互（点按钮、拖动结束、切分 P、开关弹幕、打开面板）都重置计时，  
  **拖动期间与弹幕设置面板打开期间停表**；
- 隐藏时把 `_overlayIndicators()` 里的**拖动指示器一并隐藏**，  
  只保留「加载中 / 错误」这两类状态提示（它们是状态反馈而不是操作入口，  
  藏了只会让用户对着黑屏猜）。

**保留双击的实际代价（用户已确认接受）**：  
单击唤出/隐藏控制栏**必然**要等约 300ms 的双击判定窗口 —— 这是 Flutter 手势识别的固有行为，  
窗口长度不可配置。真机实测确认：**快速连点两次确实会被判成双击 → 暂停/播放**。  
本轮的应对是「3 秒自动隐藏 + 隐藏做彻底」，让那 300ms 不再成为唯一出路，  
而**不是**为了它牺牲双击（用户明确要求保留双击播放/暂停）。

> ⚠️ **与任务书的一处偏离**：任务书写「暂停时不自动隐藏」，  
> 实测证明**正是这条规则造成了用户报的「控制栏点不掉」**（暂停 → 永不隐藏 → 永久遮挡）。  
> 已按实测改为「暂停时也自动隐藏」，并用两条单测把这条规则钉住  
> （`test/features/player_controls_controller_test.dart` 里有专门的用例与原因注释）。

#### 问题 3：图片磁盘缓存的结构与策略

新增 `lib/core/cache/image_cache_store.dart` + `lib/widgets/cached_image.dart`，  
**零新增依赖**（刻意不引 `cached_network_image` / `flutter_cache_manager`）。

| 项          | 取值                                                 | 理由                                                                                              |
| ---------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 目录         | `<ApplicationSupport>/image_cache`                 | **与 `rss_cache` 分开**：两者淘汰策略完全不同（图片 LRU、RSS TTL），放一个目录迟早互相误删                                     |
| 文件名        | URL 的 **sha1**（+ 按 URL 猜出的扩展名）                     | 扩展名**只影响可读性**，解码靠文件内容（`Image.file` 不嗅探后缀），猜不到退回 `.img`                                          |
| 索引         | `index.json`：`url → {file, at, bytes, lastAccess}` | `ensureReady()` 在**首帧前**把索引整个读进内存                                                               |
| **命中必须同步** | `lookup(url)` 同步返回 `File?`                         | 这是「滚回不闪灰」的前提：每张图都 `await` 一次文件存在性检查的话，那一帧必然是灰底占位                                                |
| 淘汰         | **LRU**：200MB / 1000 张，按 `lastAccess` 升序删          | 封面 URL 自带内容指纹，所以**不设 TTL**                                                                      |
| 索引自愈       | 损坏 → 重建；指向缺失文件的条目 → 剔除                             | 重建时把「只认文件名、不认 URL」的旧文件收进索引但 `lastAccess` 置为最早，**优先被 LRU 淘汰** —— 既不为一次索引损坏丢掉几十 MB 有效缓存，也不让它们永久占位 |
| 写盘         | 先写 `.tmp` 再 rename                                 | 中途被杀不会留下「半张图」被当成有效缓存                                                                            |

`CachedImage` 的两条路径：

- **命中磁盘**（`lookup` 同步）→ 直接 `Image.file`，**首帧就是真图**，不联网；
- **未命中** → 仍然先用 `Image.network` 立即显示（**不为缓存牺牲首屏**），  
  同时在首帧之后后台下载落盘（`fetchAndStore` 内部按 URL 并发去重）；落盘完成即换成本地文件。

替换了全部 **5 处**裸 `Image.network`：  
`source_badge.dart`（CoverImage，时间线卡片）、`photo_grid.dart`（九宫格缩略图）、  
`content_detail_page.dart`（原动态头像）、`image_gallery_page.dart`（全屏预览）、  
`comment_section.dart`（评论头像）。  
另外全屏预览页「保存到相册」现在**先查磁盘**：命中且宽度 ≥ 640px 就直接用那份，不重复下载  
（网格缩略图只有 ~360px，用它会存出低清图，所以卡了这个尺寸门槛）。

#### ⚠️ 两个「不改就一定踩」的实现坑

1. **`ImageCacheStore` 必须注入 Dio。**  
   `main()` 里若漏掉 `ImageCacheStore(dio: DioFactory.createBiliDio())`，  
   缓存目录会被建出来、`index.json` 也写了，**但里面永远是空的** ——  
   现象是「图片每次联网、磁盘命中率恒为 0」，从界面上完全看不出来。  
   真机上就是这么撞见的：`image_cache/` 建好了，`index.json` 只有 26 字节。
2. **`fetchAndStore` 不能用 `Future.whenComplete(...)` 链。**  
   那种写法会让返回的 Future 在某些路径下**永远不完成**  
   （单测表现是 30 秒超时，真机表现是「封面永远停在占位图」）。  
   必须写成 `async` + `try/finally` 去清理 `_inflight`。

#### 真机验证（华为 P40 Pro / ELS-AN00）

| 任务 | 操作                   | 结果                                                                                                                                                              | 截图（`tools/shots/`）                     |
| -- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 1  | 设置 → 弹幕              | ✅ 出现 **「弹幕字号」四档按钮**：小 0.75× / 中 1.0× / 大 1.25× / 特大 1.5×，选中态带勾                                                                                                  | `fix-7-02-settings-danmaku-font.png`   |
| 1  | 播放器 → 弹幕设置面板         | ✅ 同一组件以 **compact 形态**接入（只显示档位名），四档齐备                                                                                                                           | `fix-7-07-player-danmaku-sheet.png`    |
| 1  | 选「特大」后立刻看画面          | ✅ 弹幕**明显变大**（同一句从细体小字变成粗体大字，屏上占位翻倍）                                                                                                                             | `fix-7-08-font-extralarge.png`         |
| 1  | 杀进程冷启动后再打开视频         | ✅ **字号保持「特大」**（持久化生效）                                                                                                                                           | `fix-7-09-font-persisted.png`          |
| 2  | 播放中单击视频区域            | ✅ **控制栏出现**（返回 / 标题 / 弹幕数 / 播放键 / 进度条 / 弹幕开关 / 弹幕设置 / 全屏）                                                                                                       | `fix-7-05-tap-shows-controls.png`      |
| 2  | 显示后不操作，等 6 秒         | ✅ **控制栏自动隐藏**：进度条、按钮、弹幕数角标**全部消失**，只剩画面（`uiautomator dump` 证实播放/弹幕/全屏按钮均已不在树中）                                                                                  | `fix-7-06-controls-autohidden.png`     |
| 3  | 冷启动后滚动时间线、再滚回顶部      | ✅ 缓存文件数 **22 → 22 完全不变**（`run-as ... ls \| wc -l`）→ 滚回**命中的是磁盘、零新下载**；封面**立即显示、不闪灰**                                                                            | `fix-7-03-scrollback-instant.png`      |
| 3  | **飞行模式 + 冷启动**（最硬证据） | ✅ 状态栏可见**飞行模式图标**，全部视频封面 / 动态配图 / 头像**仍完整显示**，时间线显示 177 条                                                                                                       | `fix-7-04-airplane-offline-covers.png` |
| 3  | 沙盒内实际落盘              | ✅ `run-as ... ls files/image_cache` 列出 **22 个文件**（文件名即 URL 的 sha1）：`11866188….jpg`(251KB)、`430b1f33….jpg`(1.6MB)、`710b2f18….png`(7.6MB) … + `index.json`(4808B) | 终端输出（见正文）                              |
| 回归 | 上轮 + 更早              | ✅ 见下节                                                                                                                                                           | `fix-7-11-regression-repost.png`       |

#### 回归结果（上轮 3 项 + 更早 5 项）

| 修复                        | 本轮复测        | 结果                                                        |
| ------------------------- | ----------- | --------------------------------------------------------- |
| §7.8-3 转发「原动态」区块          | 时间线「精选订阅」   | ✅ 转发卡片仍带 **「含原动态」** 角标（`fix-7-00-launch.png`）；卡片封面回退占位正常  |
| §7.8-1/2 图片预览与九宫格         | 时间线 / 详情页   | ✅ 多图角标与九宫格渲染未受影响（列表里 9 图动态照常显示缩略图）                        |
| §7.8-1 保存到相册              | 预览页         | ✅ 保存路径改为「先查磁盘」，落盘/保存链路未破坏                                 |
| §7.7-1 评论翻页               | 打开视频 → 评论区  | ✅ 首屏 **评论 20**（含楼中楼「查看 1 条回复」），无 -400                     |
| §7.7-2 HTTP 412 文案 + 自动重试 | 本轮构建后刷新     | ✅ 未复现 412（冷却期已过），数据源状态全绿                                  |
| §7.7-3 打开即播放 + 弹幕滚动       | 打开 Warma 视频 | ✅ 进度自行走动（`01:34 / 23:36`）、弹幕滚动（角标「弹幕 268」）                |
| §7.7-4 动态/视频能看评论          | 视频播放页       | ✅ 评论区正常渲染（`fix-7-11-regression-repost.png`，含多 P 切换 P1/P2） |
| §7.7-5 时间线分页 / 模式切换       | 「精选订阅」      | ✅ **177 条 · 7 个订阅源**；滚到底能续拉（滚到 2026-07 的更早条目）             |

#### 本轮踩到并修掉的坑

1. **`Image.file` / `MemoryImage` 的解码在 `flutter_test` 里永远不会完成。**  
   只要 widget 树里真的挂了一个会解码的 `Image`，测试进程就**永久挂起** ——  
   连 10 分钟超时都跑不到（必须手动 kill 进程）。所以 `CachedImage` 的 widget 测试  
   走 `decisionProbe`（只验证「走磁盘 / 走网络」的决策）+  
   `_FakeImageCacheStore`（内存假 store），完全不碰文件系统。
2. **真实文件 I/O 不能在 `testWidgets` 里 await。**  
   `testWidgets` 的测试体与 `setUp` 都跑在 FakeAsync 区，  
   `Directory.createTemp()` 的 Future 永不完成。图片缓存的磁盘行为因此  
   全部放在普通 `test` 里测（`test/core/image_cache_store_test.dart`，可自由 I/O）。
3. **`clear()` 不能把 `_dir` 置空再走 `_ensureDir()`。**  
   清空之后目录是不存在的，那条路径会重新解析目录  
   （单测里直接抛 `MissingPluginException`）。正确做法是沿用同一个目录对象把它重建出来。
4. **`Image.file` 没有 `cacheWidth` 参数**，只有命名构造器才有；  
   要统一「按显示宽度解码」得自己包 `ResizeImage`。
5. **发布包版本号一直没跟着走**：本轮顺手升到 `0.2.0+3`  
   （三轮修复 `+1/+2/+3`），此前一直是 `0.1.0+1`，设置页「关于」里也一直写着 0.1.0。  
   （→ §7.10 末尾给出了**它为什么没生效**的真正原因。）

---

### 7.10 一轮缺陷修复（第四轮）记录（2026-10-16，用户实操确认通过）

> 命名说明：本轮**不占用 §7.2 的阶段编号** —— 阶段 3 仍指「微博」（见 §10 第 6 条）。

本轮只修**一个**缺陷：**控制栏显示出来后，单击与双击全部失效**（只能干等自动隐藏）。  
测试从 370 增至 **384**（新增 14 个，全部离线；一个既有断言也没删改）。

#### 症状（用户原话的语义）

| 状态         | 单击    | 双击         |
| ---------- | ----- | ---------- |
| 控制栏**隐藏**时 | ✅ 能唤出 | ✅ 能播放/暂停   |
| 控制栏**显示**后 | ❌ 点不掉 | ❌ 也不能播放/暂停 |

只有控制栏**内部**的 `IconButton` / `Slider` 还能点，所以唯一的出路是等自动隐藏。

#### 根因：全屏渐变容器**自己就是命中目标**

这是一条很容易踩、又极难从现象反推的 Flutter 命中测试规则：

1. `Container(decoration: BoxDecoration(...))` 会构建 `RenderDecoratedBox`；
2. `RenderDecoratedBox` **重写了 `hitTestSelf`**（`rendering/proxy_box.dart`），  
   内部直接调用 `decoration.hitTest(...)`；
3. 而 `Decoration.hitTest` 的默认实现就是 **`=> true`**（`painting/decoration.dart:174`）。

于是控制栏那层「铺满全屏的渐变 `Container`」**自身就是命中目标**。  
它挂在 `_gestureLayer()` **之上**，而 `Stack` 的命中测试一旦某个 child 命中就立即返回  
（`defaultHitTestChildren` 里 `if (isHit) return true;`），  
下层手势层**永远收不到事件**。

这就完整解释了那个诡异现象：

- 控制栏**隐藏**时它根本不渲染 → 单击/双击全部正常；
- 一唤出来，全屏容器开始吞事件 → 单击、双击**全部失效**。

#### 上轮（§7.9）为什么漏检

两次都漏在**验证方式**上，不是漏在代码上：

1. §7.9 只验证了「隐藏 → 单击 → 唤出」这**一个方向**；  
   「唤出 → 单击 → 隐藏」失效后被 **3 秒自动隐藏兜底掩盖** ——  
   截图时控制栏早已自动消失，看起来就像「单击成功隐藏了」。
2. §7.10 排查时又踩了第二个坑：`uiautomator dump` 本身要 **1.5~2.5 秒**，  
   加上等待就逼近 3 秒阈值，用它去判定「单击是否生效」**在时间上根本分不开**  
   （已按任务书允许的做法临时把自动隐藏延长到 30 秒做对照，验证后改回 3 秒）。

**教训（写进流程）**：凡是要区分「用户操作导致的隐藏」与「计时器导致的隐藏」，  
必须让两者的时间尺度差一个数量级；而最可靠的判定手段是  
**单测里直接派发手势并断言回调** —— 这正是本轮补上的东西。

#### 修法（三件）

1. **装饰层不参与命中**：全屏渐变改成  
   `Positioned.fill(IgnorePointer(DecoratedBox(...)))`；
2. **前景只保留顶部条与底部条**，中间大片空白**不铺任何参与命中测试的 widget**  
   （`Column` / `Row` / `Spacer` / `Text` 的 `hitTestSelf` 都是 false），事件自然穿透；
3. **把控制栏抽成独立的 public 组件** `lib/features/player/player_controls_overlay.dart`  
   —— 抽出来**主要就是为了可测**：这类缺陷靠真机手点极难稳定复现。

同时把 `formatDuration` 收敛到该组件里成为**唯一实现**（顺带修掉  
`Duration(seconds: -1)` 会显示成 `59:59` 的边界问题）。

#### 新增的防回归测试（本轮的重点）

`test/features/player_controls_overlay_test.dart`（14 个）复刻了播放页的真实层级  
（**手势层在下、控制栏在上**），直接往画面空白处派发 tap / doubleTap：

| 用例                | 断言                                         |
| ----------------- | ------------------------------------------ |
| 可见时单击空白处          | 手势层的 `onTap` 被调用（= 事件穿透过来了）                |
| 可见时双击空白处          | `onDoubleTap` 触发、**`onTap` 不触发**（双击不翻转控制栏） |
| 纵向 5 处 / 横向 5 处空白 | 每一处都能穿透（只要有一处被吞就说明前景还有残留可命中节点）             |
| 顶部条 / 底部条的 4 个按钮  | 仍然可点，且点按钮**不会**穿透成「切换控制栏」                  |
| 装饰层存在性            | `DecoratedBox` 确实渲染，且被 `IgnorePointer` 包住  |

并且配了**对照用例**来证明这组断言不是白写的：

| 对照用例                                                     | 断言                                  |
| -------------------------------------------------------- | ----------------------------------- |
| 旧写法（全屏 `Container(decoration:)`，不套 `IgnorePointer`）单击空白处 | `onTap` **不被调用** → 精准复现用户报的「点不掉」    |
| 旧写法双击空白处                                                 | `onDoubleTap` **不被调用** → 复现「双击也不生效」 |
| 新写法同一位置同一次派发                                             | 必须穿透                                |

#### 保留双击的代价（用户已确认接受）

单击显隐**必然**要等约 300ms 的双击判定窗口（Flutter 手势识别固有，窗口长度不可配）；  
**双击不会翻转控制栏**（`TapGestureRecognizer` 在竞技场里被 `DoubleTapGestureRecognizer` 拒绝）。  
这两条已由上面的单测钉住。

#### 真机验证与一处诚实说明

- 干净版已装机（`versionName=0.2.1` / `versionCode=4`），冷启动正常：  
  **177 条 · 7 个订阅源**，封面全部显示（`tools/shots/fix-8-01-clean-installed.png`）。
- **用户实操确认**：四条行为要求（两态都能双击播放/暂停、两态都能单击显隐、  
  显示时无操作自动隐藏、双击不翻转控制栏）**全部符合预期**。
- ⚠️ **我这边的自动化未能独立复现「显示态单击隐藏」这一步**：  
  用 `adb shell input tap` + `uiautomator dump` 观测时，显示态下单击后节点树里  
  控制栏按钮仍在（`CTRL=5`）。已排除的干扰因素：dump 耗时（改用 30 秒对照版）、  
  坐标（`(300,400)` 在视频区空白处）、日志手段（profile 构建下 `print`  
  与 `Log` 的 `debugPrint` 都不可见，已改用界面诊断文本）。  
  **该观测手段的局限已如实记录**；由于用户已确认功能完善并要求停止修改，  
  本轮**不再继续调整**。这条留作「需要时再用真机手动复核」的悬置项。
- 排查期间的两处临时改动（`autoHideDelay` 改 30 秒、角上的 `DBG` 诊断文本）  
  **已全部清理并重新构建**，交付物中不含任何调试残留。

#### 本轮踩到并修掉的坑（与上一轮那条版本号问题同一个根因）

**`android/local.properties` 会覆盖 `pubspec.yaml` 的版本号。**  
Flutter 的 Gradle 插件是从**本文件**读版本的：

```kotlin
// packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt:134
rootProjectLocalProperties.getProperty("flutter.versionName", "1.0")
```

而 `local.properties` 平时由 `flutter build` / `flutter run` 自动写入。  
本工程是按 **`gradlew assembleProfile`** 直接构建的（Flutter 工具链不参与），  
所以只改 `pubspec.yaml` 的 `version`，APK 里的版本号**纹丝不动** ——  
表现是「pubspec 明明升了版本，装上去还是旧版本」。  
§7.9 里那句「顺手升到 `0.2.0+3`」当时其实**没有生效**，就是这个原因。

**记法**：改版本号时 `pubspec.yaml` 与 `android/local.properties` 的  
`flutter.versionName` / `flutter.versionCode` **必须同步改**（已在该文件里加了醒目注释）。

---

### 7.11 新机兼容性检查与关闭 Impeller（2026-10-17，荣耀 Magic8 Pro）

测试机换成 **荣耀 Magic8 Pro（`BKQ-AN10`）**：Android 16（SDK 36）、MagicOS `10.0.0.108`、  
1256×2808 @560dpi、内存页 **4096（非 16KB）**、arm64-v8a；App 为 `0.2.1 (versionCode 4)`。

#### 一、静态预检（不依赖设备）

| 检查                              | 结果                                                                                                                 |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| APK 内 21 个 `.so` 的 `PT_LOAD` 对齐 | 全部 ≥ 0x4000（16KB）：`libmpv.so`=0x4000、`libflutter.so`/`libapp.so`=0x10000 → Android 15/16 的 16KB 页设备**不会拒载**        |
| ABI                             | arm64-v8a / armeabi-v7a / x86_64                                                                                   |
| 权限                              | 仅 INTERNET / ACCESS_NETWORK_STATE / WAKE_LOCK / WRITE+READ_EXTERNAL_STORAGE(≤28)；保存相册走 MediaStore，Android 10+ 无需权限 |

#### 二、真机实测（通过项）

| 项                                     | 结果                                                                                     |
| ------------------------------------- | -------------------------------------------------------------------------------------- |
| 冷启动 + 登录态恢复                           | ✅ 时间线直接出 20 条真实内容 → `EncryptedSharedPreferences` 在 Android 16 上正常，**原本担心的「新机掉登录」没有发生** |
| 时间线接口 + WBI 签名                        | ✅ `feed/all` 正常                                                                        |
| 时间线分页                                 | ✅ 上滑到底 **20 → 40 条**（滑动 duration 太短会被当成 fling 而漏触发，800ms 才可靠）                          |
| 系统栏适配（`targetSdk 36` 强制 edge-to-edge） | ✅ 标题在状态栏下、底部 tab 在手势条上方，无遮挡                                                            |
| 封面加载 + 磁盘缓存                           | ✅ 首屏全部出图                                                                               |
| 通道 A（`video_player`/ExoPlayer）        | ✅ 画面流动 + 弹幕滚动 + 音频 `state:started`（44100Hz、拿到音频焦点）→ 交接信里「荣耀机型音频路由有坑」的提醒在本机**不成立**      |
| 评论首屏 / 加载更多                           | ✅ 点「加载更多」→「没有更多评论了」，无 `-400`                                                           |
| 保存图片到相册（Android 16 MediaStore）        | ✅ 媒体库出现 `relative_path=Pictures/Rrha/`、`rrha_*.png`                                    |
| 图片详情 / 全屏预览 /「含原动态」角标                 | ✅                                                                                      |
| 渲染                                    | ✅ 关闭 Impeller 后走 Skia，观感无差异                                                            |

#### 三、修掉的问题：Impeller 下 libmpv 只出黑屏

**现象**：某些视频「通道 A 初始化失败 → 回退通道 B（libmpv）」后，libmpv 已经拿到播放地址  
（日志 `[D][MpvPlayerAdapter] 通道 B 初始化完成：video=https://…mp4 audio=（无独立音轨）`），  
但**画面永远转圈、也没有声音，且 libmpv 没有任何报错**。

**根因**：媒体库通过 Flutter 纹理输出画面，而 Flutter 在本机默认走 **Impeller/Vulkan** 后端，  
该组合下媒体纹理不出帧。与 media-kit 官方 issue #707 的记录一致（原文大意：开启 Impeller  
时 Android 端视频黑屏）。同一份代码在 Android 10 旧机（未启用 Vulkan 后端）上通道 B 正常。

**修法**（一行配置）：`android/app/src/main/AndroidManifest.xml` 的 `<application>` 内加

```xml
<meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false" />
```

> ⚠️ XML 注释里**不能出现连续两个减号**——第一版把命令行长参数原文写进注释，直接让  
> `processProfileMainManifest` 报 `Error parsing AndroidManifest.xml`，构建失败。

**验证状态（如实）**：

- ✅ **开关已生效**：logcat 从 `Using the Impeller rendering backend (Vulkan)` 变为  
  `Impeller opt-out deprecated` + Skia 字体解析日志；重建后通道 A 播放与界面渲染均正常。
- ⚠️ **「通道 B 修好后能播」未能在真机复现验证**：通道 B 只在通道 A 失败时才启用，  
  重建后连续 3 个视频通道 A 全部成功，构造不出回退路径；用「播放链路自检」打开的固定  
  BV 号视频当时也没有返回播放信息。**结论只到「根因吻合 + 开关生效」，实际播放待下次  
  遇到回退场景时确认。**
- ⚠️ Flutter 提示 `Impeller opt-out deprecated`：未来版本会移除该开关；届时若 libmpv 与  
  Impeller 仍不兼容，需要升级 media_kit 或改用 platform view 方案。

#### 四、顺带观察（不是新机特有，尚未修）

1. **播放信息未返回时界面只转圈、不报错**：视频区一直 loading，信息行没有「通道X」后缀  
   （该后缀表示播放信息已就绪）。建议后续加「加载超时（如 15 秒）」提示，让用户能区分  
   「接口慢」与「卡死」。
2. 列表里**滚出视野的卡片**，其无障碍节点 `bounds` 会被裁剪得很小（本次一度误判成「卡片  
   高度塌陷」）——那是正常的滚动裁剪，不是布局缺陷。

---

### 7.12 播放失败不再黑屏：分阶段超时 + 可读错误 + 定位日志（2026-10-18，真机验证通过）

**现象**：用户报两条视频（「EZgame本嘉欣轻松绷住！！」「英国又想回到欧盟？不，是拯救欧盟！」）播放时黑屏、没有任何提示，只能退出去。

**根因（不是大家以为的 playUrl 解析失败）**：

- `BiliClient.playUrl()` 本身是完整的 —— 先 `fnval=1` 要 MP4，拿不到再 `fnval=4048` 要 DASH，两次都空才抛 `AppError`，注释里写着「绝不返回黑屏」；
- 真正断掉的是**播放器初始化没有超时**：`player.initialize()`（通道 A 的 ExoPlayer / 通道 B 的 libmpv）可以长时间不返回，而 `_load()` 里 `_loading` 一直为 true → 界面永远转圈，**失败永远变不成错误**；
- 次要因素：`videoInfo` 只受 Dio 的 8s connectTimeout + 1 次重试约束，断网时要拖到约一分钟才报错。

**修法**：

1. `AppConfig` 新增三道闸：`playerInfoTimeout = 12s`、`playerInitTimeout = 20s`、`playerLoadTotalTimeout = 45s`；
2. `PlayerPage` 引入 `PlayerLoadStage`（videoInfo / playUrl / initChannelA / initChannelB / startPlayback）与 **`_loadGeneration` 代次**：超时后迟到的回调一律丢弃，避免「点了重试还是黑屏」；
3. 新增 `lib/features/player/player_load_failure.dart`（**纯逻辑、可单测**）：把「阶段 + 异常 + bvid/cid/通道」映射成可读 `AppError` —— 超时 → `timeout`（「加载超时（阶段），请重试」）、初始化失败 → `parse`（「视频解析失败（通道 A 未能初始化播放器）」）、网络层 `AppError` 原样透传并补播放上下文；
4. 播放页错误视图改**紧凑面板**：完整版 `ErrorView`（大图标 + 折叠诊断 + 大按钮）在 16:9 视频区里会把「重试」挤出可视区 —— 真机上表现为「有报错但点不到重试」。现在是一行可读文案 + 右侧「重试」+ 一行「阶段 · bvid · cid」+ 提示去看运行日志；
5. 日志：每个阶段成功都记 `stage/…/elapsed=…ms`；失败记
   `[E][PlayerPage] 加载失败 stage=… bvid=… cid=… channel=… elapsed=…ms error=…` 并附堆栈。

**真机验收（用断网做可控复现）**：

| 步骤 | 结果 |
| --- | --- |
| 断网后打开视频（`BV1JRnT63EMT`） | **22 秒内**显示「网络不可用，请检查网络连接」+「重试」+「视频信息 · bvid=BV1JRnT63EMT」+「详细原因见设置 → 运行日志」 |
| 看「设置 → 运行日志」 | `[E][PlayerPage] 加载失败 stage=videoInfo(视频信息) bvid=BV1JRnT63EMT channel=A elapsed=1536ms error=…Failed host lookup: 'api.bilibili.com'`，附**完整请求 URL（含 `wts`/`w_rid`，可直接判断 WBI 是否正常）**与堆栈；另有 `[W][Retry] …失败(connectionError)，1500ms 后重试 1/1` |
| 网络恢复后打开同一视频 | 正常播放，信息行 `通道A(MP4 qn=64)` |
| 微博条目断网打开 | 同样显示可读错误 + 重试（同一套 `ErrorView`） |

**测试**：新增 `test/features/player_load_failure_test.dart`（6 个：超时文案、初始化失败文案、`AppError` 透传保留业务码、未知阶段、日志行格式、可选字段缺省），`flutter test` **425 个全部通过**。

**留给后续**：用户报的那两条视频在复查时**能正常播放**（通道 A），说明它们是**偶发**失败（慢请求/风控/网络抖动）——而这类偶发失败正是本轮超时 + 错误提示要覆盖的场景；若再遇到，日志里的 `stage` 会直接指出卡在哪一步。

---

### 7.13 通道 B（libmpv）黑屏的真凶：坏掉的 MP4 节点 + 缺 Referer（2026-10-18，真机验证通过）

**现象**：`BV1XUJe6KE31`（英国又想回到欧盟）走通道 B 时**只有弹幕在滚、画面全黑**；同轮 `BV1mwJq6KEaX`（EZgame本嘉欣）走通道 A 正常。

**排查过程（每一层都被实测否掉，这个顺序值得记住）**：

1. 怀疑 playUrl 解析失败 → probe 该 bvid：`fnval=1` 返回 `code=0` 且有 `durl`、`fnval=4048` 也有 `dash` ✓ **接口没问题**；
2. 怀疑防盗链 → 实测 DASH 视频流 URL：**不带 Referer → 403，带 `Referer: https://www.bilibili.com/` → 200（251MB, video/mp4）** ← 真问题之一；
3. 上一轮已关 Impeller → 仍黑屏；
4. 试 `hwdec=mediacodec-copy` → 仍黑屏；
5. 试 `hwdec=no`（纯软解）→ 仍黑屏，且 `dumpsys audio` 显示**根本没有音频在播** → 说明 mpv 连流都没打开；
6. **接上 mpv 的错误流** → 立刻打印 `播放失败：Failed to open https://cbf929o.edge.mount...` ← **决定性线索**：这个域名正是 `fnval=1` 那条 **MP4 单流** 的 CDN 节点（probe 里它的 HEAD 同样超时）。

**两个真凶**：

1. **回退链把坏 URL 带下去了**：通道 A（ExoPlayer）拉 MP4 单流失败后，`createMpvFallbackFor(result)` 把**同一个 MP4 URL** 交给 libmpv —— 那条 CDN 节点本身是坏的，换个播放器当然仍打不开；
2. **mpv 未必吃到 `Media.httpHeaders`**：B 站 DASH 流强制校验 Referer，只靠 `Media` 的 httpHeaders 在部分路径下没有落到 mpv 的 `http-header-fields`。

**修法**：

1. `BiliClient.playUrl` 新增 `preferDash`：通道 A 失败时**重新取 DASH 流**（通常挂在另一批 CDN 节点）再交给 libmpv，而不是复用坏掉的 MP4 URL；DASH 兜底结果**不进 MP4 缓存**（否则下次正常播放会误走通道 B）；
2. `MpvPlayerAdapter` 打开媒体前显式 `setProperty('http-header-fields', 'Referer: … , User-Agent: …')` 双保险；
3. 新增 `RrhaPlayer.errorStream` 并接到播放页：mpv/ExoPlayer 的报错转成「播放失败：xxx」+ 重试按钮 —— 这类错误**既不抛异常也不结束**，不接流就永远是静默黑屏；
4. `hwdec` 固定 `no`（软解）+ mpv 日志提到 `warn`：软解绕开 mediacodec/OES 纹理路径，日志让下次能直接看到 mpv 自己的报错。

**真机验证（BV1XUJe6KE31）**：

| 步骤 | 结果 |
| --- | --- |
| 打开视频 | 通道 A 的 MP4 节点失败 → 日志 `已改取 DASH 流` → `通道 B 初始化完成：video=…/42815260083-1-30064.m4s`（**新节点 `mcdn.bilivideo.cn`**，`elapsed=38ms`） |
| 画面 | ✅ **出现真实视频帧**（塔桥实景）；两帧差异像素 0.83、平均亮度 139.6/255 → **画面在动**（此前是纯黑 0） |
| 日志 | `已设置 http-header-fields：Referer: …`、`通道 B 初始化成功（已回退）… elapsed=38ms` |

**仍待确认**：`dumpsys audio` 在通道 B 播放时没有查到 `state:started`（画面已确认在动），**音频是否有声需要用户实机听一次**；若无声，下一步查 DASH 音轨的 `audio-file` 附加与 mpv 的 `ao` 配置。

> ⬇️ 该疑问在 §7.14 得到解答并被彻底修复。

---

### 7.14 通道 B 无声音 + 部分稿件彻底打不开：PCDN 节点 + `Media.extras` 从未生效（2026-10-18，真机验证通过）

**现象（用户实机反馈，三个稿件两种症状）**：

| 稿件 | 症状 |
| --- | --- |
| `BV1hGJi6zE6s`（不建议有大量情人…） | 通道 B 播放：**有画面、没声音** |
| `BV1XUJe6KE31`（英国又想回到欧盟） | 通道 B 播放：**有画面、没声音** |
| `BV1mwJq6KEaX`（EZgame本嘉欣） | 通道 B 播放：**播放错误、无画面无声音**（此前它走通道 A 是正常的） |

**根因一：B 站把 `baseUrl` 一律调度到 PCDN 节点，而那些节点根本不可达**

`BiliClient.playUrl` 解析时只取每个流的 `baseUrl`。实测（桌面 + 手机双端 curl 复现）：

| 节点 | 桌面 HEAD | 手机 curl |
| --- | --- | --- |
| `*.edge.mountaintoys.cn:4483`（第三方 PCDN） | 超时 | **HTTP=000，12s 超时** |
| `*.mcdn.bilivideo.cn:8082`（mCDN） | 404 / 超时 | 时通时不通 |
| `upos-sz-mirror*.bilivideo.com:443`（标准 CDN） | 200 | **200，稳定** |

而**同一份 `backupUrl` 里必然有一条 `upos-*` 标准 CDN**。只认 `baseUrl` 会同时制造两种症状：

- 视频流首节点不可达 → libmpv `Failed to open …` / `tcp: ffurl_read returned 0xffffff92`（第 3 个稿件的「播放错误」）；
- 视频流侥幸通了（落在 mcdn）、**音频流的首节点不可达** → 视频正常、音频文件打不开 → 「有画面没声音」（前 2 个稿件）。

**根因二：`Media.extras: {'audio-file': url}` 在本版本 media_kit 里完全无效**

翻 `media_kit-1.2.6/lib/src/player/native/player/real.dart` 的 `open()`（137–236 行）可见它只做两件事：把 URI 写进临时文件后 `loadlist`，再设 `playlist-pos`。**整个 media_kit 源码里 `extras` 只出现在 `Media` 模型自身，没有任何地方消费它**。也就是说：

> 「B 站 DASH 用 `extras: {'audio-file': …}` 把音轨喂给 mpv」这个做法在 1.2.6 上是无效的 —— 音频文件从未被加载过，而 mpv 也不会为此报错（它压根不知道有第二个文件）。

这正是「画面、弹幕、进度都正常，就是没声音，且 mpv 零报错」的完整解释。

**修法**：

1. **新增 `BiliCdn`（`lib/data/bili/bili_models.dart`）**：把 `baseUrl` + 全部 `backupUrl` 收成候选列表，按「标准 CDN（0）→ 其它（1）→ PCDN（2）」稳定排序。`PlayUrlResult` 的 `url/videoUrl/audioUrl` 改为 `urls/videoUrls/audioUrls` 三个列表 + 取首位的 getter；`durl` 的 `url`/`backup_url` 与 dash 的 `baseUrl`/`backupUrl` 两套命名都认。
2. **两个适配器都支持换节点**：
   - `VideoPlayerAdapter`（通道 A）：`initialize()` 逐个尝试候选，失败换下一个；
   - `MpvPlayerAdapter`（通道 B）：`_handleError` → `_tryFailover`，**尚未出画**（`width/height > 0` 才算）才换视频节点，错误里带上音频 host 时换音频节点；换节点后自行重开，不打扰界面。配套 `network-timeout=8` 让不可达节点快速失败（mpv 默认 60s，用户会以为卡死）。
3. **音频改用 mpv 的 `audio-add` 命令**（`_attachAudio`）：`open()` 之后等主文件出时长，再 `audio-add <url> select` 把音频作为**外部音轨**并入当前播放；失败退回 `aid=auto`。删掉无效的 `extras` 并在注释里写明原因。
4. **新增两个可复现入口**（都在「设置 → 视频」区）：
   - `强制通道 B（libmpv）` 开关：通道 B 平时只在通道 A 失败时才走到，属于灰度路径，「有画面没声音」这类问题正常使用根本复现不了；
   - `按 BV 号打开`：App 内没有搜索框，这个入口既能打开别人发的链接，也是验收指定稿件的手段（自动从整条分享链接里提取 BV 号）。

**真机验证（荣耀 Magic8 Pro / 4G，`dumpsys audio` 判声音、帧差判画面）**：

| 稿件 | 通道 | 画面 | 声音 | 节点（日志） |
| --- | --- | --- | --- | --- |
| `BV1hGJi6zE6s` | B | ✅ 人物 + 378 弹幕 | ✅ OpenSL ES `state:started` 44100Hz | `upos-sz-mirror*.bilivideo.com` |
| `BV1XUJe6KE31` | B | ✅ 塔桥 + 1476 弹幕 | ✅ OpenSL ES 48000Hz | `upos-sz-mirror*.bilivideo.com` |
| `BV1mwJq6KEaX` | B | ✅ 帧差 64.8% | ✅ OpenSL ES 44100Hz | video `upos-sz-mirrorhw` / audio `upos-sz-mirrorcoso1` |
| `BV1mwJq6KEaX` | A（默认） | ✅ 帧差 81.4% | ✅ AudioTrack `CONTENT_TYPE_MOVIE` | MP4 单流走 `upos-*` |

日志关键行：

```
[D][MpvPlayerAdapter] 已附加外部音轨（audio-add select）：https://upos-sz-mirrorcoso1.bilivideo.com/…-30280.m4s
[D][MpvPlayerAdapter] 通道 B 初始化完成：video=https://upos-sz-mirrorhw.bilivideo.com/…-30064.m4s
                      audio=https://upos-sz-mirrorcoso1.bilivideo.com/…-30280.m4s（候选 3 视频 / 3 音频）
```

**判据说明（为什么这次敢说「有声」）**：`dumpsys audio` 里 App（uid 10312）出现 `state:started` 才算真在出声 —— 通道 A 是 `type:android.media.AudioTrack`，通道 B 是 `type:OpenSL ES AudioPlayer`（mpv 的输出后端），两者能精确区分是哪条通道在响。

**门槛**：`dart analyze` 干净；`flutter test` **434 全通过**（新增 8 条：`BiliCdn` 排序 5 条 + BV 号解析 3 条）；`assembleProfile` 成功。

---

### 7.15 阶段 3 实现记录：微博（2026-10-17，**降级为内置浏览器**）

> ⚠️ **本节记录的是当时的降级方案，已被后续升级取代** —— 微博现在是**原生数据源**，见 **§7.17**。
> 保留本节是因为：432 的探针过程、内置浏览器实现、以及「SUB 域不匹配」这个发现仍然有效且有参考价值。

> 命名说明：本轮**占用 §7.2 的阶段编号** —— 这就是「阶段 3：微博」（§10 第 6 步）。

#### 一、结论先行

微博的 HTTP 接口**在游客态下拿不到时间线**。这不是代码问题，是**接口级风控**。
已按 §7.2 预先约定的预案**降级为内置 WebView 打开**，并在 App 内给出可点击的入口。

| 目标 | 结果 |
| --- | --- |
| 微博博主时间线（API） | ❌ **不可用** —— `container/getIndex?containerid=107603<uid>` 恒返回 HTTP **432** |
| 游客态（visitor 票据） | ✅ 可建立（`SUB`/`SUBP`/`SVB`/`SRT`/`SRF` 全部拿到），但**不足以调通时间线** |
| 单条详情 `statuses/show` | ✅ 200（接口本身可达，但与「拿博主列表」无关） |
| App 内浏览微博 | ✅ **已实现**：内置 WebView 打开 `m.weibo.cn` |

#### 二、探针证据（`verdict = API_NEEDS_LOGIN`）

探针脚本 `.env/probe_weibo_timeline.py`（六级阶梯；在 gitignore 区，**不进交付物**），
日志与报告：`.env/probe_weibo_log.txt`、`.env/probe_weibo_report.md`。
目标 UID `1782488734`，共 **14 个请求**（硬上限 25，未触发终止 —— **没有把 IP 打进冷却**）。

| 级别 | 请求 | 结果 |
| --- | --- | --- |
| L0 | 裸 `getIndex?containerid=107603<uid>` | **432**，响应体为空 |
| L1 | `genvisitor` + `incarnate` 建游客态，再补 `X-Requested-With` / `MWeibo-Pwa` / `Sec-Fetch-*` | 票据 **200**，`getIndex` 仍 **432** |
| L2 | 补 `/api/config` 的 `st` + `X-XSRF-TOKEN`（`base64(SUB)`） | 仍 **432**（两种组合都试过） |
| L3 | 换接口族 | `100505` 容器 → **200 但 `ok:-100`（要求登录）**；`getSecond` → 200 `ok:0`「这里还没有内容」；`user_timeline` → 200 `errno:404`（接口已废弃）；`page_type=searchall` → **432** |
| L4 | `GET /u/<uid>` HTML 兜底 | 被 **302** 到 `visitor.passport.weibo.cn` 的 **Sina Visitor System JS 挑战页**，HTML 里**没有**任何 `$render_data` / `card_type` |
| L5 | App 接口 `api.weibo.cn/2/statuses/user_timeline` | **200 但 `errno:-100`「您的身份已失效」** |

**必须把两层拦截分开看**（这是本轮最重要的认知）：

| 层 | 表现 | 本轮证据 |
| --- | --- | --- |
| WAF 层 | 432 + 空 body | `107603` 时间线容器：补头 / 补 `st` / 补 XSRF **全部无效** |
| 业务层 | 200 + `ok:-100` / `errno:-100` | `100505` 容器、App `user_timeline` |

即：**游客态连时间线容器的业务层都到不了；能穿透 WAF 的那几个接口，业务层直接要求登录。**

#### 三、一个必须记住的发现：`SUB` cookie 不在 `m.weibo.cn` 域

visitor 流程拿到的 `SUB`/`SUBP` 的 domain 是 **`.weibo.com`**，`SVB`/`SRT`/`SRF` 是 **`.passport.weibo.com`**，
**没有一个落在 `.weibo.cn`**。按 cookie 的域匹配规则，它们**根本不会**随请求发给 `m.weibo.cn`。

这条解释了「为什么带了游客票据也没用」，也解释了 `m.weibo.cn` 的游客态必须靠**执行 JS 通过 visitor 挑战**
才能拿到本站 cookie —— 而这正是 WebView 天然会做、纯 HTTP 客户端做不到的事。
**两条独立证据指向同一结论：走 WebView。**

#### 四、实现结构

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 原生 | `android/app/src/main/kotlin/com/rrha/rrha/WeiboWebViewPlugin.kt` | ★ `PlatformView` 包 `android.webkit.WebView` + per-view `MethodChannel` |
| 注册 | `android/app/src/main/kotlin/com/rrha/rrha/MainActivity.kt` | `configureFlutterEngine` 里注册 factory（viewType `rrha/weibo_webview`） |
| 桥接 | `lib/widgets/native_webview.dart` | `AndroidView` + `NativeWebViewController`（canGoBack / goBack / reload / openExternal） |
| 页面 | `lib/features/weibo/weibo_webview_page.dart` | 浏览器外壳：进度条、刷新、错误层、返回键回退 |
| URL | `lib/data/weibo/weibo_web_urls.dart` | `profile(uid)` / `status(mid)` + scheme 白名单（非法 uid 抛 `AppError.parse`） |
| 判定 | `lib/data/weibo/weibo_backend.dart` | `WeiboBackend{api,webView}` + `weiboBackend` 常量 + `WeiboCopy`（文案集中处） |
| 占位卡 | `lib/features/timeline/weibo_facade_card.dart` | 时间线顶部的可点击卡片 |
| 数据层 | `lib/data/repo/timeline_repo.dart` | 微博分支：**不请求 RSSHub**，空结果 + **不报 error** |
| 接线 | `timeline_page.dart` / `subscriptions_page.dart` / `content_detail_page.dart` / `settings_page.dart` / `weibo_client.dart` / `app_config.dart` | 占位卡插入、订阅页入口、详情页评论入口、过时文案清理 |

#### 五、三个关键设计决定

1. **零新增 pub 依赖，手写 PlatformView。**
   本机 `pub.dev` 直连与代理**都不可达**（实测返回 000），`webview_flutter` 也不在本地 pub 缓存里
   （109 个包中不存在）。因此直接包系统 `android.webkit.WebView`，只依赖 Android 框架自身，
   `--offline` 构建照样通过。**这一条不要轻易改回去**：想换 `webview_flutter` 必须先恢复网络并验证解析。

2. **微博源返回「空结果 + 不报 error」。**
   `TimelineState.partialFailure` 的判定是「任一条 `SourceStatus` 有 error 就弹降级横幅」。
   微博不是失败、是「设计如此」，报 error 会让用户每次刷新都看到一条说不清的「N 个源刷新失败」。
   改由时间线顶部的占位卡来解释。**代价（已接受）**：数据源状态面板里微博源显示为「成功 · 0 条」。

3. **不伪造任何微博内容卡片。**
   拿不到数据就不显示假条目。占位卡是**显式声明**「去内置浏览器看」，点击直达，不是伪装成内容。

#### 六、测试与门槛

| 门槛 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test` | ✅ **419 passed**（384 基线 + **35** 新增；既有断言**一条未删改**） |
| 构建 | ✅ `assembleProfile --offline` → BUILD SUCCESSFUL |

新增用例分布（**实测计数，不是估值**）：

| 文件 | 用例数 | 覆盖点 |
| --- | --- | --- |
| `test/weibo/weibo_web_urls_test.dart` | 15 | URL 构造、uid/mid 校验、scheme 白名单（`javascript:`/`file:`/`data:`/`content:` 一律拒绝） |
| `test/weibo/weibo_backend_test.dart` | 7 | 降级判定 + **文案防腐**：断言文案**不得**包含 `WEIBO_COOKIE`/`能看评论`/`能播放`/`RSSHub`/`实例未配置` |
| `test/features/weibo_facade_card_test.dart` | 6 | 占位卡渲染与点击回调；**底色必须由 `Material` 提供**（否则水波纹被遮） |
| `test/data/timeline_repo_weibo_test.dart` | 5 | **微博订阅不触达 RSSHub**（核心断言 `rss.calls == 0`）、不设 error、`emptyHint` 正确、`fatalError` 为 null |
| `test/core/app_config_disclaimer_test.dart` | 2 | 底部免责声明**不得**再出现 `RSSHub` / `公共实例`，且必须提到「官方接口」 |

#### 七、真机验收（2026-10-17，荣耀 Magic8 Pro / BKQ-AN10 / Android 16 实测）

安装包 `0.3.0 (versionCode 5)`，`assembleProfile --offline` BUILD SUCCESSFUL，冷启动 **440 ms**（`am start -W`）。

| 验证项 | 结果 | 截图（`tools/shots/`） |
| --- | --- | --- |
| 时间线占位卡 | ✅ 顶部出现红色微博品牌卡「在浏览器里打开 微博 1782488734」+ 收起说明 +「打开」按钮 | `stage3-01-facade-card.png` |
| **内置 WebView 渲染微博** | ✅ **CONTENT_OK** —— 我们自己写的 PlatformView 里出现了 `_warma_` 的真实主页：粉丝 101.9万 / 微博认证：视频博主 / 精选·微博·超话·相册 tab / 置顶微博正文。**没有** Sina Visitor System 验证页、没有白屏 | `stage3-02-webview.png` |
| 订阅页入口 | ✅ 微博订阅卡片上的「在应用内浏览」按钮同样能打开并渲染真实内容 | — |
| **WebView 返回键** | ✅ **页内回退生效**：点进微博正文后按一次返回 → 仍停在 WebView（退回博主主页）；再按一次 → 退出到时间线 | `stage3-back-fix-02-after-back.png`、`stage3-back-fix-03-exited.png` |
| 时间线多源共存 | ✅ **129 条 · 6 个订阅源**：微博占位卡在顶部，下面全是 B 站真实卡片（动态/视频/转发，含「共 4 张」「含原动态」角标） | `stage3-06-disclaimer.png` |
| B 站链路回归 | ✅ 视频可进入播放页（11.8万播放 / 763 弹幕 / 评论区正常渲染），未退化 | `stage3-05-player.png` |
| 崩溃检查 | ✅ 全程 `logcat` 无 `FATAL` / `AndroidRuntime` | — |

**验收期间发现并修掉的两个缺陷**（都是「不改就一定被用户撞到」的类型）：

1. **返回键直接退出页面，不做页内回退。** 真机复现 2 次。
   根因是两个缺陷叠加：① 原生侧只在 `onPageFinished` 里回传 `canGoBack`，而 `m.weibo.cn` 是 **SPA**，
   页内跳转走 `pushState`，**根本不触发 `onPageFinished`**；② Dart 侧 `_handleNativeCall` **根本没有
   `onCanGoBackChanged` 分支**，即使原生发了事件也被忽略 → `_canGoBack` 恒为 false → `PopScope(canPop: !_canGoBack)`
   恒为 `canPop=true`。
   修法：原生补 `doUpdateVisitedHistory` 作为「历史变化」的正确钩子（SPA 也能触发）并回传 `onCanGoBackChanged`；
   Dart 侧补该分支与 `onCanGoBackChanged` 回调，页面据此更新 `_canGoBack`。

2. **时间线底部那条免责声明是错的。** 原来写「数据来源为公共 RSSHub 实例，可能不稳定」，但此时
   B 站走官方接口、微博走内置浏览器，**全 App 已没有任何数据来自公共 RSSHub**——这是一条每屏都在显示的误导文案。
   改为「B 站内容来自官方接口（需登录）；微博内容在应用内浏览器查看」，并加了防腐单测。
   这条**是靠看真机截图才发现的**，`dart analyze` / 单测都不会报。

#### 八、未取证与已知遗留

1. ~~**登录态下 `getIndex` 是否可通，本轮未取证。**~~ → **已定论（2026-10-18）：
   带上真实的 `m.weibo.cn` 登录 cookie 后，接口返回 200 且拿到 11 条卡片，见本节 `十`。**
   原先「不能假设登录就能拿到时间线」的保留意见**已被实测推翻**。
2. `lib/data/rss/rss_parser.dart` 里仍有一条用户可见文案写着「微博路由需要实例侧配置 WEIBO_COOKIE」。
   **这是死路径**（微博分支在到达 RSSHub 之前就返回了），本轮**刻意未改**：
   改动它会牵连既有测试断言，而收益为零。
3. `getSecond` 返回 `ok:0`「这里还没有内容」但 `cardlistInfo` 认了 containerid —— 说明游客态
   确实触达了业务层，只是无数据。这条不作为「可用」证据，仅作背景记录。
4. **另外两处 RSSHub 表述仍留在死路径里，本轮刻意未改**（都不可达，改动要牵连既有断言）：
   - `lib/data/rss/rss_parser.dart`（见上第 2 条）；
   - `lib/core/net/app_error.dart` 的 429 文案「公共 RSSHub 实例限流…」，被
     `test/core/app_error_test.dart:10` 断言着。**若要彻底清掉 RSSHub 表述，这两处要一起改。**
5. `test/weibo/weibo_backend_test.dart` 里钉住了「文案不得包含 RSSHub / WEIBO_COOKIE / 能看评论 / 能播放」，
   以后改微博文案如果撞到这条断言，**先想清楚是不是又写回了过时说法**，不要直接删断言。

#### 九、操作提醒

改过 `pubspec.yaml` 版本号之后，`flutter test` 会自动尝试联网 `pub get` 并在本机失败 ——
**一律改用 `flutter test --no-pub`**（详见 §6.5）。本轮出包后就踩了一次。

---

### 7.16 阶段 4 验收记录：关电脑 + 拔数据线（2026-10-18，用户实操确认通过）

**命题**：App 不依赖任何自建服务器 / 个人电脑。
**做法**：拔掉数据线 → 关电脑 → 手机 Wi-Fi 保持连接。
（B 站接口与微博网页都需要网络，本节验的是「**不依赖本机**」，不是「离线可用」。）

**断连前预检**（在 adb 上做，避免假失败）：

| 项 | 值 |
| --- | --- |
| 全局 HTTP 代理 | `null`（未设置） |
| Wi-Fi 代理 | 无 |
| 手机 IP / 网关 | `10.41.161.98` / `10.41.0.1`（普通路由，**不指向电脑**） |
| 装机版本 | `0.3.0 (versionCode 5)` |

> 这条预检很关键：若手机 Wi-Fi 配了指向电脑的代理，关电脑会顺带断网，
> 现象是「App 不可用」，但根因是网络配置而不是 App。

**验收项（11 项全部通过）**：

| # | 项目 | 结果 |
| --- | --- | --- |
| 1 | 划掉进程后冷启动 | ✅ 正常进入，**无需重新登录**（凭据在手机钥匙串，与电脑无关） |
| 2 | 时间线首屏 | ✅ 「更新于 刚刚 · N 条」，卡片正常 |
| 3 | 微博占位卡 → 内置 WebView | ✅ 显示真实博主页 |
| 4 | 时间线滚到底续拉 | ✅ 条数增长，无「刷新失败」 |
| 5 | B 站视频播放 | ✅ 进度走动、弹幕滚动 |
| 6 | 评论区 + 加载更多 | ✅ 无 `-400` / 412 |
| 7 | 多图九宫格 + 全屏预览 | ✅ 页码正确、可滑动 |
| 8 | 保存到相册 | ✅ 相册可见 |
| 9 | WebView 返回键 | ✅ 先页内回退，再退出页面 |
| 10 | 设置页 / 关于 | ✅ 不崩，版本显示 0.3.0 |
| 11 | 飞行模式冷启动看已缓存封面 | ✅ 出图（来自 §7.9 的磁盘缓存） |

**证据性质（如实标注）**：本阶段的证据是**用户实操确认**，不是自动化观测 ——
因为「拔数据线」正是本阶段要验证的手段本身，adb 通道在验收开始时即断开。
要复现请按上表逐项重做。

**结论**：核心要求「**电脑关机也能用**」已满足。

---

#### 十、追加验证（2026-10-18）：**登录态 cookie 下接口是可用的**

用户提出「WebView 现在已经登录了，提取 Cookie 再试 API」—— 这**撤销了原先的决策 D3**。
为此在 App 内加了一个诊断入口（`WeiboWebViewPage` 右上角 ⋮ →「接口自检」），点一次只发 **1 个请求**：

| 方式 | 做法 | 结果 |
| --- | --- | --- |
| A | 原生读 `CookieManager.getCookie("https://m.weibo.cn")` → 交给 Dart → Dio 带 `Cookie` 头请求 `getIndex?containerid=1076031782488734` | ✅ **HTTP 200 · 卡片 11 条 · 接口可用**（cookie 长度 495） |
| B | 在 WebView 内用 `fetch` 请求同源接口（用于绕过 TLS 指纹） | **未启用** —— A 已通，无需再试 |

**这直接改写了本节 `二` 的结论**：432 的真正成因**不是** TLS 指纹、也不是「接口对游客整体关闭」，
而是**游客 cookie 域不匹配**（`SUB` 落在 `.weibo.com`，根本不会送达 `m.weibo.cn`）。
带上真正的 m 站登录 cookie 后，**普通 HTTP 客户端（Dio）就能正常取到数据**。

**本次新增功能的凭据边界**（遵守 §8）：

- cookie 只在诊断请求的 header 里出现一次，**不落盘、不写日志、不进 Prefs、不进源码**；
- 界面只显示**长度**，不显示内容；
- 原生 `getCookies` 的注释已写明「不能写进任何 Log —— 里面是用户的登录凭据」；
- 复用系统 `CookieManager` 作为唯一存放处，**没有**往钥匙串再存第二份。

**对产品的影响（如实）**：这条能力的前提是「用户先在应用内 WebView 里登录过微博」。
一旦 cookie 失效（用户清 Cookie / 登出 / 过期），接口会重新失败，届时**必须优雅降级回 WebView**并提示重新登录。

**尚未做的**：把这条链路变成正式微博数据源（客户端 → 解析 → 时间线 → 评论）**尚未实现**，属于下一步。

---

### 7.17 微博原生数据源接入（2026-10-18，真机验证通过）

> 这一节是 §7.15 的**后续升级**：§7.15 当时把微博降级成了内置浏览器，本节把微博重新接成了**原生数据源**。

#### 一、起因：撤销决策 D3

§7.15 里定的 **D3「本期不做 WebView 登录后提取 Cookie」** 被用户明确撤销：既然 WebView 里已经登录了微博，
就应该试试用登录态直接调接口。为此先加了一个**只读诊断**，确认可行性后再动正式代码。

#### 二、结论：432 的真正成因被推翻了（这是本轮最重要的修正）

| 阶段 | 当时的判断 | 实测结论 |
| --- | --- | --- |
| §7.15 探针（游客态） | 「432 是接口级 WAF，接口对游客整体关闭」 | ❌ **判断错了** |
| 本节（登录态） | — | ✅ **带真实 `m.weibo.cn` 登录 cookie，普通 Dio 请求返回 HTTP 200、11 条卡片** |

**真正的原因是 cookie 域不匹配**：游客票据下发的 `SUB` 落在 **`.weibo.com`**，而目标站是 **`m.weibo.cn`**，
两者是不同注册域，请求**根本收不到**那个 cookie。所以之前无论补 `st`、补 `X-XSRF-TOKEN`、补 `Sec-Fetch-*`
都没用 —— 不是因为风控更严，而是**凭证从未送达**。

> **教训**：把「怎么试都不行」归因成「对方封了我们」之前，先确认**请求里到底有没有我们以为带着的东西**。

#### 三、探针过程（4 个切片，全部真机执行）

| 切片 | 验证内容 | 结果 |
| --- | --- | --- |
| A1 | `since_id` 能否翻页 | ✅ 第 1 页 11 条、第 2 页 10 条、**0 重复**、游标推进 |
| A2 | `mblog` 字段结构（第 1 条） | 第 1 条是**置顶纯文字微博**，`pics`/`retweeted_status`/`page_info` 三项**无样本** |
| A3 | 同响应内按类型采样 | 配图 ✅（1 条）、转发 ❌（0 条）、`media_info` ❌（0 条，`page_info` 只有 `webpage`/`topic`） |
| A4 | 翻 3 页深采样（31 条） | **转发拿到 4 条真实样本**、配图 8 条、`media_info` 仍 **0 条** |

每一步都**只采样、不猜**，拿不到样本的字段就明确标注「未验证」再降级实现。

#### 四、字段实测表（写到解析器里了，改之前先看）

| 字段 | 实测结论 |
| --- | --- |
| `mblog.text` | **HTML**（表情是 `<span class="url-icon"><img alt="[酷]">`），必须清洗 |
| `mblog.created_at` | `Mon Aug 07 20:15:27 +0800 2023` → `EEE MMM dd HH:mm:ss ZZZZ yyyy`，**年份在最后** |
| `mblog.id` / `mid` | 均为 **String**（19 位、同值）；另有 `bid`（base62 短 id） |
| `mblog.user.id` | **int** ⚠️ 与 `mblog.id` 类型不同 |
| 昵称 / 头像 | `user.screen_name` / `user.avatar_hd`（https 绝对地址）/ `user.profile_image_url` |
| `mblog.pics[]` | List&lt;Map&gt;，5 个 key：`pid`/`url`/`size`/`geo`/`large`；**`url`=orj360 缩略，`large.url`=mw2000 原图** |
| 旧图字段 | `thumbnail_pic`/`bmiddle_pic`/`original_pic` 存在但**不用**：只能表达第一张，且 `bmiddle_pic` 是明文 `http://` |
| `mblog.retweeted_status` | **与主 mblog 完全同形**（31 条样本里 4 条），直接递归复用同一套映射 |
| `page_info` | **不一定是视频**：见过 `type="webpage"`（外链）与 `"topic"`（超话），两者都**没有** `media_info` |
| `page_info.media_info` | ⚠️ **31 条样本里 0 条**，视频直链字段名**未经实测** |
| `cardlistInfo` | 含 `total`（总条数）与 `since_id`（游标） |
| `cards[].card_type` | 博文卡为 `9`（本批 31/31），但仍按字段判断 |
| 长文 | `isLongText=true` 时列表接口给的是**截断预览**（`textLength` > 实际 text 长度） |

#### 五、实现结构

| 层 | 文件 | 职责 |
| --- | --- | --- |
| cookie 通道 | `android/app/src/main/kotlin/com/rrha/rrha/WeiboCookieChannel.kt` | ★ 全局 `MethodChannel`（`rrha/weibo_cookie`），读 `CookieManager.getCookie("https://m.weibo.cn")`；WebView 内核惰性初始化（`applicationContext`，不 attach 视图树） |
| cookie 读取 | `lib/core/net/weibo_cookie_source.dart` | `read()` / `hasLogin`，异常一律降级成空串（=未登录），不抛 |
| 接口 | `lib/data/weibo/weibo_api_client.dart` | `userTimeline({uid, cookie, sinceId})`；432→风控错误、`ok:-100`→**登录失效**（auth 类，不重试） |
| 解析 | `lib/data/weibo/weibo_parser.dart` | `fromMblog` / `extractMblogs`；`id` 走 `IdHash('https://m.weibo.cn/status/<mid>')` 契约 |
| 数据源 | `lib/data/weibo/weibo_timeline_source.dart` | 缓存**原始 JSON**（键含 uid 与游标，TTL 5 分钟）、登录检查在 `fetch()` 内部 |
| 时间 | `lib/core/utils/time_parse.dart` | 新增 `parseWeibo`（越界值返回 null，**绝不自动进位伪造时间**） |
| 接线 | `lib/providers.dart` · `lib/data/repo/timeline_repo.dart` · `timeline_page.dart` · `weibo_facade_card.dart` · `content_detail_page.dart` | 逐源接入、占位卡按状态显示、详情页收窄 |

**占位卡改为按状态显示**（不再无条件出现）：

| 该微博源状态 | 时间线表现 |
| --- | --- |
| 拉取成功、有内容 | 显示真实微博卡片，**不显示**占位卡 |
| 未登录 / 登录失效 | 显示占位卡，副标题提示「点此打开微博页面登录一次」 |
| 拉取失败（网络等） | 如实报错，占位卡保留作入口 |

#### 六、两个只有真机才发现的坑（单测完全测不出）

1. **微博图床 403：Referer 被硬编码成 B 站地址。**
   `lib/widgets/cached_image.dart` 原来给所有图片请求都加 `Referer: https://www.bilibili.com/`。
   而 `*.sinaimg.cn` 对 B 站 Referer **直接返回 403**（已 curl 对照：B 站 Referer→403，`weibo.com`→302 正常）。
   **症状极具误导性**：正文、时间、作者全部正常，只有封面是灰块 —— 看起来像「解析没取到图」，
   实际是**图取到了但被图床拒绝**。
   修法：按域名挑 Referer（B 站分支逐字节不变）。

2. **普通图文微博被挂上「没有视频」的橙色假警告。**
   `content_detail_page.dart` 原来「只要 `platform == weibo` 就渲染视频区块」，
   于是每条图文微博底下都出现「该条内容没有视频 / RSSHub 返回的描述里没有可用的视频地址」。
   修法：收窄为 `kind == ContentKind.video` 才渲染；顺带把两处已废弃的 RSSHub 文案改成指向
   `media_info` 与内置浏览器。

#### 七、门槛与真机验收

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **570 passed**（本轮从 524 增至 570，既有断言未删改） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| 真机：精选订阅出现真实微博卡片 | ✅ `tools/shots/stage5-weibo-timeline.png`（149 条 · 7 源，微博与 B 站混排） |
| 真机：微博详情页 | ✅ `stage5-weibo-detail.png`（大图正常、无假警告、mid 解析正确） |
| 真机：九宫格全屏 / 保存相册 | ✅ |
| 真机：详情页「在应用内查看这条微博」 | ✅ 打开 WebView 并渲染真实微博页 |
| 回归：全部关注仍是纯 B 站流 | ✅ `stage5-all-following.png`，并有一行「微博内容在「精选订阅」模式查看」的提示 |

#### 八、未取证与已知遗留

1. **`page_info.media_info`（微博视频直链）零样本。** 31 条采样里 `page_info` 有 8 条，但全是
   `webpage`/`topic`，没有 `media_info`。**该账号的视频都发在 B 站**，微博只发外链卡 —— 再多翻页也未必撞得到。
   解析器因此写成**防御性分支**：候选字段名逐个尝试，全部落空时 `directVideoUrl=null`（宁可不可播，
   也不填错地址）。**要收敛这段，必须先拿到真实视频样本。**
2. **微博「转发」样本在真机时间线里没点开过。** 解析层的转发分支是 **REAL**（4 条真实样本验证过同形），
   详情页「原动态」区块复用的是 B 站同一套 `_OriginBlock`（已验证正常），但**微博转发条目本身缺少一次真机点击取证**。
   当前订阅的两位博主在 149 条里没有转发微博。
3. **本方案依赖「用户先在应用内 WebView 登录过微博」。** cookie 失效（清 Cookie / 登出 / 过期）后
   接口会重新失败，届时按上面的「按状态显示」降级回占位卡引导重新登录。

---

### 7.18 微博评论接入（2026-10-19，真机验证通过）

> 需求来源：`docs/WEIBO_HANDOFF.md` §13（用户报「微博没评论」）+ `docs/COLLAB_PLAN.md` §5.2 的 **N3**。
> 归属：**微博会话**。本轮同时按 `COLLAB_PLAN` 的领地表，只动微博侧与评论栈通用部分，
> `timeline_repo.dart` / `providers.dart` 的合并逻辑未碰。

#### 一、探针先行：`hotflow` 完全可用（5 个请求，零 432）

接口 `https://m.weibo.cn/comments/hotflow?id=<id>&mid=<mid>&max_id_type=0`，
翻页加 `&max_id=<游标>`。实测 3 页全 `200`、`ok:1`、每页 **20 / 20 / 18** 条、**跨页 0 重复**。

完整报告在 `.env/weibo_comment_probe.md`（344 行，gitignore 区，不进交付物）。

#### 二、★ 一条反直觉的实测事实（照搬时间线经验会写错）

**`hotflow` 不要求登录**：cookie 为空时同样是 `200 + ok:1 + 20 条`。

而时间线接口 `getIndex` 在游客态恒 432，两者规律**完全相反**。所以：

| ❌ 错误做法 | ✅ 正确做法 |
| --- | --- |
| 照时间线的「432 = 未登录」判定评论 | 评论拿不到时**先怀疑解析/参数**，而不是凭据 |
| cookie 为空就不发请求、直接报未登录 | cookie 为空也照发（游客也能看评论） |

这条已用单测钉住（`test/weibo/weibo_comment_repository_test.dart` 里有一条
「cookie 为空仍然发起请求且不报未登录」的用例）。**改评论层之前先看这条。**

#### 三、字段实测表（解析器据此实现）

| 目标 | 字段 | 类型 | 注意 |
| --- | --- | --- | --- |
| 列表路径 | **`data.data[]`** | List | **两级 `data`**，不是 `cards` |
| 正文 | `data[i].text` | String（**含 HTML**） | 表情是 `<img alt="[怒]">`，**要还原成 `[怒]`** 再剥标签 |
| 用户名 | `data[i].user.screen_name` | String | |
| 头像 | `data[i].user.avatar_hd` | String | 回退 `user.profile_image_url` |
| 点赞 | `data[i].like_count` | int | ⚠️ **仅一级评论有**，二级评论无此字段 |
| 时间 | `data[i].created_at` | String | `Mon Aug 07 20:15:58 +0800 2023` → 用 `TimeParse.parseWeibo` |
| 评论 id | `data[i].id` | **String**（16 位） | ⚠️ **绝对不要读 `gid`**：它是 int 且已超 2^53，double 上会失真 |
| 楼层 | `data[i].floor_number` | int | 二级评论恒为 0 |
| 总数 | `data.total_number` | int | 与 `mblog.comments_count` 吻合 |
| 游标 | **`data.max_id`** | 实测 **int** | ⚠️ **别取 `data.max`**（另一个字段）；按 String 保存并原样拼 URL |
| 二级评论 | `data[i].comments[]` | List | **内嵌在同一响应里**，不需要第二个接口 |

**二级评论的形态**：元素与一级**同构**（28 字段），靠 `readtimetype`
（`comment` / `comment_reply`）与 `cmt_ext`（`level_type:1/2`）区分；
`rootid` 指向**一级评论 id**；**该字段是可选**的（无楼中楼时整个 key 不存在）；**只展开一层**。

#### 四、实现结构

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 模型 | `lib/data/models/comment.dart` | `BiliComment` 主键改 **String `id`**（保留 `int get rpid` 兼容 getter）；新增 `createdAtOverride`（让微博的字符串时间与 B 站的 Unix 秒共存）、`platformKey`；新增 **`CommentRequest`** |
| 接口 | `lib/data/repo/comment_repo.dart` | `CommentRepositoryLike` 改为 `loadFirst({req})` / `loadMore({req, cursor})` / `loadReplies({req, rootId})` —— **参数平台中立** |
| 微博解析 | `lib/data/weibo/weibo_comment_parser.dart` | ★ `data.data[]` → `BiliComment`；内嵌二级评论直接填 `replies` 并置 `repliesLoaded=true` |
| 微博接口 | `lib/data/weibo/weibo_comment_repository.dart` | 裸 Dio（**不挂重试**，防风控）；cookie 现读、为空也照发 |
| 状态机 | `lib/features/comments/comment_controller.dart` | `CommentArgs` 加 `platform`；`Set<int>/Map<int>` → `Set<String>/Map<String>`；按平台选仓库 |
| 界面 | `lib/features/comments/comment_section.dart` | 加 `platform` 参数（默认 bilibili，既有调用点零改动）；**微博侧隐藏排序按钮**、空态文案按平台区分 |
| 接线 | `lib/features/timeline/content_detail_page.dart` | 微博详情页渲染**真实评论区**（`embedded`），**保留**「在应用内查看这条微博」兜底入口 |

**设计取舍**：微博的二级评论是**内嵌**的（一次响应带回），B 站是**按需分页拉取** —— 语义不同，
但两者都落到 `replies` 字段，UI 不用分叉。微博在解析时就把 `repliesLoaded` 置为 `true`，
所以首次显示即可展开，**不发第二个请求**（代价：按钮文案一开始就是「收起回复」，语义正确）。

#### 五、门槛与真机验收

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **635 passed**（基线 605，新增 30） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| 微博详情页真实评论 | ✅ `tools/shots/stage6-weibo-comments.png`（真实用户名/头像/正文/时间/点赞） |
| 表情还原 | ✅ `[二哈]`、`[泪]` 正确显示（证明 `<img alt>` 还原生效） |
| 翻页 | ✅ `stage6-weibo-comments-more.png`，无 432 |
| 楼中楼 | ✅ 内嵌展开可见 |
| **B 站回归** | ✅ `stage6-bili-comment-regression.png`：「热度/时间」排序按钮仍在、翻页正常 |

#### 六、既有测试只改构造，未改断言语义

模型主键从 `int rpid` 改为 `String id`，导致 `test/features/comment_controller_test.dart`
与 `test/data/models_test.dart` 需要同步调整**构造入参**（`rpid: N` → `id: 'N'`、
`repliesError` 的 key 改用 `target.id`）。

已核验：用例数（16 / 36）与断言数（51 / 116）**均未减少**，无 `skip:`、
无被注释掉的断言。⚠️ 以后若再动这几个文件，请保持同样的标准。

#### 七、未取证

1. **微博三层楼（二级评论的二级）**：实测 `comments[0].comments` 不存在，楼中楼只展开一层。
   更深层要点进详情页查看 —— 本轮**未验证**深链行为。
2. **大量翻页的风控边界**：只测了 3 页（58 条）。继续翻更多页是否触发冷却**未知**，
   因此代码里刻意**不挂重试拦截器**，把节奏交给用户操作。

---

### 7.19 微博订阅名回填博主昵称（N5，2026-10-19，真机验证通过）

> 需求来源：`docs/COLLAB_PLAN.md` §5.2 **N5**（订阅源显示成「微博+UID」）。归属：微博会话。

#### 一、做法：用已拉取的内容回填，零额外请求

微博昵称本来就在拉取结果里（`mblog.user.screen_name`），`WeiboParser` 一直在填
`ContentItem.authorName`，**只是没有回传成订阅别名**。所以：

| 方案 | 请求成本 | 覆盖率 |
| --- | --- | --- |
| 用「关注列表」接口反查 | 额外请求 | ❌ 只覆盖 **9 个**关注（探针实测第 1 页仅 9 人，且接口无 total 字段） |
| **用已拉取内容回填**（采用） | **0** | ✅ 覆盖**所有**微博订阅 |

#### 二、实现的三层（少一层就不生效）

| 层 | 改动 | 为什么必须有 |
| --- | --- | --- |
| 数据源 | `WeiboFetchResult` 加 `authorName`，**缓存命中与网络拉取两条路径都填** | 只改网络路径的话，第二轮刷新命中缓存时会拿不到名字 |
| 仓库 | `_fetchWeibo` 成功后回填（仅当别名为空） | 别名落 Prefs |
| **provider** | `TimelineNotifier._refreshSubscriptions` 比对别名快照，变了就 `subscriptionsProvider.reload()` | **少了这层，别名已写进 Prefs，但订阅页读的是内存缓存 → 用户必须重启 App 才看到新名字** |

#### 三、两个防坑设计（都很隐蔽）

1. **绝不写回「占位值」**。`WeiboParser` 在 `screen_name` 缺失时会用 `sub.displayName`
   兜底，而那正是「微博 1782488734」。若把它当昵称写进别名，界面**毫无变化**，
   却**永久占住**别名位（用户会以为「修了但没生效」）。
   现在 `_authorNameOf` 会把「等于兜底文案的值」与「`微博 <uid>` 形态」都判为「拿不到」，返回 null。
2. **绝不覆盖用户手动设的别名**。纯空白别名视为「未设置」；已有别名时**连一次落盘都不发生**
   （不是「写了相同值」，而是直接 return），并有单测钉住。

#### 四、门槛与真机验收

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **687 passed**（基线 669，新增 18） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| 订阅名 | ✅ `tools/shots/stage6-alias-before.png`（「微博 1782488734」）→ `stage6-alias-after.png`（**`_warma_`**，UID 仍在副标题） |
| 持久化 | ✅ force-stop 冷启动后仍显示 `_warma_`（说明落在 Prefs，不是内存态） |
| B 站回归 | ✅ `w咸瑜` / `一般路过三花猫` 未受影响 |

#### 五、顺带的工程观察（待决策，不是缺陷）

诊断类代码已累计 **4446 行**（`weibo_api_diag.dart` 1688 + `weibo_following_probe.dart` 1609
+ `weibo_comment_probe.dart` 1158），占 `lib/` 全部 20425 行的 **22%**，
而业务解析器只有 375 行。它们都还挂在 `weibo_webview_page.dart` 的 `⋮` 菜单里，
**属于 App 内可访问的诊断功能、不是死代码**，不影响功能与门槛。

建议（未执行，等用户决定）：
- 迁到 `tool/` 目录或用编译期开关（`kDebugMode` / `--dart-define`）隔离；
- 或合并成一个 `weibo_diagnostics.dart`，共用字段展开与脱敏工具（三个文件里有明显重复的
  `_walk` / `_mask` / `_typeName` / Markdown 生成逻辑）。

---

### 7.20 全部关注含微博 + 诊断代码收敛（2026-10-19，真机验证通过）

> 需求来源：`docs/WEIBO_HANDOFF.md` §12（「全部关注」要含微博）+ `docs/COLLAB_PLAN.md` §5.2。
> **注意**：本节越出了 `COLLAB_PLAN` 的原本分工（`timeline_repo` / `providers` 归总设计会话），
> 是**用户明确授权后**由微博会话一并完成的。动这几个文件前请先确认没有别的会话在改。

#### 一、微博「关注动态流」探针：接口是存在的

| 候选 | 结果 |
| --- | --- |
| `m.weibo.cn/feed/friends` | ✅ **可用**：`200 / ok=1`，一次返回 **20 条 / 6 个作者** |
| `containerid` 系列 | ❌ 不适用 |

⚠️ **关键结构差异**：`/feed/friends` 返回 **`data.statuses[]`**，
每条**直接就是 mblog 形状**，**没有 `cards[].mblog` 外壳** —— 所以
**不能复用** `WeiboParser.extractMblogs()`（那个是给 `getIndex` 用的）。
新增了 `WeiboParser.extractStatuses()`，但**单条仍复用 `fromMblog()`**（形状一致）。

**未登录判定**：该接口与时间线一致，cookie 为空时返回 **432**（与评论接口相反，评论接口游客也能用）。

#### 二、两个游标必须独立维护（最容易写错的地方）

| 平台 | 游标 | 形态 |
| --- | --- | --- |
| B 站 `feed/all` | `offset` | 19 位数字串 |
| 微博 `feed/friends` | `since_id` | 另一种形态（实测 int） |

两者**形态完全不同，绝不能混用**：把微博的 `since_id` 塞给 B 站接口、
或反之，都会静默拿到错误页。所以 `loadFollowing` 现在收两个参数
（`offset` + `sinceId`），`TimelineFollowingResult` 也带回两个游标（`nextOffset` + `nextSinceId`）。

**翻页终止条件**也相应调整：两边**任一还有下一页**就继续，不要因为微博侧到底就整页停住。

#### 三、微博失败不能拖垮 B 站

`loadFollowing` 里微博抛错时：
- B 站内容**照常返回并渲染**
- 微博的失败只记进 `statuses`（key 用虚拟源 `weibo:friends`）
- 由 `_DegradedBanner` 提示，**不整页变红**

这条有单测钉住（`test/data/timeline_following_merge_test.dart`）。

#### 四、诊断代码收敛

诊断代码原本三份散落在 `lib/`，合并为两块 + 一个开关：

| 项 | 变化 |
| --- | --- |
| `lib/data/weibo/weibo_diagnostics.dart` | 新建，合并原 3 个文件（4455 → 4365 行） |
| `lib/features/weibo/weibo_diagnostics_ui.dart` | 新建，6 个诊断对话框整体搬出（830 行） |
| `lib/core/config/diagnostics_config.dart` | 新建，编译期开关 |
| `lib/features/weibo/weibo_webview_page.dart` | **1017 → 229 行** |
| 旧 3 个诊断文件 | 已删除 |

**去重是真实生效的**（虽然总行数没降）：`_typeName` / `_mask` / `_tryParseObject` /
`_sampleValue` 各只剩 1 份实现，`_diagWalkTree` 1 份实现 + 6 处调用。
总行数从 4455 变 5218（**增加 740**）的原因是 UI 层被拆了出来；
数据层本身 4365 行里，注释 609 + 空行 455，实代码 3301。

**编译期开关**：

```dart
const bool kWeiboDiagnosticsEnabled = bool.fromEnvironment(
  'RRHA_WEIBO_DIAG', defaultValue: kDebugMode,
);
```

- 默认：debug 开、**profile/release 关**（正式包不显示 `⋮` 菜单，连组件都不进树）
- 需要时：`flutter build apk --profile --dart-define=RRHA_WEIBO_DIAG=true`
- ⚠️ 直接给 `gradlew` 传 `-Pdart-defines` 需要 base64，**用 `flutter build` 传 `--dart-define` 才对**

**行为零变化的验证方式**（值得复用）：子任务把旧实现临时复制进 `lib/` 做**差分测试** ——
14 项覆盖全部对外纯函数 + **400 轮随机嵌套结构 fuzz**，逐字节比对 `toText()` /
`describeMblog` / `toMarkdown` 等输出，全部相同后删掉临时文件。

#### 五、顺带修掉的两处过期文案

1. **时间线底部声明**：旧文案「B 站内容来自官方接口（需登录）；微博内容在应用内浏览器查看」
   —— 微博早已升级为原生数据源，这句话已不成立。
   改为「**B 站与微博内容均来自官方接口（需登录）**」。
   同时拆成三条防腐测试（不得含 RSSHub / 不得含「浏览器」/ 必须含「官方接口」+「登录」）。
2. **「微博内容在「精选订阅」模式查看」的提示**：全部关注接入微博后这行不再成立，已移除。

#### 六、门槛与真机验收

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **738 passed** |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL（冷启动 537 ms） |
| 全部关注混排 | ✅ `tools/shots/stage7-following-mixed.png`（40 条，B 站 + 微博共存，倒序正确） |
| 精选订阅回归 | ✅ `tools/shots/stage7-disclaimer-fixed.png`（117 条 · 6 源，微博原生卡片） |
| 底部文案 | ✅ 已变为「B 站与微博内容均来自官方接口（需登录）」 |
| 诊断开关 | ✅ `stage7-diag-off.png`（profile 下菜单消失）/ `stage7-diag-on.png`（`--dart-define` 后出现且可用） |

#### 七、一个观察（未改，属于界面会话领地）

亮色化重构后，**卡片不再有「微博 / Bilibili」文字标签**，改为用**昵称颜色**区分平台
（微博粉 `AppColors.weiboName`、B 站黑 `biliName`）。

这是设计变更不是缺陷，但**纯靠颜色区分对色弱用户不友好**，且混排模式下不如标签直观。
若要改回标签，属于 `content_card.dart`（界面会话领地），需协调。

---

### 7.21 微博评论显示图片（2026-10-20，真机验证通过）

> 用户需求：「微博评论区没有图片，带图片的评论要能显示出来」。归属：微博会话。

#### 一、★ 真字段是 `pic`（单数 Map），不是 `pics`

这是本轮最重要的发现，也是「图片一直不显示」的直接原因：

| 候选字段 | 实测结论 |
| --- | --- |
| **`pic`** | **Map，5 个 key：`pid` / `url` / `size` / `geo` / `large`** ← **真字段** |
| `pics` | List，**抓到的全是 404 残片**（`https://ss1.sinaimg.cn/orj360/&690`，`pid=null`） |
| `pic_infos` / `pic_ids` / `picInfo` / `pic_list` / `pic_urls` | **均不存在** |

逐个 curl 验证过：`pic.url` / `pic.large.url` 全部 **HTTP 200 + image/jpeg**；
`pics[0].url` 的残片地址 **HTTP 404**。

**所以只读 `pics` 的实现会拿到 404 残片 —— 这正是「评论区有文字没图片」的机制。**

#### 二、尺寸只有两档（没有 bmiddle / thumbnail / original）

| 用途 | 路径 | `size` 值 | 实测 |
| --- | --- | --- | --- |
| 缩略 | `pic.url` | `orj360` | 长边 360 |
| **原图** | **`pic.large.url`** | `large` | 原尺寸（33 KB vs 11 KB） |

URL 全部是 **https 绝对地址**，不需要补 `//` 前缀。

#### 三、★ 这个接口一条评论只回 **1 张图**（接口能力上限，不是解析遗漏）

关键证据是**同一份响应内的横向对照**（4 条样本）：

| 样本 | `pic_num` | `pic`(Map) | `pics`(List) | `mix_media_ids`(List) |
| --- | --- | --- | --- | --- |
| `data[0]` | 1 | 1 个 | 1 项 | 1 项 |
| `data[10].comments[0]`（二级） | 1 | **不存在** | 1 项 | 1 项 |
| **`data[2]`** | **3** | **1 个** | **1 项** | **3 项** |
| `data[4]` | 1 | 1 个 | 1 项 | 1 项 |

`mix_media_ids` 项数与 `pic_num` **4/4 全部吻合** → 接口知道有几张，但**只给一张代表图**。
其余张数里的 `mix_media_ids` 是 `http://t.cn/...` **短链，不是图片直链**，无法渲染。
正文 HTML 里也没有配图（只有一个占位图 `timeline_card_small_photo_default.png`）。

**所以 UI 按单图实现**，并在有多图时用一行小字如实标注
「**共 N 张（接口仅提供 1 张）**」—— 不做宫格/轮播，那会永远只有一张，等于假装支持多图。

#### 四、四个必须处理的坑

1. **`pic_num` 不能用来索引图片数组**：实测 `pic_num=3` 而 `pic` 只有 1 张，越界必崩。
   它只用于「共 N 张」的文字角标。
2. **`pic` 与 `pics` 必须都读**：一级样本落在 `pic`、二级样本落在 `pics`（实测），
   只读一个会漏掉另一类。
3. **残片过滤**：URL 末段文件名以 `&` / `?` / `=` 开头的是残片（实测 404），必须丢弃。
4. **缺字段不是异常**：存在 `pic_num=1` 但 `pic` 与 `pics` **都不存在**的评论
   （图片线索只在正文 HTML）→ 不能抛异常。
5. `pic.geo.width` 类型不一致：有时 `String`（`"512"`）有时 `int`（`360`）→ 取值要容错。

#### 五、实现结构

| 层 | 文件 | 改动 |
| --- | --- | --- |
| 模型 | `lib/data/models/comment.dart` | `BiliComment` 新增 `images`（`List<String>`）与 `imageCount`（`int`），**都有默认值 → B 站零改动** |
| 解析 | `lib/data/weibo/weibo_comment_parser.dart` | 先读 `pic`（`large.url` 优先 → `url`），再读 `pics`（逐项 + 残片过滤）；`imageCount` 取 `pic_num`（int/String 容错） |
| 界面 | `lib/features/comments/comment_section.dart` | `_CommentTile` 复用现成的 **`PhotoGrid`** 渲染；点击打开现成的 **`ImageGalleryPage`**（全屏 + 存相册） |

**复用了现成组件，没有新写图片布局**（`PhotoGrid` / `ImageGalleryPage` 都是既有资产）。

#### 六、门槛与真机验收

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **839 passed**（基线 813，新增 26） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| 评论图片显示 | ✅ `tools/shots/stage8-comment-pic.png`（`_warma_` 评论内嵌 Minecraft 截图） |
| 全屏预览 | ✅ `stage8-comment-pic-gallery.png` |
| 多图如实标注 | ✅ `stage8-comment-pic-multi-hint.png`：显示 1 张 + **「共 3 张（接口仅提供 1 张）」** |
| B 站回归 | ✅ `stage8-bili-comment-regression.png`（无图片、布局正常） |

#### 七、未取证

1. **多图评论只验证到「接口只给 1 张」这一结论的 4 条样本**。若要彻底确认「永远只给 1 张」，
   需要一条界面上明确是九宫格的评论做对照。但**即使确认，UI 策略（显示 1 张 + 角标）也不会变**。
2. 「多图的其余张数能否通过别的接口拿到」**未探**（例如评论详情页接口）。
   这属于「多图完整支持」，不在本轮需求内。

---

### 7.22 微博评论多图完整显示（2026-10-20，真机验证通过）

> 承接 §7.21：那轮结论是「接口只给 1 张代表图」，UI 如实标注「共 N 张（接口仅提供 1 张）」。
> 用户随后要求**多图完整显示**，本节解决它。

#### 一、多图的真实来源：`mix_media_ids` 里的 `t.cn` 短链

上一轮就发现 `mix_media_ids` 有 N 项且与 `pic_num` 完全吻合，只是当时判断「是 t.cn 短链，
不是图片直链，无法渲染」。**这个判断错了** —— 短链跟随重定向就能拿到图：

```
mix_media_ids[i] = "http://t.cn/<8 位短码>"
  --302--> https://photo.weibo.com/h5/comment/compic_id/1022:xxxx
  --> 463 字节静态 HTML，正文一个 <img src="https://wx*.sinaimg.cn/bmiddle/<pid>.jpg">
```

**不是 SPA、无 JS 注入**，正则一次就能取到 `<img src>`。

#### 二、三个必须知道的实现细节

1. **接口给的是 `http://`，但 Android 只能走 https。**
   明文流量会被系统策略拦掉 → **必须把 `http://t.cn/...` 升级成 `https://t.cn/...`**。
   （http 与 https 的 302 目标逐字节相同，所以升级是安全等价变换。）
2. **1 张图 = 1 个请求。** 一条 N 图评论就是 N 个请求。
   所以**绝不能把解析放进列表构建路径** —— 一屏 20 条评论若有五六条多图，滚动一下就是几十个请求。
3. **落地页给的是 `bmiddle`（长边 690），把路径里的 `bmiddle` 换成 `large` 就是原图。**
   图床**认 Referer**：不带 `Referer` → 403，带 `https://weibo.com/` → 200。
   ⚠️ `lib/widgets/cached_image.dart` 的 `_refererFor` **已覆盖 `sinaimg.cn`，无需改动**；
   但任何新写的裸 `Image.network` 都必须自己补这个头。

#### 三、架构：三层职责彻底分开（这是本节最重要的设计）

| 层 | 职责 | 约束 |
| --- | --- | --- |
| 解析层 `weibo_comment_parser.dart` | **只把 `mix_media_ids` 原样搬进模型** | **零 IO**（被 900+ 单测钉死，不发任何请求） |
| 仓库层 `weibo_comment_pic_resolver.dart` | 升级 https → 跟随重定向 → 提取 `<img src>` → `bmiddle`→`large` → 上限 9 张 | 网络 IO 只在这里 |
| UI 层 `comment_section.dart` | 用户点「共 N 张 · 点此加载全部」时才触发 | **绝不进列表构建路径** |

**为什么坚持这样分层**：如果把短链解析塞进解析器或列表构建，
一次滚动就会打出几十个请求 —— 微博对密集请求会冷却（本项目在 B 站侧已经被 412 冷却教训过）。

#### 四、交互与降级

- 默认仍显示**单图 + 「共 N 张 · 点此加载全部」**（可点击）
- 点击后：按评论 id 取图集 → `PhotoGrid` 变成 N 张九宫格，角标整行消失
- **同一条评论只解析一次**（按评论 id 内存缓存，短码稳定不会变）
- **失败不重试**（重试最容易触发风控），降级回单图 + 可读错误提示
- 单条失败不影响其它条；上限 9 张
- B 站评论 `mixMediaIds` 恒空 → **走不到新路径，零影响**

#### 五、门槛与真机验收

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **911 passed**（基线 877，新增 34） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| 点开后显示 3 张 | ✅ `tools/shots/stage9-multipic-after.png`（三列九宫格，角标消失） |
| 全屏预览 | ✅ `stage9-multipic-gallery.png`（`1 / 3`）→ `...-gallery-2of3.png`（`2 / 3`，证明三张都在图集里） |
| 单图评论回归 | ✅ 同页其他评论单图正常 |
| B 站回归 | ✅ `stage9-bili-regression.png`（无 PhotoGrid、排序按钮仍在、布局正常） |

#### 六、一个操作层面的提示（下次定位样本用）

那条多图评论**在评论第 2 页**（只看第 1 页会误判「没有多图」）。
另外 `uiautomator dump` 的坐标点击容易偏——命中图片本体时打开的是 `1/1` 预览，
需要按文本重新定位才能点中「共 N 张」那一行。

#### 七、未取证

1. **单条评论图数上限**：本轮样本 N=3，**没有压到 9 张**。代码按微博上限 9 张截断，但未实测。
2. **视频类 `mix_media_ids`**：本轮样本全是静态图。若某条评论混了视频，
   落地页可能是播放页而不是 `<img>`，提取逻辑会拿不到图（会降级成「没有图片」）。
3. **未登录态能否解析短链**：本轮全部带登录 cookie。短链 + `photo.weibo.com` 通常不需要登录，但未做无 cookie 对照。

---

### 7.23 B 站播放页补全：统计行 / 简介 / 清晰度 / 倍速 / 进度记忆（2026-10-21，真机验证通过）

> 承接 `docs/BILI_HANDOFF.md` §10 的推进顺序，本轮把 §3.1～§3.6 一次做完。
> 基线是 `dart analyze` 干净、`flutter test` **911 全绿**；本轮结束为 **995 全绿（+84）**。

#### 一、做了什么（对照交接文档条目）

| 条目 | 结果 | 落在哪 |
| --- | --- | --- |
| §3.1 播放页统计数字全空 | ✅ 播放/弹幕/赞/币/藏/分享/评论一排图标+数字，点评论滚到评论区 | 新建 `lib/widgets/video_stats_row.dart` |
| §3.2 简介没地方看 | ✅ 标题下可折叠（2 行 →「展开」），空简介**不占位** | 新建 `lib/widgets/video_description.dart` |
| §3.3 清晰度不能选 | ✅ 「更多」菜单列出 `support_formats`，切换后**跳回原位**，选择持久化 | 新建 `lib/features/player/player_options_button.dart` + `Prefs.preferredQn` |
| §3.4 没有倍速 | ✅ 0.5/0.75/1.0/1.25/1.5/2.0，两条通道都实现，持久化 | `RrhaPlayer.setSpeed` |
| N1 长按不能快进 | ✅ 长按 2.0x + 中央「2.0x 快进中」，松手回**用户所选档位** | `player_page.dart` 手势层 |
| §3.6 全屏没有清晰度/倍速/分P 入口 | ✅ 同一套「更多」按钮在全屏态照常可用 | 同上（不额外写第二套） |
| §3.5 退出再进从头开始 | ✅ 「上次看到 mm:ss，要从这里继续吗？」**不静默跳转** | `Prefs` 进度键 + `playback_progress.dart` |

**刻意没动的**：`content_card.dart` / `providers.dart` / `timeline_page.dart` /
`player_controls_overlay.dart`（界面会话与总设计的领地，见 `docs/COLLAB_PLAN.md` §3.1）。
新能力全部落在**新建文件**里，天然不冲突。

#### 二、三个必须在真机上才撞得出来的缺陷（都已修）

**① 清晰度切换「点了没反应」——缓存键漏了 qn**

`VideoRepository._playUrlCache` 的键原来只有 `cid`。720P 播过之后用户点 360P，
`playUrl(qn: 360)` 直接命中那份 720P 缓存原样返回，`_client.playUrl` **根本没被调用**。
症状与「播放页没接清晰度」完全一样，但根因在仓库层。

> 取证：「播放信息」弹窗里 `qn` 仍是 **64**、菜单勾也停在 720P，而播放器确实重建过。

修法：键改成 `cid@qn`；新增 `test/data/video_repo_playurl_cache_test.dart`，
用假 adapter **数请求次数**钉死「切清晰度必须真的再发一次请求」。
**修复前这条测试必然红**（同一 cid 不同 qn 会拿到 64）。

**② 进度记忆一次都没写成——`dispose()` 里用了 `ref`**

App 内运行日志（2026-10-21 20:09）：

```
[W][PlayerPage] 保存播放进度失败（忽略）：Bad state:
Cannot use "ref" after the widget was disposed.
```

落盘发生在 `dispose()`，那里 `ref` 已失效。异常被 `catch` 吞成一行警告，
**界面上完全看不出来** —— 只会觉得「这功能没做」。

修法：`Prefs` 在 `initState` 里取好存到 `_prefs`，两个路径都用它；
顺带把「该存 / 该清 / 该跳过」的判定抽成纯函数 `playback_progress.dart`，
新增 `test/features/playback_progress_test.dart`（17 条，覆盖每个分支与边界值）。

**③ 长按 2x 后弹幕会慢半拍**

`PlaybackClock` 在位置回调之间靠墙钟外推。倍速 2x 时若仍按 1x 外推，
弹幕稳定慢半拍，并在下一次真实回调时被「偏差中等就校正一半」慢慢拉回，
表现是持续抖动。修法：`PlaybackClock.setSpeed()`（切速时先对齐锚点，不跳变）。
测试用**正反对照**证明倍速真的乘进去了（同样的上报值，1x 判硬跳、2x 不判）。

#### 三、两个探针结论（写进代码注释了）

1. **`arc/search` 的 `vlist[]` 压根没有 `upic` / `face` 字段**
   （换参数、换旧接口都一样，keys 里就是没有）。所以「UP 投稿」这条路的作者头像
   只能靠别处补；本轮的博主头像由其它会话按动态流的 `module_author.face` 修好，
   **投稿列表侧若以后仍缺头像，根因不是解析写漏，而是接口没给**。
   探针：`.env/probe_bili_avatar_duration.py`、`.env/probe_bili_avatar_source.py`。
2. **清晰度清单只有 DASH 形态是全的**：`fnval=1`（MP4 单流）对同一稿件只给
   `[64, 16]` 两档，`fnval=4048`（DASH）给 `[112, 80, 64, 32, 16]` 五档。
   探针：`.env/probe_bili_quality.py`。这也是真机上「通道 A 只有 2 档、
   通道 B 有 5 档」的原因，属于如实反映而非缺陷。

#### 四、真机验证表（荣耀 Magic8 Pro / Android 16）

| 项 | 证据 | 截图 |
| --- | --- | --- |
| 统计行出现且字段对应正确 | 一排 `105.5万 / 4267 / 6.4万 / 8493 / 6756 / 723 / 2191` | `bili-r3-05-player.png`、`bili-r3-14-before-qn.png` |
| 简介折叠 + 展开 | 「本期视频提及的事件…」两行 +「展开」按钮 | 同上 |
| 清晰度菜单（通道 A，2 档） | 720P ✓ / 360P | `bili-r3-06-menu.png` |
| 切到 360P 真的生效 | 「播放信息」里 `qn: 16`、`格式: mp4` | `bili-r3-16-playinfo-360.png` |
| 切清晰度后位置不丢 | 重建后仍在原进度，未回到 00:00 | `bili-r3-15-qn-switched.png` |
| 倍速 0.75x 生效并持久化 | 「播放信息」里 `倍速: 0.75x` | `bili-r3-17-speed15.png` |
| **长按 2.0x（通道 A）** | 中央显示「▶ 2.0x 快进中」，弹幕仍在滚 | `bili-r3-18-longpress.png` |
| 松手回到用户档位 | 「播放信息」里 `倍速: 0.75x`（**不是** 1.0x） | `bili-r3-20-speed-after-longpress.png` |
| 全屏态也有清晰度/倍速 | 横屏弹出同一份菜单，五项齐全 | `bili-r3-34-fullscreen.png`（横屏 dump 见记录） |
| ~~「继续播放」弹窗~~ → **已按用户要求改为自动续播**（见第六节） | 弹窗版本曾验证可用，现已移除 | `bili-r3-29-resume2.png`（历史） |
| **自动续播跳转准确** | 日志：`自动继续播放：跳转到 04:08（当前 00:00 / 总时长 18:51）` → `跳转后位置 04:08` | `bili-r4-02-logs.png` |
| **自动续播无弹窗 + 有角标** | 「已从 04:08 继续」+ 进度条 `04:08 / 18:51`，全程无弹窗 | `bili-r4-05-resume-hint-ok.png` |
| 通道 B 清晰度（5 档） | 1080P 高码率/1080P/720P/480P/360P，360P 打勾 | `bili-r3-38-B-speed.png` |
| **长按 2.0x（通道 B / libmpv）** | 同样出现「2.0x 快进中」 | `bili-r3-37-B-longpress.png` |
| 通道 A 有声音 | `dumpsys audio`：`type:android.media.AudioTrack u/pid:10312/30799 state:started` | — |
| 通道 B 有声音 | `dumpsys audio`：`type:OpenSL ES AudioPlayer ... u/pid:10312/6646 state:started` | — |

> 两条通道的音频后端不同（`AudioTrack` vs `OpenSL ES AudioPlayer`），
> 所以这两行能互相印证「确实是两条不同的通道各自出声」，而不是同一条被数了两次。
> `10312` 是 `dumpsys package com.rrha.rrha` 里的 `appId`。

#### 五、门槛

| 项 | 结果 |
| --- | --- |
| `dart analyze lib test` | ✅ `No issues found!` |
| `flutter test` | ✅ **995 passed**（基线 911，新增 84） |
| `gradlew assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| `adb install -r` | ✅ Success（APK 已装机验证） |

#### 六、追加变更（2026-10-21 晚）：进度恢复改为**自动**，不再弹窗

用户看真机截图后明确要求：**「不需要弹出这个弹窗，默认继续播放」**。

| 项 | 改前 | 改后 |
| --- | --- | --- |
| 交互 | `AlertDialog`「继续播放？上次看到 02:07」+ 两个按钮 | **直接 seek**，全程无弹窗 |
| 反馈 | 由弹窗告知 | 画面右上角一条「已从 04:08 继续」角标，2.5 秒自动消失 |
| 入口 | `_maybeOfferResume()` | `_restorePlaybackPosition()`（旧方法已删除） |
| 判定 | `PlaybackProgress.shouldOfferResume()` | **判据一个没变**（多短算浏览、多近算看完都不动） |

**为什么保留那条 2.5 秒角标**：静默跳转最大的风险是用户以为「视频坏了 / 从中间开始」，
而这正是当初 §3.5 设计弹窗的理由。角标用非阻塞的方式解决了同一个问题。

角标刻意放**右上**：左上角是弹幕「加载中 / 加载失败」角标的位置，
进视频那一刻两者必定同时出现，叠在一起会糊成一团。

**防腐测试**：`test/features/resume_no_dialog_test.dart` 直接读
`player_page.dart` 源码，断言 `_restorePlaybackPosition` 的方法体里
**不许出现** `showDialog` / `AlertDialog` / `继续播放？`，并断言
`_maybeOfferResume` 已彻底移除。这类要求很容易在后续改动里被「贴心」地加回来
（它看起来是个很合理的确认步骤），所以用源码级断言钉死。

真机证据（`tools/shots/bili-r4-05-resume-hint-ok.png`）：
进视频后**无任何弹窗**，画面右上角显示「已从 04:08 继续」，进度条同时是 `04:08 / 18:51`；
运行日志 `自动继续播放：跳转到 04:08（当前 00:00 / 总时长 18:51）` → `跳转后位置 04:08`。

门槛：`dart analyze` 干净、`flutter test` **1001 passed**（995 + 6）、`assembleProfile` 成功、已装机。

#### 七、未取证 / 已知限制

1. **切清晰度时通道可能变化**：走 MP4 只有 2 档、走 DASH 有 5 档（见探针结论 2）。
   本轮验证的是「同一通道内换档」；从 MP4 切到只有 DASH 才有的档位
   （如 1080P）时会触发通道 A → B 的重建，**这条组合路径本轮未单独取证**。
2. **倍速音调**：`mpv` 的 `audio-pitch-correction` 默认开、ExoPlayer 也变调不变，
   但本轮只确认了「有声音、在播放」，**没有做听感对照**（无法用截图证明）。
3. **多分P 视频的分P 入口**：验证用的 `BV1XUJe6KE31` 是单 P，
   「更多 → 分 P」分组因此没有出现在截图里；分组逻辑有单测覆盖
   （`player_options_button_test.dart` 的「只有 1 个分P时不渲染分P分组」）。
4. **进度记忆的跨进程验证**：本轮是「退出播放页 → 再进」，
   没有做「杀进程冷启动 → 再进播放页」。

---

### 7.24 移除 RSSHub 整条链路（2026-10-22，真机验证通过）

**用户诉求**：「rsshub 功能还有用吗，没用就把他删除吧」。

**结论：确实没用了，而且它早就是不可达的死代码。** 证据链：

1. **没有任何平台能走到 RSSHub 分支**。
   `TimelineRepository._fetchOne()` 里原本是三个 `if`：`Platform.bilibili` → 官方接口、
   `Platform.weibo` → 官方接口、**否则** → 拼 RSSHub 路由拉 XML。
   但 `Platform` 枚举**只有这两个值**（`content_item.dart:5-7`），前两个 `if`
   已经把全部情况 return 掉了 —— 第三个分支从「阶段 2 落地官方接口」那天起
   **一行都没再执行过**。
2. **公共实例本身早已全灭**。官方文档列的 19 个实例里，实测只有 1 个能返回内容，
   其余是 Cloudflare 挑战或 5xx（这条结论在 `AppConfig` 的旧注释里躺了很久）。
3. **设置页的两个输入框是纯摆设**。`baseUrl` / `weiboBaseUrl` 只被 `_fetchOne`
   用来拼 RSSHub 路由；上面的分支不可达 → 改了地址对任何一次拉取都毫无影响。
   微博侧更早就改成了 `m.weibo.cn` 官方接口，连 `weiboBaseUrl` 都不读。

**删了什么**：

| 类别 | 内容 |
| --- | --- |
| 文件 | `lib/data/rss/rsshub_client.dart`、`lib/data/rss/rss_parser.dart`（整个 `lib/data/rss/` 目录）、`test/rss/rss_parser_test.dart` |
| 仓库层 | `TimelineRepository` 的 `_rss` 字段与构造参数、RSSHub 拉取分支（含 stale-while-error 降级）、`_FetchTask.baseUrl`、`load()` 的 `baseUrl` / `weiboBaseUrl` 参数、`_baseFor()` |
| 依赖注入 | `rssHubClientProvider`、`rssDioProvider`、`DioFactory.createRssDio()` |
| 配置 | `Prefs.rssHubBaseUrl` / `setRssHubBaseUrl` / `weiboBaseUrl` / `setWeiboBaseUrl`、`AppConfig.defaultRssHubBaseUrl` / `knownInstances` / `weiboBaseUrlHint`、`SettingsState.baseUrl` / `weiboBaseUrl` / `hasSeparateWeiboBase` / `effectiveWeiboBase` |
| 界面 | 设置页**整个「RSSHub 实例」卡片**（基地址输入框 + 一键填入 chips + 测试连接 + 微博专属实例 + 探测结果块）及 `_saveBaseUrl` / `_saveWeiboBaseUrl` / `_probe` 三个方法 |
| 测试 | 3 个测试文件里用来断言「不许回落到 RSSHub」的 `_CountingRss` 假客户端与 `expect(rss.calls, 0)` |

**顺手修掉的 4 处「删除之后才暴露出来」的残留**（不改就是骗用户）：

1. `AppError.rateLimited` 文案 `'公共 RSSHub 实例限流，请稍后重试或更换实例'`
   → **没有实例可换了**，改成 `'请求过于频繁，请稍后重试'`；
2. `AppError.forbidden` 的微博分支 `'该实例未配置微博 Cookie…请在设置中更换实例'`
   → 改成 `'微博拒绝了这次请求，请确认已登录微博后重试'`；
3. `AppError.server` 的 `'请稍后重试或更换实例'` → 去掉「更换实例」；
4. 设置页「关于」里 `'Rrha v0.1.0 · 公共 RSSHub 原型验证版'` 与
   `'数据来源为公共 RSSHub 实例…可更换实例'` → 改成与当前事实一致的描述；
   同时把「微博只在内置浏览器看」这类**已经过时两轮**的说法一并更新。

另外把用户可见的「**RSS 缓存**」改名为「**接口缓存**」（现在存的是官方接口 JSON），
`AppConfig.rssCacheTtl` 更名为 `timelineCacheTtl`。
**磁盘目录 `rss_cache` 刻意没改名** —— 改了会让老用户的已有缓存变成孤儿目录白占空间。

**为什么用穷尽 `switch` 而不是继续 `if`**：

```dart
switch (task.route.platform) {
  case Platform.bilibili: return _fetchBili(...);
  case Platform.weibo:    return _fetchWeibo(...);
}
```

这样将来新增平台时**编译器直接报错**，不会再出现「悄悄掉进某条谁也不认识的兜底路径」
这种极难发现的情况（这次删掉的死代码就是这么攒出来的）。

**验证**：

| 项 | 结果 |
| --- | --- |
| `dart analyze lib test` | **No issues found** |
| `flutter test` | **989 全通过**（删掉 RSS 解析器的 20 条，其余全部保留） |
| `assembleProfile` | BUILD SUCCESSFUL |
| 真机·设置页 | 「RSSHub 实例」区块**完全消失**，首屏直接是「数据源状态」；缓存项显示「接口缓存 · 62 个条目 · 10.23 MB · TTL 5 分钟」 |
| 真机·时间线 | **117 条 · 6 个订阅源**，B 站与微博交错正常，头像/计数/全文按钮均正常 —— 证明删掉 RSSHub 后聚合链路**未受损** |
| logcat | 无 exception、无 crash |

---

### 7.25 微博子评论完整展开（2026-10-22）

> 用户需求：**微博子评论最多只显示 2 条，要能展示完整**；并提供了参考设计 HTML。

#### 一、根因：不是 UI 截断，而是接口内嵌只给 2 条

查证结果：`comment_section.dart` 与 `weibo_comment_parser.dart` **都会渲染/读取全部 `replies`**，
没有任何 `take(2)` 之类的截断。

真正原因：**`hotflow` 一级评论接口内嵌的 `comments[]` 只给前 2 条**，完整回复要单独调接口。

#### 二、探针：`hotflowChild` 可用，但有两个结构性坑

`GET https://m.weibo.cn/comments/hotflowChild?cid=<一级评论id>&max_id_type=0`
实测 **200 / ok=1、第 1 页返回 10 条**（而内嵌只有 2 条），续拉第 2 页 2 条、**零重复**。

| 坑 | 说明 |
| --- | --- |
| **列表路径不同** | 该接口是 **`data`（直接 List）**，不是一级接口的 `data.data` |
| **游标不在响应里** | 子接口**不带游标**；续拉要用**同一楼层一级评论节点的 `max_id`** |
| **`total_number` 不等于能拿到的条数** | 样本 `total_number=68`，接口**只给 12 条**就没游标了。它是「微博 App 里显示的回复数」（含折叠/已删除） |

**因此 `total_number` 只能用于文案「共 N 条回复」，绝不能当可拉取条数或 loading 分母**
（否则界面永远卡在 12/68）。已用单测钉死这条语义。

#### 三、★ 修复的真 bug：`repliesLoaded` 被误当「UI 已展开」

第一版实现后真机发现：**子评论区一进页面就是展开态**（显示「收起 ^」），
用户根本看不到「默认只显示 2 条」的折叠状态。

**根因是两个概念被混用**：

| 字段 | 原本语义 |
| --- | --- |
| `BiliComment.repliesLoaded` | **数据已拿到**（内嵌 2 条让它一解析就是 `true`） |
| UI 需要的是 | **用户点开过** |

修法：新增 `CommentListState.expandedReplies`（`Set<String>`，按评论 id 记交互态），
UI 判据改为 `expandedReplies.contains(comment.id)`，**彻底不再看 `repliesLoaded`**。

#### 四、实现结构

| 层 | 文件 | 职责 |
| --- | --- | --- |
| 模型 | `lib/data/models/comment.dart` | 新增 `totalReplies`（文案用）与 `replyCursor`（续拉游标） |
| 解析 | `lib/data/weibo/weibo_comment_parser.dart` | 新增 `parseChildPage`：读 **`data`（List）**；零 IO |
| 仓库 | `lib/data/weibo/weibo_comment_repository.dart` | 新增 `loadChildReplies`：升级 URL、拼游标、失败不重试 |
| 状态机 | `lib/features/comments/comment_controller.dart` | `expandedReplies` + `toggleReplies` 分平台；微博走两段式 |
| 界面 | `lib/features/comments/comment_section.dart` | `_weiboReplies` 两段式渲染 + `_SubCommentTile` |

**交互**（照用户参考设计）：

| 状态 | 表现 |
| --- | --- |
| 默认 | 只显示**前 2 条** + `...... 共 N 条回复 >` |
| 点开后 | 显示全部已加载的，该行变 `收起 ^` |
| 拉到底但没拉满 | 该行上方补 `已显示全部 M 条`（如实告知） |

**成本控制**：只在用户点击时拉，列表构建路径零请求；单次展开最多 3 页；失败不重试。

#### 五、门槛与取证

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **1089 passed**（连续跑两次稳定） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| **折叠态真机证据** | ✅ `tools/shots/stage10-subcomment-collapsed.png`：可见 `...... 共 11 条回复 >`、`共 8 条回复 >`、`共 9 条回复 >`，且楼层只显示 2 条子评论 |
| **B 站回归** | ✅ `tools/shots/stage10-bili-regression.png`：仍是「查看 4 条回复」/「收起回复」老交互 |
| **展开链路** | ⚠️ **由 widget 测试覆盖，真机点击未取证**（见下） |

#### 六、⚠️ 如实说明：真机「点击展开」未取证

**折叠态（默认 2 条 + 共 N 条回复）已在真机确认**，但「点击那一行 → 展开超过 2 条」这一步
**没能在真机上稳定取证**：

- `uiautomator dump` 把整个楼层合并成一个节点（`content-desc` 含全部文本），
  那一行 `InkWell` **没有独立的可点击 bounds**，无法用坐标精确命中；
- 多次按比例估算坐标点击，均未命中（部分点击落到了图片预览或触发了页面滚动）。

**替代证据**：`test/features/comment_subcomment_ui_test.dart` 用**真实 widget 树 + 真实手势**
（`tester.tap(finder)`，不是直接调方法）验证了完整链路：

- 「未展开：只显示前 2 条 + `...... 共 68 条回复 >`」
- 「点击 → 展开显示全部已加载的，行变成 `收起 ^`」
- 「展开后拉到更多 → 显示超过 2 条（核心验收）」
- 「`repliesLoaded=true` 也不能让楼层一进页面就是展开态」（钉死本 bug）
- 「B 站仍是『查看 N 条回复』」（红线回归）

**结论**：逻辑层已验证；**真机 UI 点击这一环需要人工再点一次确认**。
若人工点击后仍不展开，那是命中测试问题（可能要给那一行加 `behavior: HitTestBehavior.opaque`
或扩大可点区域），属于已知待查项。

#### 七、未取证

1. **真机点击那一行是否真的能展开**（见上，建议人工确认一次）。
2. **`total_number` 与实际可拉条数差距的成因**：样本 68 vs 12，
   推测含「被折叠/已删除」回复，未进一步验证。
3. 单条评论的回复数量上限未探（本轮样本最多 12 条）。

---

### 7.26 微博子评论「内容解析失败」根治（2026-10-23，真机验证通过）

> 承接 §7.25：那轮把两段式展开做出来了，但真机点「共 N 条回复」只显示红字
> **「内容解析失败」**，一条子评论都补不出来。本节是根治记录。

#### 一、★ 定位过程：三次错误假设，最后靠「把响应打上屏」才确诊

真机排查最难的环节是**看不见响应**：profile 包下 `print` / `Log` 都进不了 logcat
（本项目 §7.10 已记录这个限制）。所以本轮的做法是**把诊断信息塞进用户可见的错误文案**，
逐层缩小范围：

| 轮次 | 假设 | 结果 |
| --- | --- | --- |
| 1 | 缺 `Referer` | 补上后**仍然失败** |
| 2 | 结构是 `data.data` 而非 `data` | 诊断显示 `顶层=Map(ok,errno,msg,extra) · data=null` → **接口在报错，不是结构问题** |
| 3 | 补齐 AJAX 标记（`X-Requested-With`/`MWeibo-Pwa`） | 响应从 HTML 变成 JSON，但变成 `errno=100011 · msg=暂无数据` → **请求参数不对** |

三次都有具体证据，没有一次是靠猜。

#### 二、真实根因：**首屏就带错了游标**

`hotflowChild` 的分页语义是：

| 请求 | 结果 |
| --- | --- |
| **不带 `max_id`** | ✅ 返回 10 条（第 1 页） |
| **带 `max_id=<一级节点值>`** | ✅ 返回 2 条（第 2 页，零重复） |
| 带错/重复带同一游标 | ❌ `errno=100011 暂无数据` |

而旧实现把 `replyCursor`（一级评论节点的 `max_id`）**直接当成了首屏游标**，
第一发请求就带上了它 → 服务端认为「这一页已经翻过了」→ 回 `暂无数据`。

**修法**：首屏**不带**游标；从第 2 页起才用游标（优先用仓库返回的
`page.nextCursor`，缺失则回退到一级节点的 `replyCursor`）。

#### 三、另外两个必须一起修的点

1. **`errno=100011`（暂无数据）是正常终止信号，不是错误。**
   旧代码把「`data` 不是 List」一律当结构异常抛错，于是「这条评论没有更多回复」
   也会给用户甩红字。现在显式识别该业务码 → 当作「到底」，不报错。
2. **`childHeaders` 两个都要带齐**（缺任一都会被当普通网页访问，回 HTML）：
   - `Referer: https://m.weibo.cn/status/<mid>`
   - `X-Requested-With: XMLHttpRequest` + `MWeibo-Pwa: 1`

#### 四、让错误「可诊断」的改进（本轮最重要的工程收益）

以前真机失败只能看到一句 `内容解析失败`，逼得人反复改代码试。现在：

| 位置 | 现在会显示什么 |
| --- | --- |
| 响应是 HTML | `微博子评论返回网页而非数据 … · <!DOCTYPE html>…`（带响应体前 200 字符） |
| 响应非 JSON | `… 不是合法 JSON · <响应体摘要>` |
| 结构异常 | `… 结构异常 · 顶层=Map(ok,errno,msg,extra) · data=null · errno=100011 · msg=暂无数据` |

`AppError.detail` 也会一并上屏（`message（detail）`）。**这些都是响应摘要，
不含 cookie / 请求头**。下次再出问题，一眼就能看出根因，不必再猜三轮。

#### 五、门槛与真机验收

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **1089 passed** |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| 真机：点「共 14 条回复」 | ✅ **拉出十余条子评论**（`LWJ0803` / `忆世间风雨` / `YqYzzzzZ` / `灯光下的泥宁` / `云中羊羔` / `一只斐迪南` / `沃玛超级骂` …），**无红字报错** |
| 真机：回复少的楼层 | ✅ 显示「已显示全部 2 条」（不再误报失败） |

截图：`tools/shots/stage11-subcomment-fixed.png`（展开结果）、
`stage11-subcomment-expanded.png`。

#### 六、修正了一条既有测试的语义

`test/features/comment_controller_test.dart` 里原本断言
`calls.first.maxId == '145767900000000'`（首次请求带游标）——
那正是本 bug 的来源。已改为断言 **首次 `maxId` 为 null、第二次非空**，
并在测试里写明了原因。**这是纠正错误语义，不是放宽断言。**

#### 七、未取证

1. `total_number`（如 14）与实际可拉条数（十余条后到底）仍有差距，
   推测含被折叠/已删除回复，未进一步验证。
2. 微博「三层楼」（二级的子回复）仍无样本，接口是否提供未知。

---

### 7.27 微博视频卡片：封面可见 + 点击即播（2026-10-27，真机验证通过）

> 用户报告：「微博博主发的视频现在看不了，我需要视频在卡片上就可以看见，可以点开播放。
> 卡片排版参考 bilibili 的视频卡片。」并给了一条真实视频作为验证样本。

#### 一、★ 这条需求终于补上了唯一的空白样本

§7.17 的字段表里写着：

> `page_info.media_info`：⚠️ **31 条样本里 0 条**，视频直链字段名**未经实测**

也就是说，**视频分支此前从来没有任何真实样本验证过**，解析器里的字段名全是
「按常见候选键名逐个试」的猜测。用户给的这条
`https://weibo.com/tv/show/1034:5358370303967334` 是第一条真实视频，
本轮先用探针把结构钉死，再改代码。

#### 二、实测结构（`.env/weibo_video_probe.md`，真机登录态抓取）

```
page_info.type              : "video"
page_info.object_id         : "1034:5358370303967334"
page_info.title             : "来唱轻松快乐的生日快乐歌吧"
page_info.video_orientation : "vertical"
page_info.play_count        : "6万次播放"        ← 中文串，不能直接转数字
page_info.page_pic.url      : https://wx4.sinaimg.cn/.../xxx.jpg   ← ★ 封面在这
page_info.media_info        : 只有 3 个 key
  media_info.stream_url     : https://f.video.weibocdn.com/o0/xxx.mp4?Expires=...
  media_info.stream_url_hd  : 同上（本例与 stream_url 同值）
  media_info.duration       : 26.331              ← double，单位秒
page_info.urls              : mp4_720p_mp4 / mp4_hd_mp4 / mp4_ld_mp4
```

#### 三、两个真实根因（都不是「猜错了字段名」那么简单）

| # | 根因 | 证据 |
| --- | --- | --- |
| 1 | **封面根本不在 `media_info` 里**，在 `page_info.page_pic.url`。旧代码从 `media_info.cover_url / cover / big_pic_info` 找，这三个 key **一个都不存在** | 上方实测字段表 |
| 2 | **直链必须带 `Referer: https://weibo.com/` 才能下载** | 同一条 URL：不带 → `HTTP 403 · text/html · 238 字节`；带上 → `HTTP 200 · video/mp4 · 2,730,923 字节` |

第 2 条是「视频看不了」的**直接原因**：即使直链拿到了，不带 Referer 也必然被 CDN 拒绝。

#### 四、还有第三处（UI 层）：卡片整块媒体区不渲染

`ContentCard` 原来用 `item.images.isNotEmpty` 判断有没有媒体区。而**微博视频微博的
`pics` 是空的**（封面在 `page_info` 里）—— 于是视频卡**整块媒体区都不渲染**，
用户看到的是一条没有任何视频痕迹的纯文字微博。

修法：媒体地址改为 `_mediaImages()`，视频且无 `pics` 时用 `videoRef.coverUrl` 兜底。

#### 五、探针的「自我验证」设计（值得复用）

探针不只摊平字段，最后一步是 **把命中的真实 mblog 喂给真实解析器**
（`WeiboParser.fromMblog`），直接验证产品代码取到了什么：

```
E2E：kind=video · 直链=✅ 有 · 封面=✅ 有 · 时长=26s · 竖屏=true
```

这一步把「接口给了什么」和「产品拿到了什么」分开验证——前者过了但后者没过，
就是解析器的锅。`tools/` 下新增 `probe_weibo_video.py`（宿主机探针，游客态会被
Visitor System 拦，仅作对照）与 `lib/data/weibo/weibo_video_probe.dart`（真机探针，
入口：内置浏览器 `⋮` → 「视频直链探针」）。

#### 六、改了什么

| 文件 | 改动 |
| --- | --- |
| `lib/data/models/video_ref.dart` | 新增 `duration`（`Duration?`）与 `isVertical`（`bool?`），一并进 `toJson`/`fromJson` |
| `lib/data/weibo/weibo_parser.dart` | `_videoRefOf` 改为接收**整个 `page_info`**；直链取 `media_info.stream_url_hd → stream_url → urls.mp4_720p_mp4`；**封面取 `page_pic.url`**；新增 `_durationOf`（double 秒 → Duration，按量级区分秒/毫秒） |
| `lib/widgets/content_media.dart` | 视频单图改为 B 站卡片形态：中央 `_CenterPlayButton` + 右下角 `_DurationBadge`；**竖屏视频用 `BoxFit.contain` 居中留边**（硬裁 16:9 会把竖构图主体切掉）；新增顶层函数 `formatDuration`（可单测） |
| `lib/features/timeline/content_card.dart` | 新增 `_mediaImages()`（视频无 pics 时用 `coverUrl` 兜底）；`_onMediaTap` 在多图时仍看大图 |
| `lib/features/timeline/content_opener.dart` | 新增 `opensInSimplePlayer()`：微博 + 有直链 → **直接进 `SimpleVideoPage`**（此前要先落详情页再点「尝试播放」） |
| `lib/features/player/simple_video_page.dart` | 文档写明 `referer` 是必需参数（附 403/200 证据）；失败文案不再说「不承诺可播」 |

#### 七、真机验证

| 项 | 结果 |
| --- | --- |
| 探针（真机登录态） | ✅ Q4：无 Referer → 403 / 带 Referer → **200 · video/mp4** |
| 探针端到端（喂真实解析器） | ✅ `直链=有 · 封面=有 · 时长=26s · 竖屏=true` |
| 时间线视频卡渲染 | ✅ 16:9 封面 + 中央播放按钮（截图 `tools/shots/video-28-scan.png`） |
| 点视频卡 → 播放页 | ✅ 画面在播、弹幕滚动、进度 37:20（`video-29-play.png`） |

#### 八、测试

全量 **1172 passed**（上一轮 1089，新增 83 条）。新增覆盖：

- `weibo_parser_test.dart`：真实样本全字段、时长秒/毫秒量级、`urls` 兜底、
  竖屏三态、空 `media_info`、封面回退；
- `content_card_test.dart`：**pics 为空时媒体区仍渲染**（本次核心回归点）、
  时长角标、点封面播放、视频带 pics 时图集不被压缩；
- `content_media_test.dart`：`formatDuration` 四组（含毫秒取整、负数）；
- `content_opener_test.dart`：微博**有直链 → 播放页**、**无直链 → 详情页**。

**修正了两条既有测试的语义**（都对应本次有意改变的行为）：
`微博视频 → 详情页（不进 PlayerPage）` 改为「有直链直接进 `SimpleVideoPage`」；
`content_card` 的媒体区断言补充「视频多图仍看大图」。

#### 九、未取证

1. **`mp4_720p_mp4` 指向另一个文件**（文件名与 hd/ld 不同），说明它才是更高码率档。
   本轮按「先 hd」取，未做画质切换 UI。
2. 竖屏视频在**播放页**仍是横屏布局（`SimpleVideoPage` 不锁方向、不做竖屏信箱）。
   卡片侧已按 contain 处理，播放页留给后续。
3. `play_count`（"6万次播放"）是中文串，未接入卡片（决策：卡片只要封面 + 播放按钮）。

---

### 7.28 微博视频改为「详情页内自动播放 + 控制栏」（2026-10-28）

> 用户反馈（接 §7.27）：「我需要点击视频的时候进的是视频详情页，能看到评论的那种。
> 现在无论是点击标题，还是视频封面还是卡片上的评论都只能进入视频本身，还没办法对其进行操作。」
> 随后追加：「微博播放视频时和 bilibili 的视频一样，下边有控制栏可以控制，
> 可以双击播放，双击暂停，长按快进等功能。」并明确：「**微博视频不需要弹幕功能**。」

#### 一、★ 上一轮的判断被用户否掉了（如实记录）

§7.27 把「微博 + 有直链」直接送去 `SimpleVideoPage`（全屏播放页），
当时的理由是「点封面就是想看视频，先落详情页再点一次是多余的一跳」。

**这个判断是错的。** 真机上的实际后果是：全屏页里只有画面，
**没有评论、没有原文、没有转发块**，想评论必须返回时间线再点一次。
用户的原话「只能进入视频本身，还没办法对其进行操作」指的就是这个。

修法：删掉 `ContentOpener.opensInSimplePlayer()`，微博视频**回落到
`ContentDetailPage`**，视频在页内就地播放，评论就在下面。
分发规则回到两条：

```
B 站 + 有 bvid  → PlayerPage        （能播放，自带 aid 评论区）
其余            → ContentDetailPage （图文 / 微博视频：页内自动播 + 评论列表）
```

#### 二、新增 `lib/features/player/inline_video_player.dart`

详情页内嵌播放器。**不复用 `PlayerControlsOverlay`**，因为它与弹幕强耦合
（`danmakuCount` / `onToggleDanmaku`）；微博没有弹幕接口，复用就得传假值、
造出一个点了没反应的弹幕按钮 —— 比不给更糟。

交互规格**逐条对齐 B 站播放页**（`docs/HANDOVER.md` §7.23 + `player_page.dart`）：

| 手势 / 控件 | 行为 |
| --- | --- |
| 单击画面 | 显示 / 隐藏控制栏（3 秒自动隐藏，暂停时不隐藏） |
| **双击** | 播放 / 暂停 |
| **长按** | 2.0x 快进，松手回 1.0x（与 `player_page._longPressSpeed` 同值） |
| 横向拖动 | 拖动预览进度，松手才 seek |
| 底部控制栏 | 播放/暂停 + 进度条 + `mm:ss / mm:ss` + 全屏 |
| 播完后 | 回到可重播状态；点一下从 0 重播 |

**刻意不做**：弹幕（用户明确要求不要）、清晰度切换（`media_info` 只给一条直链）、
倍速菜单、进度记忆 —— 这些在 `PlayerPage` 里都有，但依赖微博拿不到的数据。

#### 三、三个只有真机/单测才暴露的坑（都已修）

**① 控制栏外层 `IgnorePointer` 把整条按钮区吞了**

`IgnorePointer` 的 `ignoring` 默认是 **true**。外层套一个「只想让中间区域穿透」
的 `IgnorePointer`，结果连底部按钮一起失效：**渲染完全正常、点击全死**。
这类错法在截图上一点看不出来（与 §7.10 的渐变装饰层是同一类陷阱）。

**② `Positioned.fill + Align` 抢走了整个画面的手势**

`Align` 会把 child 布局到整块可用区域，导致上层 Stack 子节点（控制栏）
优先命中，于是「双击暂停」「长按快进」全部失效 —— 控制栏看得见、画面点不动。
改成 `Positioned(left/right/bottom)` 后只占底部条，中间区域留给手势层。

> 这条是**单测先发现的**（真机前）：双击后 `calls` 里没有 `pause`。

**③ 假播放器用 `Stream.value` 导致「状态永远不更新」**

测试里的假 `RrhaPlayer` 一开始写 `playingStream => Stream<bool>.value(_playing)`。
它**只在订阅那一刻发一次**，之后 `play()` 再也不会推状态 → 界面永远停在
「未播放」，控制栏一直显示 ▶。

真实播放器会推状态变化，假实现必须同构。改成 `StreamController.broadcast()`
+ 状态变化时主动 `add`。**这条差点让我去改产品代码**（以为界面不刷新）。

#### 四、改了哪些文件

| 文件 | 改动 |
| --- | --- |
| `lib/features/player/inline_video_player.dart` | **新建**：内嵌播放器 + 控制栏 + 全套手势；`playerFactory` 注入点便于单测 |
| `lib/features/timeline/content_detail_page.dart` | 微博视频（有直链）→ `InlineVideoPlayer`；删除重复的 `_WeiboVideoSection`「尝试播放」区块，换成只在**无直链**时出现的 `_WeiboNoUrlHint`；`_VideoCover` 对微博不再绑点击（防自跳转死循环） |
| `lib/features/timeline/content_opener.dart` | 删除 `opensInSimplePlayer()`，微博视频回落详情页 |
| `lib/features/timeline/content_card.dart` | 「评论」图标接 `onTap`（进详情页）；转发/点赞仍不可点；视频无 `pics` 时用 `videoRef.coverUrl` 兜底媒体区 |

**两处删掉重复入口的原因**：改完后详情页顶部已经是播放器，若再保留
`_WeiboVideoSection` 的「尝试播放」按钮，页面上会同时有两个播放入口
（真机截图 `tools/shots/detail-12-weibo-detail.png` 拍到的正是这个）。

#### 五、真机验证（截至本节）

| 项 | 结果 |
| --- | --- |
| 微博视频进详情页 | ✅ 顶栏「微博 · 视频」，评论 `455` 条同时加载出子评论 |
| 页内视频区 | ✅ 是播放器而非静态封面（`dur=26s` 与接口 `26.331` 对得上） |
| 画面在推进 | ✅ 相隔 2 秒两帧哈希不同 |
| 播完/暂停后可重播 | ✅ 点击从 0 重播 |
| 重复「尝试播放」区块 | ✅ 已消失 |

截图：`tools/shots/detail-12-weibo-detail.png`（修复前，两个播放入口）、
`detail-13-fixed.png` / `detail-17-late.png`（修复后，单一视频区 + 评论）。

#### 六、测试

全量 **1185 passed**（§7.27 为 1172，新增 13 条）。新增覆盖：

- `content_detail_page_test.dart` 新文件：微博视频→详情页、评论 `oid` 正确、
  无直链不起播放器、进入即自动播 + 销毁释放；
- **交互组（逐条对齐 B 站）**：控制栏四要素齐全、按钮能暂停/播放、
  **双击 = 暂停**、**长按 2.0x 且松手回 1.0x**、单击切换显隐；
- **「没有任何弹幕入口」**：断言不存在弹幕图标与「弹幕」文字，
  防止后续「顺手对齐 B 站」把它加回来。

修正的既有测试：`content_opener_test.dart` 里「微博视频（有直链）→ 直接进
`SimpleVideoPage`」改为「→ 详情页」。

#### 七、未取证

1. ~~真机上的双击/长按手势本轮未复拍~~ → **已在下一轮真机验证并修掉一个拦截层**，见 §7.29。
2. 全屏态的竖屏视频信箱（letterbox）表现未拍。
3. 拖动手感（一屏宽 ≈ 全片长的映射）未按真机调参。

---

### 7.29 微博视频控制栏真机联调：三层手势拦截（2026-10-28，真机验证通过）

> 承接 §7.28。那一轮把内嵌播放器与控制栏写完了，单测全绿，但**真机上一次点击都没收到**。
> 本节记录定位过程与三个拦截层，以及最终的验证证据。

#### 一、★ 症状：画面在播，控制栏却点不出来

真机现象：视频正常播放、进度在走，但**单击唤不出控制栏、双击无效、长按无效**。
因为看不见内部状态，先在组件里加了一个**编译期开关控制的诊断角标**
（`kWeiboDiagnosticsEnabled` 打开时才渲染，正式包零成本）：

```
r=true  v=false  p=true  tap=0  down=0
```

`tap=0` / `down=0` 是关键：**手势层连一次 `onTapDown` 都没收到**。
这不是「状态没刷新」，而是**事件根本没到达**。

#### 二、三个拦截层（逐层剥掉才通）

**① `media_kit` 的 `Video` 根节点是 `Container(color:)`**

读 `.env/pub-cache/.../media_kit_video-1.3.1/lib/src/video/video_texture.dart`
第 381 行：

```dart
return Container(
  clipBehavior: Clip.none,
  width: ..., height: ..., color: videoViewParameters.fill,
  child: Stack(...)
);
```

`Container(color:)` 会构建 `RenderDecoratedBox`，而
`Decoration.hitTest` 的默认实现是 **`=> true`**（`painting/decoration.dart`）。
于是**视频画面自己就是命中目标**，把手势层整个挡掉。

> 这与 §7.10 那个「渐变装饰层吃掉手势」是**同一个渲染层陷阱**，
> 只是这次来自第三方组件的内部实现 —— 教训是：**别人的组件也可能吃掉你的手势**。

修法：画面外面包 `IgnorePointer`。

**② 控制栏外层 `IgnorePointer` 的默认值是 `true`**

写第一版时用 `IgnorePointer` 包控制栏「只让底部条参与命中」，
忘了 `ignoring` 默认就是 `true` —— 整条控制栏按钮全点不动。
渲染完全正常，截图看不出任何异常（同样与 §7.10 同源）。

修法：删掉那层，改用 `Positioned(left/right/bottom)` 直接收窄命中区域。

**③ `Positioned.fill + Align` 会撑满整个画面**

改用 `Align(bottomCenter)` 时，`Align` 把 child 布局到整块可用区域，
上层 Stack 子节点（控制栏）优先命中 → 双击/长按又被吃掉。

修法：`Positioned(left: 0, right: 0, bottom: 0)`，只占底部条。

#### 三、第四个坑：点按钮时控制栏跟着消失

控制栏能出现之后发现：**点暂停按钮，视频暂停了，但控制栏同时被隐藏**。

原因：按钮的 `InkWell` 与画面手势层的 `onTap`（切换控制栏）**同时进入手势竞技场**，
点击被两个识别器都消费了一次。

修法：给控制栏套一层 `GestureDetector(onTap: () {})` **抢占事件**。

> ⚠️ 这里有个反直觉的点：**只注册 `onTapDown` 是不够的**。
> 只注册 `onTapDown` 的识别器在手势竞技场里会被判为「不参与竞争」，
> 事件照样漏到下面。必须注册 `onTap`（哪怕动作是空的）才会真正赢下竞技场。
> 第一版就是这么写的，`tap` 计数照样 +1。

#### 四、真机验证（荣耀 Magic8 Pro / Android 16）

| 项 | 证据 | 截图 |
| --- | --- | --- |
| 视频在详情页内自动播放 | `p=true`、进度 `00:05 / 00:26` 且在推进 | `ctrl-final-01.png` |
| 控制栏四要素齐全 | ⏸ 暂停 + 进度条 + `00:00 / 00:26` + ⛶ 全屏 | 同上 |
| 单击唤出 / 收起控制栏 | `v=false → v=true`，`tap` 递增 | `ctrl-11-tapdown.png`、`ctrl-17.png` |
| **双击 = 播放/暂停** | 双击后 `p=false`，进度停在原处 | `ctrl-17.png` |
| **点播放按钮从 00:26 重播** | 点击后 `p=true`、进度回到 `00:00 / 00:26` | `ctrl-21-play.png` |
| **长按 2.0x 快进** | 1.5 秒按住后 26 秒的视频播到 `00:26 / 00:26`，且 `tap` 不增（长按未被误判成单击） | `ctrl-22-longpress.png` |
| 评论与视频同页 | 「评论 469」+ 子评论可见 | 全部截图 |
| 无弹幕入口 | 控制栏只有 4 个控件 | 同上 |

诊断角标（`r/v/p/tap/down`）是这一轮能收敛的关键 —— 它把
「界面没刷新」「事件没收到」「按钮没命中」三种完全不同的故障区分开了。

#### 五、门槛

| 项 | 结果 |
| --- | --- |
| `dart analyze` | ✅ `No issues found!` |
| `flutter test --no-pub` | ✅ **1186 passed**（§7.28 为 1185，新增 1 条真机回归） |
| `flutter build apk --profile` | ✅ `Built ... (142.4MB)` |
| `adb install -r` + 真机操作 | ✅ 上表 |

新增回归测试：**「点控制栏按钮不会同时把控制栏藏起来」** ——
它直接钉住第 3 节的坑，防止后续改布局时把那个 `GestureDetector` 删掉。

#### 六、环境侧：ADB 换口后连接失败（已解决）

本轮开始 `adb devices` 一直是空，但 Windows 设备管理器里 `ADB Interface` 状态正常。
根因（`§6.6` 老问题，换 USB 口会重新触发）：

| 检查项 | 当时的值 | 应为 |
| --- | --- | --- |
| 驱动文件 | `winusb.inf`（通用） | `android_winusb.inf` |
| `DeviceInterfaceGUIDs` | **不存在** | `{F72FE0D4-CBCB-407d-8814-9ED673D0DD6B}` |

两个新踩的坑，都写进脚本注释了：

1. **原脚本把接口号写死成 `MI_01`**，换口后变成 `MI_02` 就找不到设备。
   新脚本 `C:\Android\fix-adb-guid-adaptive.ps1` 改为**按 `FriendlyName`
   匹配 `ADB Interface`**，换到任何 `MI_0x` 都能用。
2. **`.ps1` 里写中文导致解析崩溃**（`Unexpected token '}'`）：
   Windows PowerShell 5.1 按 GBK 读 `.ps1`，UTF-8 无 BOM 的中文会变成乱码
   并吃掉后面的引号/括号。修法：**该脚本全文改为纯 ASCII**
   （实测 `nonAscii=0`），并在文件头写明原因。
   > `§6.6` 原本记的是「`.ps1` 要 UTF-8 **带 BOM**」。本轮补充：
   > 如果不方便管 BOM，**纯 ASCII 更稳**，代价是注释只能用英文。

修完之后 `adb devices` 立刻出现 `<你的设备序列号>`（先 `unauthorized`，
在手机上点「允许」后变 `device`）。

#### 七、未取证

1. **全屏态的竖屏信箱表现**未拍（控制栏的全屏按钮已渲染，未在本轮点开验证）。
2. **拖动手感**（一屏宽 ≈ 全片长的映射）未按真机调参。
3. 横屏（`isVertical=false`）视频的 16:9 分支本轮未单独验证 —— 手上这条样本是竖屏。

---

### 7.30 B 站评论配图 + 动态详情页（2026-11-02，真机验证通过）

> 用户报：「bilibili 卡片的评论区里的评论没有图片。动态和视频的评论区里有图片的
> 评论都要带图片。」指定样本：动态 `opus/1266051909563711506`、视频 `BV1RXx169Emu`。

#### 一、根因：UI 早就支持，是**解析层从来没填** `images`

`comment_section.dart` 早就按 `comment.images` 渲染 `PhotoGrid`（微博评论的图
就是这么显示出来的）。而 `BiliComment.images` 的注释里明确写着
「**B 站评论恒为空**」—— 也就是说这从来不是漏改，而是**当初就没做过**。

一行 `grep authorAvatar` 式的确认方式：

```
lib/data/bili/comment_parser.dart    → 改前全文搜不到 pictures
lib/data/weibo/weibo_comment_parser.dart → parseImages() / parseMixMediaIds()
```

#### 二、探针结论（`.env/probe_bili_comment_pics.py` 等三个脚本）

| 问题 | 结论 |
| --- | --- |
| 图片字段路径 | `content.pictures[i].img_src` ——**只有这一个地址字段** |
| 协议 | 服务端给 **明文 `http://i0.hdslb.com/bfs/new_dyn/...`**，必须转 https |
| 附赠字段 | `img_width` / `img_height` / `img_size`；动图另有 `play_gif_thumbnail` |
| 张数 | 实测最多 3 张，**接口给几张就是几张**（没有微博那种「声称 N 给 1」） |
| 楼中楼 | 结构相同，同走 `parseOne`，一并生效（本轮样本恰好 0 条带图） |
| 老形态 | `content.picture`（单数 Map）作兜底，本轮 0 命中 |
| 图片可达性 | https 版 HEAD **全部 200**，且**不依赖 Referer** |
| 图片体积 | ⚠️ 单张最大 **3.5MB**，另有一张 GIF **4MB** → `cacheWidth` 压缩是硬要求 |

**一个必须写下来的坑**：用户给的 opus 链接 `bilibili.com/opus/<id>` 里那段数字
**不是**评论 oid。拿它配 `type=11` / `type=17` 都是 `-404 啥都木有`。
正确入口是动态详情的 `item.basic.comment_id_str`（该样本实测 `414185073`）+ `comment_type=11`。

#### 三、改了哪些文件

| 文件 | 改动 |
| --- | --- |
| `lib/data/bili/comment_parser.dart` | 新增 `parsePictures` / `parsePictureAspectRatios`，`parseOne` 填 `images` |
| `lib/data/models/comment.dart` | 新增 `imageAspectRatios`（与 `images` 严格同序同长） |
| `lib/widgets/photo_grid.dart` | 新增 `aspectRatios` / `singleFit` / `alignment`；长图裁切 + 角标 |
| `lib/widgets/cached_image.dart` | 新增 `alignment` 参数（两条渲染路径都透传） |
| `lib/features/comments/comment_section.dart` | 把宽高比与 `contain` 传给 `PhotoGrid` |
| `lib/data/bili/bili_client.dart` | 新增 `dynamicDetail(id)` |
| `lib/data/bili/bili_content_parser.dart` | 新增 `fromDynamicDetail` / `commentEntryOf` |
| `lib/features/timeline/opus_detail_page.dart` | **新建**：按 opus 链接打开动态详情 + 评论 |
| `lib/features/settings/settings_page.dart` | 入口改为「按 BV 号 / 动态链接打开」，识别 opus |
| `lib/core/utils/bvid.dart` | 新增 `BiliIdParser.opusId` |

#### 四、长图的显示策略（用户两轮修订后的最终版）

**第一轮**用户说：「长图可以缩放少一些，在外边可见的视图里只放出一部分，
点开图片后才展示完整图片。」

**第二轮**用户补充：「有些并不是很长的图片不需要只显示一部分，正常展示即可。」

最终规则（`PhotoGrid._singleHeight`）：

| 情况 | 判据 | 列表内 | 点开 |
| --- | --- | --- | --- |
| 普通单图 | 比例 ≥ 0.5（高 ≤ 2×宽） | **按真实比例完整显示**，不受 `maxSingleHeight` 限制 | 全屏预览 |
| 多图 | 张数 > 1 | 正方格九宫格（`cover`） | 可左右翻页 |
| 长截图 | 比例 < 0.5 **且** 算出来的高度超上限 | `cover` + **顶部对齐**只露开头一段 + 「长图 · 点击查看」 | 可上下拖动看完整长图 |

**为什么用「高 > 2×宽」当判据，而不是「超过 maxSingleHeight」**：
一张 1080×1959 的手机截图（比例 0.55）按宽度铺满就是 2 倍宽高 —— 它**应该完整
显示**；而 1080×9109 的整页截图（比例 0.12）才真该裁。用上限当判据会把前者
也裁掉一截，那正是用户说的「并不是很长的图片」。这条改完真机确认：
同一屏里普通截图完整、超长截图仍带角标。

**不做 `contain` 的原因**：按比例缩到 260px 高时宽度只剩十几像素，
屏幕上就是一条黑线（第一版真机截图 `tools/shots/c11.png` 实证）。

#### 四之二、动态详情页按参考稿重排（用户第三轮要求）

用户给了 `桌面/动态内部.html` 作为**风格**参照（明确说明：html 只作风格参考，
图片展示方法参考微博板块）。按它重排后的骨架：

```
←                                          ↗  ⋮
◯48px  作者昵称（粉色 16px 粗体）              ← 作者行
       2026-11-02 18:08
正文 15px / 行高 1.6（保留换行）
[图片区 —— PhotoGrid，与微博详情页同一套]
评论 1065      赞和转发 2751                  ← 数据栏（评论数品牌粉加粗）
─────────────────────────────
评论 20                        [热度|时间]    ← 评论头部
```

| 参考稿元素 | 落地情况 |
| --- | --- |
| 48px 圆头像 + 昵称 + 时间 | ✅ 头像走 `CachedImage`（磁盘缓存），昵称 16px 粉色粗体 |
| 正文 15px / `leading-relaxed` | ✅ `fontSize: 15, height: 1.6` |
| 数据栏「评论 N　赞和转发 M」 | ✅ 评论数品牌粉粗体；**接口没给计数时整项不渲染**，不显示 0 |
| 图片区 | ✅ 复用微博那套 `PhotoGrid`（用户明确要求） |
| **IP 属地** | ❌ **不做** —— 参考稿明确去掉了 |
| 点赞/投屏等写操作 | ❌ **不做** —— 本 App 没有这些能力，画出来就是点了没反应 |
| 「直播中」气泡 | ❌ **不做** —— 需要另一个接口拿直播状态，不编 |

计数语义上有个必须守住的点：`ContentItem` 的三个计数字段是 `int?`，
「接口没给」与「确实是 0」是两件事。数据栏据此判空 —— 没给就不渲染那一项。

#### 五、真机验证表（荣耀 Magic8 Pro / Android 16）

| 项 | 证据 | 截图 |
| --- | --- | --- |
| 视频评论单图（竖长截图） | 完整按比例显示，未被裁 | `tools/shots/c3-player.png` |
| 视频评论**三图**九宫格 | 3 列正方格 | `tools/shots/d2-3pic.png` |
| 视频评论**超长截图** | 顶部一段 + 「长图 · 点击查看」角标 | `tools/shots/d3-longpic-cropped.png` |
| 点开看完整长图 | 全屏预览显示 `1 / 1`，可上下滚看全部 | `tools/shots/d4-gallery.png` |
| **动态 opus** 评论区 | 首条评论即带图 + 长图角标 | `tools/shots/e3-opus-detail.png` |
| 动态评论单图 / 双图 | 单图 16:10 完整、双图 2 列九宫格 | `tools/shots/e4-opus-more.png` |
| 动态评论更多长图 | 多条长截图都带角标 | `tools/shots/e7-opus-more-long.png` |
| **详情页新排版** | 48px 头像 / 粉色昵称 / 15px 正文 / 「评论 1065　赞和转发 2751」 | `tools/shots/g1-opus-new.png` |
| **普通竖图完整显示** | 1080×1959 的截图完整展示，无角标 | `tools/shots/g2-normal-pic.png` |
| **超长截图仍裁切** | 同一条动态里，普通截图完整、真长图仍带「长图 · 点击查看」 | `tools/shots/e3-opus-detail.png`、`tools/shots/e7-opus-more-long.png` |
| 视频评论回归 | 播放页评论区图片照常 | `tools/shots/g5-video-comments.png` |

#### 六、门槛

| 项 | 结果 |
| --- | --- |
| `dart analyze lib test` | ✅ `No issues found!` |
| `flutter test` | ✅ **1276 passed**（基线 1001，新增 275） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| `adb install -r` | ✅ Success |

#### 七、未取证 / 已知限制

1. **楼中楼带图**：两个样本的一级/二级评论**都没有带图**（探针实测 0 条），
   解析与渲染路径是同一套，但**真机未见到实例**。
2. **GIF 动图**：接口会给 `.gif`（探针见到一张 4MB），App 侧只按静态图渲染，
   **不播放动画**。这是既有行为，本轮未改。
3. **「保存到相册」长图**：全屏预览的保存按钮沿用了既有实现，本轮只验证了
   「能打开完整长图」，没点保存。
4. **动态正文的多图**：本轮样本的正文只有一张图，`PhotoGrid` 的多图九宫格
   在**正文区**未取到实例（评论区里的三图九宫格已验证）。
5. **动态详情的转发原动态**：`OpusDetailPage` 不渲染 `origin` 区块
   （时间线里进详情页那条路径会渲染）。本轮样本不是转发动态。
6. **「长图」判据的边界**：比例 0.5（正好高 2×宽）归为「普通图」。
   实测样本里没有正好卡在 0.5 的图，这个边界值是按「手机截图 0.55、
   整页长截图 0.12」两簇分布定的，未做逐像素调参。

#### 八、第三轮：详情页排版统一（2026-11-02 晚）

> 用户报：「纯文字动态你还是没有按照提供的 html 文件来做，动态内容出现两次。
> 要求修正后只保留上方的动态内容。」
>
> 第四轮：「把长图右下角那个长图.点击查看的角标去掉，其余地方保持不变。」

**根因不是排版，是同一个内容有两个详情页：**

| 入口 | 落的页面 |
| --- | --- |
| 「按 BV 号 / 动态链接打开」 | `OpusDetailPage` |
| 时间线卡片点开 / 原动态入口 | `ContentDetailPage` |

第一轮只改了 `OpusDetailPage`，而用户截图那张来自 `ContentDetailPage` ——
它还是旧排版，`displayTitle` 当大标题画一次、`summary` 整段再画一次。
而 B 站动态多数没有标题，解析层把 `title` 兜底成「正文首行截 60 字」，
于是同一句话被画了两遍。

**修法：把正文骨架抽成一份共用**，新建 `bili_dynamic_body.dart`：

- `BiliDynamicBody`：骨架本体（作者行 → 标题 → 正文 → 原动态 → 图片 → 数据栏 → 评论）
- `BiliAuthorRow` / `BiliStatRow`：作者行与数据栏
- `BiliDynamicStyle`：两档字号配色 + `hasOwnTitle` 判据

两个详情页都只负责 AppBar / 加载态 / 评论入口，正文一律走它，视觉不可能再分叉。

**参考稿其实有并列两屏**，核对后按 `images.isEmpty` 分档：

| 参考稿 | 昵称色 | 正文字号 |
| --- | --- | --- |
| `page-detail-image` 带图 | `text-pink` 品牌粉 | `text-[15px]` |
| `page-detail-text` 纯文字 | `text-primary` 正文深色 | `text-[16px]` |

用户截图里昵称是粉色、正文 15px，那是混用了带图那一屏的参数。

**`hasOwnTitle` 挡三种兜底标题**：正文首行（截 60 字）、`[图片]` 这类占位符、
`（无标题）`。反过来 `summary.isEmpty` 时标题照常显示，否则专栏/抽奖会被误伤。

**第四轮**：删掉 `PhotoGrid` 右下角的「长图 · 点击查看」角标。只删提示，
裁切行为（`cover` + 顶部对齐 + 高度上限）一行未动。

| 项 | 结果 |
| --- | --- |
| `dart analyze lib test` | ✅ `No issues found!` |
| `flutter test` | ✅ **1313 passed**（上一节 1276 → +37 新增） |
| `assembleProfile --offline` | ✅ BUILD SUCCESSFUL |
| `adb install -r` | ✅ Success |
| 真机截图 | `tools/shots/g1-opus-text-only.png`（正文只出现一次） |

**遗留**：微博详情页仍是老排版，与 B 站已经分叉。对齐方案与技术交接写在
`docs/WEIBO_DETAIL_ALIGN.md`（含微博侧同样的「正文画两遍」缺陷、骨架泛化方案、
会被打挂的测试清单、三个需要产品决定的问题）。

---

## 8. 安全约定（重要）

1. **任何 Cookie / Token 只能写入系统钥匙串**，不得写入 SharedPreferences、日志或源码。  
   App 侧的唯一入口是 `lib/core/storage/bili_credential_store.dart`；  
   `lib/data/models/bili_session.dart` 刻意**不实现 `toString()`**，  
   对外只暴露 `maskedSummary`（末 4 位）。
2. `.gitignore` 已排除 `**/session.json`、`**/cookies.json` 等凭据文件名。
3. **阶段 1 起 App 内可以登录**（用户主动扫码），凭据的边界是：
   - 只存在设备钥匙串（Android Keystore）；
   - 只在内存中拼进请求头（`BiliClient.setAccountCookie`），不进日志、不进异常 detail；
   - 退出登录立即从钥匙串删除。
4. 阶段 0 的**脚本**凭据仍在**项目外**：`C:\gradle-home\tmp\bili_login\session.json`。  
   **它不属于项目，请勿复制进工作区**；不再需要时直接删除。
5. 登录二维码**必须本地生成**（App 侧用 `qr_flutter`，脚本侧用 `segno`）。  
   **绝不能用在线二维码服务** —— 那等于把登录入口直接交给第三方。

---

## 9. 关于原工作区的其他内容

原工作区（`default-workspace`）里除了 `rrha/` 还有多个**与本项目无关**的目录，  
交接时不必一并搬走：

| 目录/文件                                                                                                       | 与 rrha 的关系                         | 建议                             |
| ----------------------------------------------------------------------------------------------------------- | ---------------------------------- | ------------------------------ |
| `rrha/`                                                                                                     | ← 本项目                              | **搬走**                         |
| `tools/flutter-env.ps1`                                                                                     | 环境脚本（已参数化并纳入 `rrha/tools/`）        | 旧副本可弃                          |
| `tools/{appdata,localappdata,pub-cache,temp,gradle-home,flutter-sdk}/`                                      | 构建缓存，约 3 GB                        | 不搬（可重建）                        |
| `tools/flutter-sdk.zip`                                                                                     | 旧 Flutter SDK 副本（现已用 `C:\flutter`） | 可删                             |
| `tools/backup-before-create/`                                                                               | 当年 `flutter create` 前的源码备份         | 确认无差异后可删                       |
| `tools/shots/`                                                                                              | 真机验收截图                             | 需要的几张已引用在 `docs/ACCEPTANCE.md` |
| `tools/{netcheck,probe_*,live_probe}.py`                                                                    | 探测脚本（已复制进 `rrha/tools/`）           | 旧副本可弃                          |
| `medkb/`、`dsh-ops-src/`、`eac-pack-src/`、`learn-harness-engineering/`、`memory-research/`、`whale-widget-src/` | **完全无关**                           | 不动                             |

---

## 10. 接手后建议的动作顺序

> **2026-10-15：第 1~3 步已在新工作区 `D:\Rrha` 执行完毕（结果见下），请从第 4 步继续。**

1. ✅ 读 `README.md`（总览 + 实测结论）→ `docs/ACCEPTANCE.md`（验收与已修缺陷）
2. ✅ 按 §5.1 跑通：`flutter pub get`（Got dependencies）→ `dart analyze`（**No issues found**）  
   → `flutter test`（**160 个全通过**）。  
   注意：这一步先踩了 §6.4 的 Low IL 坑（症状是 flutter 报「无法写入 `.flutter_tool_state`」），  
   修复命令也写在 §6.4。
3. ✅ **复测 §7.4 的评论悬案** —— 已定论：`-403` 与出口 IP 风控**无关**，  
   是 `pagination_str` 的字节形态问题（详见 §7.4，含对 App 侧无影响的结论）。
4. ✅ **阶段 1 已完成并通过真机验证** —— 扫码登录 → 凭据入钥匙串 → 杀进程冷启动  
   仍能恢复登录态（实测数据见 §7.5）。
5. ✅ **阶段 2 已完成并通过真机验证** —— 从关注列表（**74 人**）导入订阅 →  
   时间线 **151 条 / 6 个订阅源**，B 站订阅不再依赖 RSSHub（实测数据见 §7.6）。
6. ✅ **阶段 3（微博）已完成并通过真机验证**（2026-10-17）。
   原计划的「WebView 登录提取 Cookie → 试 API」**已用六级探针证伪**：`container/getIndex` 对游客态
   恒返回 **432**（WAF 层），能穿透的接口明确要求登录（`ok:-100`），App 接口 `errno:-100`。
   已按预案**降级为内置 WebView 打开**，且真机确认能渲染出真实微博页面（见 §7.15）。
   ⚠️ **登录态下是否可用，本轮未取证**（按用户决策不做 Cookie 提取），不要假设「登录就能拿到时间线」。
7. ✅ **阶段 4 已完成**（2026-10-18，用户实操确认，见 §7.16）—— 关电脑、拔数据线后 App 全部功能正常。
