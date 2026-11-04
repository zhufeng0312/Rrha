import 'package:flutter/foundation.dart';

/// 编译期开关：微博诊断入口（`⋮` 菜单与 6 个探针面板）是否可见。
///
/// 默认只在 debug 构建打开：正式包不给用户看这些探针面板（它们会拿 WebView
/// 里的登录 cookie 去打一堆诊断请求，既不体面也白耗流量）。
///
/// 需要时用编译期变量覆盖，不需要改代码：
///
/// ```
/// flutter build apk --profile --dart-define=RRHA_WEIBO_DIAG=true
/// ```
///
/// 覆盖只认 `true` / `false` 两个字符串：`bool.fromEnvironment` 对大小写与
/// 其它取值一律回落到 defaultValue，所以写错不会「意外打开」。
///
/// 【为什么是 const 而不是运行时变量】
/// 开关必须在**编译期**就能被 tree shaking 感知，才能让正式包里连诊断面板的
/// 代码都不进包；用 `bool.fromEnvironment` + const 是最直接的做法。
const bool kWeiboDiagnosticsEnabled = bool.fromEnvironment(
  'RRHA_WEIBO_DIAG',
  defaultValue: kDebugMode,
);
