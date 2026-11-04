# Rrha 构建环境（dot-source 使用）
#
#   . .\tools\flutter-env.ps1
#   flutter test
#   cd android; .\gradlew.bat assembleProfile
#
# 为什么需要这个文件 —— 下面每一条都是实机踩出来的，不是预防性配置。
#
# 1) 【最关键】GRADLE_USER_HOME 必须位于纯 ASCII 路径。
#    本机用户名含中文时，JVM 的 sun.jnu.encoding=GBK 会把 user.home 解成乱码
#    （实测得到 "C:\Users\侷?"），后果有两个：
#      - Gradle 连发行包都放不下：FileNotFoundException ... .zip.lck
#      - Kotlin DSL 脚本编译崩掉，报一堆 Unresolved reference 'run'/'file'/
#        'plugins'，看起来像语法错，实际是 classpath 取不到
#    ⚠️ NTFS junction 解决不了！Gradle 会把 junction 规范化回中文真实路径。
#       必须是真的 ASCII 目录（如 C:\gradle-home）。
#
# 2) Java 不认 HTTP_PROXY 环境变量，必须用 -D 系统属性。
#    用 JAVA_TOOL_OPTIONS 是因为它会被**每一个** JVM 进程自动拾取，
#    包括 Gradle wrapper 自己的下载器（GRADLE_OPTS 覆盖不到那个阶段）。
#
# 3) Flutter 默认往 %APPDATA% / %LOCALAPPDATA% 写状态，重定向到项目内，
#    避免污染用户目录（也绕开某些受限环境只允许写工作区的问题）。
#
# 4) Flutter SDK 必须位于纯 ASCII 路径：中文路径会让 impellerc 找不到
#    flutter/runtime_effect.glsl 而构建失败。
#
# 5) 代理：本机直连极慢（实测 baidu 24s、bilibili 96s），走代理 170ms。

param(
    # 必须是真实 ASCII 目录，不能是 junction
    [string]$GradleHome = "C:\gradle-home",
    # 必须是纯 ASCII 路径
    [string]$FlutterSdk = "C:\flutter",
    [string]$JdkHome    = "C:\jdk",
    [string]$Proxy      = "http://127.0.0.1:7897"
)

# 项目根 = 本脚本所在目录（tools/）的上一级
$projectRoot = Split-Path -Parent $PSScriptRoot

$env:FLUTTER_ROOT = $FlutterSdk
$env:JAVA_HOME = $JdkHome
$env:PATH = "$FlutterSdk\bin;$JdkHome\bin;$env:PATH"

# --- 构建缓存重定向到项目内（Dart 侧）---
$env:APPDATA = Join-Path $projectRoot ".env\appdata"
$env:LOCALAPPDATA = Join-Path $projectRoot ".env\localappdata"
$env:PUB_CACHE = Join-Path $projectRoot ".env\pub-cache"
$env:TEMP = Join-Path $projectRoot ".env\temp"
$env:TMP = $env:TEMP

# --- Gradle / JVM 侧：必须 ASCII ---
$env:GRADLE_USER_HOME = $GradleHome

# --- 代理（Dart/Python/Git 认环境变量；Java 认 -D）---
$env:HTTPS_PROXY = $Proxy
$env:HTTP_PROXY = $Proxy
$env:NO_PROXY = "localhost,127.0.0.1,::1"

$proxyNoScheme = $Proxy -replace '^https?://', ''
$proxyHost, $proxyPort = $proxyNoScheme.Split(':')
$env:JAVA_TOOL_OPTIONS = (
    "-Dhttp.proxyHost=$proxyHost -Dhttp.proxyPort=$proxyPort " +
    "-Dhttps.proxyHost=$proxyHost -Dhttps.proxyPort=$proxyPort " +
    "-Dhttp.nonProxyHosts=localhost|127.0.0.1 " +
    "-Djava.io.tmpdir=$(Join-Path $GradleHome 'tmp')"
)

$env:FLUTTER_SUPPRESS_ANALYTICS = "true"
$env:PUB_HOSTED_URL = "https://pub.dev"
$env:PYTHONIOENCODING = "utf-8"

# --- 建目录 ---
foreach ($d in @($env:APPDATA, $env:LOCALAPPDATA, $env:PUB_CACHE, $env:TEMP,
                 $GradleHome, (Join-Path $GradleHome 'tmp'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# --- 体检：把「环境不满足」在构建前就说清楚，而不是等 Gradle 报天书 ---
Write-Host "Rrha 构建环境已加载" -ForegroundColor Green
Write-Host "  projectRoot      = $projectRoot"
Write-Host "  FLUTTER_ROOT     = $FlutterSdk"
Write-Host "  JAVA_HOME        = $JdkHome"
Write-Host "  GRADLE_USER_HOME = $GradleHome"
Write-Host "  PUB_CACHE        = $env:PUB_CACHE"
Write-Host "  HTTPS_PROXY      = $Proxy"

$problems = @()
foreach ($p in @($FlutterSdk, $JdkHome, $GradleHome)) {
    if ($p -match '[^\x00-\x7F]') { $problems += "路径含非 ASCII 字符：$p" }
    if (-not (Test-Path $p)) { $problems += "路径不存在：$p" }
}
if (-not (Test-Path (Join-Path $projectRoot 'pubspec.yaml'))) {
    $problems += "未在 rrha 项目根找到 pubspec.yaml（projectRoot=$projectRoot）"
}
if ($problems.Count -gt 0) {
    Write-Host "`n⚠️ 环境检查发现 $($problems.Count) 个问题：" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
} else {
    Write-Host "`n环境检查通过。" -ForegroundColor Green
}
