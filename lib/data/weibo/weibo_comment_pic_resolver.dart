import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/net/weibo_cookie_source.dart';
import 'weibo_web_urls.dart';

/// 微博评论**多图**短链解析（`mix_media_ids` → 真实图片直链）。
///
/// ## 为什么解析在这里、不在解析层
///
/// `WeiboCommentParser` 是零 IO 的纯函数（被大量单测钉死），它只负责把
/// `mix_media_ids` **原样**搬进 `BiliComment.mixMediaIds`。真正的短链跟随是
/// **网络 IO**，所以放在仓库层，并且满足三条硬约束：
///
/// 1. **懒执行**：只有用户点「共 N 张 · 点此加载全部」时才调用，
///    绝不进列表构建路径（否则滚一屏就是几十个请求，必然触发风控）；
/// 2. **失败不重试**：单条失败只丢这一条，返回已成功的部分；
/// 3. **按评论 id 缓存**：同一条评论只解析一次（短码是稳定的）。
///
/// ## 实测链路（见 `.env/weibo_comment_multi_pic_probe.md`）
///
/// ```
/// mix_media_ids[i] = http://t.cn/XXXXXXXX      ← 接口给的是 http，Android 会拦
///   →（升级）https://t.cn/XXXXXXXX             ← followRedirects: true
///   → 302 → https://photo.weibo.com/h5/comment/compic_id/1022:xxxx
///   → 该页 463 字节静态 HTML，正文唯一 <img src="https://wx*.sinaimg.cn/bmiddle/<pid>.jpg">
///   → 把路径段 bmiddle 换成 large = 原图（长边 690 → 原尺寸）
/// ```
///
/// **1 条 N 图评论 = N 个短链请求**（每个短链 1 次，自动跟随重定向）。
///
/// ⚠️ 图床认 `Referer`：不带 → 403。图片**加载**由 `CachedImage` 负责，
/// 它的 `_refererFor` 已覆盖 `sinaimg.cn`；本类只解析地址，不下载图片。
///
/// ## 凭据安全
///
/// cookie 只在请求头里出现一次：不落盘、不进日志、不进任何 UI 文案。
class WeiboCommentPicResolver {
  WeiboCommentPicResolver({Dio? dio, WeiboCookieSource? cookies})
      : _dio = dio ?? createDio(),
        _cookies = cookies ?? WeiboCookieSource();

  final Dio _dio;
  final WeiboCookieSource _cookies;

  /// 微博单条内容最多 9 张图（九宫格上限）。超出直接截断。
  static const int maxPics = 9;

  /// 解析结果的进程内缓存：评论 id（或短链集合指纹）→ 图片直链。
  ///
  /// 刻意做成**实例字段**而不是全局静态：静态字段会让不同单测之间串味，
  /// 也容易在长生命周期进程里无界增长。
  final Map<String, List<String>> _cache = <String, List<String>>{};

  /// 命中缓存返回 true（供 UI 判断是否需要转圈）。
  bool isCached(String commentId) => _cache.containsKey(commentId.trim());

  /// 把一条评论的多图短链解析成真实图片地址（原图）。
  ///
  /// - 每条短链 1 个请求（`followRedirects: true`），**串行**发出：
  ///   并发能省时间，但更容易撞风控，而这里本来就是用户主动等一次点击；
  /// - 失败**不重试**，返回已成功解析的部分（可能为空）；
  /// - 结果按 [commentId] 缓存（[commentId] 为空时退化为按短链集合缓存）。
  Future<List<String>> resolveCommentPics(
    List<String> mixMediaIds, {
    String? commentId,
  }) async {
    final List<String> ids = _sanitize(mixMediaIds);
    if (ids.isEmpty) return const <String>[];

    final String key = (commentId ?? '').trim().isNotEmpty
        ? commentId!.trim()
        : ids.join(',');
    final List<String>? cached = _cache[key];
    if (cached != null) return cached;

    final String cookie = await _cookies.read();
    final Map<String, String> headers = requestHeaders(cookie: cookie);

    final List<String> out = <String>[];
    for (final String raw in ids) {
      if (out.length >= maxPics) break;
      final String? image = await _resolveOne(raw, headers: headers);
      if (image == null) continue; // 单条失败：跳过，不影响其它条。
      if (out.contains(image)) continue;
      out.add(image);
    }

    final List<String> result = List<String>.unmodifiable(out);
    _cache[key] = result;
    return result;
  }

