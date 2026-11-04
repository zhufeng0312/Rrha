import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/bili_client.dart';
import 'package:rrha/data/bili/comment_parser.dart';

/// 回归测试：评论翻页 -400。
///
/// 实测 B 站的 `pagination_str` **只认** `{"offset":"..."}` 形态，
/// 而 `next_offset` 本身是裸游标串；早先的实现把它原样发出去，于是
/// 首屏正常、点「加载更多」必报 -400。这里把两层约定钉死：
/// 解析层交裸值，包装只在 client 层发生，且产物必须紧凑（无空格）。
void main() {
  const rawCursor = 'CAESEDE4MzUwNzg0NzQyOTc0OTYa';

  group('pagination_str 包装', () {
    test('空游标 → 分页第一页的形态', () {
      expect(BiliClient.paginationStr(null), '{"offset":""}');
      expect(BiliClient.paginationStr(''), '{"offset":""}');
      expect(BiliClient.paginationStr('   '), '{"offset":""}');
    });

    test('裸游标被包进 offset 字段', () {
      final encoded = BiliClient.paginationStr(rawCursor);
      expect(jsonDecode(encoded), <String, dynamic>{'offset': rawCursor});
      expect(encoded, '{"offset":"$rawCursor"}');
    });

    test('产物是紧凑 JSON：不允许出现空格', () {
      for (final cursor in <String?>[null, '', '   ', 'abc', rawCursor]) {
        expect(
          BiliClient.paginationStr(cursor).contains(' '),
          isFalse,
          reason: '带空格的 pagination_str 会被 B 站判 -403',
        );
      }
    });

    test('游标首尾空白被清掉，不污染参数', () {
      expect(BiliClient.paginationStr('  $rawCursor  '),
          '{"offset":"$rawCursor"}');
    });
  });

  group('解析层只管裸游标', () {
    test('next_offset 原文被原样保留，不做 JSON 包装', () {
      final page = CommentParser.parseMain(<String, dynamic>{
        'data': <String, dynamic>{
          'cursor': <String, dynamic>{
            'is_end': false,
            'pagination_reply': <String, dynamic>{'next_offset': rawCursor},
          },
        },
      });

      expect(page.nextCursor, rawCursor);
      // 包装只发生在 client 层：游标里不该出现任何 JSON 片段。
      expect(page.nextCursor, isNot(contains('offset')));
      expect(page.nextCursor, isNot(contains('{')));
      expect(page.isEnd, isFalse);
    });

    test('解析结果可直接交给 client 包装（端到端形态一致）', () {
      final page = CommentParser.parseMain(<String, dynamic>{
        'data': <String, dynamic>{
          'cursor': <String, dynamic>{
            'is_end': false,
            'pagination_reply': <String, dynamic>{'next_offset': rawCursor},
          },
        },
      });
      expect(
        BiliClient.paginationStr(page.nextCursor),
        '{"offset":"$rawCursor"}',
      );
    });

    test('旧接口的 cursor.next（页码语义）不再被伪造成游标', () {
      final page = CommentParser.parseMain(<String, dynamic>{
        'data': <String, dynamic>{
          'cursor': <String, dynamic>{'is_end': false, 'next': 2},
        },
      });

      // 页码 ≠ 偏移游标；伪造空 offset 只会让「加载更多」原地打转。
      expect(page.nextCursor, isNull);
      expect(page.isEnd, isTrue);
    });
  });
}
