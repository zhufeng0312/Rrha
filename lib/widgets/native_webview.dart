import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 内置浏览器的控制器：Dart 侧调用原生 WebView 的唯一入口。
///
/// 通道是 **per-view** 的（`rrha/weibo_webview_<viewId>`），由 [NativeWebView]
/// 在 `onPlatformViewCreated` 里创建后 [attach] 上来。所以在 PlatformView
/// 还没创建（或已被回收）时，这里所有方法都必须安全失败，不能抛异常到 UI。
class NativeWebViewController {
  MethodChannel? _channel;

  /// PlatformView 是否已就绪（通道已绑定）。
  bool get isReady => _channel != null;

  /// 由 [NativeWebView] 在创建 / 销毁 PlatformView 时调用。
  void attach(MethodChannel channel) {
    _channel = channel;
  }

  /// 由 [NativeWebView] 在 dispose 时调用。
  void detach() {
    _channel = null;
  }

  /// 当前页面是否还能后退。原生未就绪时按「不能后退」处理。
  Future<bool> canGoBack() async {
    final MethodChannel? channel = _channel;
    if (channel == null) return false;
    try {
      final bool? result = await channel.invokeMethod<bool>('canGoBack');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  /// 读取 m.weibo.cn 域下的 cookie。
  ///
  /// 仅供诊断请求使用：调用方**不得**记录/持久化/展示其内容，只能用于请求头。
  /// 通道未就绪时返回空串。
  Future<String> getCookies() async {
    final MethodChannel? channel = _channel;
    if (channel == null) return '';
    try {
      final String? result = await channel.invokeMethod<String>('getCookies');
      return result ?? '';
    } on PlatformException catch (_) {
      return '';
    } on MissingPluginException catch (_) {
      return '';
    }
  }

  /// 后退一页。原生侧会自己判断 `canGoBack()`，无历史时是空操作。
  Future<void> goBack() async {
    final MethodChannel? channel = _channel;
    if (channel == null) return;
    try {
      await channel.invokeMethod<void>('goBack');
    } on PlatformException catch (_) {
      // 忽略：后退失败不该让页面崩，用户还能用返回键退出。
    } on MissingPluginException catch (_) {
      // 同上。
    }
  }

  /// 刷新当前页面。
  Future<void> reload() async {
    final MethodChannel? channel = _channel;
    if (channel == null) return;
    try {
      await channel.invokeMethod<void>('reload');
    } on PlatformException catch (_) {
      // 同上。
    } on MissingPluginException catch (_) {
      // 同上。
    }
  }

  /// 把当前地址交给系统浏览器 / 微博 App 打开。
  Future<void> openExternal() async {
    final MethodChannel? channel = _channel;
    if (channel == null) return;
    try {
      await channel.invokeMethod<void>('openExternal');
    } on PlatformException catch (_) {
      // 同上。
    } on MissingPluginException catch (_) {
      // 同上。
    }
  }
}

/// 包了 `android.webkit.WebView` 的 PlatformView 的 Dart 侧封装。
///
/// 为什么不用 `webview_flutter`：本工程在无网络环境开发，pub.dev 不可达，
/// 不能新增 pub 依赖，所以自己在 Android 侧包一层 `WebView`
/// （见 `android/app/src/main/kotlin/com/rrha/rrha/WeiboWebViewPlugin.kt`）。
class NativeWebView extends StatefulWidget {
  const NativeWebView({
    super.key,
    required this.initialUrl,
    required this.controller,
    this.onProgress,
    this.onPageStarted,
    this.onPageFinished,
    this.onCanGoBackChanged,
    this.onError,
  });

  /// 首次加载的地址。改动该值**不会**自动重新导航（需要重建 widget）。
  final String initialUrl;

  /// 由页面持有并复用的控制器。
  final NativeWebViewController controller;

  /// 加载进度，已归一化到 0..1。
  final ValueChanged<double>? onProgress;

  final VoidCallback? onPageStarted;
  final VoidCallback? onPageFinished;

  /// WebView 的历史栈变化（含 SPA 页内跳转）时回调，参数为「当前是否还能后退」。
  final ValueChanged<bool>? onCanGoBackChanged;

  /// 原生侧报错（含 SSL 证书失败）。code 为系统错误码，description 为可读文案。
  final void Function(String code, String description)? onError;

  @override
  State<NativeWebView> createState() => _NativeWebViewState();
}

class _NativeWebViewState extends State<NativeWebView> {
  /// PlatformView 未创建前为 null。
  MethodChannel? _channel;

  /// creationParamsCodec 在 Android 上必须是 StandardMessageCodec。
  static const StandardMessageCodec _codec = StandardMessageCodec();

  @override
  void dispose() {
    // 先摘掉 Dart 侧 handler，再断开控制器，避免原生回调打到已销毁的 State。
    _channel?.setMethodCallHandler(null);
    _channel = null;
    widget.controller.detach();
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    final MethodChannel channel = MethodChannel('rrha/weibo_webview_$id');
    channel.setMethodCallHandler(_handleNativeCall);
    _channel = channel;
    widget.controller.attach(channel);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onProgress':
        final Object? progressArgs = call.arguments;
        if (progressArgs is Map) {
          final Object? raw = progressArgs['progress'];
          if (raw is num) {
            // 原生发的是 0..100 的整数。
            widget.onProgress?.call((raw.toDouble() / 100).clamp(0.0, 1.0));
          }
        }
      case 'onPageStarted':
        widget.onPageStarted?.call();
      case 'onPageFinished':
        widget.onPageFinished?.call();
      case 'onCanGoBackChanged':
        final Object? args = call.arguments;
        if (args is Map) {
          final Object? raw = args['canGoBack'];
          if (raw is bool) widget.onCanGoBackChanged?.call(raw);
        }
      case 'onError':
        final Object? errorArgs = call.arguments;
        String code = '';
        String description = '页面加载失败';
        if (errorArgs is Map) {
          final Object? rawCode = errorArgs['code'];
          final Object? rawDesc = errorArgs['description'];
          if (rawCode != null) code = rawCode.toString();
          if (rawDesc != null) description = rawDesc.toString();
        }
        widget.onError?.call(code, description);
      default:
        // 未知回调忽略：不同系统版本可能多发事件，不能因此抛异常。
        break;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // iOS / 桌面 / Web 侧没有这套 PlatformView，给一句说明而不是崩掉。
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '内置浏览器当前仅支持 Android 平台',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return AndroidView(
      viewType: 'rrha/weibo_webview',
      creationParams: <String, dynamic>{'url': widget.initialUrl},
      creationParamsCodec: _codec,
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}
