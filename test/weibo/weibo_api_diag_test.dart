import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/weibo/weibo_diagnostics.dart';

/// 微博接口自检的离线验收。
///
/// `judge` 是纯函数，本任务的真机结论全靠它翻译成人话，所以这里把
/// 四条判定分支逐条钉死：可用 / WAF 拦截 / 仍要求登录 / 响应不可用。
///
/// 额外断言：`note` 里**永远不能出现 cookie 内容**（凭据安全红线）。
void main() {
  /// 构造一个正常的 getIndex 响应：2 条含 mblog 的卡片 + 1 条不含。
  const String okBody = '{"ok":1,"data":{"cards":['
      '{"card_type":9,"mblog":{"id":"1","text":"a"}},'
      '{"card_type":9,"mblog":{"id":"2","text":"b"}},'
      '{"card_type":11,"title":"header"}]}}';

  group('判定：接口可用', () {
    test('200 + 2 条含 mblog 的卡片 → ok=true，cardCount=2', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: 200,
        body: okBody,
      );
      expect(r.ok, isTrue);
      expect(r.cardCount, 2);
      expect(r.httpStatus, 200);
      expect(r.note, '接口可用');
    });

    test('200 + ok=1 但没有卡片 → 不算可用', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: 200,
        body: '{"ok":1,"data":{"cards":[]}}',
      );
      expect(r.ok, isFalse);
      expect(r.cardCount, 0);
    });
  });

  group('判定：风控与登录态', () {
    test('432 + 空 body → ok=false，note 含 432', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: 432,
        body: '',
      );
      expect(r.ok, isFalse);
      expect(r.cardCount, 0);
      expect(r.note, contains('432'));
    });

    test('200 + {"ok":-100} → ok=false，note 含 -100', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: 200,
        body: '{"ok":-100}',
      );
      expect(r.ok, isFalse);
      expect(r.note, contains('-100'));
    });
  });

  group('判定：异常输入', () {
    test('200 + 非法 JSON → cardCount=0，ok=false', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: 200,
        body: 'not json at all',
      );
      expect(r.cardCount, 0);
      expect(r.ok, isFalse);
      expect(r.httpStatus, 200);
    });

    test('请求本身失败（httpStatus=null）→ ok=false', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: null,
        body: '',
      );
      expect(r.ok, isFalse);
      expect(r.httpStatus, isNull);
      expect(r.note, isNotEmpty);
    });

    test('其它状态码（如 418）→ note 带上状态码', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: 418,
        body: '{"ok":1,"data":{"cards":[{"mblog":{}}]}}',
      );
      expect(r.ok, isFalse);
      expect(r.note, contains('418'));
    });

    test('cards 里的 mblog 为 null 不计入', () {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: 200,
        body: '{"ok":1,"data":{"cards":[{"mblog":null},{"mblog":{"id":"1"}}]}}',
      );
      expect(r.cardCount, 1);
      expect(r.ok, isTrue);
    });
  });

  test('凭据安全：note 里不出现传给 judge 的敏感串', () {
    // judge 的入参里根本没有 cookie，这里只是把红线写成断言：
    // 任何分支的 note 都不能回显响应体内容。
    const String secret = 'SUB=_2A25SECRETTOKEN';
    for (final int? status in <int?>[null, 200, 432, 403, 418]) {
      final WeiboApiDiagResult r = WeiboApiDiag.judge(
        httpStatus: status,
        body: '{"ok":-100,"secret":"$secret"}',
      );
      expect(r.note, isNot(contains(secret)));
    }
  });

  // ————————————————————————————————————————————————————————————
  // 分页测试相关的纯函数：extractSinceId / diffMblogIds / judgePaging
  // ————————————————————————————————————————————————————————————

  group('extractSinceId：从响应体里找游标', () {
    test('data.cardlistInfo.since_id 优先', () {
      const String body = '{"data":{"cardlistInfo":{"since_id":"12593123"},'
          '"since_id":"999"}}';
      expect(WeiboApiDiag.extractSinceId(body), '12593123');
    });

    test('没有 cardlistInfo 时退回 data.since_id', () {
      const String body = '{"data":{"since_id":"424242"}}';
      expect(WeiboApiDiag.extractSinceId(body), '424242');
    });

    test('没有 data 时退回顶层 cardlistInfo.since_id', () {
      const String body = '{"cardlistInfo":{"since_id":"777"}}';
      expect(WeiboApiDiag.extractSinceId(body), '777');
    });

    test('退回顶层 since_id', () {
      expect(WeiboApiDiag.extractSinceId('{"since_id":12345}'), '12345');
    });

    test('19 位大整数游标原样保留，不丢精度', () {
      const String big = '4201234567890123456';
      final String body = '{"data":{"cardlistInfo":{"since_id":$big}}}';
      final String? got = WeiboApiDiag.extractSinceId(body);
      expect(got, big);
      expect(got!.length, 19);
    });

    test('没有任何游标字段 → null', () {
      expect(
        WeiboApiDiag.extractSinceId('{"ok":1,"data":{"cards":[]}}'),
        isNull,
      );
    });

    test('游标为空串 / null 视作没有', () {
      expect(
        WeiboApiDiag.extractSinceId('{"data":{"cardlistInfo":{"since_id":""}}}'),
        isNull,
      );
      expect(
        WeiboApiDiag.extractSinceId(
          '{"data":{"cardlistInfo":{"since_id":null},"since_id":""}}',
        ),
        isNull,
      );
    });

    test('非法 JSON 不崩，返回 null', () {
      expect(WeiboApiDiag.extractSinceId('not json'), isNull);
      expect(WeiboApiDiag.extractSinceId(''), isNull);
      expect(WeiboApiDiag.extractSinceId('[1,2,3]'), isNull);
      expect(WeiboApiDiag.extractSinceId('{"data":"不是对象"}'), isNull);
    });
  });

  group('diffMblogIds：两页差异', () {
    String page(List<String> ids) => '{"ok":1,"data":{"cards":['
        '${ids.map((String id) => '{"mblog":{"id":"$id"}}').join(',')}]}}';

    test('两页完全无重复 → duplicate=0, novel=2', () {
      final ({int duplicate, int novel}) d = WeiboApiDiag.diffMblogIds(
        page(<String>['1', '2']),
        page(<String>['3', '4']),
      );
      expect(d.duplicate, 0);
      expect(d.novel, 2);
    });

    test('两页部分重复 → duplicate=1, novel=1', () {
      final ({int duplicate, int novel}) d = WeiboApiDiag.diffMblogIds(
        page(<String>['1', '2']),
        page(<String>['2', '3']),
      );
      expect(d.duplicate, 1);
      expect(d.novel, 1);
    });

    test('两页完全相同 → novel=0', () {
      final ({int duplicate, int novel}) d = WeiboApiDiag.diffMblogIds(
        page(<String>['1', '2']),
        page(<String>['1', '2']),
      );
      expect(d.duplicate, 2);
      expect(d.novel, 0);
    });

    test('id 缺失时退回 mid', () {
      const String p1 = '{"data":{"cards":[{"mblog":{"mid":"555"}}]}}';
      final ({int duplicate, int novel}) d = WeiboApiDiag.diffMblogIds(
        p1,
        page(<String>['555']),
      );
      expect(d.duplicate, 1);
      expect(d.novel, 0);
    });

    test('非法 JSON 当作空页，不崩', () {
      final ({int duplicate, int novel}) d = WeiboApiDiag.diffMblogIds(
        'not json',
        '',
      );
      expect(d.duplicate, 0);
      expect(d.novel, 0);
    });
  });

  group('judgePaging：人话结论', () {
    const String p1Body = '{"ok":1,"data":{"cardlistInfo":{"since_id":"100"},'
        '"cards":[{"mblog":{"id":"1"}},{"mblog":{"id":"2"}}]}}';
    const String p2Body = '{"ok":1,"data":{"cardlistInfo":{"since_id":"200"},'
        '"cards":[{"mblog":{"id":"3"}},{"mblog":{"id":"4"}}]}}';

    test('第 1 页没游标 → note=未找到 since_id，且第 2 页未发出', () {
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 200,
        page1Body: '{"ok":1,"data":{"cards":[{"mblog":{"id":"1"}}]}}',
        sinceIdFromPage1: null,
        page2Status: null,
        page2Body: '',
      );
      expect(r.note, '未找到 since_id 字段');
      expect(r.page2Status, 0);
      expect(r.page1Cards, 1);
      expect(r.cursorAdvanced, isFalse);
    });

    test('两页全新增且游标推进 → 分页可用', () {
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 200,
        page1Body: p1Body,
        sinceIdFromPage1: WeiboApiDiag.extractSinceId(p1Body),
        page2Status: 200,
        page2Body: p2Body,
      );
      expect(r.page1Cards, 2);
      expect(r.page2Cards, 2);
      expect(r.duplicateCount, 0);
      expect(r.newCount, 2);
      expect(r.cursorAdvanced, isTrue);
      expect(r.note, contains('分页可用'));
    });

    test('第 2 页全重复 → 分页异常', () {
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 200,
        page1Body: p1Body,
        sinceIdFromPage1: '100',
        page2Status: 200,
        page2Body: p1Body,
      );
      expect(r.newCount, 0);
      expect(r.duplicateCount, 2);
      expect(r.note, contains('分页异常'));
    });

    test('第 1 页 432 → 接口不可用', () {
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 432,
        page1Body: '',
        sinceIdFromPage1: null,
        page2Status: null,
        page2Body: '',
      );
      expect(r.note, contains('432'));
    });

    test('第 1 页请求失败 → 接口不可用', () {
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: null,
        page1Body: '',
        sinceIdFromPage1: null,
        page2Status: null,
        page2Body: '',
      );
      expect(r.page1Status, 0);
      expect(r.note, contains('不可用'));
    });

    test('第 2 页请求失败 → 分页不可用', () {
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 200,
        page1Body: p1Body,
        sinceIdFromPage1: '100',
        page2Status: null,
        page2Body: '',
      );
      expect(r.note, contains('分页不可用'));
      expect(r.cursorAdvanced, isFalse);
    });

    test('第 2 页 432 → 分页不可用（带状态码）', () {
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 200,
        page1Body: p1Body,
        sinceIdFromPage1: '100',
        page2Status: 432,
        page2Body: '',
      );
      expect(r.note, contains('432'));
    });

    test('游标摘要只给前 8 位 + 长度，不是完整游标', () {
      const String long = '4201234567890123456';
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 200,
        page1Body: p1Body,
        sinceIdFromPage1: long,
        page2Status: 200,
        page2Body: p2Body,
      );
      expect(r.page1CursorHint, startsWith('42012345'));
      expect(r.page1CursorHint, isNot(contains(long)));
      expect(r.page1CursorHint, contains('19 位'));
    });

    test('凭据安全：note 与游标摘要里不出现 cookie 串', () {
      const String secret = 'SUB=_2A25SECRETTOKEN';
      final WeiboPagingDiagResult r = WeiboApiDiag.judgePaging(
        page1Status: 200,
        page1Body: p1Body,
        sinceIdFromPage1: '100',
        page2Status: 200,
        page2Body: p2Body,
      );
      expect(r.note, isNot(contains(secret)));
      expect(r.page1CursorHint, isNot(contains(secret)));
      expect(r.page2CursorHint, isNot(contains(secret)));
    });
  });

  // ————————————————————————————————————————————————————————————
  // 字段结构 dump：describeMblog / judgeStructure
  // ————————————————————————————————————————————————————————————

  group('describeMblog：结构展开', () {
    test('嵌套 map/list 逐层展开，数组下标写成 [i]', () {
      final Map<String, Object?> mblog = <String, Object?>{
        'text': '你好！',
        'id': 4900000000000000,
        'pics': <Object?>[
          <String, Object?>{
            'pid': 'p1',
            'url': 'https://x/a.jpg',
            'large': <String, Object?>{'url': 'r'},
          },
        ],
        'user': <String, Object?>{'screen_name': '某人'},
      };
      final List<String> lines = WeiboApiDiag.describeMblog(mblog);

      expect(lines, contains('mblog.text : String : "你好！"'));
      expect(lines, contains('mblog.id : int : 4900000000000000'));
      expect(lines, contains('mblog.pics[0].pid : String : "p1"'));
      expect(lines, contains('mblog.pics[0].url : String : "https://x/a.jpg"'));
      expect(lines, contains('mblog.user.screen_name : String : "某人"'));
      // mblog(0) → pics[0].large(3) → 深度 4 才到上限，所以 large 里的 key 可见。
      expect(lines, contains('mblog.pics[0].large.url : String : "r"'));
    });

    test('值截断：超过 80 字符的串被截断并标注原长', () {
      final String long = 'a' * 200;
      final List<String> lines = WeiboApiDiag.describeMblog(
        <String, Object?>{'text': long},
      );
      expect(lines.length, 1);
      final String line = lines.single;
      expect(line, contains('…'));
      // 「mblog.text : String : " + 80 字符 + 截断说明」
      expect(line.contains(long), isFalse);
      expect(line, contains('原长 200'));
    });

    test('深度上限：超过 4 层不再展开，只留一句提示', () {
      final Map<String, Object?> deep = <String, Object?>{
        'a': <String, Object?>{
          'b': <String, Object?>{
            'c': <String, Object?>{
              'd': <String, Object?>{'e': '不再展开'},
            },
          },
        },
      };
      final List<String> lines = WeiboApiDiag.describeMblog(deep);
      // mblog(0) → a(1) → b(2) → c(3) → d(4) 到深度上限，d 的子节点不再展开。
      expect(lines, contains('mblog.a.b.c.d : Map : …（深度上限，1 个 key）'));
      expect(lines.any((String l) => l.contains('mblog.a.b.c.d.e')), isFalse);
      expect(lines.any((String l) => l.contains('不再展开')), isFalse);
    });

    test('null 安全：null / 空 map 返回空列表', () {
      expect(WeiboApiDiag.describeMblog(null), isEmpty);
      expect(WeiboApiDiag.describeMblog(<String, Object?>{}), isEmpty);
    });

    test('非 Map 输入不崩', () {
      expect(WeiboApiDiag.describeMblog('字符串'), isEmpty);
      expect(WeiboApiDiag.describeMblog(<Object?>[1, 2, 3]), isEmpty);
      expect(WeiboApiDiag.describeMblog(42), isEmpty);
      expect(WeiboApiDiag.describeMblog(true), isEmpty);
    });

    test('空容器单独成行，空值标成 null 类型', () {
      final List<String> lines = WeiboApiDiag.describeMblog(<String, Object?>{
        'pics': <Object?>[],
        'extra': <String, Object?>{},
        'retweeted_status': null,
      });
      expect(lines, contains('mblog.pics : List : []'));
      expect(lines, contains('mblog.extra : Map : {}'));
      expect(lines, contains('mblog.retweeted_status : null : null'));
    });

    test('retweeted_status 内部也会被递归展开', () {
      final Map<String, Object?> mblog = <String, Object?>{
        'id': '1',
        'retweeted_status': <String, Object?>{
          'id': '9',
          'text': '原动态',
          'user': <String, Object?>{'screen_name': '原作者'},
        },
      };
      final List<String> lines = WeiboApiDiag.describeMblog(mblog);
      expect(lines, contains('mblog.retweeted_status.id : String : "9"'));
      expect(
        lines,
        contains('mblog.retweeted_status.user.screen_name : String : "原作者"'),
      );
    });

    test('行数上限：最多 200 行', () {
      final Map<String, Object?> wide = <String, Object?>{
        for (int i = 0; i < 500; i++) 'k$i': i,
      };
      final List<String> lines = WeiboApiDiag.describeMblog(wide);
      expect(lines.length, 200);
    });
  });

  group('judgeStructure：响应体整理', () {
    const String body = '{"ok":1,"data":{"cardlistInfo":{"since_id":"123",'
        '"total":42},"cards":['
        '{"card_type":11,"title":"t"},'
        '{"card_type":9,"mblog":{"id":"1","text":"a","user":{"screen_name":"u"}}},'
        '{"card_type":9,"mblog":{"id":"2","text":"b"}}'
        ']}}';

    test('card_type 分布 / 空 mblog 计数 / cardlistInfo keys', () {
      final WeiboStructureDump d = WeiboApiDiag.judgeStructure(
        httpStatus: 200,
        body: body,
      );
      expect(d.httpStatus, 200);
      expect(d.cardTotal, 3);
      expect(d.cardTypeCounts['9'], 2);
      expect(d.cardTypeCounts['11'], 1);
      expect(d.emptyMblogCount, 1);
      expect(d.cardlistInfoKeys, containsAll(<String>['since_id', 'total']));
      expect(d.sinceIdPresent, isTrue);
      expect(d.note, contains('mblog'));
    });

    test('只用第一条含 mblog 的卡片展开', () {
      final WeiboStructureDump d = WeiboApiDiag.judgeStructure(
        httpStatus: 200,
        body: body,
      );
      expect(d.mblogLines, contains('mblog.id : String : "1"'));
      expect(d.mblogLines.any((String l) => l.contains('"b"')), isFalse);
    });

    test('非 200 / 非法 JSON 不崩，给出人话结论', () {
      final WeiboStructureDump bad = WeiboApiDiag.judgeStructure(
        httpStatus: 432,
        body: 'not json',
      );
      expect(bad.httpStatus, 432);
      expect(bad.cardTotal, 0);
      expect(bad.mblogLines, isEmpty);
      expect(bad.note, contains('432'));

      final WeiboStructureDump down = WeiboApiDiag.judgeStructure(
        httpStatus: null,
        body: '',
      );
      expect(down.httpStatus, isNull);
      expect(down.note, contains('请求失败'));
      expect(down.cardlistInfoKeys, isEmpty);
      expect(down.sinceIdPresent, isFalse);
    });

    test('toText 汇总成文本且不含 cookie 内容', () {
      const String secret = 'SUB=_2A25SECRETTOKEN';
      final WeiboStructureDump d = WeiboApiDiag.judgeStructure(
        httpStatus: 200,
        body: body,
      );
      final String text = d.toText();
      expect(text, contains('card_type=9 × 2'));
      expect(text, contains('mblog.user.screen_name : String : "u"'));
      expect(text, isNot(contains(secret)));
    });
  });

  group('pickSamples：按类型挑样本', () {
    /// 造一张含 mblog 的卡片。
    Map<String, Object?> card(Map<String, Object?> mblog) =>
        <String, Object?>{'card_type': 9, 'mblog': mblog};

    test('三类都有样本：各挑第一条，返回各自 index', () {
      final List<Object?> cards = <Object?>[
        card(<String, Object?>{'id': '0', 'text': '纯文字', 'pic_num': 0}),
        card(<String, Object?>{'id': '1', 'text': '带图', 'pic_num': 4}),
        card(<String, Object?>{
          'id': '2',
          'text': '转发',
          'retweeted_status': <String, Object?>{'id': '9'},
        }),
        card(<String, Object?>{
          'id': '3',
          'text': '视频',
          'page_info': <String, Object?>{'type': 'video'},
        }),
        // 第二条带图：不应被选中（只要第一条）。
        card(<String, Object?>{'id': '4', 'text': '也带图', 'pic_num': 9}),
      ];
      final WeiboSamplePicks picks = WeiboApiDiag.pickSamples(cards);
      expect(picks.picsIndex, 1);
      expect(picks.retweetedIndex, 2);
      expect(picks.pageInfoIndex, 3);
      expect(picks.isEmpty, isFalse);
    });

    test('有图 / 无图：pic_num=0 不算有图', () {
      final List<Object?> noPics = <Object?>[
        card(<String, Object?>{'id': '0', 'pic_num': 0, 'pics': <Object?>[]}),
      ];
      expect(WeiboApiDiag.pickSamples(noPics).picsIndex, isNull);

      final List<Object?> withPics = <Object?>[
        card(<String, Object?>{'id': '0', 'pic_num': 1}),
      ];
      expect(WeiboApiDiag.pickSamples(withPics).picsIndex, 0);
    });

    test('有转发 / 无转发：retweeted_status 为 null 不算转发', () {
      final List<Object?> none = <Object?>[
        card(<String, Object?>{'id': '0', 'retweeted_status': null}),
      ];
      expect(WeiboApiDiag.pickSamples(none).retweetedIndex, isNull);

      final List<Object?> one = <Object?>[
        card(<String, Object?>{'id': '0', 'retweeted_status': null}),
        card(<String, Object?>{'id': '1', 'retweeted_status': <String, Object?>{}}),
      ];
      expect(WeiboApiDiag.pickSamples(one).retweetedIndex, 1);
    });

    test('有 page_info / 无：null 不算页面卡', () {
      final List<Object?> none = <Object?>[
        card(<String, Object?>{'id': '0', 'page_info': null}),
      ];
      expect(WeiboApiDiag.pickSamples(none).pageInfoIndex, isNull);

      final List<Object?> one = <Object?>[
        card(<String, Object?>{'id': '0'}),
        card(<String, Object?>{'id': '1', 'page_info': <String, Object?>{}}),
      ];
      expect(WeiboApiDiag.pickSamples(one).pageInfoIndex, 1);
    });

    test('全都没有样本：三个 index 都是 null，isEmpty=true', () {
      final List<Object?> cards = <Object?>[
        card(<String, Object?>{'id': '0', 'pic_num': 0}),
        card(<String, Object?>{'id': '1', 'pic_num': 0}),
      ];
      final WeiboSamplePicks picks = WeiboApiDiag.pickSamples(cards);
      expect(picks.picsIndex, isNull);
      expect(picks.retweetedIndex, isNull);
      expect(picks.pageInfoIndex, isNull);
      expect(picks.isEmpty, isTrue);
    });

    test('空列表 / 不含 mblog 的卡片：不崩，全 null', () {
      expect(WeiboApiDiag.pickSamples(<Object?>[]).isEmpty, isTrue);
      final List<Object?> header = <Object?>[
        <String, Object?>{'card_type': 11, 'title': 'header'},
      ];
      expect(WeiboApiDiag.pickSamples(header).isEmpty, isTrue);
    });

    test('序号只数含 mblog 的卡片，header 卡不占号', () {
      final List<Object?> cards = <Object?>[
        <String, Object?>{'card_type': 11, 'title': 'header'},
        card(<String, Object?>{'id': '0', 'pic_num': 0}),
        card(<String, Object?>{'id': '1', 'pic_num': 3}),
      ];
      expect(WeiboApiDiag.pickSamples(cards).picsIndex, 1);
    });
  });

  group('profileMblog：单条类型标记', () {
    test('摘要行格式符合约定', () {
      final WeiboMblogProfile? p = WeiboApiDiag.profileMblog(<String, Object?>{
        'pic_num': 4,
        'isLongText': true,
        'textLength': 180,
        'title': <String, Object?>{'text': '置顶'},
      });
      expect(p, isNotNull);
      expect(p!.hasPics, isTrue);
      expect(p.hasRetweeted, isFalse);
      expect(p.hasPageInfo, isFalse);
      expect(p.isLongText, isTrue);
      expect(p.textLength, 180);
      final String line = p.toSummaryLine();
      expect(line, startsWith('#0 '));
      expect(line, contains('pic_num=4'));
      expect(line, contains('retweeted=no'));
      expect(line, contains('page_info=no'));
      expect(line, contains('longText=yes'));
      expect(line, contains('textLen=180'));
      expect(line, contains('「置顶」'));
    });

    test('缺 textLength 时退回 text 的字符串长度', () {
      final WeiboMblogProfile? p = WeiboApiDiag.profileMblog(
        <String, Object?>{'text': '一二三四五'},
      );
      expect(p, isNotNull);
      expect(p!.textLength, 5);
      expect(p.picNum, 0);
      expect(p.toSummaryLine(), isNot(contains('「')));
    });

    test('非 Map 输入返回 null', () {
      expect(WeiboApiDiag.profileMblog(null), isNull);
      expect(WeiboApiDiag.profileMblog('x'), isNull);
      expect(WeiboApiDiag.profileMblog(<Object?>[1]), isNull);
    });
  });

  group('judgeRichStructure：全量分类采样', () {
    const String body = '{"ok":1,"data":{"cardlistInfo":{"since_id":"123",'
        '"total":42},"cards":['
        '{"card_type":11,"title":"t"},'
        '{"card_type":9,"mblog":{"id":"0","text":"置顶纯文字","pic_num":0,'
        '"textLength":1111,"isLongText":true,'
        '"title":{"text":"置顶"}}},'
        '{"card_type":9,"mblog":{"id":"1","text":"带图","pic_num":4,'
        '"pics":[{"pid":"p1","url":"https://x/a.jpg",'
        '"large":{"url":"https://x/b.jpg"}}]}},'
        '{"card_type":9,"mblog":{"id":"2","text":"转发",'
        '"retweeted_status":{"id":"9","text":"原动态",'
        '"user":{"screen_name":"原作者"},'
        '"pics":[{"url":"https://x/c.jpg"}]}}},'
        '{"card_type":9,"mblog":{"id":"3","text":"视频",'
        '"page_info":{"type":"video","media_info":{"duration":35}}}}'
        ']}}';

    test('摘要表覆盖全部 mblog，行数与 mblog 数一致', () {
      final WeiboRichStructureDump d = WeiboApiDiag.judgeRichStructure(
        httpStatus: 200,
        body: body,
      );
      expect(d.profiles.length, 4);
      expect(d.emptyMblogCount, 1);
      expect(d.cardTypeCounts['9'], 4);
      expect(d.cardTypeCounts['11'], 1);
      expect(d.profiles[0].toSummaryLine(), contains('「置顶」'));
      expect(d.profiles[0].isLongText, isTrue);
      expect(d.profiles[1].hasPics, isTrue);
      expect(d.profiles[2].hasRetweeted, isTrue);
      expect(d.profiles[3].hasPageInfo, isTrue);
    });

    test('三类样本各挑第一条，index 与摘要表序号一致', () {
      final WeiboRichStructureDump d = WeiboApiDiag.judgeRichStructure(
        httpStatus: 200,
        body: body,
      );
      expect(d.picks.picsIndex, 1);
      expect(d.picks.retweetedIndex, 2);
      expect(d.picks.pageInfoIndex, 3);
      expect(d.picSampleCount, 1);
      expect(d.retweetedSampleCount, 1);
      expect(d.pageInfoSampleCount, 1);
      expect(d.note, contains('全量分类采样'));
    });

    test('toText 分段展开：每段标注样本来源 #N，含 pics/转发/page_info 字段', () {
      final String text = WeiboApiDiag.judgeRichStructure(
        httpStatus: 200,
        body: body,
      ).toText();
      // 全量摘要表
      expect(text, contains('全量分类摘要'));
      expect(text, contains('#0 pic_num=0'));
      expect(text, contains('#1 pic_num=4'));
      // 配图段：元素字段看得见
      expect(text, contains('本类样本来自 #1'));
      expect(text, contains('mblog.pics[0].pid : String : "p1"'));
      expect(text, contains('mblog.pics[0].large.url : String : "https://x/b.jpg"'));
      // 转发段：retweeted_status 内部结构
      expect(text, contains('本类样本来自 #2'));
      expect(text, contains('mblog.retweeted_status.id : String : "9"'));
      expect(
        text,
        contains('mblog.retweeted_status.user.screen_name : String : "原作者"'),
      );
      // 页面卡段：media_info
      expect(text, contains('本类样本来自 #3'));
      expect(text, contains('mblog.page_info.media_info.duration : int : 35'));
      // 分隔线
      expect(text, contains('════════════════════════════════════'));
    });

    test('某类没有样本时明确写「未找到」，不拿别的字段硬凑', () {
      const String onlyText = '{"ok":1,"data":{"cards":['
          '{"card_type":9,"mblog":{"id":"0","text":"纯文字","pic_num":0}}'
          ']}}';
      final WeiboRichStructureDump d = WeiboApiDiag.judgeRichStructure(
        httpStatus: 200,
        body: onlyText,
      );
      expect(d.picks.isEmpty, isTrue);
      final String text = d.toText();
      expect(text, contains('未找到含 pics 的样本（1 条中 0 条）'));
      expect(text, contains('未找到含 retweeted_status 的样本（1 条中 0 条）'));
      expect(text, contains('未找到含 page_info 的样本（1 条中 0 条）'));
      expect(text, isNot(contains('★ 样本 #')));
    });

    test('非 200 / 非法 JSON 不崩，全空且无样本', () {
      final WeiboRichStructureDump bad = WeiboApiDiag.judgeRichStructure(
        httpStatus: 432,
        body: 'not json',
      );
      expect(bad.httpStatus, 432);
      expect(bad.cardTotal, 0);
      expect(bad.profiles, isEmpty);
      expect(bad.picks.isEmpty, isTrue);
      expect(bad.note, contains('432'));
      expect(bad.toText(), contains('没有可展示的 mblog'));

      final WeiboRichStructureDump down = WeiboApiDiag.judgeRichStructure(
        httpStatus: null,
        body: '',
      );
      expect(down.httpStatus, isNull);
      expect(down.note, contains('请求失败'));
      expect(down.cardlistInfoKeys, isEmpty);
      expect(down.sinceIdPresent, isFalse);
    });

    test('凭据安全：toText 与 note 里不出现 cookie 串', () {
      const String secret = 'SUB=_2A25SECRETTOKEN';
      final WeiboRichStructureDump d = WeiboApiDiag.judgeRichStructure(
        httpStatus: 200,
        body: body,
      );
      expect(d.toText(), isNot(contains(secret)));
      expect(d.note, isNot(contains(secret)));
    });
  });
}
