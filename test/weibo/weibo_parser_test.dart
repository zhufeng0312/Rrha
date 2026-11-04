import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/utils/id_hash.dart';
import 'package:rrha/core/utils/time_parse.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/models/video_ref.dart';
import 'package:rrha/data/weibo/weibo_parser.dart';

/// 微博 `mblog` → [ContentItem] 的离线验收。
///
/// **所有 fixture 的字段名都来自真机实测**（见 `.env/weibo_mblog_structure*.md`），
/// 不是臆想的：
/// - `pics[]` 的 5 个一级 key 是 `pid`/`url`/`size`/`geo`/`large`；
/// - 原图在 `pics[i].large.url`（mw2000），缩略图在 `pics[i].url`（orj360）；
/// - `created_at` 是 `Mon Aug 07 20:15:27 +0800 2023`（年份在最后）；
/// - `mblog.id`/`mid` 是 String，`user.id` 是 **int**；
/// - `page_info` 实测有 `type="webpage"` 且**没有** `media_info`。
void main() {
  final DateTime fetchedAt = DateTime.utc(2026, 10, 18, 12, 0, 0);

  final Subscription sub = Subscription(
    platform: Platform.weibo,
    uid: '1782488734',
    routes: const <FeedRoute>{FeedRoute.weiboUser},
    alias: '沃玛',
    addedAt: DateTime.utc(2026, 1, 1),
  );

  /// 实测样本里的 user 块（`id` 是 int，头像两个字段都在）。
  Map<String, Object?> user({String name = '_warma_'}) => <String, Object?>{
        'id': 1782488734,
        'screen_name': name,
        'profile_image_url':
            'https://tvax2.sinaimg.cn/crop.0.0.600.600.180/6a3e9e9ely8hobt1otu99j20go0gowgh.jpg',
        'avatar_hd':
            'https://wx2.sinaimg.cn/orj480/6a3e9e9ely8hobt1otu99j20go0gowgh.jpg',
      };

  /// 一张实测形态的配图：`url` 是 orj360 缩略，`large.url` 是 mw2000 原图。
  ///
  /// [host] 可变：真实样本里不同图会落在 `wx2`/`wx4` 等不同 CDN 子域上
  /// （P2 #15 的 pics[0] 就是 `wx4`），不是固定值。
  Map<String, Object?> pic(String pid, {String host = 'wx2'}) =>
      <String, Object?>{
        'pid': pid,
        'url': 'https://$host.sinaimg.cn/orj360/$pid.jpg',
        'size': 'orj360',
        'geo': <String, Object?>{'width': 480, 'height': 270, 'croped': false},
        'large': <String, Object?>{
          'size': 'large',
          'url': 'https://$host.sinaimg.cn/mw2000/$pid.jpg',
        },
      };

  group('纯文字微博', () {
    test('各字段正确，kind=dynamic，无图时 coverUrl/images 为空', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '5354385849713417',
          'mid': '5354385849713417',
          'created_at': 'Thu Oct 15 20:48:48 +0800 2026',
          'text': '吱吱！吱吱吱吱 明天 12：00',
          'textLength': 65,
          'pic_num': 0,
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );

      expect(item, isNotNull);
      expect(item!.platform, Platform.weibo);
      expect(item.kind, ContentKind.dynamic);
      expect(item.sourceId, 'weibo:1782488734');
      expect(item.authorName, '_warma_');
      // `user.id` 是 int，必须转成字符串。
      expect(item.authorId, '1782488734');
      expect(
        item.authorAvatar,
        'https://wx2.sinaimg.cn/orj480/6a3e9e9ely8hobt1otu99j20go0gowgh.jpg',
      );
      expect(item.summary, '吱吱！吱吱吱吱 明天 12：00');
      expect(item.title, '吱吱！吱吱吱吱 明天 12：00');
      expect(item.link, 'https://m.weibo.cn/status/5354385849713417');
      expect(item.images, isEmpty);
      expect(item.coverUrl, isNull);
      expect(item.origin, isNull);
      expect(item.videoRef, isNull);
      expect(item.hasReliableTime, isTrue);
      expect(item.fetchedAt, fetchedAt);
    });

    test('正文是 HTML 时被清洗成纯文本（去标签 + 实体反转义）', () {
      // 实测形态：表情图标是 <span class="url-icon"><img alt="[酷]">。
      final String html = '【投稿】<span class="url-icon">'
          '<img alt="[酷]" src="https://face.t.sinajs.cn/t4/x.png"></span>'
          '好耶 &amp; 棒<br />第二行';
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '1',
          'mid': '1',
          'text': html,
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );

      expect(item, isNotNull);
      expect(item!.summary, isNot(contains('<span')));
      expect(item.summary, isNot(contains('<img')));
      expect(item.summary, contains('好耶 & 棒'));
      expect(item.summary, contains('第二行'));
      // 标题与 ContentItem.displayTitle 同一套做法：singleLine 压成一行再截断，
      // 所以不含换行、长度受 60 字上限约束。
      expect(item.title, isNot(contains('\n')));
      expect(item.title.length, lessThanOrEqualTo(61));
      expect(item.title, contains('好耶 & 棒'));
    });

    test('正文为空时不伪造标题', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '1',
          'mid': '1',
          'text': '',
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.title, '');
      expect(item.summary, '');
      // displayTitle 才是唯一兜底点。
      expect(item.displayTitle, '（无标题）');
    });

    test('长文截断预览也能正常解析（textLength 大于实际 text）', () {
      // 实测：置顶那条 textLength=1111，而 text 原长只有 735。
      final String preview = '长文预览正文……';
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '4932195589819028',
          'mid': '4932195589819028',
          'created_at': 'Mon Aug 07 20:15:27 +0800 2023',
          'text': preview,
          'textLength': 1111,
          'isLongText': true,
          'pic_num': 0,
          'user': user(),
          'title': <String, Object?>{'text': '置顶'},
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.summary, preview);
      expect(item.kind, ContentKind.dynamic);
      // 截断预览仍然给得出发布时间。
      expect(item.publishedAt, isNotNull);
      expect(item.hasReliableTime, isTrue);
    });
  });

  group('计数字段（卡片操作栏）', () {
    /// 微博的命名反直觉：点赞叫 `attitudes_count`，不是 like_count。
    Map<String, Object?> withCounts({
      Object? comments = 143,
      Object? attitudes = 833,
      Object? reposts = 21,
    }) =>
        <String, Object?>{
          'id': '5354385849713499',
          'mid': '5354385849713499',
          'created_at': 'Thu Oct 15 20:48:48 +0800 2026',
          'text': '带计数的微博',
          'user': user(),
          if (comments != null) 'comments_count': comments,
          if (attitudes != null) 'attitudes_count': attitudes,
          if (reposts != null) 'reposts_count': reposts,
        };

    test('评论 / 点赞 / 转发读数正确（点赞取 attitudes_count）', () {
      final ContentItem? item = WeiboParser.fromMblog(
        withCounts(),
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.commentCount, 143);
      expect(item.likeCount, 833);
      expect(item.repostCount, 21);
    });

    test('字段缺失时是 null，不是 0（不能凭空显示 0 条评论）', () {
      final ContentItem? item = WeiboParser.fromMblog(
        withCounts(comments: null, attitudes: null, reposts: null),
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.commentCount, isNull);
      expect(item.likeCount, isNull);
      expect(item.repostCount, isNull);
    });

    test('确实是 0 时保留 0', () {
      final ContentItem? item = WeiboParser.fromMblog(
        withCounts(comments: 0, attitudes: 0, reposts: 0),
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.commentCount, 0);
      expect(item.likeCount, 0);
      expect(item.repostCount, 0);
    });

    test('数字字符串也能解析（个别接口版本给 String）', () {
      final ContentItem? item = WeiboParser.fromMblog(
        withCounts(comments: '12', attitudes: '34', reposts: '56'),
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.commentCount, 12);
      expect(item.likeCount, 34);
      expect(item.repostCount, 56);
    });

    test('坏数据（空串 / 非数字）回落 null，不当成 0', () {
      final ContentItem? item = WeiboParser.fromMblog(
        withCounts(comments: '', attitudes: 'abc', reposts: null),
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.commentCount, isNull);
      expect(item.likeCount, isNull);
      expect(item.repostCount, isNull);
    });

    test('计数能穿过缓存往返', () {
      final ContentItem? item = WeiboParser.fromMblog(
        withCounts(),
        sub: sub,
        fetchedAt: fetchedAt,
      );
      final restored = ContentItem.fromJson(item!.toJson());
      expect(restored!.commentCount, 143);
      expect(restored.likeCount, 833);
      expect(restored.repostCount, 21);
    });
  });

  group('带图微博', () {
    test('1 张图：images 取全，coverUrl=images.first，URL 是 https 原图', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '2',
          'mid': '2',
          'text': '单图',
          'pic_num': 1,
          'pics': <Object?>[pic('p1')],
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );

      expect(item, isNotNull);
      expect(item!.images.length, 1);
      // 优先 large.url（mw2000 原图），不是 orj360 缩略。
      expect(
        item.images.single,
        'https://wx2.sinaimg.cn/mw2000/p1.jpg',
      );
      expect(item.coverUrl, item.images.first);
      expect(item.images.single.startsWith('https://'), isTrue);
      expect(item.hasMultipleImages, isFalse);
      // 配图不改变形态判定：仍是 dynamic。
      expect(item.kind, ContentKind.dynamic);
    });

    test('4 张图：顺序与张数都保持服务端原样', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '3',
          'mid': '3',
          'text': '四图',
          'pic_num': 4,
          'pics': <Object?>[pic('a'), pic('b'), pic('c'), pic('d')],
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );

      expect(item, isNotNull);
      expect(item!.images.length, 4);
      expect(item.images, <String>[
        'https://wx2.sinaimg.cn/mw2000/a.jpg',
        'https://wx2.sinaimg.cn/mw2000/b.jpg',
        'https://wx2.sinaimg.cn/mw2000/c.jpg',
        'https://wx2.sinaimg.cn/mw2000/d.jpg',
      ]);
      expect(item.coverUrl, 'https://wx2.sinaimg.cn/mw2000/a.jpg');
      expect(item.hasMultipleImages, isTrue);
    });

    test('图片字段回退：只有 url 没有 large 时也能取到', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '4',
          'mid': '4',
          'text': '只有缩略',
          'pic_num': 1,
          'pics': <Object?>[
            <String, Object?>{
              'pid': 'nolearge',
              'url': 'https://wx1.sinaimg.cn/orj360/nolarge.jpg',
              'size': 'orj360',
            },
          ],
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );

      expect(item, isNotNull);
      expect(item!.images.single, 'https://wx1.sinaimg.cn/orj360/nolarge.jpg');
      expect(item.coverUrl, item.images.first);
    });

    test('协议相对地址被归一化成 https（Android 9+ 禁明文）', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '5',
          'mid': '5',
          'text': '相对地址',
          'pic_num': 1,
          'pics': <Object?>[
            <String, Object?>{
              'url': '//wx2.sinaimg.cn/orj360/rel.jpg',
            },
          ],
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.images.single, 'https://wx2.sinaimg.cn/orj360/rel.jpg');
    });

    test('空串与重复图片被去掉，不占张数', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '6',
          'mid': '6',
          'text': '脏数据',
          'pic_num': 3,
          'pics': <Object?>[
            <String, Object?>{'url': '   '},
            <String, Object?>{'url': 'https://wx2.sinaimg.cn/mw2000/dup.jpg'},
            <String, Object?>{'url': 'https://wx2.sinaimg.cn/mw2000/dup.jpg'},
            <String, Object?>{'pid': 'nourl'},
            'not a map',
          ],
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.images, <String>['https://wx2.sinaimg.cn/mw2000/dup.jpg']);
    });
  });

  group('时间解析', () {
    test('created_at 解析正确（+0800 换算成 UTC）', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '7',
          'mid': '7',
          'created_at': 'Mon Aug 07 20:15:27 +0800 2023',
          'text': '时间样本',
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      // 20:15:27 +0800 == 12:15:27 UTC
      expect(item!.publishedAt, DateTime.utc(2023, 8, 7, 12, 15, 27));
      expect(item.publishedAt!.isUtc, isTrue);
      expect(item.hasReliableTime, isTrue);
      expect(item.sortKey, item.publishedAt);
    });

    test('created_at 非法 → publishedAt=null 且 hasReliableTime=false', () {
      for (final String bad in <String>[
        '刚刚',
        '',
        '2023-08-07 20:15:27',
        'Mon Aug 07 20:15:27 2023',
        'Mon Aug 32 20:15:27 +0800 2023',
        'Mon Aug 07 25:15:27 +0800 2023',
        'Mon Xxx 07 20:15:27 +0800 2023',
      ]) {
        final ContentItem? item = WeiboParser.fromMblog(
          <String, Object?>{
            'id': '8',
            'mid': '8',
            'created_at': bad,
            'text': '时间异常',
            'user': user(),
          },
          sub: sub,
          fetchedAt: fetchedAt,
        );
        expect(item, isNotNull, reason: 'bad="$bad"');
        expect(item!.publishedAt, isNull, reason: 'bad="$bad"');
        // 绝不拿 fetchedAt 冒充发布时间。
        expect(item.hasReliableTime, isFalse, reason: 'bad="$bad"');
        expect(item.sortKey, fetchedAt, reason: 'bad="$bad"');
      }
    });

    test('parseWeibo：负时区与缺秒都能算对', () {
      expect(
        TimeParse.parseWeibo('Tue Jan 02 03:04:05 -0430 2024'),
        DateTime.utc(2024, 1, 2, 7, 34, 5),
      );
      expect(
        TimeParse.parseWeibo('Tue Jan 02 03:04 -0430 2024'),
        DateTime.utc(2024, 1, 2, 7, 34),
      );
      expect(TimeParse.parseWeibo(null), isNull);
      expect(TimeParse.parseWeibo('  '), isNull);
    });
  });

  group('id 稳定性', () {
    test('同一 mid 两次解析得到同一个 id', () {
      final Map<String, Object?> raw = <String, Object?>{
        'id': '5354615314844741',
        'mid': '5354615314844741',
        'text': '同一条',
        'user': user(),
      };
      final ContentItem? a = WeiboParser.fromMblog(
        raw,
        sub: sub,
        fetchedAt: fetchedAt,
      );
      final ContentItem? b = WeiboParser.fromMblog(
        raw,
        sub: sub,
        fetchedAt: DateTime.utc(2027, 1, 1),
      );
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.id, b!.id);
      // id 契约：status 网页地址的 hash。
      expect(
        a.id,
        IdHash.itemId(
          'weibo',
          'https://m.weibo.cn/status/5354615314844741',
        ),
      );
      expect(a.id, startsWith('weibo:'));
    });

    test('mid 缺失时退回 id，仍然稳定', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{'id': '123456', 'text': '只有 id', 'user': user()},
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.link, 'https://m.weibo.cn/status/123456');
      expect(
        item.id,
        IdHash.itemId('weibo', 'https://m.weibo.cn/status/123456'),
      );
    });
  });

  group('降级与容错', () {
    test('user 缺失时作者名回退 sub.displayName', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{'id': '9', 'mid': '9', 'text': '无 user'},
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.authorName, '沃玛');
      expect(item.authorId, isNull);
      expect(item.authorAvatar, isNull);
    });

    test('头像回退到 profile_image_url', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '10',
          'mid': '10',
          'text': '只有小头像',
          'user': <String, Object?>{
            'id': 1,
            'screen_name': '甲',
            'profile_image_url': 'https://tvax2.sinaimg.cn/crop/x.jpg',
          },
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.authorAvatar, 'https://tvax2.sinaimg.cn/crop/x.jpg');
    });

    test('非 Map / 无 id 的输入返回 null，不抛异常', () {
      expect(
        WeiboParser.fromMblog(null, sub: sub, fetchedAt: fetchedAt),
        isNull,
      );
      expect(
        WeiboParser.fromMblog('字符串', sub: sub, fetchedAt: fetchedAt),
        isNull,
      );
      expect(
        WeiboParser.fromMblog(<Object?>[1, 2], sub: sub, fetchedAt: fetchedAt),
        isNull,
      );
      expect(
        WeiboParser.fromMblog(
          <String, Object?>{'text': '没有 id'},
          sub: sub,
          fetchedAt: fetchedAt,
        ),
        isNull,
      );
      expect(
        WeiboParser.fromMblog(
          <String, Object?>{'id': '   ', 'mid': ''},
          sub: sub,
          fetchedAt: fetchedAt,
        ),
        isNull,
      );
    });

    test('page_info 是 webpage 外链卡时不算视频（实测形态）', () {
      // 实测 #4：page_info 7 个 key，没有 media_info。
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '11',
          'mid': '11',
          'text': '投稿啦！',
          'page_info': <String, Object?>{
            'object_type': 2,
            'type': 'webpage',
            'page_pic': <String, Object?>{
              'url': 'https://i0.hdslb.com/bfs/community-share/a04.jpg',
            },
            'page_url': 'https://weibo.cn/sinaurl?luicode=10000011',
            'url_ori': 'http://t.cn/AXlYfDBP',
            'page_title': 'Warma',
            'content1': '1281播放  398点赞  4弹幕',
          },
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      // 关键：不能因为「有 page_info」就判成视频。
      expect(item!.kind, ContentKind.dynamic);
      expect(item.videoRef, isNull);
      // 外链卡封面不占 pics，所以 images 仍为空。
      expect(item.images, isEmpty);
      expect(item.coverUrl, isNull);
    });
  });

  group('extractMblogs', () {
    test('只取 card_type==9 且 mblog 非空，header 卡被跳过', () {
      const String body = '{"ok":1,"data":{"cardlistInfo":{"since_id":"1"},'
          '"cards":['
          '{"card_type":11,"title":"header"},'
          '{"card_type":9,"mblog":{"id":"1","text":"a"}},'
          '{"card_type":9,"mblog":null},'
          '{"card_type":9},'
          '{"card_type":9,"mblog":{}},'
          '{"card_type":9,"mblog":{"id":"2","text":"b"}},'
          '"not a card"'
          ']}}';
      final List<Object?> mblogs = WeiboParser.extractMblogs(body);
      expect(mblogs.length, 2);
      expect((mblogs[0] as Map)['id'], '1');
      expect((mblogs[1] as Map)['id'], '2');
    });

    test('card_type 是字符串 "9" 也认', () {
      const String body = '{"data":{"cards":['
          '{"card_type":"9","mblog":{"id":"1"}}'
          ']}}';
      expect(WeiboParser.extractMblogs(body).length, 1);
    });

    test('空 / 非法 JSON / 结构不符都不崩', () {
      expect(WeiboParser.extractMblogs(null), isEmpty);
      expect(WeiboParser.extractMblogs(''), isEmpty);
      expect(WeiboParser.extractMblogs('not json at all'), isEmpty);
      expect(WeiboParser.extractMblogs('[]'), isEmpty);
      expect(WeiboParser.extractMblogs('{"data":null}'), isEmpty);
      expect(WeiboParser.extractMblogs('{"data":{"cards":"x"}}'), isEmpty);
      expect(WeiboParser.extractMblogs(<String, Object?>{}), isEmpty);
      expect(WeiboParser.extractMblogs(42), isEmpty);
    });

    test('接受已解码的 Map（与接受字符串等价）', () {
      final Map<String, Object?> decoded =
          jsonDecode('{"data":{"cards":[{"card_type":9,'
                  '"mblog":{"id":"1"}}]}}')
              as Map<String, Object?>;
      expect(WeiboParser.extractMblogs(decoded).length, 1);
    });

    test('抽出的 mblog 能直接喂给 fromMblog', () {
      const String body = '{"data":{"cards":['
          '{"card_type":9,"mblog":{"id":"5123","mid":"5123",'
          '"created_at":"Thu Oct 15 20:48:48 +0800 2026",'
          '"text":"带图","pic_num":1,'
          '"pics":[{"pid":"p1","url":"https://wx2.sinaimg.cn/orj360/p1.jpg",'
          '"large":{"url":"https://wx2.sinaimg.cn/mw2000/p1.jpg"}}],'
          '"user":{"id":1782488734,"screen_name":"_warma_"}}}'
          ']}}';
      final List<Object?> mblogs = WeiboParser.extractMblogs(body);
      expect(mblogs.length, 1);
      final ContentItem? item = WeiboParser.fromMblog(
        mblogs.single,
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.images.single, 'https://wx2.sinaimg.cn/mw2000/p1.jpg');
      expect(item.publishedAt, DateTime.utc(2026, 10, 15, 12, 48, 48));
    });
  });

  // ————————————————————————————————————————————————————————————
  // 转发 / 视频分支
  //
  // 转发分支**已有真实样本**：3 页深度采样（`.env/weibo_mblog_structure3.md`）
  // 在 31 条里抓到 4 条 retweeted_status，结构与主 mblog 完全同形。
  // 视频分支**仍然零样本**：31 条里 page_info 有 8 条，但全是
  // type="webpage" / "topic"，没有 media_info。所以那里的断言是
  // 「防御性行为」而非「实测字段名」。
  // ————————————————————————————————————————————————————————————

  group('转发分支（有真实样本 · 同形递归）', () {
    /// 构造一条「与主结构同形」的转发：字段名都用主 mblog 的实测名字。
    Map<String, Object?> repost() => <String, Object?>{
          'id': '9001',
          'mid': '9001',
          'created_at': 'Fri Oct 16 12:00:38 +0800 2026',
          'text': '转发理由',
          'user': user(),
          'retweeted_status': <String, Object?>{
            'id': '8001',
            'mid': '8001',
            'created_at': 'Thu Oct 15 08:00:00 +0800 2026',
            'text': '原微博正文',
            'pic_num': 1,
            'pics': <Object?>[
              <String, Object?>{
                'pid': 'orig1',
                'url': 'https://wx2.sinaimg.cn/orj360/orig1.jpg',
                'large': <String, Object?>{
                  'url': 'https://wx2.sinaimg.cn/mw2000/orig1.jpg',
                },
              },
            ],
            'user': user(name: '原作者'),
          },
        };

    test('kind=repost，origin 非空，原微博正文与图片正确', () {
      final ContentItem? item = WeiboParser.fromMblog(
        repost(),
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.kind, ContentKind.repost);

      final ContentItem? origin = item.origin;
      expect(origin, isNotNull);
      expect(origin!.summary, '原微博正文');
      expect(origin.authorName, '原作者');
      expect(
        origin.images,
        <String>['https://wx2.sinaimg.cn/mw2000/orig1.jpg'],
      );
      expect(origin.coverUrl, origin.images.first);
      expect(origin.publishedAt, DateTime.utc(2026, 10, 15, 0, 0, 0));
      expect(origin.kind, ContentKind.dynamic);
      // 原微博的 sourceId 沿用同一条订阅。
      expect(origin.sourceId, item.sourceId);
      expect(origin.platform, Platform.weibo);
    });

    test('真实样本形态：4 图 + 超话 page_info 的原微博能完整解析', () {
      // 照抄 P2 #15 的真实结构（`.env/weibo_mblog_structure3.md` 第三节）：
      // - id/mid 是 19 位 String；
      // - user.id 是 int；
      // - 4 张图都在 pics[]，large.url 是 /mw2000/ 原图；
      // - page_info.type = "topic"（超话），**没有** media_info；
      // - 还带着旧版单图字段 thumbnail_pic/bmiddle_pic/original_pic（不应被使用）。
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '5348166884919831',
          'mid': '5348166884919831',
          'created_at': 'Wed Sep 23 18:33:04 +0800 2026',
          'text': '下课就飞过去取快递了',
          'user': user(),
          'retweeted_status': <String, Object?>{
            'id': '5346379155378373',
            'mid': '5346379155378373',
            'created_at': 'Wed Sep 23 18:33:04 +0800 2026',
            'text': '收到快递的香蕉人belike小乌鸦<br />香蕉人已经化身…',
            'textLength': 796,
            'isLongText': true,
            'pic_num': 4,
            'thumbnail_pic':
                'https://wx4.sinaimg.cn/thumbnail/008rxNohgy1ihdrt7p76ej30u0140gs5.jpg',
            'bmiddle_pic':
                'http://wx4.sinaimg.cn/bmiddle/008rxNohgy1ihdrt7p76ej30u0140gs5.jpg',
            'original_pic':
                'https://wx4.sinaimg.cn/large/008rxNohgy1ihdrt7p76ej30u0140gs5.jpg',
            'pics': <Object?>[
              pic('008rxNohgy1ihdrt7p76ej30u0140gs5', host: 'wx4'),
              pic('008rxNohgy1ihdrt8dxoaj31400u0gsi', host: 'wx4'),
              pic('008rxNohgy1ihdrt70izlj31400u0q9d'),
              pic('008rxNohgy1ihdrt9mk0zj30rs0rsjzf'),
            ],
            'user': <String, Object?>{
              'id': 7736078413,
              'screen_name': '蓝色香蕉人',
              'avatar_hd':
                  'https://wx2.sinaimg.cn/orj480/008rxNohly8iaxnsbhlykj30u00u03z9.jpg',
            },
            'page_info': <String, Object?>{
              'type': 'topic',
              'object_type': 0,
              'page_pic': <String, Object?>{
                'url': 'https://wx3.sinaimg.cn/thumbnail/005Dk7Tjly1fwcghf1vwgj30mb0mbwk7.jpg',
              },
              'page_title': '【超话】warma',
              'content1': '这里是B站up主Warma的小社区…',
              'content2': '305989人关注',
            },
          },
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );

      expect(item, isNotNull);
      expect(item!.kind, ContentKind.repost);
      final ContentItem origin = item.origin!;

      // 19 位 String 的 id 走同一条 status URL 契约。
      expect(
        origin.id,
        IdHash.itemId(
          'weibo',
          'https://m.weibo.cn/status/5346379155378373',
        ),
      );
      expect(origin.authorName, '蓝色香蕉人');
      // 内层 user.id 仍是 int，仍要转成字符串。
      expect(origin.authorId, '7736078413');
      expect(origin.images.length, 4);
      expect(
        origin.images.first,
        'https://wx4.sinaimg.cn/mw2000/008rxNohgy1ihdrt7p76ej30u0140gs5.jpg',
      );
      // 旧版单图字段不被采用：否则会只剩 1 张，且 bmiddle 是明文 http。
      expect(origin.images.length, isNot(1));
      expect(origin.images.any((String u) => u.contains('/bmiddle/')), isFalse);
      expect(origin.summary, isNot(contains('<br')));
      expect(origin.publishedAt, DateTime.utc(2026, 9, 23, 10, 33, 4));
      // page_info.type=topic 不是视频。
      expect(origin.kind, ContentKind.dynamic);
      expect(origin.videoRef, isNull);
    });

    test('origin 只展开一层：嵌套转发的 origin.origin 为 null', () {
      final Map<String, Object?> nested = repost();
      final Map<String, Object?> inner =
          nested['retweeted_status']! as Map<String, Object?>;
      inner['retweeted_status'] = <String, Object?>{
        'id': '7001',
        'mid': '7001',
        'text': '更早的原微博',
        'user': user(name: '更早的作者'),
      };
      final ContentItem? item = WeiboParser.fromMblog(
        nested,
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.origin, isNotNull);
      expect(item.origin!.origin, isNull);
      // 序列化不会无限递归。
      expect(item.toJson()['origin'], isNotNull);
    });

    test('retweeted_status 是空 Map / 非 Map 时不算转发', () {
      for (final Object? bad in <Object?>[
        <String, Object?>{},
        null,
        'x',
        <Object?>[1],
      ]) {
        final ContentItem? item = WeiboParser.fromMblog(
          <String, Object?>{
            'id': '9002',
            'mid': '9002',
            'text': '不是转发',
            'retweeted_status': bad,
            'user': user(),
          },
          sub: sub,
          fetchedAt: fetchedAt,
        );
        expect(item, isNotNull, reason: 'bad=$bad');
        expect(item!.kind, ContentKind.dynamic, reason: 'bad=$bad');
        expect(item.origin, isNull, reason: 'bad=$bad');
      }
    });
  });

  group('视频分支（2026-10-27 真机实测样本）', () {
    /// 真实样本：`page_info` 的完整形态，来自 `.env/weibo_video_probe.md`。
    ///
    /// 这是一个**实测抓下来的**结构，不是臆想的：`media_info` 只有 3 个 key，
    /// 封面在 `page_pic.url`（不在 media_info 里），duration 是 double 秒。
    Map<String, Object?> realVideoPageInfo() => <String, Object?>{
          'type': 'video',
          'object_type': 11,
          'url_ori': 'http://t.cn/AXjXm7dN',
          'page_pic': <String, Object?>{
            'width': '480',
            'height': '853',
            'pid': '6a3e9e9ely1iig1ghpa4hj20u01hcmyz',
            'source': '21',
            'is_self_cover': '0',
            'type': '0',
            'url': 'https://wx4.sinaimg.cn/orj480/6a3e.jpeg',
          },
          'page_url': 'https://video.weibo.com/show?fid=1034:5358370303967334',
          'object_id': '1034:5358370303967334',
          'page_title': '_warma_的微博视频',
          'title': '来唱轻松快乐的生日快乐歌吧',
          'content1': '_warma_的微博视频',
          'content2': '来唱轻松快乐的生日快乐歌吧！[酷]',
          'video_orientation': 'vertical',
          'play_count': '6万次播放',
          'media_info': <String, Object?>{
            'stream_url': 'https://f.video.weibocdn.com/o0/bsr90E010.mp4?Expires=1',
            'stream_url_hd':
                'https://f.video.weibocdn.com/o0/bsr90E010.mp4?Expires=1',
            'duration': 26.331,
          },
          'urls': <String, Object?>{
            'mp4_720p_mp4': 'https://f.video.weibocdn.com/o0/iUdP0E.mp4?Expires=1',
            'mp4_hd_mp4': 'https://f.video.weibocdn.com/o0/bsr90E010.mp4?Expires=1',
            'mp4_ld_mp4': 'https://f.video.weibocdn.com/o0/bsr90E010.mp4?Expires=1',
          },
        };

    test('真实视频样本：直链 / 封面 / 时长 / 竖屏 全部按实测字段取出', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '9301',
          'mid': '9301',
          'text': '来唱轻松快乐的生日快乐歌吧',
          'page_info': realVideoPageInfo(),
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );

      expect(item, isNotNull);
      expect(item!.kind, ContentKind.video);

      final VideoRef ref = item.videoRef!;
      // 直链取 media_info.stream_url_hd（实测存在）。
      expect(
        ref.directVideoUrl,
        'https://f.video.weibocdn.com/o0/bsr90E010.mp4?Expires=1',
      );
      expect(item.isPlayable, isTrue);

      // **封面来自 page_info.page_pic.url** —— 这是最容易再改错的一条：
      // media_info 里根本没有封面字段，从那里找会永远拿不到封面。
      expect(ref.coverUrl, 'https://wx4.sinaimg.cn/orj480/6a3e.jpeg');

      // 时长：double 秒 26.331 → 26.331 秒（不是 26 毫秒）。
      expect(ref.duration, isNotNull);
      expect(ref.duration!.inMilliseconds, 26331);

      // 方向：video_orientation == "vertical"。
      expect(ref.isVertical, isTrue);
    });

    test('时长按量级判断：秒值 vs 毫秒值都不会被放大/缩小', () {
      ContentItem? build(Object? duration) => WeiboParser.fromMblog(
            <String, Object?>{
              'id': '9302',
              'mid': '9302',
              'text': 'x',
              'page_info': <String, Object?>{
                'type': 'video',
                'media_info': <String, Object?>{
                  'stream_url': 'https://x/v.mp4',
                  'duration': duration,
                },
              },
              'user': user(),
            },
            sub: sub,
            fetchedAt: fetchedAt,
          );

      // 实测形态：double 秒。
      expect(build(26.331)!.videoRef!.duration!.inMilliseconds, 26331);
      // 整数秒同样按秒算。
      expect(build(35)!.videoRef!.duration!.inSeconds, 35);
      // 大数按毫秒算（35 秒 = 35000 毫秒）。
      expect(build(35000)!.videoRef!.duration!.inSeconds, 35);
      // 缺字段 / 非正数 → null（不显示时长，不编 0）。
      expect(build(null)!.videoRef!.duration, isNull);
      expect(build(0)!.videoRef!.duration, isNull);
      expect(build(-5)!.videoRef!.duration, isNull);
      expect(build('abc')!.videoRef!.duration, isNull);
    });

    test('media_info 没有直链时退到 page_info.urls 的 mp4_720p_mp4', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '9303',
          'mid': '9303',
          'text': 'x',
          'page_info': <String, Object?>{
            'type': 'video',
            'page_pic': <String, Object?>{'url': 'https://wx4.sinaimg.cn/c.jpg'},
            'media_info': <String, Object?>{'duration': 10.0},
            'urls': <String, Object?>{
              'mp4_720p_mp4': 'https://f.video.weibocdn.com/o0/720.mp4',
            },
          },
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.videoRef!.directVideoUrl,
          'https://f.video.weibocdn.com/o0/720.mp4');
      expect(item.videoRef!.coverUrl, 'https://wx4.sinaimg.cn/c.jpg');
    });

    test('video_orientation 缺失 → isVertical 为 null（不猜方向）', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '9304',
          'mid': '9304',
          'text': 'x',
          'page_info': <String, Object?>{
            'type': 'video',
            'media_info': <String, Object?>{'stream_url': 'https://x/v.mp4'},
          },
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.videoRef!.isVertical, isNull);
    });

    test('horizontal → isVertical 为 false', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '9305',
          'mid': '9305',
          'text': 'x',
          'page_info': <String, Object?>{
            'type': 'video',
            'video_orientation': 'horizontal',
            'media_info': <String, Object?>{'stream_url': 'https://x/v.mp4'},
          },
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item!.videoRef!.isVertical, isFalse);
    });

    test('空 media_info 不算视频（防空壳误判）', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '9203',
          'mid': '9203',
          'text': '空 media_info',
          'page_info': <String, Object?>{
            'type': 'video',
            'media_info': <String, Object?>{},
          },
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.kind, ContentKind.dynamic);
      expect(item.videoRef, isNull);
    });

    test('封面回退：page_pic 缺失时用 mblog 首图', () {
      final ContentItem? item = WeiboParser.fromMblog(
        <String, Object?>{
          'id': '9204',
          'mid': '9204',
          'text': '视频 + 配图',
          'pic_num': 1,
          'pics': <Object?>[pic('v1')],
          'page_info': <String, Object?>{
            'media_info': <String, Object?>{'stream_url': 'https://x/v.mp4'},
          },
          'user': user(),
        },
        sub: sub,
        fetchedAt: fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.kind, ContentKind.video);
      expect(item.coverUrl, 'https://wx2.sinaimg.cn/mw2000/v1.jpg');
      expect(item.videoRef!.coverUrl, item.coverUrl);
    });
  });
}
