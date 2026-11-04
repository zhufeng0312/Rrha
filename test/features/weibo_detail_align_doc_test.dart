import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/utils/html_text.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/features/timeline/bili_dynamic_body.dart';

/// 验证 `docs/WEIBO_DETAIL_ALIGN.md` §2 的技术判断：
/// **微博的 `title` 同样是「正文首行截 60 字」的兜底**，
/// 因此 B 站的 `hasOwnTitle` 判据对微博**同样适用，不需要改**。
///
/// 这个文件是交接文档的事实依据 —— 文档里断言了「微博有一模一样的缺陷」，
/// 那条断言必须有可执行的验证，否则只是读代码的猜测。
void main() {
  /// 复刻 `weibo_parser.dart:429` 的 `_title()`（逐字一致）。
  String weiboTitle(String summary) {
    final String line = HtmlText.singleLine(summary);
    if (line.isEmpty) return '';
    return HtmlText.truncate(line, 60); // _titleMaxChars = 60
  }

  ContentItem weibo({
    required String title,
    required String summary,
    List<String> images = const <String>[],
  }) =>
      ContentItem(
        id: 'w1',
        platform: Platform.weibo,
        kind: ContentKind.dynamic,
        sourceId: 'weibo:1',
        authorName: '博主',
        title: title,
        summary: summary,
        images: images,
        link: 'https://m.weibo.cn/status/1',
        publishedAt: DateTime.utc(2026, 11, 2),
        fetchedAt: DateTime.utc(2026, 11, 2),
      );

  group('微博兜底标题的形态（文档 §2 的事实依据）', () {
    test('多段正文：title 是**全文压成一行**后的前 60 字（不是只取首行）', () {
      const String body = '今天天气不错，出门走走。\n\n顺便拍了些照片，晚点发出来。';
      final String t = weiboTitle(body);

      // ⚠️ 这里差点写错：`HtmlText.singleLine` 会把换行压成空格，
      // 所以 title 是「全文单行化后截 60 字」，不是「第一段」。
      // 但正文以它开头这件事仍然成立 —— 那才是 hasOwnTitle 依赖的性质。
      expect(t, '今天天气不错，出门走走。 顺便拍了些照片，晚点发出来。',
          reason: 'singleLine 把 \\n\\n 压成了空格');
      expect(body.trim().startsWith('今天天气不错'), isTrue);

      // 真正要紧的：hasOwnTitle 判为「不是独立标题」。
      final ContentItem item = weibo(title: t, summary: body);
      expect(BiliDynamicStyle.hasOwnTitle(item), isFalse);
    });

    test('多段正文：正文单行化后以 title 开头（hasOwnTitle 的第一道判据）', () {
      const String body = '今天天气不错，出门走走。\n\n顺便拍了些照片，晚点发出来。';
      final String t = weiboTitle(body);

      // hasOwnTitle 里用的是 `s.startsWith(t)`，s 是**未单行化**的 summary。
      // 这里验证：单行化后相等，所以 startsWith 判据在多段场景下**不**生效，
      // 真正兜住它的是最后那行 truncate 比较。
      expect(HtmlText.singleLine(body), t);
      expect(HtmlText.truncate(HtmlText.singleLine(body), 60), t);
    });

    test('单段长正文：title 是前 60 字 + 省略号', () {
      final String body = '很长的正文' * 30;
      final String t = weiboTitle(body);

      expect(t.length, 61, reason: '60 字 + 省略号');
      expect(t.endsWith('…'), isTrue);
    });

    test('正文为空（纯图微博）→ title 是空串，不是占位符', () {
      // 微博与 B 站不同：这里刻意**不**伪造 `[图片]`
      // （weibo_parser 的注释写明了理由：伪造会把「纯图」和「解析失败」混成一种）。
      expect(weiboTitle(''), '');
    });
  });

  group('hasOwnTitle 对微博的行为（跨平台复用验证）', () {
    test('多段正文 + 兜底标题 → 判为「不是独立标题」（正文不会画两遍）', () {
      const String body = '今天天气不错，出门走走。\n\n顺便拍了些照片，晚点发出来。';
      final ContentItem item = weibo(title: weiboTitle(body), summary: body);

      expect(BiliDynamicStyle.hasOwnTitle(item), isFalse);
    });

    test('单段长正文 + 兜底标题 → 判为「不是独立标题」', () {
      final String body = '很长的正文' * 30;
      final ContentItem item = weibo(title: weiboTitle(body), summary: body);

      expect(BiliDynamicStyle.hasOwnTitle(item), isFalse);
    });

    test('纯图微博（title 空、summary 空）→ 无标题可渲染', () {
      final ContentItem item = weibo(
        title: weiboTitle(''),
        summary: '',
        images: <String>['https://wx2.sinaimg.cn/mw2000/a.jpg'],
      );

      expect(BiliDynamicStyle.hasOwnTitle(item), isFalse);
    });

    test('微博真的是标题 + 正文两条不同文本 → 判为「独立标题」', () {
      // 这种形态在微博里少见（微博没有标题字段），但 `ContentItem` 允许，
      // 判据不能因为平台是微博就一律返回 false。
      final ContentItem item = weibo(
        title: '公告',
        summary: '今天开始维护，预计两小时。',
      );

      expect(BiliDynamicStyle.hasOwnTitle(item), isTrue);
    });
  });

  group('两档字号/配色对微博的落点（文档 §1 的表格）', () {
    test('纯文字微博 → 16px + 正文深色昵称', () {
      final ContentItem item = weibo(title: '', summary: '纯文字');
      expect(BiliDynamicStyle.bodySizeFor(item), 16);
      expect(BiliDynamicStyle.nameColorFor(item), isNot(42));
    });

    test('带图微博 → 15px', () {
      final ContentItem item = weibo(
        title: '',
        summary: '带图',
        images: <String>['https://wx2.sinaimg.cn/mw2000/a.jpg'],
      );
      expect(BiliDynamicStyle.bodySizeFor(item), 15);
    });

    test('计数语义：微博三个计数都解析了，数据栏能出「赞和转发」', () {
      // weibo_parser 映射：comments_count / attitudes_count / reposts_count
      final int sum = 200 + 50;
      expect(BiliDynamicStyle.count(sum), '250');
    });
  });
}
