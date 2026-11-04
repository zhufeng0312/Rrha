import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/weibo/weibo_subcomment_probe.dart';

/// `WeiboSubCommentProbe` 的离线验收。
///
/// 探针本体要真机跑才有结论，但**判定逻辑全是纯函数**，所以这里把
/// 「总回复数字段怎么认、样本怎么挑、子接口列表在哪、游标怎么取、
/// 两页怎么去重、URL 怎么脱敏、请求节制」逐条钉死：
/// 真机上一旦拿到响应，翻译成人话的那一步不会再出错。
///
/// 三种响应形态分别覆盖：
/// - A：`hotflowChild` 与 `hotflow` **同构**（`data.data[]` + `data.max_id`）；
/// - B：列表直接在 `data[]`（没有第二级 data）；
/// - C：路径不对 / 空体 / 432 —— 必须判成不可用，而不是「0 条可用」。

/// 一条一级评论（可调内嵌条数与「像总数」的字段）。
Map<String, dynamic> _post({
  String id = '4932195724034522',
  int inline = 2,
  Object? commentsNum,
  Object? replyCount,
  Object? totalNumber,
  List<Map<String, dynamic>>? extra,
  String text = '<span>你确定是偶尔直播？</span>',
  String name = '若叶睦子米Mutsumi',
}) =>
    <String, dynamic>{
      'id': id,
      'mid': id,
      'floor_number': 6,
      'text': text,
      'like_count': 1276,
      'pic_num': 0,
      'readtimetype': 'comment',
      'cmt_ext': 'level_type:1',
      'gid': 4932195724034522,
      'restrict_state': 0,
      'disable_reply': 0,
      if (commentsNum != null) 'comments_num': commentsNum,
      if (replyCount != null) 'reply_count': replyCount,
      if (totalNumber != null) 'total_number': totalNumber,
      'user': <String, dynamic>{'id': 6611538293, 'screen_name': name},
      'comments': <Map<String, dynamic>>[
        for (int i = 0; i < inline; i++)
          <String, dynamic>{
            'id': '493219609785237$i',
            'rootid': id,
            'floor_number': 0,
            'text': '回复 $i',
            'readtimetype': 'comment_reply',
            'cmt_ext': 'level_type:2',
          },
        if (extra != null) ...extra,
      ],
    };

/// hotflow 一页。
String _hotflowPage(
  List<Map<String, dynamic>> posts, {
  Object? cursor = 182712657086119,
  int ok = 1,
  int total = 362,
}) =>
    jsonEncode(<String, dynamic>{
      'ok': ok,
      'data': <String, dynamic>{
        'data': posts,
        'max': cursor,
        'max_id': cursor,
        'max_id_type': 0,
        'status': 0,
        'total_number': total,
      },
    });

/// hotflowChild 一页（与 hotflow 同构）。
String _childPage(
  List<Map<String, dynamic>> replies, {
  Object? cursor = 145080195823562,
  int ok = 1,
  int? total = 11,
}) =>
    jsonEncode(<String, dynamic>{
      'ok': ok,
      'data': <String, dynamic>{
        'data': replies,
        'max': cursor,
        'max_id': cursor,
        'max_id_type': 0,
        'status': 0,
        if (total != null) 'total_number': total,
      },
    });

/// 一条二级评论。
Map<String, dynamic> _reply(int i) => <String, dynamic>{
      'id': '506226519629577724$i',
      'rootid': '4932195724034522',
      'floor_number': 0,
      'text': '二级回复 $i',
      'readtimetype': 'comment_reply',
      'cmt_ext': 'level_type:2',
    };

/// 从结果里取出「第 1 页」以外的断言入口（探针 run 要真网络，这里只测纯函数）。
ChildPageProbe _parse(
  String body, {
  int? status = 200,
  String label = 'T1 第 1 页',
  int dup = 0,
}) =>
    parseChildPage(
      body: body,
      httpStatus: status,
      urlMasked: 'https://m.weibo.cn/comments/hotflowChild?cid=<16 位>&max_id_type=<1 位>',
      label: label,
      duplicateOfPrevious: dup,
    );

