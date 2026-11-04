import '../../core/utils/html_text.dart';

/// 微博支持层。
///
/// ## 当前形态（不伪造能力）
///
/// - **数据来源**：微博的 HTTP 接口在游客态被风控恒定拦截（432），能穿透的
///   接口明确要求登录态，客户端绕不过去（绕过即等于破解风控，属明确不做）。
///   所以微博改为**内置浏览器打开 `m.weibo.cn`**（见 `WeiboWebViewPage`），
///   由系统 WebView 维护登录态与 Cookie，App 不碰。微博**不再走 RSSHub**。
///
/// - **本类的职责**：只保留「视频直链提取」这几个纯函数工具 ——
///   缓存/旧数据里仍可能带着描述 HTML，用得上它们判断能不能尝试播放。
///   这里只做「尽力提取」：从描述 HTML 里找 `*.mp4` 或 `f.video.weibocdn.com`
///   链接。微博 CDN 直链带时效签名与防盗链，成功率不保证；提取不到或播放
///   失败时 UI 明确显示「视频解析失败」，**不会假装能播**。
///
/// - **评论**：App 内**不做**评论列表。公开接口 `/ajax/statuses/buildComments`
///   需要访客 Cookie + `XSRF-TOKEN`，风控频繁。评论只能在内置浏览器里看，
///   文案见 [commentUnavailableMessage]。
class WeiboClient {
  WeiboClient._();

  /// 微博视频页面链接（`video.weibo.com/show?fid=1034:xxxx`）。
  static final RegExp _fidRe = RegExp(
    r'(?:fid=|weibo\.com/tv/show/)(\d+:\w+)',
    caseSensitive: false,
  );

  static final RegExp _mp4Re = RegExp(
    r'''https?://[^\s"'<>]*?\.mp4[^\s"'<>]*''',
    caseSensitive: false,
  );

  static final RegExp _cdnRe = RegExp(
    r'''https?://[^\s"'<>]*?weibocdn\.com[^\s"'<>]*''',
    caseSensitive: false,
  );

  /// 评论占位文案（如实说明，不得假装已完成）。
  static const String commentUnavailableMessage = '微博评论当前需在「内置浏览器」里查看。';

  /// 从描述 HTML 里尽力提取可播的视频直链。
  ///
  /// 返回 null 表示「没能提取到」——调用方必须显示失败提示，而不是猜一个地址。
  static String? extractVideoUrl(String? html) {
    if (html == null || html.isEmpty) return null;

    final fromVideoTag = HtmlText.firstVideoUrl(html);
    if (fromVideoTag != null && fromVideoTag.isNotEmpty) return fromVideoTag;

    final mp4 = _mp4Re.firstMatch(html)?.group(0);
    if (mp4 != null && mp4.isNotEmpty) return mp4;

    final cdn = _cdnRe.firstMatch(html)?.group(0);
    if (cdn != null && cdn.isNotEmpty) return cdn;

    return null;
  }

  /// 提取微博视频的 fid（后续若要接入接口解析会用到）。
  static String? extractFid(String? html) {
    if (html == null || html.isEmpty) return null;
    return _fidRe.firstMatch(html)?.group(1);
  }

  /// 该直链是否像「能直接给播放器用」的地址。
  ///
  /// 微博的 m3u8 需要额外的分片处理，本轮不作为可播地址透出。
  static bool isDirectlyPlayable(String? url) {
    if (url == null || url.isEmpty) return false;
    final u = url.toLowerCase();
    if (u.endsWith('.m3u8')) return false;
    return u.startsWith('http://') || u.startsWith('https://');
  }
}
