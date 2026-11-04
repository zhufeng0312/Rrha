import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/weibo/weibo_comment_parser.dart';

/// 评论配图解析的离线验收。
///
/// 字段结构全部来自 `.env/weibo_comment_pics_probe.md` 的实测：
/// - 真字段是 **`pic`（单数 Map）**，5 个 key：`pid`/`url`/`size`/`geo`/`large`；
/// - `pics`（复数 List）在这些样本里是 **404 残片**（`.../orj360/&690`、`pid:null`）；
/// - 尺寸只有两档：`url` = `orj360`（长边 360）、`large.url` = `large`（原图）；
/// - **本接口一条评论只回 1 张图**，`pic_num` 会大于实际张数。

/// 一条「干净」的 `pic`（样本 1 原样）。
Map<String, dynamic> _pic({
  String pid = '6a3e9e9egy1ii5jxawqooj20e805igm8',
  String? url =
      'https://wx2.sinaimg.cn/orj360/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg',
  Object? geo = const <String, dynamic>{
    'width': '512',
    'height': '198',
    'croped': false,
  },
  String largeUrl =
      'https://wx2.sinaimg.cn/large/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg',
  bool withLarge = true,
}) =>
    <String, dynamic>{
      'pid': pid,
      'url': url,
      'size': 'orj360',
      'geo': geo,
      if (withLarge)
        'large': <String, dynamic>{
          'size': 'large',
          'url': largeUrl,
          'geo': geo,
        },
    };

/// 一条残片（样本 1 同一评论里 `pics[0]` 的原样）。
Map<String, dynamic> _fragment() => <String, dynamic>{
      'pid': null,
      'url': 'https://ss1.sinaimg.cn/orj360/&690',
      'size': 'orj360',
      'geo': false,
      'large': <String, dynamic>{
        'size': 'large',
        'url': 'https://ss1.sinaimg.cn/large/&690',
        'geo': false,
      },
      'duration': 0,
      'type': 'video',
    };

Map<String, dynamic> _comment({
  String id = '4932195724034522',
  Map<String, dynamic>? pic,
  List<Map<String, dynamic>>? pics,
  Object? picNum,
  List<Map<String, dynamic>>? replies,
}) =>
    <String, dynamic>{
      'id': id,
      'rootid': id,
      'text': '测试评论',
      'created_at': 'Mon Aug 07 20:15:58 +0800 2023',
      'like_count': 12,
      'user': <String, dynamic>{
        'screen_name': '若叶睦子米Mutsumi',
        'avatar_hd': 'https://wx1.sinaimg.cn/orj480/hd.jpg',
      },
      if (pic != null) 'pic': pic,
      if (pics != null) 'pics': pics,
      if (picNum != null) 'pic_num': picNum,
      if (replies != null) 'comments': replies,
    };

Map<String, dynamic> _page(List<Map<String, dynamic>> comments) =>
    <String, dynamic>{
      'ok': 1,
      'data': <String, dynamic>{
        'data': comments,
        'max_id': 182712657086119,
        'max_id_type': 0,
        'total_number': 10,
      },
    };

BiliComment _parseOne(Map<String, dynamic> raw) {
  final BiliComment? c = WeiboCommentParser.parseOne(raw);
  expect(c, isNotNull, reason: '有 id 的评论不该被丢掉');
  return c!;
}