void main() {
  group('countLikeFields：认「总回复数」字段', () {
    test('comments_num / reply_count / total_number 都能命中', () {
      final List<CountLikeField> f = countLikeFields(
        _post(commentsNum: 11, replyCount: 11, totalNumber: 3),
      );
      expect(
        f.map((CountLikeField x) => x.key).toList(),
        <String>['comments_num', 'reply_count', 'total_number'],
      );
      expect(f.first.value, 11);
    });

    test('like_count / floor_number / pic_num 这类噪声被排除', () {
      final List<CountLikeField> f = countLikeFields(_post());
      expect(f, isEmpty);
    });

    test('String 形态的数字也认（微博偶尔把计数给成字符串）', () {
      final List<CountLikeField> f = countLikeFields(
        <String, dynamic>{'id': '1', 'comments_num': '11'},
      );
      expect(f.single.value, 11);

      // 非数字串 / 布尔 / 对象一律不算
      expect(
        countLikeFields(<String, dynamic>{'id': '1', 'comments_num': '很多'}),
        isEmpty,
      );
      expect(
        countLikeFields(<String, dynamic>{'id': '1', 'comments_num': true}),
        isEmpty,
      );
      expect(
        countLikeFields(<String, dynamic>{'id': '1', 'comments_num': <int>[1]}),
        isEmpty,
      );
    });

    test('坏输入（null / List / 字符串）一律空列表，不抛', () {
      expect(countLikeFields(null), isEmpty);
      expect(countLikeFields(<Object?>[]), isEmpty);
      expect(countLikeFields('x'), isEmpty);
    });
  });

  group('pickInlineSample：挑「内嵌 2 条但总数更大」的一级评论', () {
    test('优先选有更大总数声明的（哪怕内嵌条数不是最多）', () {
      final String body = _hotflowPage(<Map<String, dynamic>>[
        _post(id: '111', inline: 2),
        _post(id: '222', inline: 1, commentsNum: 15),
        _post(id: '333', inline: 2),
      ]);
      final SubCommentInlineSample? s = pickInlineSample(body);
      expect(s, isNotNull);
      expect(s!.id, '222');
      expect(s.inlineCount, 1);
      expect(s.claimedField, 'comments_num');
      expect(s.claimedTotal, 15);
      expect(s.isStrong, isTrue);
      expect(s.postIndex, 1);
    });

    test('一级评论节点里的 max_id 被带出来（子接口续拉游标的唯一来源）', () {
      final String body = jsonEncode(<String, dynamic>{
        'ok': 1,
        'data': <String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{
              ..._post(id: '111', inline: 2, totalNumber: 68),
              'max_id': 145767000000000,
            },
          ],
          'max_id': 182712657086119,
        },
      });
      final SubCommentInlineSample s = pickInlineSample(body)!;
      expect(s.inlineMaxId, '145767000000000',
          reason: '必须是评论节点自己的 max_id，不是页级 data.max_id');
      expect(s.claimedTotal, 68);
    });

    test('总数字段等于内嵌条数 → 不算「声称更大」，回落选内嵌最多的', () {
      final String body = _hotflowPage(<Map<String, dynamic>>[
        _post(id: '111', inline: 1),
        _post(id: '222', inline: 3),
        _post(id: '333', inline: 2, commentsNum: 2),
      ]);
      final SubCommentInlineSample? s = pickInlineSample(body);
      expect(s!.id, '222');
      expect(s.claimedField, isNull);
      expect(s.isStrong, isFalse);
    });

    test('没有任何内嵌评论时仍返回样本（交给 T1 判定，而不是谎报找不到）', () {
      final String body = _hotflowPage(<Map<String, dynamic>>[
        _post(id: '111', inline: 0, commentsNum: 7),
      ]);
      final SubCommentInlineSample? s = pickInlineSample(body);
      expect(s, isNotNull);
      expect(s!.id, '111');
      expect(s.inlineCount, 0);
      expect(s.claimedTotal, 7);
    });

    test('没有 id 的条目被跳过（无法稳定标识）', () {
      final String body = _hotflowPage(<Map<String, dynamic>>[
        <String, dynamic>{'text': '没有 id'},
        _post(id: '222', commentsNum: 9),
      ]);
      expect(pickInlineSample(body)!.id, '222');
    });

    test('坏 JSON / 结构不对 / 空列表 → null，不抛', () {
      expect(pickInlineSample(''), isNull);
      expect(pickInlineSample('not json'), isNull);
      expect(pickInlineSample('{"ok":1}'), isNull);
      expect(pickInlineSample('{"ok":1,"data":{"data":[]}}'), isNull);
      expect(pickInlineSample('{"ok":1,"data":{"data":"x"}}'), isNull);
    });

    test('正文截断到 24 字符以内（落盘不灌长文）', () {
      final String body = _hotflowPage(<Map<String, dynamic>>[
        _post(text: 'A' * 200, commentsNum: 9),
      ]);
      final SubCommentInlineSample s = pickInlineSample(body)!;
      expect(s.textHead.length, lessThanOrEqualTo(25));
    });
  });

  group('parseChildPage：结构发现（不预设列表路径）', () {
    test('与 hotflow 同构时命中 data.data，游标取 max_id', () {
      final ChildPageProbe p = _parse(
        _childPage(<Map<String, dynamic>>[for (int i = 0; i < 11; i++) _reply(i)]),
      );
      expect(p.httpStatus, 200);
      expect(p.okFlag, 1);
      expect(p.listPath, 'data.data');
      expect(p.returned, 11);
      expect(p.cursorField, 'max_id');
      expect(p.cursorValue, '145080195823562');
      expect(p.totalNumber, 11);
      expect(p.usable, isTrue);
      expect(p.hasMore, isTrue);
      expect(p.duplicateOfPrevious, 0);
    });

    test('列表直接在 data[] 时也能认出来（路径写进结果）', () {
      final String body = jsonEncode(<String, dynamic>{
        'ok': 1,
        'data': <Map<String, dynamic>>[for (int i = 0; i < 5; i++) _reply(i)],
      });
      final ChildPageProbe p = _parse(body);
      expect(p.listPath, 'data');
      expect(p.returned, 5);
      expect(p.usable, isTrue);
    });

    test('列表在 data.comments[] 时也能认出来', () {
      final String body = jsonEncode(<String, dynamic>{
        'ok': 1,
        'data': <String, dynamic>{
          'comments': <Map<String, dynamic>>[_reply(1), _reply(2)],
          'max_id': 999,
        },
      });
      final ChildPageProbe p = _parse(body);
      expect(p.listPath, 'data.comments');
      expect(p.returned, 2);
      expect(p.cursorField, 'max_id');
    });

    test('ok=0 且列表为空 → 不可用（不能判成「0 条也算成功」）', () {
      final ChildPageProbe p = _parse(
        jsonEncode(<String, dynamic>{
          'ok': 0,
          'data': <String, dynamic>{'data': <Object?>[]},
        }),
      );
      expect(p.okFlag, 0);
      expect(p.returned, 0);
      expect(p.usable, isFalse);
      expect(p.hasMore, isFalse);
    });

    test('432 空体 → 不可用，且不抛', () {
      final ChildPageProbe p = _parse('', status: 432);
      expect(p.httpStatus, 432);
      expect(p.okFlag, isNull);
      expect(p.listPath, 'NONE');
      expect(p.usable, isFalse);
      expect(p.byteLength, 0);
    });

    test('没有游标 → hasMore=false（说明这页就是全部）', () {
      final ChildPageProbe p = _parse(
        _childPage(<Map<String, dynamic>>[_reply(1)], cursor: null),
      );
      expect(p.cursorField, isNull);
      expect(p.hasMore, isFalse);
      expect(p.usable, isTrue);
    });

    test('游标优先选精确的 max_id（宁可不用 max）', () {
      final String body = jsonEncode(<String, dynamic>{
        'ok': 1,
        'data': <String, dynamic>{
          'data': <Map<String, dynamic>>[_reply(1)],
          'max': 111,
          'max_id': 222,
          'more': 333,
        },
      });
      final ChildPageProbe p = _parse(body);
      expect(p.cursorField, 'max_id');
      expect(p.cursorValue, '222');
    });

    test('只有 max 时退回 max；只有 page 时也能用', () {
      final ChildPageProbe a = _parse(
        jsonEncode(<String, dynamic>{
          'ok': 1,
          'data': <String, dynamic>{
            'data': <Map<String, dynamic>>[_reply(1)],
            'max': 111,
          },
        }),
      );
      expect(a.cursorField, 'max');
      expect(a.cursorValue, '111');

      final ChildPageProbe b = _parse(
        jsonEncode(<String, dynamic>{
          'ok': 1,
          'data': <String, dynamic>{
            'data': <Map<String, dynamic>>[_reply(1)],
            'next_page': 2,
          },
        }),
      );
      expect(b.cursorField, 'next_page');
      expect(b.cursorValue, '2');
    });

    test('total_number 缺失时不瞎猜，返回 null', () {
      final ChildPageProbe p = _parse(
        _childPage(<Map<String, dynamic>>[_reply(1)], total: null),
      );
      expect(p.totalNumber, isNull);
    });

    test('data keys 被记录（报告里能看出为什么用这个路径）', () {
      final ChildPageProbe p = _parse(
        _childPage(<Map<String, dynamic>>[_reply(1)]),
      );
      expect(p.dataKeys, contains('data'));
      expect(p.dataKeys, contains('max_id'));
      expect(p.dataKeys, contains('total_number'));
    });
  });

  group('findCursors：游标字段扫描', () {
    test('max_id_type 不是游标（恒为 0，拼上去会拿到同一页）', () {
      final List<ChildCursor> c = findCursors(<String, dynamic>{
        'max_id': 123,
        'max_id_type': 0,
      });
      expect(c.single.key, 'max_id');
      expect(c.single.value, '123');
    });

    test('只收名字像游标的标量（max/cursor/since/next/page/offset）', () {
      final List<ChildCursor> c = findCursors(<String, dynamic>{
        'max_id': 123,
        'max': 456,
        'cursor': 'abc',
        'next_offset': 'x',
        'status': 0,
        'more': 1,
      });
      final List<String> keys = c.map((ChildCursor x) => x.key).toList()..sort();
      expect(keys, <String>['cursor', 'max', 'max_id', 'next_offset']);
      expect(c.firstWhere((ChildCursor x) => x.key == 'max_id').path, 'data.max_id');
    });

    test('嵌套一层也能找到（data.cursor.pagination_reply.next_offset 这类形态）', () {
      final List<ChildCursor> c = findCursors(<String, dynamic>{
        'cursor': <String, dynamic>{'next_offset': 'p2'},
      });
      expect(c.single.path, 'data.cursor.next_offset');
      expect(c.single.value, 'p2');
    });

    test('null / List 值不进游标（续拉时不能拼 [object]）', () {
      final List<ChildCursor> c = findCursors(<String, dynamic>{
        'max_id': null,
        'max_list': <int>[1, 2],
      });
      expect(c, isEmpty);
    });

    test('data 为 null 时返回空，不抛', () {
      expect(findCursors(null), isEmpty);
    });

    test('游标展示形态带类型与长度（不落全量值）', () {
      final ChildCursor c = ChildCursor(
        path: 'data.max_id',
        key: 'max_id',
        value: '145080195823562',
        typeName: 'int',
      );
      expect(c.text, contains('data.max_id(int)'));
      expect(c.text, contains('15 位'));
      expect(c.text.contains('145080195823562'), isFalse);
    });
  });

  group('overlapCount：第 2 页是否在重复第 1 页', () {
    test('完全重复 → 等于长度', () {
      expect(overlapCount(<String>['a', 'b'], <String>['a', 'b']), 2);
    });
    test('部分重复 → 只算交集', () {
      expect(overlapCount(<String>['a', 'b', 'c'], <String>['c', 'd']), 1);
    });
    test('完全不相交 / 任一侧为空 → 0', () {
      expect(overlapCount(<String>['a'], <String>['b']), 0);
      expect(overlapCount(const <String>[], <String>['b']), 0);
      expect(overlapCount(<String>['a'], const <String>[]), 0);
    });
  });

  group('hotflowCursorOf / intScalars / nodeAt', () {
    test('hotflow 游标取 data.max_id', () {
      expect(hotflowCursorOf(_hotflowPage(<Map<String, dynamic>>[])),
          '182712657086119');
    });

    test('intScalars 排除噪声键，留下可比对的整数', () {
      final Map<String, int> m = intScalars(_post(commentsNum: 11, totalNumber: 89));
      expect(m['comments_num'], 11);
      expect(m['total_number'], 89);
      expect(m.containsKey('like_count'), isFalse);
      expect(m.containsKey('floor_number'), isFalse);
    });

    test('nodeAt 按下标取节点，越界返回 null', () {
      final String body = _hotflowPage(<Map<String, dynamic>>[
        _post(id: '111'),
        _post(id: '222'),
      ]);
      expect(nodeAt(body, 0)!['id'], '111');
      expect(nodeAt(body, 1)!['id'], '222');
      expect(nodeAt(body, 2), isNull);
      expect(nodeAt(body, -1), isNull);
    });
  });

  group('scalarDump：字段摘录（人工核查用）', () {
    test('Map / List 只写类型与项数，不灌长文', () {
      final List<String> d = scalarDump(<String, dynamic>{
        'text': '正文',
        'like_count': 1276,
        'user': <String, dynamic>{'a': 1, 'b': 2},
        'comments': <Object?>[1, 2, 3],
      });
      expect(d, contains('text : String : "正文"'));
      expect(d, contains('like_count : int : 1276'));
      expect(d.any((String x) => x.startsWith('user : Map（2 个 key）')), isTrue);
      expect(d.any((String x) => x.startsWith('comments : List（3 项）')), isTrue);
    });

    test('id 类字段脱敏（报告里不出现完整 mid / cid）', () {
      final List<String> d = scalarDump(<String, dynamic>{
        'id': '4932195724034522',
        'mid': '4932195724034522',
        'rootid': '4932195724034522',
        'text': '4932195724034522',
      });
      final String idLine = d.firstWhere((String x) => x.startsWith('id :'));
      expect(idLine.contains('4932195724034522'), isFalse,
          reason: 'id 必须脱敏成前 6 位 + 长度');
      expect(idLine, contains('493219'));
      // 正文里的数字不是 id，不该被误伤
      expect(d.firstWhere((String x) => x.startsWith('text :')),
          contains('4932195724034522'));
    });

    test('超长字符串被截断并标注原长', () {
      final List<String> d = scalarDump(<String, dynamic>{'text': 'x' * 200});
      expect(d.single, contains('原长 200'));
      expect(d.single.length, lessThan(200));
    });

    test('limit 生效（防止一条评论顶掉整份报告）', () {
      final Map<String, dynamic> m = <String, dynamic>{
        for (int i = 0; i < 80; i++) 'k$i': i,
      };
      expect(scalarDump(m, limit: 10).length, 10);
    });
  });

  group('bodyKindOf：响应形态判定', () {
    test('JSON / HTML / 空 / 文本分得清', () {
      expect(bodyKindOf('{"ok":1}'), 'json');
      expect(bodyKindOf('  [1,2]'), 'json');
      expect(bodyKindOf('<!DOCTYPE html><html>'), 'html');
      expect(bodyKindOf('<html><body>x'), 'html');
      expect(bodyKindOf(''), 'empty');
      expect(bodyKindOf('   '), 'empty');
      expect(bodyKindOf('ok'), 'text');
    });
  });

  group('URL：拼接与脱敏', () {
    test('hotflow 第 1 页不带游标，续页原样拼 max_id', () {
      final String a = WeiboSubCommentProbe.hotflowPageUrl(mid: '5355066445792642');
      expect(a, contains('?id=5355066445792642&mid=5355066445792642'));
      expect(a, contains('max_id_type=0'));
      expect(a.contains('&max_id='), isFalse);

      final String b = WeiboSubCommentProbe.hotflowPageUrl(
        mid: '5355066445792642',
        cursor: '182712657086119',
      );
      expect(b, endsWith('&max_id=182712657086119'));
    });

    test('hotflowChild 第 1 页只带 cid，续页拼游标字段名', () {
      final String a = WeiboSubCommentProbe.childUrl(cid: '4932195724034522');
      expect(a, 'https://m.weibo.cn/comments/hotflowChild?cid=4932195724034522&max_id_type=0');

      final String b = WeiboSubCommentProbe.childUrl(
        cid: '4932195724034522',
        cursor: '145080195823562',
        cursorKey: 'max_id',
      );
      expect(b, endsWith('&max_id=145080195823562'));

      // 游标字段名跟着接口实际给的名字走，不写死
      final String c = WeiboSubCommentProbe.childUrl(
        cid: '4932195724034522',
        cursor: 'p2',
        cursorKey: 'next_offset',
      );
      expect(c, endsWith('&next_offset=p2'));
    });

    test('脱敏：只留参数名与长度，值本身不进报告', () {
      final String masked = WeiboSubCommentProbe.maskUrl(
        'https://m.weibo.cn/comments/hotflowChild?cid=4932195724034522&max_id_type=0',
      );
      expect(masked, contains('https://m.weibo.cn/comments/hotflowChild'));
      expect(masked, contains('cid=<16 位>'));
      expect(masked, contains('max_id_type=<1 位>'));
      expect(masked.contains('4932195724034522'), isFalse);
    });

    test('非法 URL 不抛', () {
      expect(WeiboSubCommentProbe.maskUrl('::'), contains('非法'));
    });

    test('id 脱敏：前 6 位 + 长度', () {
      final String m = WeiboSubCommentProbe.maskId('4932195724034522');
      expect(m, contains('493219'));
      expect(m, contains('16 位'));
      expect(m.contains('4932195724034522'), isFalse);
    });

    test('T3 URL 用 id 参数', () {
      expect(
        WeiboSubCommentProbe.t3Url(
          WeiboSubCommentProbe.t3ShowChild,
          cid: '4932195724034522',
        ),
        endsWith('?id=4932195724034522'),
      );
    });
  });

  group('请求纪律常量', () {
    test('硬上限与间隔符合任务要求', () {
      expect(WeiboSubCommentProbe.maxRequests, 16);
      expect(WeiboSubCommentProbe.maxPostPages, 3);
      expect(WeiboSubCommentProbe.maxConsecutive432, 3);
      expect(WeiboSubCommentProbe.minGap, const Duration(milliseconds: 2500));
      expect(WeiboSubCommentProbe.itemTimeout, const Duration(seconds: 20));
    });

    test('接口地址形态（大写变体单独常量，别混）', () {
      expect(WeiboSubCommentProbe.childEndpoint,
          'https://m.weibo.cn/comments/hotflowChild');
      expect(WeiboSubCommentProbe.t3UpperChild.contains('hotFlowChild'), isTrue);
      expect(WeiboSubCommentProbe.hotflowEndpoint,
          'https://m.weibo.cn/comments/hotflow');
    });
  });

  group('SubCommentProbeResult：结论与落盘', () {
    ChildPageProbe page(
      List<String> ids, {
      String? cursor = 'c1',
      int? total = 11,
    }) =>
        ChildPageProbe(
          label: 'T1 第 1 页',
          urlMasked: 'https://m.weibo.cn/comments/hotflowChild?cid=<16 位>',
          httpStatus: 200,
          okFlag: 1,
          listPath: 'data.data',
          ids: ids,
          cursors: <ChildCursor>[
            if (cursor != null)
              ChildCursor(
                path: 'data.max_id',
                key: 'max_id',
                value: cursor,
                typeName: 'int',
              ),
          ],
          cursorField: cursor == null ? null : 'max_id',
          cursorValue: cursor,
          totalNumber: total,
          dataKeys: const <String>['data', 'max_id', 'total_number'],
          duplicateOfPrevious: 0,
          byteLength: 4096,
        );

    SubCommentProbeResult result({
      required ChildPageProbe? first,
      ChildPageProbe? second,
      int inline = 2,
      String totalField = 'comments_num',
      bool verified = true,
      List<T3Attempt> t3 = const <T3Attempt>[],
    }) =>
        SubCommentProbeResult(
          mid: '5355066445792642',
          postPagesFetched: 1,
          scannedPages: const <String>['第 1 页：一级评论 20 条 · 最佳样本 data.data[0] 内嵌 2 条'],
          sample: SubCommentInlineSample(
            postIndex: 0,
            id: '4932195724034522',
            author: '若叶睦子米Mutsumi',
            inlineCount: inline,
            countFields: const <CountLikeField>[
              CountLikeField(key: 'total_number', value: 68),
            ],
            claimedField: 'total_number',
            claimedTotal: 68,
            textHead: '你确定是偶尔直播？',
            inlineMaxId: '145767000000000',
          ),
          sampleScalars: const <String>['id : String : 493219…（16 位）'],
          childFirst: first,
          childSecond: second,
          t3: t3,
          requestLog: const <String>['A 一级评论第 1 页 → HTTP 200'],
          requestCount: 2,
          saw432: false,
          max432Streak: 0,
          maxRequests: 16,
          totalField: totalField,
          totalFieldVerified: verified,
          note: '假数据',
        );

    test('第 1 页拿到 11 条、内嵌 2 条 → OK，差值 +9', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 11; i++) 'r$i']),
      );
      expect(r.verdict, 'OK');
      expect(r.returnedCount, 11);
      expect(r.inlineCount, 2);
      expect(r.delta, 9);
      expect(r.cursorField, 'max_id');
      expect(r.requestsToFetchAll, isNull,
          reason: '11 条 < 声称总数 68、第 2 页没拉 → 拿全请求数未知');
      expect(r.requestsToFetchAllText, '≥2');
      expect(r.cursorSource, 'child');
    });

    test('第 1 页条数已覆盖声称总数 → 1 个请求拿全', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 68; i++) 'r$i'], cursor: null),
      );
      expect(r.requestsToFetchAll, 1);
      expect(r.requestsToFetchAllText, '1');
    });

    test('子接口不给游标时，游标来源判为 inline（真机实测形态）', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 10; i++) 'r$i'], cursor: null),
      );
      expect(r.cursorField, 'NONE', reason: '子接口自己确实没有游标');
      expect(r.cursorSource, 'inline');
      expect(r.effectiveCursorField, 'max_id');
      expect(r.requestsToFetchAllText, '≥2',
          reason: '10 条 < 声称总数 68 → 一页不够');
    });

    test('子接口自带游标时来源判为 child（优先）', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 10; i++) 'r$i']),
      );
      expect(r.cursorSource, 'child');
      expect(r.effectiveCursorField, 'max_id');
    });

    test('两处都没有游标 → NONE', () {
      final SubCommentProbeResult base = result(
        first: page(<String>['a'], cursor: null),
      );
      final SubCommentProbeResult r = SubCommentProbeResult(
        mid: base.mid,
        postPagesFetched: 1,
        scannedPages: base.scannedPages,
        sample: SubCommentInlineSample(
          postIndex: 0,
          id: '4932195724034522',
          author: null,
          inlineCount: 1,
          countFields: const <CountLikeField>[],
          claimedField: null,
          claimedTotal: null,
          textHead: 'x',
          inlineMaxId: null,
        ),
        sampleScalars: const <String>[],
        childFirst: base.childFirst,
        childSecond: null,
        t3: const <T3Attempt>[],
        requestLog: const <String>[],
        requestCount: 1,
        saw432: false,
        max432Streak: 0,
        maxRequests: 16,
        totalField: 'NONE',
        totalFieldVerified: false,
        note: 'x',
      );
      expect(r.cursorSource, 'NONE');
      expect(r.effectiveCursorField, 'NONE');
    });

    test('第 2 页已无游标 → 就是到底了，2 个请求（哪怕总数说还有更多）', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 20; i++) 'r$i']),
        second: page(<String>['x1', 'x2'], cursor: null),
      );
      expect(r.secondPageWorks, isTrue);
      // 没有游标 = 服务端没有更多可给。此时 total_number（68）与实际可获取
      // 条数（22）不一致，属于微博自己的数字口径问题，不能据此继续编请求数。
      expect(r.requestsToFetchAll, 2);
      expect(r.requestsToFetchAllText, '2');
    });

    test('两页合计覆盖声称总数 → 2 个请求拿全', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 60; i++) 'r$i']),
        second: page(<String>[for (int i = 0; i < 10; i++) 'x$i'], cursor: null),
      );
      expect(r.requestsToFetchAll, 2);
      expect(r.requestsToFetchAllText, '2');
    });

    test('声称总数 68 vs 实拉 12 → 判为 mismatch（不能当可展开条数）', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 10; i++) 'r$i'], cursor: null),
        second: page(<String>['x1', 'x2'], cursor: null),
      );
      expect(r.obtainableCount, 12);
      expect(r.totalConsistency, 'mismatch');
      final String md = r.toMarkdown(cookieLength: 573, date: '2026-10-22');
      expect(md, contains('**68 vs 12**'));
      expect(md, contains('不一致'));
      expect(md, contains('已显示全部 12 条'));
    });

    test('实拉条数等于声称总数 → consistent', () {
      final SubCommentProbeResult base = result(
        first: page(<String>[for (int i = 0; i < 68; i++) 'r$i'], cursor: null),
      );
      final SubCommentProbeResult r = SubCommentProbeResult(
        mid: base.mid,
        postPagesFetched: 1,
        scannedPages: base.scannedPages,
        sample: SubCommentInlineSample(
          postIndex: 0,
          id: '4932195724034522',
          author: null,
          inlineCount: 2,
          countFields: const <CountLikeField>[
            CountLikeField(key: 'total_number', value: 68),
          ],
          claimedField: 'total_number',
          claimedTotal: 68,
          textHead: 'x',
          inlineMaxId: null,
        ),
        sampleScalars: const <String>[],
        childFirst: base.childFirst,
        childSecond: null,
        t3: const <T3Attempt>[],
        requestLog: const <String>[],
        requestCount: 2,
        saw432: false,
        max432Streak: 0,
        maxRequests: 16,
        totalField: 'total_number',
        totalFieldVerified: true,
        note: 'x',
      );
      expect(r.obtainableCount, 68);
      expect(r.totalConsistency, 'consistent');
    });

    test('还有未拉完的页 → obtainableCount 未知，不瞎报数字', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 10; i++) 'r$i']),
      );
      expect(r.obtainableCount, isNull);
      expect(r.totalConsistency, 'unknown');
    });

    test('第 2 页重复第 1 页 → 判定为不可续拉', () {
      final SubCommentProbeResult r = result(
        first: page(<String>['a', 'b']),
        second: ChildPageProbe(
          label: 'T1 第 2 页',
          urlMasked: 'u',
          httpStatus: 200,
          okFlag: 1,
          listPath: 'data.data',
          ids: <String>['a', 'b'],
          cursors: const <ChildCursor>[],
          cursorField: null,
          cursorValue: null,
          totalNumber: 11,
          dataKeys: const <String>['data'],
          duplicateOfPrevious: 2,
          byteLength: 1024,
        ),
      );
      expect(r.secondPageWorks, isFalse);
      expect(r.verdict, 'OK', reason: '第 1 页可用就算 OK');
    });

    test('第 1 页 432 → FAILED，diff/base 不会炸', () {
      final SubCommentProbeResult r = result(
        first: ChildPageProbe(
          label: 'T1 第 1 页',
          urlMasked: 'u',
          httpStatus: 432,
          okFlag: null,
          listPath: 'NONE',
          ids: const <String>[],
          cursors: const <ChildCursor>[],
          cursorField: null,
          cursorValue: null,
          totalNumber: null,
          dataKeys: const <String>[],
          duplicateOfPrevious: 0,
          byteLength: 0,
        ),
        totalField: 'NONE',
        verified: false,
      );
      expect(r.verdict, 'FAILED');
      expect(r.requestsToFetchAll, isNull);
      expect(r.requestsToFetchAllText, 'N/A',
          reason: '第 1 页就没通，不能假称「3 个请求能拉全」');
      expect(r.toText(), contains('FAILED'));
    });

    test('没有样本 → NO_SAMPLE（不是 FAILED）', () {
      final SubCommentProbeResult r = SubCommentProbeResult(
        mid: '5355066445792642',
        postPagesFetched: 3,
        scannedPages: const <String>['第 1 页：一级评论 0 条'],
        sample: null,
        sampleScalars: const <String>[],
        childFirst: null,
        childSecond: null,
        t3: const <T3Attempt>[],
        requestLog: const <String>[],
        requestCount: 3,
        saw432: false,
        max432Streak: 0,
        maxRequests: 16,
        totalField: 'NONE',
        totalFieldVerified: false,
        note: '没样本',
      );
      expect(r.verdict, 'NO_SAMPLE');
      expect(r.toText(), contains('NO_SAMPLE'));
      expect(r.toMarkdown(cookieLength: 573), contains('## 一、样本选择'));
    });

    test('T1 失败但 T3 拿到数据 → 仍判 OK', () {
      final SubCommentProbeResult r = result(
        first: null,
        t3: const <T3Attempt>[
          T3Attempt(
            label: 'T3-a api/comments/showChild',
            urlMasked: 'u',
            httpStatus: 200,
            okFlag: 1,
            listPath: 'data.data',
            returned: 7,
            bodyKind: 'json',
            note: '拿到 7 条',
          ),
        ],
      );
      expect(r.verdict, 'OK');
    });

    test('落盘 Markdown：七节齐全，且不含 cookie 内容与原始 id', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 11; i++) 'r$i']),
      );
      final String md = r.toMarkdown(cookieLength: 573, date: '2026-10-22');
      expect(md, startsWith('# 微博子评论（二级回复）探针（2026-10-22）'));
      for (final String h in <String>[
        '## 一、样本选择',
        '## 二、T1 hotflowChild 结果',
        '## 三、T2 总回复数字段',
        '## 四、结论（逐条回答）',
        '## 五、若可行：实现建议',
        '## 六、未取证',
        '## 七、cookie 长度',
      ]) {
        expect(md, contains(h));
      }
      expect(md, contains('`573`'));
      expect(md.contains('4932195724034522'), isFalse,
          reason: '样本 cid 必须脱敏后才能落盘');
      expect(md, contains('**11**'));
    });

    test('toText 可滚动展示的文本包含关键结论', () {
      final SubCommentProbeResult r = result(
        first: page(<String>[for (int i = 0; i < 11; i++) 'r$i']),
      );
      final String t = r.toText();
      expect(t, contains('微博子评论（二级回复）探针'));
      expect(t, contains('判定：OK'));
      expect(t, contains('游标 `max_id`'));
      expect(t, contains('来源 child'));
    });
  });
}