  /// 一条短链 → 一张图片直链。任何失败都返回 null（**不重试**）。
  Future<String?> _resolveOne(
    String raw, {
    required Map<String, String> headers,
  }) async {
    final String url = httpsUrl(raw);
    if (url.isEmpty) return null;

    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: headers,
          followRedirects: true,
          responseType: ResponseType.plain,
          // 放宽到 <400：只有真正的成功才算数，3xx 在 followRedirects 下
          // 不该留下，432 / 5xx 一律按失败处理（不重试）。
          validateStatus: (int? s) => s != null && s < 400,
        ),
      );
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }

    final int status = res.statusCode ?? 0;
    if (status < 200 || status >= 400) return null;

    final Object? data = res.data;
    final String html = data is String ? data : (data?.toString() ?? '');
    final String? src = firstImgSrc(html);
    if (src == null) return null;

    // 落地页已经跳到了图片本身（无反代理解析）时，body 不是 HTML：
    // 那种情况 firstImgSrc 拿不到，属于「跟随失败」，同样跳过。
    return toOriginal(src);
  }

  // ------------------------------------------------------------ 纯函数（可离线单测）

  /// `http://t.cn/x` → `https://t.cn/x`；已是 https 原样返回。
  ///
  /// 接口原样给的是 **http**，而 Android 9+ 默认拦明文流量
  /// （本项目没开 `usesCleartextTraffic`），所以运行时必须升级。
  /// 无 scheme 的裸串按 https 补全；其它 scheme（`javascript:` / `file:` 等）
  /// 返回空串 —— 不认识的一律不请求。
  static String httpsUrl(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return '';
    final int idx = s.indexOf('://');
    if (idx < 0) {
      // 没有 `://` 但含 `:` 的（`javascript:alert(1)`、`mailto:x`）是别的
      // scheme，绝不能当成裸域名去请求。
      final int colon = s.indexOf(':');
      final int slash = s.indexOf('/');
      if (colon >= 0 && (slash < 0 || colon < slash)) return '';
      return 'https://$s';
    }
    final String scheme = s.substring(0, idx).toLowerCase();
    if (scheme != 'http' && scheme != 'https') return '';
    return 'https://${s.substring(idx + 3)}';
  }

  /// 从落地页 HTML 里提取**第一个** `<img src>`。
  ///
  /// 覆盖三种引号写法：双引号、单引号、无引号。
  /// 另外把 HTML 实体（`&amp;`）还原成 `&`，并把 `//host/...` 补成 https。
  ///
  /// 实测落地页只有 463 字节、正文唯一一个 `<img>`，所以取第一个就够；
  /// 不做「找最大图」之类的启发式 —— 页面结构固定，猜反而会错。
  static final RegExp _imgTagRe = RegExp(r'<img\b[^>]*>', caseSensitive: false);
  static final RegExp _srcAttrRe = RegExp(
    r'''\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''',
    caseSensitive: false,
  );

  static String? firstImgSrc(String html) {
    if (html.isEmpty) return null;
    for (final RegExpMatch tag in _imgTagRe.allMatches(html)) {
      final RegExpMatch? m = _srcAttrRe.firstMatch(tag.group(0) ?? '');
      if (m == null) continue;
      final String? raw = m.group(1) ?? m.group(2) ?? m.group(3);
      final String? url = _cleanSrc(raw);
      if (url != null) return url;
    }
    return null;
  }

  static String? _cleanSrc(String? raw) {
    if (raw == null) return null;
    String s = raw
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    if (s.isEmpty) return null;
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('http://')) return 'https://${s.substring(7)}';
    if (s.startsWith('https://')) return s;
    return null;
  }

  /// 缩略图地址 → 原图地址：只把**路径段** `bmiddle` 换成 `large`。
  ///
  /// - `https://wx3.sinaimg.cn/bmiddle/<pid>.jpg` → `.../large/<pid>.jpg`
  /// - `orj360` / `thumbnail` / `mw690` 等**其它**尺寸**原样不动**
  ///   （实测这些也都能 200，改成 large 反而可能 404）。
  /// - host 里的 `wx1/2/3/4` 是负载分片，照抄不换。
  static String toOriginal(String url) {
    final String s = url.trim();
    if (s.isEmpty) return s;
    if (!s.contains('/bmiddle/')) return s;
    return s.replaceFirst('/bmiddle/', '/large/');
  }

  /// 请求头。
  ///
  /// `Referer` 用微博主站：探针实测图床/落地页都不挑，而主站是最"像人"的值。
  /// cookie 为空时**不设置** Cookie 头（短链与 `photo.weibo.com` 通常不需要登录）。
  static Map<String, String> requestHeaders({required String cookie}) {
    final String trimmed = cookie.trim();
    return <String, String>{
      'User-Agent': userAgent,
      'Referer': '${WeiboWebUrls.mbBase}/',
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (trimmed.isNotEmpty) 'Cookie': trimmed,
    };
  }

  /// 移动端 Chrome UA（桌面 UA 会被微博重定向）。
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// 裸 Dio：**不挂重试拦截器**（重试最容易触发风控）。
  static Dio createDio() => Dio(
        BaseOptions(
          connectTimeout: AppConfig.connectTimeout,
          receiveTimeout: AppConfig.receiveTimeout,
          sendTimeout: AppConfig.sendTimeout,
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (int? s) => s != null && s < 400,
        ),
      );

  /// 短链清洗：去空白、跳过非 t.cn 的可疑值、去重、上限 [maxPics]。
  static List<String> _sanitize(List<String> raw) {
    final List<String> out = <String>[];
    for (final String e in raw) {
      final String s = e.trim();
      if (s.isEmpty) continue;
      if (out.contains(s)) continue;
      out.add(s);
      if (out.length >= maxPics) break;
    }
    return out;
  }
}
