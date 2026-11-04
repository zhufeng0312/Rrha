import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/weibo/weibo_comment_parser.dart';

/// `WeiboCommentParser` 的离线验收。
///
/// 响应结构照 `.env/weibo_comment_probe.md` 的实测：
/// - 列表在 **`data.data[]`**（两级 data，不是 `cards`）；
/// - 游标 **`data.max_id`**（实测 int，仍按 String 收发）；
/// - 楼中楼内嵌在 `data.data[i].comments[]`，该 key **可选**；
/// - `gid` 是 int 且超过 2^53 → **一律不读**。

/// 一条一级评论的原始 JSON（字段已按实测白名单裁剪）。
Map<String, dynamic> _comment({
  String id = '4932195724034522',
  String? text,
  int likeCount = 1276,
  String createdAt = 'Mon Aug 07 20:15:58 +0800 2023',
  List<Map<String, dynamic>>? replies,
  bool withGid = false,
  Object? totalNumber,
  Object? maxId,
}) =>
    <String, dynamic>{
      'id': id,
      'rootid': id,
      'rootidstr': id,
      'mid': id,
      'floor_number': 6,
      'text': text ??
          '你确定是偶尔直播？<span class="url-icon">'
              '<img alt="[怒]" src="https://face.t.sinajs.cn/t4/x.png"></span>',
      'created_at': createdAt,
      'like_count': likeCount,
      'readtimetype': 'comment',
      'cmt_ext': 'level_type:1',
      'user': <String, dynamic>{
        'id': 6611538293,
        'screen_name': '若叶睦子米Mutsumi',
        'avatar_hd': 'https://wx1.sinaimg.cn/orj480/hd.jpg',
        'profile_image_url': 'https://tvax1.sinaimg.cn/crop/profile.jpg',
      },
      // 噪声字段：解析器必须无视（白名单取值）。
      'report_scheme': 'sinaweibo://mpdialog?scheme=xxx',
      'comment_badge': <dynamic>[
        <String, dynamic>{'name': 'loyal_fans', 'type_and_level': '3_3'},
      ],
      if (replies != null) 'comments': replies,
      // 「共 N 条回复」的 N（含被折叠/已删除，≠ 能拉到的条数）。
      if (totalNumber != null) 'total_number': totalNumber,
      // 续拉二级回复的游标（子接口自己不给，只能取一级节点的）。
      if (maxId != null) 'max_id': maxId,
      // 16 位大整数：读它会丢精度，用来钉住「必须用 String 的 id」。
      if (withGid) 'gid': 4932196097852372,
    };

Map<String, dynamic> _page({
  required List<Map<String, dynamic>> comments,
  Object? maxId = 182712657086119,
  Object? totalNumber = 788,
}) =>
    <String, dynamic>{
      'ok': 1,
      'data': <String, dynamic>{
        'data': comments,
        // `max` 是内部上限语义，不是游标 —— 故意放一个看着像游标的值。
        'max': 999999999999999,
        'max_id': maxId,
        'max_id_type': 0,
        'total_number': totalNumber,
      },
    };

