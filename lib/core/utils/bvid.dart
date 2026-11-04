/// 从各种链接里提取 B 站 / 微博的业务标识。
///
/// RSSHub 返回的 `<link>` 形态不稳定（可能是 www.bilibili.com/video/BVxxx、
/// m.bilibili.com/video/BVxxx?p=2、b23.tv 短链、t.bilibili.com/xxx），
/// 所以这里一律用正则做「尽力提取」，失败返回 null 而不是抛异常。
class BiliIdParser {
  BiliIdParser._();

  static final RegExp _bvRe = RegExp(r'(BV[0-9A-Za-z]{10})');
  static final RegExp _avRe = RegExp(r'av(\d+)', caseSensitive: false);
  static final RegExp _uidRe = RegExp(
    r'(?:space\.bilibili\.com/|^)(\d{3,})',
    caseSensitive: false,
  );
  static final RegExp _dynamicRe = RegExp(
    r'(?:t\.bilibili\.com/|dynamic/)(\d+)',
    caseSensitive: false,
  );

  /// opus 链接：`bilibili.com/opus/<19 位数字>`。
  ///
  /// 2026-11 起 B 站把「动态 / 专栏图文」统一成 opus 形态，用户从浏览器
  /// 复制来的就是这个链接。它的 id 与 `t.bilibili.com/<id>` 是同一个动态，
  /// 但**不能**当评论接口的 oid 用（见 `BiliClient.dynamicDetail`）。
  static final RegExp _opusRe = RegExp(
    r'opus/(\d+)',
    caseSensitive: false,
  );
  static final RegExp _urlRe = RegExp(r'''https?://[^\s"'<>]+''');

  /// 提取 BV 号。
  static String? bvid(String? input) {
    if (input == null || input.isEmpty) return null;
    final m = _bvRe.firstMatch(input);
    return m?.group(1);
  }

  /// 提取 av 号。
  static int? avid(String? input) {
    if (input == null || input.isEmpty) return null;
    final m = _avRe.firstMatch(input);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 提取分 P（`?p=2`）。
  static int page(String? input) {
    if (input == null || input.isEmpty) return 1;
    final m = RegExp(r'[?&]p=(\d+)').firstMatch(input);
    return m == null ? 1 : (int.tryParse(m.group(1)!) ?? 1);
  }

  /// 从 UP 主空间链接里提取 UID。
  static String? uidFromSpaceUrl(String? input) {
    if (input == null || input.isEmpty) return null;
    final m = _uidRe.firstMatch(input);
    return m?.group(1);
  }

  /// 从动态链接里提取动态 id。
  static String? dynamicId(String? input) {
    if (input == null || input.isEmpty) return null;
    final m = _dynamicRe.firstMatch(input);
    return m?.group(1);
  }

  /// 从 opus 链接（`bilibili.com/opus/<id>`）里提取动态 id。
  ///
  /// 与 [dynamicId] 分开是因为两者形态不同：opus 后面跟的是 19 位数字，
  /// 而 `t.bilibili.com/` 那段也接受更短的旧 id。**能提取到就说明是动态**，
  /// 调用方据此决定走「动态详情页」而不是「视频播放页」。
  static String? opusId(String? input) {
    if (input == null || input.isEmpty) return null;
    final m = _opusRe.firstMatch(input);
    return m?.group(1);
  }

  /// 纯数字 UID 校验（用户在订阅页手填的场景）。
  static bool isValidUid(String input) =>
      RegExp(r'^\d{1,20}$').hasMatch(input.trim());

  /// 提取文本里第一个 http(s) 链接。
  static String? firstUrl(String? input) {
    if (input == null || input.isEmpty) return null;
    return _urlRe.firstMatch(input)?.group(0);
  }
}

/// 微博相关标识的提取。
class WeiboIdParser {
  WeiboIdParser._();

  static final RegExp _statusRe = RegExp(
    r'weibo\.com/\d+/([0-9A-Za-z]{6,})',
    caseSensitive: false,
  );
  static final RegExp _uidInUrlRe = RegExp(
    r'weibo\.com/(?:u/)?(\d{4,})',
    caseSensitive: false,
  );

  /// 从微博详情页链接提取 status id（形如 `weibo.com/1234567890/PabcDEF`）。
  static String? statusId(String? input) {
    if (input == null || input.isEmpty) return null;
    return _statusRe.firstMatch(input)?.group(1);
  }

  /// 从链接里提取 UID。
  static String? uidFromUrl(String? input) {
    if (input == null || input.isEmpty) return null;
    return _uidInUrlRe.firstMatch(input)?.group(1);
  }

  static bool isValidUid(String input) =>
      RegExp(r'^\d{4,20}$').hasMatch(input.trim());
}