void main() {
  group('pic（单数 Map）', () {
    test('同时有 large.url 与 url 时取 large（原图优先于 orj360）', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(),
        picNum: 1,
      ));

      expect(
        c.images,
        <String>['https://wx2.sinaimg.cn/large/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg'],
        reason: 'large 是原尺寸（33KB），url 只是长边 360 的缩略（11KB）',
      );
      expect(c.images.single.contains('/large/'), isTrue);
      expect(c.imageCount, 1);
    });

    test('只有 url 没有 large → 回退取 url', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(withLarge: false),
        picNum: 1,
      ));

      expect(
        c.images,
        <String>['https://wx2.sinaimg.cn/orj360/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg'],
      );
      expect(c.images.single.contains('/orj360/'), isTrue);
    });

    test('large 存在但 url 为空 → 回退 pic.url', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(largeUrl: ''),
        picNum: 1,
      ));

      expect(c.images.single.contains('/orj360/'), isTrue);
    });
  });

  group('pics（复数 List）', () {
    test('正常一项 → 取到（large 优先）', () {
      final BiliComment c = _parseOne(_comment(
        pics: <Map<String, dynamic>>[_pic()],
        picNum: 1,
      ));

      expect(c.images.length, 1);
      expect(c.images.single.contains('/large/'), isTrue);
    });

    test('残片（.../orj360/&690、pid=null）→ 被过滤，images 为空', () {
      final BiliComment c = _parseOne(_comment(
        pics: <Map<String, dynamic>>[_fragment()],
        picNum: 1,
      ));

      expect(c.images, isEmpty, reason: '残片实测 HTTP 404，宁可丢掉也不显示裂图');
    });

    test('残片与正常项混在一起 → 只留正常项', () {
      final BiliComment c = _parseOne(_comment(
        pics: <Map<String, dynamic>>[_fragment(), _pic()],
        picNum: 2,
      ));

      expect(c.images.length, 1);
      expect(c.images.single.contains('&'), isFalse);
    });
  });

  group('pic_num 只是计数', () {
    test('pic_num=3 但只给 1 张 → imageCount=3、images.length=1', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(),
        picNum: 3,
      ));

      expect(c.imageCount, 3, reason: '角标要显示「共 3 张」');
      expect(c.images.length, 1, reason: '接口只给 1 张，多图张数拿不到');
      // 钉住红线：绝不能拿 pic_num 去索引 images。
      expect(c.imageCount > c.images.length, isTrue);
    });

    test('pic_num 是 String 也能取到（类型容错）', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(),
        picNum: '3',
      ));

      expect(c.imageCount, 3);
      expect(c.images.length, 1);
    });

    test('pic 与 pics 都不存在但 pic_num=1 → 不崩、images 空、imageCount=1', () {
      final BiliComment c = _parseOne(_comment(picNum: 1));

      expect(c.images, isEmpty);
      expect(c.imageCount, 1);
      expect(c.message, '测试评论');
    });
  });

  group('pic.geo.width 类型不一致（String / int）都不崩', () {
    test('String "512"', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(geo: const <String, dynamic>{'width': '512', 'height': '198'}),
        picNum: 1,
      ));
      expect(c.images.length, 1);
    });

    test('int 360', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(geo: const <String, dynamic>{'width': 360, 'height': 198}),
        picNum: 1,
      ));
      expect(c.images.length, 1);
    });

    test('geo 是 bool false / 缺省也不影响取图', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(geo: false),
        picNum: 1,
      ));
      expect(c.images.length, 1);
    });
  });

  group('二级评论', () {
    test('登录在 comments[] 里的图片也能取到（实测落在 pics）', () {
      final BiliComment c = _parseOne(_comment(
        pic: _pic(),
        picNum: 1,
        replies: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': '4932195724034523',
            'rootid': '4932195724034522',
            'text': '二级评论带图',
            'created_at': 'Mon Aug 07 20:20:00 +0800 2023',
            'user': <String, dynamic>{'screen_name': '笑墨辞'},
            'pics': <Map<String, dynamic>>[_pic()],
            'pic_num': 1,
          },
        ],
      ));

      expect(c.replies.length, 1);
      final BiliComment sub = c.replies.single;
      expect(sub.images.length, 1);
      expect(sub.images.single.contains('/large/'), isTrue);
      expect(sub.imageCount, 1);
    });

    test('二级评论残片同样被过滤', () {
      final BiliComment c = _parseOne(_comment(
        replies: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': '4932195724034524',
            'text': '只有残片',
            'user': <String, dynamic>{'screen_name': '过客'},
            'pics': <Map<String, dynamic>>[_fragment()],
            'pic_num': 1,
          },
        ],
      ));

      expect(c.replies.single.images, isEmpty);
    });
  });

  group('容错', () {
    test('非法 JSON / 空 data → 不崩，返回空页', () {
      expect(WeiboCommentParser.parsePage(null).comments, isEmpty);
      expect(WeiboCommentParser.parsePage('not json').comments, isEmpty);
      expect(WeiboCommentParser.parsePage(const <String, dynamic>{}).comments, isEmpty);
      expect(WeiboCommentParser.parseOne(null), isNull);
      expect(WeiboCommentParser.parseOne('x'), isNull);
    });

    test('pic 是字符串 / pics 是 Map 等畸形形态 → 不崩、images 空', () {
      final BiliComment c = _parseOne(<String, dynamic>{
        'id': '4932195724034525',
        'text': '畸形',
        'user': <String, dynamic>{'screen_name': 'x'},
        'pic': 'not a map',
        'pics': <String, dynamic>{'url': 'https://wx2.sinaimg.cn/large/a.jpg'},
      });
      expect(c.images, isEmpty);
      expect(c.imageCount, 0);
    });

    test('没有任何图片字段的评论 → images 空、imageCount 0（B 站同款形态）', () {
      final BiliComment c = _parseOne(_comment());
      expect(c.images, isEmpty);
      expect(c.imageCount, 0);
    });

    test('整页解析里图片也能穿过 parsePage', () {
      final CommentPage page = WeiboCommentParser.parsePage(
        _page(<Map<String, dynamic>>[_comment(pic: _pic(), picNum: 3)]),
      );
      final BiliComment c = page.comments.single;
      expect(c.images.length, 1);
      expect(c.imageCount, 3);
    });
  });

  group('模型默认值 / copyWith（B 站零影响）', () {
    test('默认构造 images 为空、imageCount 为 0', () {
      const BiliComment c = BiliComment(id: '1', uname: 'u', message: 'm');
      expect(c.images, isEmpty);
      expect(c.imageCount, 0);
    });

    test('copyWith 带上 images / imageCount', () {
      const BiliComment c = BiliComment(id: '1', uname: 'u', message: 'm');
      final BiliComment copy = c.copyWith(
        images: const <String>['https://wx2.sinaimg.cn/large/a.jpg'],
        imageCount: 2,
      );
      expect(copy.images.length, 1);
      expect(copy.imageCount, 2);
      expect(copy.id, '1', reason: '既有字段不能被 copyWith 弄丢');
    });

    test('copyWith 不传时保留原值', () {
      const BiliComment c = BiliComment(
        id: '1',
        uname: 'u',
        message: 'm',
        images: <String>['https://wx2.sinaimg.cn/large/a.jpg'],
        imageCount: 1,
      );
      final BiliComment copy = c.copyWith(repliesLoaded: true);
      expect(copy.images.length, 1);
      expect(copy.imageCount, 1);
    });
  });
}
