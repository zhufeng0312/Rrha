import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/utils/async_utils.dart';
import 'package:rrha/core/utils/bvid.dart';
import 'package:rrha/core/utils/html_text.dart';
import 'package:rrha/core/utils/time_parse.dart';

void main() {
  group('HtmlText', () {
    test('toPlainText 去标签并保留段落', () {
      const html = '<p>第一段</p><p>第二段<br>换行</p>';
      final text = HtmlText.toPlainText(html);
      expect(text, contains('第一段'));
      expect(text, contains('第二段'));
      expect(text, contains('换行'));
      expect(text, isNot(contains('<')));
      expect(text, isNot(contains('>')));
    });

    test('解码 HTML 实体（含数字实体）', () {
      expect(
        HtmlText.decodeEntities('a&amp;b&lt;c&gt;d&quot;e&#39;f&#65;'),
        'a&b<c>d"e\'fA',
      );
    });

    test('firstImageUrl 提取首个图片并补协议', () {
      expect(
        HtmlText.firstImageUrl('<img src="//i0.hdslb.com/x.jpg">说明'),
        'https://i0.hdslb.com/x.jpg',
      );
      expect(HtmlText.firstImageUrl('没有图片'), isNull);
      expect(HtmlText.firstImageUrl(null), isNull);
    });

    test('firstInlineVideoLink 提取 mp4 直链', () {
      expect(
        HtmlText.firstInlineVideoLink('看这个 https://x.com/a.mp4?k=1 很棒'),
        'https://x.com/a.mp4?k=1',
      );
      expect(HtmlText.firstInlineVideoLink('没有视频'), isNull);
    });

    test('truncate 与 singleLine', () {
      expect(HtmlText.truncate('abcdef', 3), 'abc…');
      expect(HtmlText.truncate('ab', 3), 'ab');
      expect(HtmlText.singleLine('a\n\nb   c'), 'a b c');
    });

    test('输入为空时返回空串而不是抛异常', () {
      expect(HtmlText.toPlainText(null), '');
      expect(HtmlText.toPlainText(''), '');
    });
  });

  group('TimeParse', () {
    test('RFC822 带 +0800 偏移（RSS 最常见形态）', () {
      final dt = TimeParse.parseRss('Wed, 02 Oct 2024 13:00:00 +0800');
      expect(dt, isNotNull);
      expect(dt!.toUtc(), DateTime.utc(2024, 10, 2, 5, 0, 0));
    });

    test('RFC1123 GMT', () {
      final dt = TimeParse.parseRss('Wed, 02 Oct 2024 13:00:00 GMT');
      expect(dt!.toUtc(), DateTime.utc(2024, 10, 2, 13, 0, 0));
    });

    test('ISO8601', () {
      final dt = TimeParse.parseRss('2024-10-02T13:00:00Z');
      expect(dt!.toUtc(), DateTime.utc(2024, 10, 2, 13));
    });

    test('Unix 时间戳（秒与毫秒）', () {
      expect(
        TimeParse.parseRss('1700000000')!.millisecondsSinceEpoch,
        1700000000000,
      );
      expect(
        TimeParse.parseRss('1700000000000')!.millisecondsSinceEpoch,
        1700000000000,
      );
    });

    test('无法解析时返回 null（调用方回落到抓取时间）', () {
      expect(TimeParse.parseRss('随便写的'), isNull);
      expect(TimeParse.parseRss(null), isNull);
      expect(TimeParse.parseRss(''), isNull);
    });

    test('humanize', () {
      final now = DateTime.utc(2024, 10, 2, 12);
      expect(
        TimeParse.humanize(now.subtract(const Duration(seconds: 30)), now: now),
        '刚刚',
      );
      expect(
        TimeParse.humanize(now.subtract(const Duration(minutes: 5)), now: now),
        '5 分钟前',
      );
      expect(
        TimeParse.humanize(now.subtract(const Duration(hours: 3)), now: now),
        '3 小时前',
      );
      // 需求（2026-10-26）：N 天前要带上**具体时分**，否则「2 天前」太粗。
      // now = 10-02 12:00 UTC，减 2 天 = 09-30 12:00 UTC → 本地（+08）20:00。
      expect(
        TimeParse.humanize(now.subtract(const Duration(days: 2)), now: now),
        '2 天前 20:00',
      );
      expect(TimeParse.humanize(null), '时间未知');
    });

    test('humanize：30 天以上走绝对日期，同样带时分', () {
      final now = DateTime.utc(2024, 10, 2, 12);
      // 同一年：MM-DD HH:mm
      expect(
        TimeParse.humanize(DateTime.utc(2024, 5, 1, 6, 30), now: now),
        '05-01 14:30',
      );
      // 跨年：YYYY-MM-DD HH:mm
      expect(
        TimeParse.humanize(DateTime.utc(2023, 5, 1, 6, 30), now: now),
        '2023-05-01 14:30',
      );
    });
  });

  group('BiliIdParser', () {
    test('从各种链接形态提取 BV 号', () {
      expect(
        BiliIdParser.bvid('https://www.bilibili.com/video/BV1xx411c7mD'),
        'BV1xx411c7mD',
      );
      expect(
        BiliIdParser.bvid('https://m.bilibili.com/video/BV1xx411c7mD?p=2'),
        'BV1xx411c7mD',
      );
      expect(BiliIdParser.bvid('没有 BV 号'), isNull);
      expect(BiliIdParser.bvid(null), isNull);
    });

    test('提取 av 号与分 P', () {
      expect(BiliIdParser.avid('https://www.bilibili.com/video/av12345'), 12345);
      expect(BiliIdParser.page('https://x/video/BV1xx411c7mD?p=3'), 3);
      expect(BiliIdParser.page('https://x/video/BV1xx411c7mD'), 1);
    });

    test('UID 校验', () {
      expect(BiliIdParser.isValidUid('2267573'), isTrue);
      expect(BiliIdParser.isValidUid('abc'), isFalse);
      expect(BiliIdParser.isValidUid(''), isFalse);
    });

    test('firstUrl', () {
      expect(
        BiliIdParser.firstUrl('看看 https://a.com/b 这个'),
        'https://a.com/b',
      );
    });
  });

  group('WeiboIdParser', () {
    test('提取 statusId', () {
      expect(
        WeiboIdParser.statusId('https://weibo.com/1234567890/PabcDEFghi'),
        'PabcDEFghi',
      );
      expect(WeiboIdParser.statusId('https://weibo.com/1234567890'), isNull);
    });

    test('提取 uid', () {
      expect(
        WeiboIdParser.uidFromUrl('https://weibo.com/u/1234567890'),
        '1234567890',
      );
      expect(
        WeiboIdParser.uidFromUrl('https://weibo.com/1234567890/Pabc'),
        '1234567890',
      );
    });

    test('UID 校验', () {
      expect(WeiboIdParser.isValidUid('1234567890'), isTrue);
      expect(WeiboIdParser.isValidUid('123'), isFalse);
    });
  });

  group('mapLimit', () {
    test('保持结果顺序', () async {
      final result = await mapLimit<int, int>(
        <int>[5, 1, 4, 2, 3],
        2,
        (v) async {
          await Future<void>.delayed(Duration(milliseconds: v * 4));
          return v * 2;
        },
      );
      expect(result, <int>[10, 2, 8, 4, 6]);
    });

    test('并发不超过上限（公共实例不能被并发打爆）', () async {
      var running = 0;
      var peak = 0;
      await mapLimit<int, int>(
        List<int>.generate(10, (i) => i),
        3,
        (v) async {
          running++;
          if (running > peak) peak = running;
          await Future<void>.delayed(const Duration(milliseconds: 8));
          running--;
          return v;
        },
      );
      expect(peak, lessThanOrEqualTo(3));
      expect(peak, greaterThan(1));
    });

    test('空列表与 limit 越界', () async {
      expect(await mapLimit<int, int>(<int>[], 3, (v) async => v), isEmpty);
      expect(
        await mapLimit<int, int>(<int>[1, 2], 10, (v) async => v + 1),
        <int>[2, 3],
      );
      expect(
        await mapLimit<int, int>(<int>[1, 2], 0, (v) async => v),
        <int>[1, 2],
      );
    });
  });
}
