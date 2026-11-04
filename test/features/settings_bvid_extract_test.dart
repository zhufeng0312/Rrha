import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/features/settings/settings_page.dart';

/// 「按 BV 号打开」的输入解析。
///
/// 这个入口是 App 内打开指定稿件的唯一途径（没有搜索框），
/// 实际使用中用户多半直接粘贴分享链接，所以必须能从中抽出 BV 号。
void main() {
  group('extractBvidFromInput', () {
    test('纯 BV 号', () {
      expect(extractBvidFromInput('BV1XUJe6KE31'), 'BV1XUJe6KE31');
    });

    test('分享链接里提取', () {
      expect(
        extractBvidFromInput(
          'https://www.bilibili.com/video/BV1mwJq6KEaX/?share_source=copy&t=12',
        ),
        'BV1mwJq6KEaX',
      );
    });

    test('带空格/换行也能提取', () {
      expect(extractBvidFromInput('  BV1hGJi6zE6s  \n'), 'BV1hGJi6zE6s');
    });

    test('没有 BV 号时返回 null', () {
      expect(extractBvidFromInput(''), isNull);
      expect(extractBvidFromInput('av123456'), isNull);
      expect(extractBvidFromInput('随便一段文字'), isNull);
    });
  });

  /// 「按 BV 号 / 动态链接打开」还要认 **opus 动态链接**（2026-11-02 新增）。
  ///
  /// 用户在浏览器里复制来的是 `bilibili.com/opus/<19 位数字>`，这段 id
  /// **不是**评论 oid（拿它查评论必然 -404）。所以入口必须先认出它，
  /// 再交给 `OpusDetailPage` 去请求 detail 接口拿真正的 `comment_id_str`。
  group('extractOpusIdFromInput', () {
    test('用户实际给的那条链接（带 spm 参数）', () {
      expect(
        extractOpusIdFromInput(
          'https://www.bilibili.com/opus/1266051909563711506'
          '?spm_id_from=333.1365.0.0',
        ),
        '1266051909563711506',
      );
    });

    test('不带参数的纯 opus 链接', () {
      expect(
        extractOpusIdFromInput(
          'https://www.bilibili.com/opus/1266051909563711506',
        ),
        '1266051909563711506',
      );
    });

    test('http 协议同样识别', () {
      expect(
        extractOpusIdFromInput('http://bilibili.com/opus/123456789'),
        '123456789',
      );
    });

    test('前后有空白/换行也能提取', () {
      expect(
        extractOpusIdFromInput('  https://www.bilibili.com/opus/99887766  \n'),
        '99887766',
      );
    });

    test('视频链接不会被误判成动态', () {
      expect(
        extractOpusIdFromInput(
          'https://www.bilibili.com/video/BV1RXx169Emu/?spm_id_from=333.999',
        ),
        isNull,
      );
    });

    test('没有 opus 时返回 null', () {
      expect(extractOpusIdFromInput(''), isNull);
      expect(extractOpusIdFromInput('BV1RXx169Emu'), isNull);
      expect(extractOpusIdFromInput('t.bilibili.com/123456'), isNull);
    });

    test('数字太短不当成动态 id（避免把别的路径误认）', () {
      expect(extractOpusIdFromInput('https://x.com/opus/123'), isNull);
    });

    test('BV 与 opus 互不干扰：同一个输入两者只该命中一个', () {
      const url = 'https://www.bilibili.com/opus/1266051909563711506'
          '?spm_id_from=333.1365.0.0';
      expect(extractBvidFromInput(url), isNull);
      expect(extractOpusIdFromInput(url), '1266051909563711506');

      const video = 'https://www.bilibili.com/video/BV1RXx169Emu';
      expect(extractBvidFromInput(video), 'BV1RXx169Emu');
      expect(extractOpusIdFromInput(video), isNull);
    });
  });
}
