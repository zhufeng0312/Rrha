import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/weibo/weibo_comment_pic_probe.dart';

/// `WeiboCommentPicProbe` 的离线验收。
///
/// 探针本体要真机跑才有结论，但**判定逻辑全是纯函数**，所以这里把
/// 「图片字段在哪、容器是 List 还是 Map、URL 在哪一层、尺寸变体叫什么、
/// 协议形态、张数、二级同构、脱敏与请求节制」逐条钉死：
/// 真机上一旦拿到响应，翻译成人话的那一步不会再出错。
///
/// 测试用的三种形态分别覆盖：
/// - A：`pics: List<Map>`，元素里 `url` + `large.url`（时间线 `mblog` 的形态）；
/// - B：`pic_infos: Map<pid, Map>`（图片 key 在外部 Map 里，元素没有 url）；
/// - C：`pic_ids: List<String>` 而**没有** `pics`（有 id 没 URL 的形态）。

Map<String, dynamic> _user({String name = '测试用户'}) => <String, dynamic>{
      'id': 1782488734,
      'screen_name': name,
      'avatar_hd': 'https://wx2.sinaimg.cn/orj480/avatar.jpg',
    };

/// 一条评论（可调 `pic_num` 与图片字段）。
Map<String, dynamic> _comment({
  String id = '4932195724034522',
  int picNum = 0,
  Object? pics,
  Object? picInfos,
  Object? picIds,
  List<Map<String, dynamic>>? replies,
  String text = '带图的评论',
}) =>
    <String, dynamic>{
      'id': id,
      'mid': id,
      'floor_number': 6,
      'text': text,
      'created_at': 'Mon Aug 07 20:15:58 +0800 2023',
      'like_count': 12,
      'pic_num': picNum,
      if (pics != null) 'pics': pics,
      if (picInfos != null) 'pic_infos': picInfos,
      if (picIds != null) 'pic_ids': picIds,
      'user': _user(),
      'readtimetype': 'comment',
      if (replies != null) 'comments': replies,
    };

/// A 形态：`pics[0]` = `{pid, url, size, geo, large:{url,size,geo}}`。
Map<String, dynamic> _picA({String pid = '6a3e9e9egy1ii3btzgmuaj22yo1o04qu'}) =>
    <String, dynamic>{
      'pid': pid,
      'url': 'https://wx2.sinaimg.cn/orj360/$pid.jpg',
      'size': 'orj360',
      'geo': <String, dynamic>{'width': 480, 'height': 270, 'croped': false},
      'large': <String, dynamic>{
        'size': 'large',
        'url': 'https://wx2.sinaimg.cn/mw2000/$pid.jpg',
        'geo': <String, dynamic>{'width': 2000, 'height': 1125},
      },
    };

String _body(List<Map<String, dynamic>> comments) {
  final String json = _json(<String, dynamic>{
    'ok': 1,
    'data': <String, dynamic>{
      'data': comments,
      'max_id': 1234567890123456789,
      'max_id_type': 0,
      'total_number': 788,
    },
  });
  return json;
}

