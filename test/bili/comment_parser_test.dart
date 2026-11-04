import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/comment_parser.dart';

/// 结构参照 `/x/v2/reply/wbi/main` 的响应：
/// 主列表在 `data.replies`，置顶在 `data.top_replies`，
/// 游标是 `data.cursor.pagination_reply.next_offset`
/// （实测是**裸游标串**，JSON 包装由 client 层负责）。
Map<String, dynamic> _mainResponse({String? nextOffset, bool isEnd = false}) =>
    <String, dynamic>{
      'code': 0,
      'data': <String, dynamic>{
        'replies': <dynamic>[
          <String, dynamic>{
            'rpid': 1001,
            'root': 0,
            'parent': 0,
            'like': 12,
            'ctime': 1700000000,
            'rcount': 2,
            'member': <String, dynamic>{
              'mid': 999,
              'uname': 'UP 本人',
              'avatar': 'https://x/a.jpg',
            },
            'content': <String, dynamic>{'message': '这是一条评论'},
            'replies': <dynamic>[
              <String, dynamic>{
                'rpid': 2001,
                'root': 1001,
                'parent': 1001,
                'member': <String, dynamic>{'mid': 5, 'uname': '路人'},
                'content': <String, dynamic>{'message': '楼中楼'},
                'like': 1,
                'ctime': 1700000100,
              },
            ],
          },
          <String, dynamic>{
            'rpid': 1002,
            'member': <String, dynamic>{'mid': 6, 'uname': '另一个用户'},
            'content': <String, dynamic>{'message': '第二条'},
            'like': 3,
            'ctime': 1700000200,
          },
        ],
        'top_replies': <dynamic>[
          <String, dynamic>{
            'rpid': 900,
            'member': <String, dynamic>{'mid': 7, 'uname': '置顶'},
            'content': <String, dynamic>{'message': '置顶评论'},
          },
        ],
        'cursor': <String, dynamic>{
          'is_end': isEnd,
          'pagination_reply': <String, dynamic>{'next_offset': nextOffset},
        },
        'page': <String, dynamic>{'count': 42},
      },
    };

