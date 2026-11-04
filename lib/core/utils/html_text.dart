/// HTML 与文本处理工具。
///
/// RSSHub 各路由的 `<description>` 有的是 CDATA 包裹的 HTML，有的是
/// 转义后的实体文本，结构不统一。这里只做「尽力提取 + 原文保底」，
/// 绝不因为结构异常抛异常。
class HtmlText {
  HtmlText._();

  static final RegExp _imgSrcRe = RegExp(
    r'''<img[^>]*?\ssrc\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  static final RegExp _videoRe = RegExp(
    r'''<(?:video|source)[^>]*?\ssrc\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  static final RegExp _tagRe = RegExp(r'<[^>]*>');
  static final RegExp _wsRe = RegExp(r'[ \t\u00A0]+');
  static final RegExp _blankLineRe = RegExp(r'\n{3,}');

  /// 解码常见 HTML 实体。
  static String decodeEntities(String input) {
    if (!input.contains('&')) return input;
    return input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '…')
        .replaceAll('&amp;', '&') // 必须最后
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) {
            final code = int.tryParse(m.group(1)!);
            if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
            try {
              return String.fromCharCode(code);
            } catch (_) {
              return m.group(0)!;
            }
          },
        );
  }

  /// HTML 片段 → 纯文本（保留段落换行，压缩空白）。
  static String toPlainText(String? input) {
    if (input == null || input.isEmpty) return '';
    var s = input;
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n');
    s = s.replaceAll(_tagRe, '');
    s = decodeEntities(s);
    s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    s = s.split('\n').map((l) => l.replaceAll(_wsRe, ' ').trim()).join('\n');
    s = s.replaceAll(_blankLineRe, '\n\n').trim();
    return s;
  }

  /// 从 HTML 片段里取第一张图片地址。
  static String? firstImageUrl(String? html) {
    if (html == null || html.isEmpty) return null;
    final m = _imgSrcRe.firstMatch(html);
    final url = m?.group(1)?.trim();
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('//')) return 'https:$url';
    return decodeEntities(url);
  }

  /// 从 HTML 片段里取第一个 video/source 地址（微博视频的备用来源）。
  static String? firstVideoUrl(String? html) {
    if (html == null || html.isEmpty) return null;
    final m = _videoRe.firstMatch(html);
    final url = m?.group(1)?.trim();
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('//')) return 'https:$url';
    return decodeEntities(url);
  }

  /// 在纯文本里提取第一个 http(s) 视频直链（微博正文常见形态）。
  static String? firstInlineVideoLink(String? text) {
    if (text == null || text.isEmpty) return null;
    final m = RegExp(
      r'''https?://[^\s"'<>]*?\.mp4[^\s"'<>]*''',
      caseSensitive: false,
    ).firstMatch(text);
    return m?.group(0);
  }

  /// 截断到 [max] 个字符，超出加省略号。
  static String truncate(String input, int max) {
    if (input.length <= max) return input;
    return '${input.substring(0, max)}…';
  }

  /// 单行化：把换行压成空格，用于列表标题。
  static String singleLine(String input) =>
      input.replaceAll(RegExp(r'\s+'), ' ').trim();
}
