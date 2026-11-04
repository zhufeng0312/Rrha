import 'package:flutter/services.dart';

/// 读取 `m.weibo.cn` 域下的登录 cookie。
///
/// ⚠️ 返回值是用户凭据：调用方只能把它塞进请求头，禁止落盘 / 打日志 / 展示。
/// 这个类自己也不记录任何内容——连长度都不写进日志。
///
/// ## 为什么要走全局通道
///
/// WebView 页面里那份 cookie 挂在 **per-view** 通道
/// （`rrha/weibo_webview_<viewId>`）上：只有微博页面活着时才读得到。
/// 数据层要在后台刷新时间线，那时页面通常已销毁，所以改用原生侧注册的
/// 全局通道 `rrha/weibo_cookie`（见 `WeiboCookieChannel.kt`）。
///
/// ## 失败语义
///
/// 通道未就绪（比如跑在单测 / 非 Android 平台）、平台异常、返回类型不对——
/// **一律返回空串，绝不抛**。空串在数据层的含义是「未登录」，会转成一条
/// 可读的登录提示，比让 `MissingPluginException` 冒到 UI 更好排查。
class WeiboCookieSource {
  /// [loader] 仅用于单测注入：给了它就不再碰任何通道。
  ///
  /// [channel] 也允许注入，便于把通道名钉死在测试里。
  WeiboCookieSource({MethodChannel? channel, Future<String> Function()? loader})
      : _loader = loader,
        _channel = channel;

  /// 全局通道名，必须与 `WeiboCookieChannel.CHANNEL_NAME` 一致。
  static const String channelName = 'rrha/weibo_cookie';

  /// 方法名，与原生 `handle()` 的 `when` 分支一致。
  static const String methodGetCookies = 'getCookies';

  final Future<String> Function()? _loader;

  /// 惰性创建的通道。刻意不在构造时创建：单测里没有 Flutter binding 时
  /// `MethodChannel(...)` 也会被用到，没有必要。
  final MethodChannel? _channel;

  MethodChannel get _resolvedChannel =>
      _channel ?? const MethodChannel(channelName);

  /// 读取 cookie。空串 = 未登录。
  Future<String> read() async {
    final Future<String> Function()? loader = _loader;
    if (loader != null) {
      try {
        return (await loader()).trim();
      } catch (_) {
        return '';
      }
    }
    try {
      final String? result =
          await _resolvedChannel.invokeMethod<String>(methodGetCookies);
      return (result ?? '').trim();
    } on PlatformException catch (_) {
      // 原生侧读不到 cookie（内核没起来 / ROM 限制）——按未登录处理。
      return '';
    } on MissingPluginException catch (_) {
      // 非 Android 平台或原生未注册 —— 同上。
      return '';
    } catch (_) {
      // 兜底：任何意外都不该让「刷新时间线」整条链路崩掉。
      return '';
    }
  }

  /// 便捷判断。同样不抛，异常按「未登录」。
  Future<bool> get hasLogin async => (await read()).isNotEmpty;
}
