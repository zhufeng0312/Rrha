import '../../core/net/app_error.dart';

/// 微博 Web 端 URL 工具。
///
/// ## 为什么走 Web 而不是 HTTP 接口
///
/// 微博的移动端接口（`/api/container/getIndex`、`/comments/hotflow` 等）在
/// **游客态**被风控恒定拦截（返回 432 / 需要访客 Cookie + `XSRF-TOKEN`）。
/// 客户端绕不过去（绕过即等于破解风控，明确不做），所以这里改走
/// 「内置 WebView 打开 `m.weibo.cn`」这条链路。
///
/// 本类**只做纯字符串处理，没有任何 IO**，便于单测。所有 URL 拼接都集中在
/// 这里，避免各处手写 `https://m.weibo.cn/u/` 前缀拼错。
class WeiboWebUrls {
  WeiboWebUrls._();

  /// 微博移动端 Web 站点（桌面 UA 会被重定向，所以只认这个域名）。
  static const String mbBase = 'https://m.weibo.cn';

  /// uid / mid 必须是纯数字：拼进 URL 前先校验，避免把用户输入
  /// 直接塞进 WebView 造成注入或跳到任意站点。
  static final RegExp _digits = RegExp(r'^\d+$');

  /// 用户主页：`https://m.weibo.cn/u/<uid>`。
  static String profile(String uid) => '$mbBase/u/${_requireDigits(uid, 'uid')}';

  /// 单条微博：`https://m.weibo.cn/status/<mid>`。
  static String status(String mid) => '$mbBase/status/${_requireDigits(mid, 'mid')}';

  /// 只允许 http/https 交给内置 WebView 渲染。
  ///
  /// `javascript:` / `file:` / `data:` / `content:` 一律拒绝：这些 scheme 要么
  /// 能读取本地文件，要么能在页面上下文里执行脚本，交给 WebView 都不安全。
  static bool isAllowed(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    // `http:` 这类没有 host 的串不算可加载地址。
    return uri.host.isNotEmpty;
  }

  /// 是否为「非 http(s)」的外部 scheme，例如 `weibo://`、`intent://`、
  /// `snssdk://`、`mailto:`、`tel:`。
  ///
  /// 这类地址不该由内置 WebView 处理，应交给系统（`Intent.ACTION_VIEW`）。
  /// 注意：无 scheme 的相对地址 / 空串**不是**外部 scheme，返回 false。
  static bool isExternalScheme(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final String scheme = uri.scheme.toLowerCase();
    if (scheme.isEmpty) return false;
    return scheme != 'http' && scheme != 'https';
  }

  static String _requireDigits(String value, String name) {
    if (!_digits.hasMatch(value)) {
      throw AppError.parse('$name 必须是纯数字，实际为「$value」');
    }
    return value;
  }
}