String _json(Object? v) {
  if (v == null) return 'null';
  if (v is String) {
    return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
  if (v is num || v is bool) return '$v';
  if (v is List) return '[${v.map(_json).join(',')}]';
  if (v is Map) {
    return '{${v.entries.map((MapEntry<Object?, Object?> e) => '${_json('${e.key}')}:${_json(e.value)}').join(',')}}';
  }
  return 'null';
}

void main() {
  group('analyzePics：图片字段定位', () {
    test('A 形态 pix：pics 是 List<Map>，含量变体 url / large.url', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(picNum: 1, pics: <Object?>[_picA()]),
      );

      expect(a.found, isTrue);
      expect(a.containerKey, 'pics');
      expect(a.containerType, 'List');
      expect(a.containerLength, 1);
      expect(a.elementType, 'Map');
      expect(a.elementKeyNames, <String>['geo', 'large', 'pid', 'size', 'url']);
      expect(a.variants, containsAll(<String>['url', 'large.url']));
      expect(a.urlPaths, contains('pics[0].url'));
      expect(a.urlPaths, contains('pics[0].large.url'));
      expect(a.httpsCount, 2);
      expect(a.schemeRelativeCount, 0);
      expect(a.picNum, 1);
      expect(a.picCount, 1);
    });

    test('多图：张数取 pic_num 与容器长度较大者', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(
          picNum: 3,
          pics: <Object?>[_picA(), _picA(pid: 'aaaaaaaaaaaaaaaaaaaaaaaaaa'), _picA(pid: 'bbbbbbbbbbbbbbbbbbbbbbbbbb')],
        ),
      );
      expect(a.containerLength, 3);
      expect(a.picCount, 3);
      // 元素字段不重复累加
      expect(a.variants, <String>['url', 'large.url']);
      expect(a.urlPaths.where((String p) => p.endsWith('.url')).length, 6);
    });

    test('pic_num 与容器长度不一致时取较大值（pic_num 可能是字符串）', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(picNum: 0, pics: <Object?>[_picA()]),
      );
      expect(a.picCount, 1, reason: '容器有 1 项，不能因为 pic_num=0 就算 0 张');

      final CommentPicAnalysis b = WeiboCommentPicProbe.analyzePics(
        <String, dynamic>{'pic_num': '2', 'pics': <Object?>[_picA()]},
      );
      expect(b.picNum, 2, reason: 'pic_num 是数字字符串也要认');
      expect(b.picCount, 2);
    });

    test('pic_num=3 但 pics 只有 1 项（实测形态）→ displayCount 按容器算 1', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(picNum: 3, pics: <Object?>[_picA()]),
      );
      expect(a.picNum, 3);
      expect(a.containerLength, 1);
      expect(a.picCount, 3, reason: 'picCount 只用于对账，取较大值');
      expect(
        a.displayCount,
        1,
        reason: '实现必须按容器实际项数渲染，否则会去取不存在的下标',
      );
    });

    test('没有容器时 displayCount 退回 pic_num', () {
      final CommentPicAnalysis a =
          WeiboCommentPicProbe.analyzePics(_comment(picNum: 4));
      expect(a.found, isFalse);
      expect(a.displayCount, 4);
    });

    test('残片 URL（…/orj360/&690，实测 404）被判为不可用', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        <String, dynamic>{
          'pic_num': 1,
          'pics': <Object?>[
            <String, dynamic>{
              'url': 'https://ss1.sinaimg.cn/orj360/&690',
              'large': <String, dynamic>{
                'url': 'https://ss1.sinaimg.cn/large/&690',
              },
            },
          ],
        },
      );
      expect(a.httpsCount, 2, reason: '协议头是齐全的');
      expect(a.plausibleUrlCount, 0, reason: '文件名是 &690，实测 404');
      expect(a.distinctUrlCount, 2);
    });

    test('正常地址（末段是 pid.jpg）被判为可用', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(picNum: 1, pics: <Object?>[_picA()]),
      );
      expect(a.plausibleUrlCount, 2);
      expect(a.distinctUrlCount, 2);
    });

    // —— 实测形态的回归锁（2026-10-20，hotflow 真实响应）——
    test('实测形态：pic（真地址 Map）优先于 pics（残片 List）', () {
      final Map<String, dynamic> comment = <String, dynamic>{
        'id': '5355083253417410',
        'pic_num': 1,
        'pic': <String, dynamic>{
          'pid': '6a3e9e9egy1ii5jxawqooj20e805igm8',
          'url': 'https://wx2.sinaimg.cn/orj360/'
              '6a3e9e9egy1ii5jxawqooj20e805igm8.jpg',
          'size': 'orj360',
          'large': <String, dynamic>{
            'size': 'large',
            'url': 'https://wx2.sinaimg.cn/large/'
                '6a3e9e9egy1ii5jxawqooj20e805igm8.jpg',
          },
        },
        'pics': <Object?>[
          <String, dynamic>{
            'pid': null,
            'url': 'https://ss1.sinaimg.cn/orj360/&690',
            'size': 'orj360',
            'large': <String, dynamic>{
              'size': 'large',
              'url': 'https://ss1.sinaimg.cn/large/&690',
            },
            'duration': 0,
            'type': 'video',
          },
        ],
      };
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(comment);

      expect(a.containerKey, 'pic', reason: '必须挑到有完整地址的那个字段');
      expect(a.containerType, 'Map');
      expect(a.containerLength, 4, reason: 'pid / url / size / large 四个 key');
      expect(a.plausibleUrlCount, 2);
      expect(a.urlSamples, contains(contains('wx2.sinaimg.cn/orj360')));
      expect(a.urlSamples, isNot(contains(contains('&690'))));
    });

    test('只有残片 pics、没有 pic 时，仍会选中它但标为不可用', () {
      final Map<String, dynamic> comment = <String, dynamic>{
        'id': '1',
        'pic_num': 1,
        'pics': <Object?>[
          <String, dynamic>{
            'pid': null,
            'url': 'https://ss1.sinaimg.cn/orj360/&690',
          },
        ],
      };
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(comment);
      expect(a.containerKey, 'pics');
      expect(a.plausibleUrlCount, 0);
    });

    test('Map 语义：pic 单图对象算 1 张，不是按 key 数算', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        <String, dynamic>{
          'pic_num': 1,
          'pic': <String, dynamic>{
            'pid': 'p1',
            'url': 'https://wx2.sinaimg.cn/orj360/p1.jpg',
            'size': 'orj360',
            'geo': <String, dynamic>{'width': 1},
            'large': <String, dynamic>{'url': 'https://wx2.sinaimg.cn/large/p1.jpg'},
          },
        },
      );
      expect(a.containerLength, 5, reason: '5 个 key');
      expect(a.imageCount, 1, reason: '但只代表 1 张图');
      expect(a.displayCount, 1);
    });

    test('List 语义：pics 有几项就是几张', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(
          picNum: 2,
          pics: <Object?>[_picA(), _picA(pid: 'zzzzzzzzzzzzzzzzzzzzzzzzzz')],
        ),
      );
      expect(a.imageCount, 2);
      expect(a.displayCount, 2);
    });

    test('多图实测形态：pic_num=3 + mix_media_ids 3 项，但容器仍只 1 张', () {
      final Map<String, dynamic> comment = <String, dynamic>{
        'id': '5355289118248097',
        'pic_num': 3,
        'mix_media_ids': <Object?>[
          'http://t.cn/AXlmgHJ6',
          'http://t.cn/AXlmgHJS',
          'http://t.cn/AXlmgHJa',
        ],
        'pic': <String, dynamic>{
          'pid': '84395e04ly1ii67kl0dzkj20xw21swpi',
          'url': 'https://wx3.sinaimg.cn/orj360/'
              '84395e04ly1ii67kl0dzkj20xw21swpi.jpg',
          'size': 'orj360',
          'large': <String, dynamic>{
            'url': 'https://wx3.sinaimg.cn/large/'
                '84395e04ly1ii67kl0dzkj20xw21swpi.jpg',
          },
        },
        'pics': <Object?>[
          <String, dynamic>{
            'pid': null,
            'url': 'https://ss1.sinaimg.cn/orj360/&690',
          },
        ],
      };
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(comment);

      expect(a.picNum, 3, reason: '真张数是 3');
      expect(a.mixMediaCount, 3);
      expect(a.countTriangulated, isTrue, reason: 'pic_num 与 mix_media_ids 吻合');
      expect(a.containerKey, 'pic');
      expect(a.imageCount, 1, reason: '但图片直链只有 1 个');
      expect(a.displayCount, 1, reason: 'UI 只能显示 1 张');
    });

    test('单图时 countTriangulated 也为真（pic_num=1 / mix=1）', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        <String, dynamic>{
          'pic_num': 1,
          'mix_media_ids': <Object?>['http://t.cn/AXlR3k5T'],
          'pic': <String, dynamic>{
            'url': 'https://wx2.sinaimg.cn/orj360/a.jpg',
          },
        },
      );
      expect(a.mixMediaCount, 1);
      expect(a.countTriangulated, isTrue);
      expect(a.imageCount, 1);
    });

    test('缺 mix_media_ids 时 countTriangulated 为假，不瞎猜', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(picNum: 1, pics: <Object?>[_picA()]),
      );
      expect(a.mixMediaCount, isNull);
      expect(a.countTriangulated, isFalse);
    });

    test('B 形态：pic_infos 是 Map（pid → 图片对象），元素里没有 url 时如实报告', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(
          picNum: 2,
          picInfos: <String, dynamic>{
            'aaaa1111bbbb2222': <String, dynamic>{
              'thumbnail': <String, dynamic>{
                'url': 'https://wx1.sinaimg.cn/thumb/aaaa.jpg',
              },
              'bmiddle': <String, dynamic>{
                'url': 'https://wx1.sinaimg.cn/bmiddle/aaaa.jpg',
              },
              'original': <String, dynamic>{
                'url': 'https://wx1.sinaimg.cn/large/aaaa.jpg',
              },
            },
          },
        ),
      );
      expect(a.found, isTrue);
      expect(a.containerKey, 'pic_infos');
      expect(a.containerType, 'Map');
      expect(a.containerLength, 1);
      // pid 段被归一化掉，剩下的才是尺寸变体名
      expect(a.variants, containsAll(<String>[
        'thumbnail.url',
        'bmiddle.url',
        'original.url',
      ]));
      expect(a.httpsCount, 3);
      expect(a.otherSchemeCount, 0);
    });

    test('C 形态：只有 pic_ids（List<String>，无 URL）', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(picNum: 2, picIds: <Object?>['aaa111', 'bbb222']),
      );
      expect(a.found, isTrue);
      expect(a.containerKey, 'pic_ids');
      expect(a.containerType, 'List');
      expect(a.elementType, 'String', reason: 'pic_ids 的元素是裸 pid 字符串');
      expect(a.elementKeys, isEmpty, reason: 'String 元素没有字段');
      expect(a.urlPaths, isEmpty, reason: 'pic_ids 里没有 URL');
      expect(a.toLine(), contains('pic_ids'));
    });

    test('pic_num=0 且无图片字段 → found=false，判为无图', () {
      final CommentPicAnalysis a =
          WeiboCommentPicProbe.analyzePics(_comment());
      expect(a.found, isFalse);
      expect(a.picNum, 0);
      expect(a.picCount, 0);
      expect(a.containerKey, isNull);
      // 候选体检必须逐个如实写「不存在」，不能省略
      expect(a.candidates.length, greaterThanOrEqualTo(8));
      expect(a.candidates.every((String c) => c.endsWith('不存在')), isTrue);
      expect(a.toLine(), contains('未命中'));
    });

    test('空 List / 空 Map 不算命中（不能把 `pics: []` 当有图）', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        _comment(pics: <Object?>[], picInfos: <String, dynamic>{}),
      );
      expect(a.found, isFalse);
      expect(a.candidates.any((String c) => c.contains('pics：List（0 项）')), isTrue);
    });

    test('非 Map 输入不抛异常', () {
      expect(WeiboCommentPicProbe.analyzePics(null).found, isFalse);
      expect(WeiboCommentPicProbe.analyzePics('x').found, isFalse);
      expect(WeiboCommentPicProbe.analyzePics(<Object?>[]).found, isFalse);
    });

    test('`//` 协议相对地址被单独计数', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        <String, dynamic>{
          'pic_num': 1,
          'pics': <Object?>[
            <String, dynamic>{'url': '//wx2.sinaimg.cn/orj360/a.jpg'},
          ],
        },
      );
      expect(a.schemeRelativeCount, 1);
      expect(a.httpsCount, 0);
    });

    test('http:// 归入「其它」，不混进 https 或 //', () {
      final CommentPicAnalysis a = WeiboCommentPicProbe.analyzePics(
        <String, dynamic>{
          'pic_num': 1,
          'pics': <Object?>[
            <String, dynamic>{'url': 'http://wx2.sinaimg.cn/a.jpg'},
          ],
        },
      );
      expect(a.otherSchemeCount, 1);
      expect(a.httpsCount, 0);
      expect(a.schemeRelativeCount, 0);
    });
  });

  group('scanPage：翻页扫描', () {
    test('无图页：samples 为空、picComments=0，游标与总数照常读出来', () {
      final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
        postIndex: 1,
        pageNo: 1,
        httpStatus: 200,
        body: _body(<Map<String, dynamic>>[
          _comment(id: '1'),
          _comment(id: '2'),
        ]),
      );
      expect(scan.samples, isEmpty);
      expect(scan.page.commentCount, 2);
      expect(scan.page.picComments, 0);
      expect(scan.page.maxPicInPage, 0);
      expect(scan.page.totalValue, 788);
      expect(scan.page.okRaw, '1');
      expect(scan.page.cursor, isNotNull);
      expect(scan.page.statusText, 'HTTP 200');
      // 游标必须是脱敏摘要，不能把原值暴露出去
      expect(scan.page.cursorHint, contains('位）'));
      expect(scan.page.cursorHint, isNot(contains('1234567890123456789')));
    });

    test('有图页：命中一级评论并记录位置', () {
      final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
        postIndex: 2,
        pageNo: 3,
        httpStatus: 200,
        body: _body(<Map<String, dynamic>>[
          _comment(id: '1'),
          _comment(id: '2', picNum: 1, pics: <Object?>[_picA()]),
        ]),
      );
      expect(scan.page.picComments, 1);
      expect(scan.page.maxPicInPage, 1);
      expect(scan.samples, hasLength(1));
      final CommentPicSample s = scan.samples.first;
      expect(s.location, 'data.data[1]');
      expect(s.postIndex, 2);
      expect(s.pageNo, 3);
      expect(s.nested, isFalse);
      expect(s.commentId, '2');
      expect(s.author, '测试用户');
      expect(s.picTree.any((String l) => l.contains('large.url')), isTrue);
      expect(s.titleLine, contains('第 2 条微博 · 第 3 页'));
    });

    test('二级评论也扫：位置写成 data.data[i].comments[j]', () {
      final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
        postIndex: 1,
        pageNo: 1,
        httpStatus: 200,
        body: _body(<Map<String, dynamic>>[
          _comment(
            id: '1',
            replies: <Map<String, dynamic>>[
              _comment(id: '1-1', picNum: 2, pics: <Object?>[_picA(), _picA(pid: 'cccccccccccccccccccccccccc')]),
            ],
          ),
        ]),
      );
      expect(scan.page.commentCount, 1);
      expect(scan.page.nestedCount, 1);
      expect(scan.page.nestedPicComments, 1);
      expect(scan.samples, hasLength(1));
      final CommentPicSample s = scan.samples.first;
      expect(s.nested, isTrue);
      expect(s.location, 'data.data[0].comments[0]');
      expect(s.analysis.picCount, 2);
    });

    test('只有 pic_num>0 但没有任何图片容器 → 仍算命中（结构缺失要在报告里体现）', () {
      final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
        postIndex: 1,
        pageNo: 1,
        httpStatus: 200,
        body: _body(<Map<String, dynamic>>[_comment(picNum: 4)]),
      );
      expect(scan.samples, hasLength(1));
      final CommentPicSample s = scan.samples.first;
      expect(s.analysis.found, isFalse);
      expect(s.analysis.picCount, 4);
      expect(s.picTree.single, contains('没有非空的图片容器'));
    });

    test('sampleLimit 生效：不超过上限，但计数照样全量', () {
      final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
        postIndex: 1,
        pageNo: 1,
        httpStatus: 200,
        body: _body(<Map<String, dynamic>>[
          _comment(id: '1', picNum: 1, pics: <Object?>[_picA()]),
          _comment(id: '2', picNum: 1, pics: <Object?>[_picA()]),
          _comment(id: '3', picNum: 1, pics: <Object?>[_picA()]),
        ]),
        sampleLimit: 2,
      );
      expect(scan.samples, hasLength(2));
      expect(scan.page.picComments, 3);
    });

    test('畸形输入不抛异常（空体 / 非 JSON / data 不是 Map）', () {
      for (final String body in <String>['', 'not json', '{"ok":1}', '{"ok":1,"data":[]}']) {
        final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
          postIndex: 1,
          pageNo: 1,
          httpStatus: 200,
          body: body,
        );
        expect(scan.samples, isEmpty);
        expect(scan.page.commentCount, 0);
      }
    });

    test('跳过 user.user_token 这类票据 key（不落进字段树）', () {
      final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
        postIndex: 1,
        pageNo: 1,
        httpStatus: 200,
        body: _body(<Map<String, dynamic>>[
          <String, dynamic>{
            ..._comment(id: '1', picNum: 1, pics: <Object?>[_picA()]),
            'user': <String, dynamic>{
              ..._user(),
              'user_token': 'SECRET_TOKEN_VALUE',
            },
          },
        ]),
      );
      final String joined = scan.samples.first.fullTree.join('\n');
      expect(joined, contains('data.data[0].user.screen_name'));
      expect(joined, isNot(contains('SECRET_TOKEN_VALUE')));
      expect(joined, isNot(contains('user_token')));
    });
  });

  group('fieldsTree：深度与截断', () {
    test('深度 4 能展开到 large.url（深度 3 会截掉）', () {
      final CommentPicSample? s = WeiboCommentPicProbe.buildSample(
        _comment(picNum: 1, pics: <Object?>[_picA()]),
        postIndex: 1,
        pageNo: 1,
        commentIndex: 0,
        location: 'data.data[0]',
        nested: false,
      );
      expect(s, isNotNull);
      expect(
        s!.fullTree.any((String l) => l == 'data.data[0].pics[0].large.url : String : '
            '"https://wx2.sinaimg.cn/mw2000/6a3e9e9egy1ii3btzgmuaj22yo1o04qu.jpg"'),
        isTrue,
        reason: '深度 ${WeiboCommentPicProbe.describeDepth} 必须展开到 large.url',
      );
    });

    test('样例值超过 80 字符时截断并标注原长', () {
      final String long = 'https://wx2.sinaimg.cn/${'a' * 200}.jpg';
      final CommentPicSample? s = WeiboCommentPicProbe.buildSample(
        <String, dynamic>{
          'id': '1',
          'pic_num': 1,
          'pics': <Object?>[
            <String, dynamic>{'url': long},
          ],
          'user': _user(),
        },
        postIndex: 1,
        pageNo: 1,
        commentIndex: 0,
        location: 'data.data[0]',
        nested: false,
      );
      expect(s, isNotNull);
      final String line =
          s!.fullTree.firstWhere((String l) => l.endsWith('.url : String :') || l.contains('.url : String :'));
      expect(line, contains('原长 ${long.length}'));
    });

    test('没有图片字段时 buildSample 返回 null', () {
      expect(
        WeiboCommentPicProbe.buildSample(
          _comment(),
          postIndex: 1,
          pageNo: 1,
          commentIndex: 0,
          location: 'data.data[0]',
          nested: false,
        ),
        isNull,
      );
    });

    test('rawJson 是容器层的原始 JSON，能证明服务端到底返回了几项', () {
      final CommentPicSample? s = WeiboCommentPicProbe.buildSample(
        _comment(picNum: 3, pics: <Object?>[_picA()]),
        postIndex: 1,
        pageNo: 1,
        commentIndex: 0,
        location: 'data.data[0]',
        nested: false,
      );
      expect(s, isNotNull);
      expect(s!.rawJson, startsWith('['));
      expect(s.rawJson, contains('"size":"orj360"'));
      expect(s.rawJson, contains('"large"'));
      // 只有一个元素：JSON 里不该出现第二个 pid
      expect(
        ']'.allMatches(s.rawJson).length,
        1,
        reason: '容器只有 1 项，原始 JSON 里应当只有 1 个列表闭合',
      );
    });

    test('没有容器时 rawJson 写成明确说明，不编造', () {
      final CommentPicSample? s = WeiboCommentPicProbe.buildSample(
        _comment(picNum: 2),
        postIndex: 1,
        pageNo: 1,
        commentIndex: 0,
        location: 'data.data[0]',
        nested: false,
      );
      expect(s, isNotNull);
      expect(s!.rawJson, contains('没有非空的图片容器'));
    });

    test('huntPicUrls：pic_num=1 但无 pics 字段时，仍能在全评论里搜到地址', () {
      final Map<String, dynamic> comment = <String, dynamic>{
        'id': '1',
        'pic_num': 1,
        // 图片挂在正文 HTML 的 img 里，而不是 pics 字段
        'text': '<img src="https://ww1.sinaimg.cn/large/abc123.jpg">',
        'user': _user(),
      };
      final List<String> hits = WeiboCommentPicProbe.huntPicUrls(comment);
      expect(hits, hasLength(1));
      expect(hits.single, contains('text'));
      expect(hits.single, contains('完整'));
      expect(hits.single, contains('abc123.jpg'));
      // 候选字段体检仍然是「没有容器」——两路结论互不干扰
      expect(WeiboCommentPicProbe.analyzePics(comment).found, isFalse);
    });

    test('huntPicUrls：残片地址标成「残片」', () {
      final List<String> hits = WeiboCommentPicProbe.huntPicUrls(
        _comment(picNum: 1, pics: <Object?>[_picA()]),
      );
      expect(hits.any((String h) => h.contains('**残片**')), isFalse);
      final List<String> bad = WeiboCommentPicProbe.huntPicUrls(
        <String, dynamic>{
          'pics': <Object?>[
            <String, dynamic>{'url': 'https://ss1.sinaimg.cn/orj360/&690'},
          ],
        },
      );
      expect(bad.single, contains('**残片**'));
    });

    test('huntPicUrls：不泄漏 token 类字段', () {
      final List<String> hits = WeiboCommentPicProbe.huntPicUrls(
        <String, dynamic>{
          'user': <String, dynamic>{
            'user_token': 'https://evil.example.com/SECRET.jpg',
          },
        },
      );
      expect(hits, isEmpty);
    });
  });

  group('结论生成（三 / 四 两节的文案）', () {
    CommentPicProbeResult build({
      required List<Map<String, dynamic>> comments,
      int requests = 2,
    }) {
      final CommentPicScan scan = WeiboCommentPicProbe.scanPage(
        postIndex: 1,
        pageNo: 1,
        httpStatus: 200,
        body: _body(comments),
      );
      return CommentPicProbeResult(
        targetMid: WeiboCommentPicProbe.defaultMid,
        seed: null,
        postsScanned: 1,
        pages: <CommentPicPageStat>[scan.page],
        samples: scan.samples,
        commentsScanned: scan.scanned,
        maxPicsInOneComment: scan.maxPic,
        nestedPicComments: scan.page.nestedPicComments,
        requestLog: const <String>['#1 P1 C1 第1页 → HTTP 200'],
        requestCount: requests,
        saw432: false,
        max432Streak: 0,
        note: 'test',
      );
    }

    test('有样本：六项结论全部给出确定值', () {
      final CommentPicProbeResult r = build(
        comments: <Map<String, dynamic>>[
          _comment(picNum: 1, pics: <Object?>[_picA()]),
        ],
      );
      expect(r.found, isTrue);
      final String text = r.conclusions.join('\n');
      expect(r.conclusions.length, greaterThanOrEqualTo(6),
          reason: '六项必须全答，允许附加对账条目');
      expect(text, contains('图片列表字段名'));
      expect(text, contains('pics'));
      expect(text, contains('元素字段'));
      expect(text, contains('large.url'));
      expect(text, contains('全部是 https 绝对地址'));
      expect(text, contains('最多几张图'));
      // 二级没样本时必须明确写「不能断言同构」
      expect(text, contains('不能断言同构'));
    });

    test('无样本：六项一律「未采到」，硬结论写明不要凭字段名硬写', () {
      final CommentPicProbeResult r = build(
        comments: <Map<String, dynamic>>[_comment(), _comment(id: '2')],
      );
      expect(r.found, isFalse);
      expect(r.conclusions.length, greaterThanOrEqualTo(6),
          reason: '六项必须全答，允许附加对账条目');
      expect(
        r.conclusions.every((String c) => c.contains('未采到')),
        isTrue,
      );
      expect(r.hardConclusions.join('\n'), contains('不要凭字段名硬写'));
      expect(r.toText(), contains('（未采到带图评论）'));
      expect(r.toMarkdown(cookieLength: 495, date: '2026-10-20'), contains('NO_SAMPLE'));
    });

    test('二级样本存在且同构时明确写「同构」', () {
      final CommentPicProbeResult r = build(
        comments: <Map<String, dynamic>>[
          _comment(
            picNum: 1,
            pics: <Object?>[_picA()],
            replies: <Map<String, dynamic>>[
              _comment(id: '1-1', picNum: 1, pics: <Object?>[_picA()]),
            ],
          ),
        ],
      );
      final String text = r.conclusions.join('\n');
      expect(text, contains('同构'));
      expect(text, isNot(contains('不能断言同构')));
    });

    test('一级走 pic、二级走 pics 时，结论写「容器字段就不同」而不是乱比元素', () {
      final CommentPicProbeResult r = build(
        comments: <Map<String, dynamic>>[
          <String, dynamic>{
            ..._comment(
              picNum: 1,
              replies: <Map<String, dynamic>>[
                _comment(id: '1-1', picNum: 1, pics: <Object?>[_picA()]),
              ],
            ),
            'pic': <String, dynamic>{
              'pid': 'p1',
              'url': 'https://wx2.sinaimg.cn/orj360/p1.jpg',
              'large': <String, dynamic>{
                'url': 'https://wx2.sinaimg.cn/large/p1.jpg',
              },
            },
          },
        ],
      );
      final String text = r.conclusions.join('\n');
      expect(text, contains('容器字段就不同'));
      expect(text, contains('两个字段都要读'));
    });

    test('落盘 Markdown 含六节、cookie 只写长度、不含 token', () {
      final CommentPicProbeResult r = build(
        comments: <Map<String, dynamic>>[
          _comment(picNum: 1, pics: <Object?>[_picA()]),
        ],
        requests: 3,
      );
      final String md = r.toMarkdown(cookieLength: 495, date: '2026-10-20');
      for (final String heading in const <String>[
        '# 微博评论图片字段探针（2026-10-20）',
        '## 一、采样过程',
        '## 二、找到的带图评论样本',
        '## 三、图片字段结论',
        '## 四、给实现者的硬结论',
        '## 五、cookie 长度',
        '## 六、未取证',
      ]) {
        expect(md, contains(heading));
      }
      expect(md, contains('`495`'));
      expect(md, isNot(contains('SUB=')));
      expect(md, isNot(contains('SECRET')));
      // 目标 mid 必须脱敏（只留前 4 位）
      expect(md, isNot(contains('5355066445792642')));
      expect(md, contains('5355…'));
    });
  });

  group('judgeSeeds：兜底时间线', () {
    test('按评论数降序挑，最多 limit 条', () {
      String body(int a, int b) =>
          '{"ok":1,"data":{"cards":['
          '{"mblog":{"id":"1","mid":"1","comments_count":$a,'
          '"user":{"screen_name":"A"},"text":"x"}},'
          '{"mblog":{"id":"2","mid":"2","comments_count":$b,'
          '"user":{"screen_name":"B"},"text":"y"}},'
          '{"card_type":11}]}}';
      final List<PicProbeSeed> seeds = WeiboCommentPicProbe.judgeSeeds(
        httpStatus: 200,
        body: body(5, 99),
      );
      expect(seeds, hasLength(2));
      expect(seeds.first.commentsCount, 99);
      expect(seeds.first.mid, '2');
      expect(WeiboCommentPicProbe.judgeSeeds(
        httpStatus: 200,
        body: body(5, 99),
        limit: 1,
      ), hasLength(1));
    });

    test('畸形响应返回空列表，不抛异常', () {
      expect(
        WeiboCommentPicProbe.judgeSeeds(httpStatus: 432, body: ''),
        isEmpty,
      );
    });
  });

  group('URL 与请求节制', () {
    test('hotflowUrl 拼接顺序与 id/mid 双参数', () {
      expect(
        WeiboCommentPicProbe.hotflowUrl(postId: '1', postMid: '1'),
        endsWith('/comments/hotflow?id=1&mid=1&max_id_type=0'),
      );
      expect(
        WeiboCommentPicProbe.hotflowUrl(
          postId: '1',
          postMid: '1',
          maxId: '1234567890123456789',
          maxIdType: '1',
        ),
        endsWith('?id=1&mid=1&max_id_type=1&max_id=1234567890123456789'),
      );
    });

    test('默认目标 mid 是已知的带图评论微博', () {
      expect(WeiboCommentPicProbe.defaultMid, '5355066445792642');
    });

    test('硬上限常量在任务红线之内', () {
      expect(WeiboCommentPicProbe.maxRequests, lessThanOrEqualTo(15));
      expect(WeiboCommentPicProbe.maxPagesTotal, lessThanOrEqualTo(6));
      expect(WeiboCommentPicProbe.maxPosts, lessThanOrEqualTo(3));
      expect(WeiboCommentPicProbe.maxConsecutive432, 3);
      expect(
        WeiboCommentPicProbe.minGap.inMilliseconds,
        greaterThanOrEqualTo(2500),
      );
      expect(WeiboCommentPicProbe.itemTimeout.inSeconds, 20);
    });
  });
}