void main() {
  group('主评论解析', () {
    test('列表 / 置顶 / 游标 / 总数', () {
      final page = CommentParser.parseMain(
        _mainResponse(nextOffset: 'CAESEDE4CURSOR'),
        upMid: 999,
      );

      expect(page.comments.length, 2);
      expect(page.topComments.length, 1);
      expect(page.total, 42);
      expect(page.isEnd, isFalse);
      expect(page.nextCursor, 'CAESEDE4CURSOR');
      expect(page.isEmpty, isFalse);
    });

    test('UP 主标记由 mid 与视频作者比对得出', () {
      final page = CommentParser.parseMain(
        _mainResponse(nextOffset: 'x'),
        upMid: 999,
      );
      expect(page.comments.first.isUp, isTrue);
      expect(page.comments[1].isUp, isFalse);
    });

    test('不传 upMid 时不误标 UP', () {
      final page = CommentParser.parseMain(_mainResponse(nextOffset: 'x'));
      expect(page.comments.every((c) => !c.isUp), isTrue);
    });

    test('主接口顺带返回的楼中楼被解析并标记为已加载', () {
      final page = CommentParser.parseMain(
        _mainResponse(nextOffset: 'x'),
        upMid: 999,
      );
      final first = page.comments.first;
      expect(first.replies.length, 1);
      expect(first.replies.first.root, 1001);
      expect(first.repliesLoaded, isTrue);
      expect(first.repliesHasMore, isTrue, reason: 'rcount=2 但只带回了 1 条');
      expect(first.replyCount, 2);
      expect(first.avatar, 'https://x/a.jpg');
    });

    test('没有 next_offset 时判定为到底', () {
      final page = CommentParser.parseMain(_mainResponse());
      expect(page.isEnd, isTrue);
      expect(page.nextCursor, isNull);
    });

    test('创建时间转换为 DateTime（UTC）', () {
      final page = CommentParser.parseMain(_mainResponse(nextOffset: 'x'));
      expect(page.comments.first.createdAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true));
    });
  });

  group('容错', () {
    test('缺 data / 类型异常时返回空页，不抛异常', () {
      expect(CommentParser.parseMain(<String, dynamic>{}).comments, isEmpty);
      expect(
        CommentParser.parseMain(<String, dynamic>{'data': 'oops'}).isEnd,
        isTrue,
      );
      expect(
        CommentParser.parseMain(<String, dynamic>{
          'data': <String, dynamic>{'replies': 'oops'},
        }).comments,
        isEmpty,
      );
    });

    test('rpid 缺失的条目被跳过，其余保留', () {
      final page = CommentParser.parseMain(<String, dynamic>{
        'data': <String, dynamic>{
          'replies': <dynamic>[
            <String, dynamic>{
              'member': <String, dynamic>{'uname': 'x'},
              'content': <String, dynamic>{'message': '没有 rpid'},
            },
            <String, dynamic>{
              'rpid': 5,
              'member': <String, dynamic>{'uname': 'y'},
              'content': <String, dynamic>{'message': '正常'},
            },
          ],
        },
      });
      expect(page.comments.length, 1);
      expect(page.comments.single.message, '正常');
    });

    test('数字字段兼容字符串形式（B 站有时把 int64 传成字符串）', () {
      final page = CommentParser.parseMain(<String, dynamic>{
        'data': <String, dynamic>{
          'replies': <dynamic>[
            <String, dynamic>{
              'rpid': '12345',
              'like': '7',
              'ctime': '1700000000',
              'member': <String, dynamic>{'mid': '9', 'uname': 'u'},
              'content': <String, dynamic>{'message': 'm'},
            },
          ],
        },
      });
      expect(page.comments.single.rpid, 12345);
      expect(page.comments.single.like, 7);
      expect(page.comments.single.createdAt, isNotNull);
    });

    test('缺少 member / content 时用兜底文案而不是崩', () {
      final page = CommentParser.parseMain(<String, dynamic>{
        'data': <String, dynamic>{
          'replies': <dynamic>[
            <String, dynamic>{'rpid': 1},
          ],
        },
      });
      expect(page.comments.single.uname, '未知用户');
      expect(page.comments.single.message, '');
    });
  });

  group('楼中楼分页', () {
    test('按 pageSize 判断是否还有更多', () {
      final page = CommentParser.parseReplies(
        <String, dynamic>{
          'data': <String, dynamic>{
            'replies': List<dynamic>.generate(
              10,
              (i) => <String, dynamic>{
                'rpid': 3000 + i,
                'root': 1001,
                'member': <String, dynamic>{'uname': 'u$i'},
                'content': <String, dynamic>{'message': 'm$i'},
              },
            ),
            'page': <String, dynamic>{'count': 25},
          },
        },
        pageSize: 10,
      );

      expect(page.comments.length, 10);
      expect(page.hasMore, isTrue);
      expect(page.totalCount, 25);
    });

    test('不足一页时 hasMore 为 false', () {
      final page = CommentParser.parseReplies(
        <String, dynamic>{
          'data': <String, dynamic>{
            'replies': List<dynamic>.generate(
              3,
              (i) => <String, dynamic>{
                'rpid': 4000 + i,
                'member': <String, dynamic>{'uname': 'u$i'},
                'content': <String, dynamic>{'message': 'm$i'},
              },
            ),
            'page': <String, dynamic>{'count': 3},
          },
        },
        pageSize: 10,
      );
      expect(page.comments.length, 3);
      expect(page.hasMore, isFalse);
    });

    test('空 data 返回空页', () {
      expect(
        CommentParser.parseReplies(<String, dynamic>{}).comments,
        isEmpty,
      );
    });
  });
}