void main() {
  group('一级评论', () {
    test('各字段按实测路径取到（用户名 / 头像 / 正文 / 时间 / 点赞 / id）', () {
      final page = WeiboCommentParser.parsePage(_page(comments: <Map<String, dynamic>>[_comment()]));

      expect(page.comments.length, 1);
      final BiliComment c = page.comments.single;
      expect(c.id, '4932195724034522', reason: '主键必须是 String 的 id');
      expect(c.uname, '若叶睦子米Mutsumi');
      // avatar_hd 优先于 profile_image_url。
      expect(c.avatar, 'https://wx1.sinaimg.cn/orj480/hd.jpg');
      expect(c.like, 1276);
      expect(c.platformKey, 'weibo');
      expect(c.message, '你确定是偶尔直播？[怒]', reason: 'img alt 要还原成表情文字');
      expect(page.total, 788);
    });

    test('created_at 用 parseWeibo 解析（年份在最后 +0800）', () {
      final page = WeiboCommentParser.parsePage(_page(comments: <Map<String, dynamic>>[_comment()]));
      final DateTime? at = page.comments.single.createdAt;
      expect(at, isNotNull);
      // 2023-08-07 20:15:58 +0800 → UTC 12:15:58
      expect(at!.toUtc(), DateTime.utc(2023, 8, 7, 12, 15, 58));
      expect(page.comments.single.ctime, 0, reason: '微博没有 Unix 秒，不能被编一个');
    });

    test('avatar_hd 缺失时回退 profile_image_url', () {
      final Map<String, dynamic> raw = _comment();
      (raw['user'] as Map<String, dynamic>).remove('avatar_hd');
      final page = WeiboCommentParser.parsePage(_page(comments: <Map<String, dynamic>>[raw]));
      expect(page.comments.single.avatar, 'https://tvax1.sinaimg.cn/crop/profile.jpg');
    });

    test('游标取 data.max_id（不是 data.max），int 也能转成 String', () {
      final page = WeiboCommentParser.parsePage(_page(comments: <Map<String, dynamic>>[_comment()]));
      expect(page.nextCursor, '182712657086119');
      expect(page.nextCursor, isNot('999999999999999'));
      expect(page.isEnd, isFalse);
    });

    test('游标本身是 String 时原样保留（不做数值加工）', () {
      final page = WeiboCommentParser.parsePage(
        _page(comments: <Map<String, dynamic>>[_comment()], maxId: '182712657086119'),
      );
      expect(page.nextCursor, '182712657086119');
    });
  });

  group('二级评论（内嵌楼中楼）', () {
    test('comments[] 内嵌 → replies 非空且 repliesLoaded == true', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: <Map<String, dynamic>>[
            _comment(
              replies: <Map<String, dynamic>>[
                _comment(
                  id: '4932196097852372',
                  text: '<span class="url-icon"><img alt="[害羞]" '
                      'src="https://face.t.sinajs.cn/t4/y.png"></span>',
                  createdAt: 'Mon Aug 07 20:17:27 +0800 2023',
                  // 二级评论**没有** like_count
                  likeCount: 0,
                ),
                _comment(
                  id: '4932196291580328',
                  text: 'warma直播频率挺勤的啊',
                  createdAt: 'Mon Aug 07 20:18:14 +0800 2023',
                ),
              ],
            ),
          ],
        ),
      );

      final BiliComment root = page.comments.single;
      expect(root.replies.length, 2);
      expect(root.repliesLoaded, isTrue, reason: '内嵌拿到就算已加载，不该再发第二个请求');
      expect(root.repliesHasMore, isFalse, reason: '楼中楼只展开一层');
      expect(root.replyCount, 2);
      expect(root.replies.first.id, '4932196097852372');
      expect(root.replies.first.message, '[害羞]');
    });

    test('无 comments 字段 → replies 为空且不崩（该 key 可选）', () {
      final page = WeiboCommentParser.parsePage(_page(comments: <Map<String, dynamic>>[_comment()]));
      final BiliComment c = page.comments.single;
      expect(c.replies, isEmpty);
      expect(c.repliesLoaded, isFalse);
      expect(c.replyCount, 0);
    });

    test('comments 不是 List（脏数据）→ 当作没有楼中楼', () {
      final Map<String, dynamic> raw = _comment();
      raw['comments'] = 'oops';
      final page = WeiboCommentParser.parsePage(_page(comments: <Map<String, dynamic>>[raw]));
      expect(page.comments.single.replies, isEmpty);
    });
  });

  group('id 精度坑（gid）', () {
    test('gid 是 16 位超大 int 时仍然用 String 的 id', () {
      const String id = '4932195724034522';
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: <Map<String, dynamic>>[
            _comment(id: id, withGid: true),
          ],
        ),
      );

      final BiliComment c = page.comments.single;
      expect(c.id, id, reason: '必须原样保留字符串，不能走 gid 的数值路径');
      // gid = 4932196097852372 在 double 上会失真成 …372 之外的值；
      // 这里反向钉死「没有读到 gid」。
      expect(c.id, isNot('4932196097852372'));
      expect(c.id.length, 16);
    });

    test('缺失 id 的条目被跳过，其余保留', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: <Map<String, dynamic>>[
            <String, dynamic>{
              'text': '没有 id 的评论',
              'user': <String, dynamic>{'screen_name': 'x'},
              'gid': 4932196097852372,
            },
            _comment(id: '111'),
          ],
        ),
      );
      expect(page.comments.length, 1, reason: '有 gid 也不能顶替 id');
      expect(page.comments.single.id, '111');
    });
  });

  group('多图线索 mix_media_ids（只搬运，不解析）', () {
    List<Map<String, dynamic>> withMix(Object? value) => <Map<String, dynamic>>[
          _comment()
            ..['mix_media_ids'] = value,
        ];

    test('N 项原样读进模型，顺序与前缀都不改（仍是 http）', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: withMix(<String>[
            'http://t.cn/AXlmgHJ6',
            'http://t.cn/AXlmgHJS',
            'http://t.cn/AXlmgHJa',
          ]),
        ),
      );

      expect(page.comments.single.mixMediaIds, <String>[
        'http://t.cn/AXlmgHJ6',
        'http://t.cn/AXlmgHJS',
        'http://t.cn/AXlmgHJa',
      ]);
      expect(
        page.comments.single.mixMediaIds.first.startsWith('http://'),
        isTrue,
        reason: '解析层零 IO，前缀升级留给仓库层',
      );
    });

    test('缺失 / null / 非 List → 空列表，不崩', () {
      for (final Object? bad in <Object?>[null, 'oops', 42, <String, dynamic>{}]) {
        final page = WeiboCommentParser.parsePage(_page(comments: withMix(bad)));
        expect(page.comments.single.mixMediaIds, isEmpty, reason: 'value=$bad');
      }
      // 整个 key 都不存在。
      final page = WeiboCommentParser.parsePage(
        _page(comments: <Map<String, dynamic>>[_comment()]),
      );
      expect(page.comments.single.mixMediaIds, isEmpty);
    });

    test('去空、去重（保持首次出现顺序）', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: withMix(<Object?>[
            'http://t.cn/A',
            '  ',
            '',
            null,
            'http://t.cn/A',
            'http://t.cn/B',
            42,
          ]),
        ),
      );

      expect(page.comments.single.mixMediaIds, <String>[
        'http://t.cn/A',
        'http://t.cn/B',
      ]);
    });

    test('一级与二级评论都读', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: <Map<String, dynamic>>[
            _comment()
              ..['mix_media_ids'] = <String>['http://t.cn/root'],
            _comment(
              id: '4932196097852372',
              replies: <Map<String, dynamic>>[
                _comment(id: 'sub-1')
                  ..['mix_media_ids'] = <String>['http://t.cn/s1', 'http://t.cn/s2'],
              ],
            ),
          ],
        ),
      );

      expect(page.comments.first.mixMediaIds, <String>['http://t.cn/root']);
      expect(
        page.comments[1].replies.single.mixMediaIds,
        <String>['http://t.cn/s1', 'http://t.cn/s2'],
      );
    });

    test('单独的 parseMixMediaIds 也可直接测（纯函数）', () {
      expect(
        WeiboCommentParser.parseMixMediaIds(
          <String, dynamic>{
            'mix_media_ids': <String>['http://t.cn/x', 'http://t.cn/x'],
          },
        ),
        <String>['http://t.cn/x'],
      );
      expect(
        WeiboCommentParser.parseMixMediaIds(<String, dynamic>{}),
        isEmpty,
      );
    });
  });

  group('正文 HTML', () {
    test('剥标签 + 表情 alt 还原成 [xx]', () {
      expect(
        WeiboCommentParser.plainText(
          '你确定是偶尔直播？<span class="url-icon">'
          '<img alt="[怒]" src="https://face.t.sinajs.cn/t4/a.png"></span>',
        ),
        '你确定是偶尔直播？[怒]',
      );
    });

    test('多个表情与纯文本混排，标签全部去掉', () {
      expect(
        WeiboCommentParser.plainText(
          '<a href="https://example.com">链接</a>加'
          '<span class="url-icon"><img alt="[doge]" src="x"></span>'
          '<span class="url-icon"><img alt="[哈哈]" src="y"></span>',
        ),
        '链接加[doge][哈哈]',
      );
    });

    test('空 / null 正文返回空串，不抛', () {
      expect(WeiboCommentParser.plainText(null), '');
      expect(WeiboCommentParser.plainText(''), '');
    });

    test('没有 alt 的 img 直接去掉（不留尖括号残渣）', () {
      final String out = WeiboCommentParser.plainText('前<img src="x.png">后');
      expect(out, '前后');
      expect(out.contains('<'), isFalse);
    });
  });

  group('容错', () {
    test('空 / 非法 input 返回空页，不崩', () {
      for (final Object? bad in <Object?>[
        null,
        '',
        'oops',
        42,
        <String, dynamic>{},
        <String, dynamic>{'data': 'oops'},
        <String, dynamic>{'ok': 1},
        <String, dynamic>{'ok': 1, 'data': <String, dynamic>{'data': 'oops'}},
      ]) {
        final CommentPage page = WeiboCommentParser.parsePage(bad);
        expect(page.comments, isEmpty, reason: 'input=$bad');
        expect(page.isEnd, isTrue, reason: 'input=$bad');
      }
    });

    test('data.data 为空数组 → isEnd，且没有游标', () {
      final page = WeiboCommentParser.parsePage(_page(comments: <Map<String, dynamic>>[]));
      expect(page.comments, isEmpty);
      expect(page.isEnd, isTrue);
    });

    test('max_id 缺失 → isEnd 为 true（判末页只看游标/列表）', () {
      final page = WeiboCommentParser.parsePage(
        <String, dynamic>{
          'ok': 1,
          'data': <String, dynamic>{
            'data': <dynamic>[_comment()],
          },
        },
      );
      expect(page.comments.length, 1);
      expect(page.nextCursor, isNull);
      expect(page.isEnd, isTrue);
    });

    test('total_number 是 String 时也能取到（num / String 双兼容）', () {
      final page = WeiboCommentParser.parsePage(
        _page(comments: <Map<String, dynamic>>[_comment()], totalNumber: '788'),
      );
      expect(page.total, 788);
    });

    test('列表里混入非 Map 元素时跳过它', () {
      final page = WeiboCommentParser.parsePage(
        <String, dynamic>{
          'ok': 1,
          'data': <String, dynamic>{
            'data': <dynamic>[
              'oops',
              null,
              42,
              _comment(id: '111'),
            ],
            'max_id': 1,
            'total_number': 1,
          },
        },
      );
      expect(page.comments.length, 1);
      expect(page.comments.single.id, '111');
    });
  });

  // ---------------------------------------------------------- 子评论相关字段
  //
  // 探针实测（`.env/weibo_subcomment_probe.md`）：
  // 一级评论节点带 `total_number=68` 与 `max_id`（int，15 位）。
  // 前者只用于文案「共 N 条回复」，后者是续拉子评论的唯一游标来源。
  group('totalReplies / replyCursor（一级节点）', () {
    test('total_number → totalReplies', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: <Map<String, dynamic>>[_comment(totalNumber: 68)],
          totalNumber: 362,
        ),
      );
      final BiliComment c = page.comments.single;
      expect(c.totalReplies, 68);
      // 页级 total（362）与条目的声称总数（68）是两个字段，不能串。
      expect(page.total, 362);
    });

    test('max_id 是 int（15 位）→ replyCursor 按 String 存', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: <Map<String, dynamic>>[_comment(maxId: 145767900000000)],
        ),
      );
      expect(page.comments.single.replyCursor, '145767900000000');
    });

    test('max_id 是 String 时原样保留', () {
      final page = WeiboCommentParser.parsePage(
        _page(
          comments: <Map<String, dynamic>>[_comment(maxId: '145767900000000')],
        ),
      );
      expect(page.comments.single.replyCursor, '145767900000000');
    });

    test('total_number 是 String 也能读（num / String 双兼容）', () {
      final page = WeiboCommentParser.parsePage(
        _page(comments: <Map<String, dynamic>>[_comment(totalNumber: '68')]),
      );
      expect(page.comments.single.totalReplies, 68);
    });

    test('两个字段都缺失 → 默认 0 / null（B 站侧不受影响）', () {
      final page = WeiboCommentParser.parsePage(
        _page(comments: <Map<String, dynamic>>[_comment()]),
      );
      final BiliComment c = page.comments.single;
      expect(c.totalReplies, 0);
      expect(c.replyCursor, isNull);
    });

    test('copyWith 能带上新字段', () {
      final BiliComment c = WeiboCommentParser.parsePage(
        _page(comments: <Map<String, dynamic>>[_comment(totalNumber: 68, maxId: '999')]),
      ).comments.single;

      final BiliComment copy = c.copyWith(totalReplies: 70, replyCursor: '123');
      expect(copy.totalReplies, 70);
      expect(copy.replyCursor, '123');
      // 不传 = 保留原值。
      expect(copy.copyWith().totalReplies, 70);
      expect(copy.copyWith().replyCursor, '123');
    });
  });

  // ---------------------------------------------------------- 子评论接口响应
  //
  // 探针实测：`hotflowChild` 的响应结构**与一级接口不同** ——
  // 列表直接挂在 `data` 上（`data` 就是 List），不是 `data.data`。
  // 这组测试专门钉住这个差异：写成 `data.data` 会静默返回空页。
  group('子评论接口 parseChildPage（data 直接是 List）', () {
    Map<String, dynamic> childBody(List<Object?> list) => <String, dynamic>{
          'ok': 1,
          // 注意：`data` 本身就是数组，没有第二层。
          'data': list,
        };

    test('data 是 List → 逐条解析（与 hotflow 的 data.data 不同）', () {
      final List<BiliComment>? items = WeiboCommentParser.parseChildPage(
        childBody(<Object?>[
          _comment(id: 'sub-1', text: '第一条回复'),
          _comment(id: 'sub-2', text: '第二条回复'),
        ]),
      );

      expect(items, isNotNull);
      expect(items!.length, 2);
      expect(items.first.id, 'sub-1');
      expect(items.first.message, '第一条回复');
      expect(items[1].id, 'sub-2');
    });

    test('同一个响应丢给 parsePage（一级接口解析）→ 空页（证明两者不可互换）', () {
      final Map<String, dynamic> body = childBody(<Object?>[
        _comment(id: 'sub-1'),
      ]);

      // 子接口解析：拿得到。
      expect(WeiboCommentParser.parseChildPage(body)!.length, 1);
      // 一级接口解析：`data` 不是 Map → 判定畸形 → 空页。
      // 这正是「不能复用 parsePage」的证据。
      expect(WeiboCommentParser.parsePage(body).comments, isEmpty);
    });

    test('data 是空 List → 空列表（到底信号，不是错误）', () {
      final List<BiliComment>? items =
          WeiboCommentParser.parseChildPage(childBody(<Object?>[]));
      expect(items, isNotNull);
      expect(items, isEmpty);
    });

    test('畸形输入 → null（调用方转成「解析失败」）', () {
      for (final Object? bad in <Object?>[
        null,
        '',
        'oops',
        42,
        <Object?>[],
        <String, dynamic>{},
        <String, dynamic>{'data': 'oops'},
        <String, dynamic>{'data': <String, dynamic>{'data': <Object?>[]}},
      ]) {
        expect(
          WeiboCommentParser.parseChildPage(bad),
          isNull,
          reason: 'input=$bad',
        );
      }
    });

    test('列表里混入脏元素时只跳过它（其余照常）', () {
      final List<BiliComment>? items = WeiboCommentParser.parseChildPage(
        childBody(<Object?>['oops', null, 42, _comment(id: 'sub-1')]),
      );
      expect(items!.length, 1);
      expect(items.single.id, 'sub-1');
    });
  });
}
