# Android 平台配置说明

## 为什么不直接提供 `android/` 目录

本工程**只提供 `lib/`、`test/`、`pubspec.yaml` 等业务源码**，`android/` 平台壳需要你用
Flutter 自己生成。这是刻意的决定，原因有两个：

1. **版本矩阵脆弱**：`settings.gradle` / `build.gradle` 里的 AGP、Gradle、Kotlin 版本
   必须与你的 Flutter SDK 版本匹配。手写的版本组合在别人的机器上极易直接构建失败，
   而 `flutter create` 生成的组合一定与你的 SDK 匹配。
2. **缺二进制文件**：Gradle Wrapper 需要 `android/gradle/wrapper/gradle-wrapper.jar`
   （二进制），无法用文本方式提供；缺少它第一次构建就会失败。

生成命令（在工程根目录执行）：

```bash
flutter create --platforms=android --org com.rrha --project-name rrha .
```

这条命令**不会覆盖**已存在的 `lib/`、`test/`、`pubspec.yaml`、`README.md`，
只会补齐 `android/` 目录。

---

## 生成之后必须做的三处修改

### 1. `android/app/build.gradle`

```gradle
android {
    namespace = "com.rrha.rrha"          // 与 org 一致即可
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        applicationId = "com.rrha.rrha"
        minSdk = 23                      // ← 必改：flutter 默认值（21）偏低
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    ...
}
```

**为什么 minSdk 至少 23**：`media_kit`（libmpv，用于 DASH 通道）与较新的
ExoPlayer 都需要更高的 API 级别；21/22 上会出现原生库加载失败。

### 2. `android/app/src/main/AndroidManifest.xml`

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- 必需：拉取 RSSHub 与 B 站接口 -->
    <uses-permission android:name="android.permission.INTERNET" />
    <!-- 可选：用于「网络不可用」判断与更好的错误提示 -->
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application
        android:label="Rrha"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:usesCleartextTraffic="false">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            ...
        </activity>
    </application>
</manifest>
```

要点：

- `INTERNET` 权限：**必须**，否则所有网络请求直接失败；
- `configChanges` 必须包含 `orientation|screenSize`：播放页横屏全屏切换依赖它，
  否则旋转会重建 Activity 导致播放中断；
- `usesCleartextTraffic="false"`：RSSHub 公共实例与 B 站均为 HTTPS，
  保持明文流量关闭更安全。若你自建的 RSSHub 只有 HTTP，需临时改为 `true`。

### 3. 播放器体积（可选优化）

`media_kit_libs_video` 会为所有支持的 ABI 打包原生库。若只面向真机（arm64），
可在 `build.gradle` 里裁剪：

```gradle
defaultConfig {
    ndk {
        abiFilters "arm64-v8a"        // 只要真机，去掉 armeabi-v7a / x86_64
    }
}
```

代价是模拟器（x86_64）无法运行。**做验收测量时必须用真机**，所以这个裁剪是合理的，
但建议先不做——等 `flutter analyze` 与单元测试通过后再优化体积。

---

## 第一次运行的检查清单

```bash
flutter pub get
flutter analyze          # 必须零 error；本工程未经编译验证，这里有可能是需要修补的地方
flutter test             # 应该全绿（所有测试都不依赖网络）
flutter run --profile    # 验收测量必须用 profile 模式
```

### 如果 `flutter pub get` 报某个包不存在或版本不满足

`pubspec.yaml` 里的版本约束是在无网络环境下写的保守下界。按报错信息放宽即可，
例如把 `media_kit: ^1.1.10` 改成报错提示的版本。

### 如果 `flutter analyze` 报第三方 API 不匹配

最可能出问题的三处（因为这些包的 API 在不同大版本间有变动）：

1. `lib/features/player/player_adapter.dart` 里的 `media_kit` 调用
   （`Player` / `VideoController` / `Video` / `NoVideoControls`）；
2. 同文件里的 `video_player` 调用（`VideoPlayerController.networkUrl`）；
3. `lib/core/storage/secure_store.dart` 里的
   `FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true))`。

这些都被隔离在单独的文件里，改动是局部的，不影响其它模块。

---

## 权限说明（为什么只要 INTERNET）

| 能力 | 实现方式 | 是否需要额外权限 |
| --- | --- | --- |
| 播放器内亮度调节 | 应用内黑色遮罩叠加 | ❌ 不需要 `WRITE_SETTINGS` |
| 音量调节 | 播放器自身音量接口 | ❌ 不修改系统音量 |
| 凭证存储 | `flutter_secure_storage`（Android Keystore） | ❌ 本轮无凭证，接口已就位 |
| 横屏全屏 | `SystemChrome` 方向控制 | ❌ |

即：**本应用不申请任何敏感权限**。
