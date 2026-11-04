import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/utils/id_hash.dart';
import 'package:rrha/data/bili/bili_content_parser.dart';
import 'package:rrha/data/models/bili_user.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/subscription.dart';

/// 阶段 2（关注列表 → 时间线）的离线单测。
///
/// 重点覆盖两类「错了很难从现象反推」的地方：
/// 1. **id 算法必须与 RSS 路径一致** —— 否则数据源一换，整条时间线会被
///    错标成「新」，而且只错一次；
/// 2. 官方接口的字段名与 RSS 完全不同（`name` vs `uname`、`created` 秒 vs
///    RFC822 字符串、协议相对图片地址），抄错就是「全是空白卡片」。

Subscription _sub({String uid = '2267573'}) => Subscription(
      platform: Platform.bilibili,
      uid: uid,
      routes: <FeedRoute>{FeedRoute.bilibiliVideo, FeedRoute.bilibiliDynamic},
      addedAt: DateTime.utc(2026, 10, 15),
    );

final DateTime _now = DateTime.utc(2026, 10, 15, 12);

/// `/x/space/wbi/arc/search` → `data.list.vlist[]` 的真实形态。
Map<String, dynamic> _videoJson({
  String bvid = 'BV1QmpE6aEA7',
  int created = 1760000000,
}) =>
    <String, dynamic>{
      'aid': 117416285765897,
      'bvid': bvid,
      'title': '某个视频标题',
      'description': '简介第一行<br>简介第二行',
      'pic': '//i0.hdslb.com/bfs/archive/cover.jpg',
      'created': created,
      'author': '某UP主',
      'mid': 2267573,
      'play': 12345,
      'length': '10:00',
    };

/// `/x/polymer/web-dynamic/v1/feed/space` → `data.items[]` 的真实形态。
Map<String, dynamic> _dynamicJson({
  String idStr = '987654321098765432',
  String type = 'DYNAMIC_TYPE_AV',
  Map<String, dynamic>? major,
  String text = '这是一条动态正文',
  String? name,
  int pubTs = 1760000000,
  String? commentIdStr,
  int? commentType,
  bool includeBasic = true,
  String? face = 'https://i0.hdslb.com/bfs/face/avatar.jpg',
  // 计数字段。默认给一组真实形态的值；传 `includeStat: false` 模拟
  // 「部分形态缺 module_stat」（探针确认确实存在）。
  bool includeStat = true,
  int commentCount = 4,
  int likeCount = 62,
  int forwardCount = 1,
}) =>
    <String, dynamic>{
      'id_str': idStr,
      'type': type,
      // `basic` 是动态自己声明的评论入口（实测三种类型取值不同）。
      if (includeBasic)
        'basic': <String, dynamic>{
          if (commentIdStr != null) 'comment_id_str': commentIdStr,
          if (commentType != null) 'comment_type': commentType,
        },
      'modules': <String, dynamic>{
        'module_author': <String, dynamic>{
          'mid': 2267573,
          'name': name ?? '某UP主',
          if (face != null) 'face': face,
          'pub_ts': pubTs,
        },
        // 真实形态：`{count: int, forbidden: bool}`，且**只有**
        // comment / like / forward（没有 repost，探针实测为 null）。
        if (includeStat)
          'module_stat': <String, dynamic>{
            'comment': <String, dynamic>{'count': commentCount, 'forbidden': false},
            'like': <String, dynamic>{'count': likeCount, 'forbidden': false},
            'forward': <String, dynamic>{'count': forwardCount, 'forbidden': false},
          },
        'module_dynamic': <String, dynamic>{
          'desc': <String, dynamic>{'text': text},
          'major': major ??
              <String, dynamic>{
                'type': 'MAJOR_TYPE_ARCHIVE',
                'archive': <String, dynamic>{
                  'bvid': 'BV1dyn',
                  'title': '动态里的视频',
                  'cover': '//i0.hdslb.com/bfs/archive/dyn.jpg',
                  'desc': '视频简介',
                },
              },
        },
      },
    };

/// `/x/polymer/web-dynamic/v1/feed/all` 里转发动态的 `orig` 段。
///
/// 形态与主动态**完全同形**（实测 121 条样本：`orig` 从未缺失，
/// 内部同样有 `basic` / `id_str` / `modules` / 嵌套 `orig`）——
/// 所以复用同一个构造器造，不必另写一套字段映射。
///
/// 默认 id 刻意与 [_repostJson] 不同：解析层有「origin.id == self.id 就丢弃」
/// 的自引用保护，两边同 id 会让所有转发样本都被丢掉。
Map<String, dynamic> _originJson({
  String idStr = '1350000000000000001',
  String type = 'DYNAMIC_TYPE_DRAW',
  Map<String, dynamic>? major,
  String text = '这是原动态正文',
  String name = '原UP主',
  String? commentIdStr,
  int? commentType,
  Map<String, dynamic>? orig,
  bool includeOrig = false,
}) {
  final base = _dynamicJson(
    idStr: idStr,
    type: type,
    major: major,
    text: text,
    name: name,
    commentIdStr: commentIdStr,
    commentType: commentType,
  );
  if (includeOrig) base['orig'] = orig;
  return base;
}

/// 造一个「转发动态」，其 `orig` 由 [orig] 给出。
///
/// 默认 id 与 [_originJson] 的默认 id **不同**（见那边的注释）。
Map<String, dynamic> _repostJson({
  String idStr = '2222222222222222222',
  String text = '转发者说的话',
  Object? orig,
  bool includeOrig = true,
}) {
  final base = _dynamicJson(
    idStr: idStr,
    type: 'DYNAMIC_TYPE_FORWARD',
    text: text,
    commentIdStr: idStr,
    commentType: 17,
  );
  if (includeOrig) base['orig'] = orig;
  return base;
}

/// opus 形态的 9 图 dynamic（图片字段是 `url`，**不是** `src`）。
Map<String, dynamic> _ninePicDynamic({String idStr = '9000000000000000001'}) =>
    _dynamicJson(
      idStr: idStr,
      type: 'DYNAMIC_TYPE_DRAW',
      text: '九图动态',
      major: <String, dynamic>{
        'type': 'MAJOR_TYPE_OPUS',
        'opus': <String, dynamic>{
          'title': '',
          'summary': <String, dynamic>{'text': '九图动态'},
          'pics': <Object?>[
            for (int i = 1; i <= 9; i++)
              <String, dynamic>{
                'url': 'http://i0.hdslb.com/bfs/new_dyn/pic$i.jpg',
                'width': 1080,
                'height': 1440,
                'size': 200000,
                'live_url': null,
                'aigc': false,
                'warning': null,
              },
          ],
        },
      },
    );

void main() {
  group('BiliUser 解析', () {
    test('关注列表项：字段扁平，vip/official 是嵌套对象', () {
      final u = BiliUser.fromFollowingJson(<String, dynamic>{
        'mid': 2267573,
        'uname': '某UP主',
        'face': '//i0.hdslb.com/bfs/face/x.jpg',
        'sign': '简介',
        'fans': 12345,
        'official_verify': <String, dynamic>{'type': 0, 'desc': 'bilibili 知名UP主'},
        'vip': <String, dynamic>{'vipType': 2},
      });
      expect(u, isNotNull);
      expect(u!.mid, 2267573);
      expect(u.uname, '某UP主');
      expect(u.fans, 12345);
      expect(u.avatarUrl, 'https://i0.hdslb.com/bfs/face/x.jpg');
      expect(u.isVerified, isTrue);
      expect(u.officialTitle, 'bilibili 知名UP主');
      expect(u.isVip, isTrue);
      expect(u.uid, '2267573');
    });

    test('用户主页项：昵称字段是 name 而不是 uname', () {
      final u = BiliUser.fromSpaceInfoJson(<String, dynamic>{
        'mid': 2267573,
        'name': '主页昵称',
        'face': 'https://i0.hdslb.com/bfs/face/y.jpg',
        'official': <String, dynamic>{'title': '认证文案'},
        'vip': <String, dynamic>{'type': 1},
      });
      expect(u!.uname, '主页昵称');
      expect(u.officialTitle, '认证文案');
      expect(u.isVip, isTrue);
    });

    test('mid 缺失或非法 → null（不产出「UP 0」这种条目）', () {
      expect(BiliUser.fromFollowingJson(null), isNull);
      expect(BiliUser.fromFollowingJson(<String, dynamic>{}), isNull);
      expect(BiliUser.fromFollowingJson(<String, dynamic>{'mid': 0}), isNull);
      expect(BiliUser.fromFollowingJson(<String, dynamic>{'mid': -5}), isNull);
      expect(BiliUser.fromSpaceInfoJson(<String, dynamic>{'mid': 'abc'}), isNull);
    });

    test('昵称为空时 displayName 有兜底', () {
      final u = BiliUser.fromFollowingJson(<String, dynamic>{'mid': 42, 'uname': '  '});
      expect(u!.displayName, 'UP 42');
    });

    test('图片地址规范化：协议相对 / 明文 http / https / 空', () {
      expect(BiliUser.normalizeImageUrl('//i0.hdslb.com/a.jpg'),
          'https://i0.hdslb.com/a.jpg');
      expect(BiliUser.normalizeImageUrl('http://i0.hdslb.com/a.jpg'),
          'https://i0.hdslb.com/a.jpg');
      expect(BiliUser.normalizeImageUrl('https://i0.hdslb.com/a.jpg'),
          'https://i0.hdslb.com/a.jpg');
      expect(BiliUser.normalizeImageUrl('  '), isNull);
      expect(BiliUser.normalizeImageUrl(null), isNull);
    });
  });

  group('BiliFollowingPage 解析', () {
    test('正常分页：total 与 hasMore', () {
      final page = BiliFollowingPage.fromJson(<String, dynamic>{
        'code': 0,
        'data': <String, dynamic>{
          'total': 74,
          'list': <Object?>[
            <String, dynamic>{'mid': 1, 'uname': 'a'},
            <String, dynamic>{'mid': 2, 'uname': 'b'},
          ],
        },
      }, requestedPage: 1, requestedPageSize: 20);
      expect(page.users.length, 2);
      expect(page.total, 74);
      expect(page.hasMore, isTrue);
    });

    test('最后一页 hasMore=false', () {
      final page = BiliFollowingPage.fromJson(<String, dynamic>{
        'data': <String, dynamic>{'total': 20, 'list': <Object?>[]},
      }, requestedPage: 1, requestedPageSize: 20);
      expect(page.hasMore, isFalse);
    });

    test('data 缺失/结构异常 → 空页而不是崩', () {
      expect(BiliFollowingPage.fromJson(<String, dynamic>{}, requestedPage: 1, requestedPageSize: 20).isEmpty, isTrue);
      expect(
        BiliFollowingPage.fromJson(<String, dynamic>{'data': 'oops'},
            requestedPage: 1, requestedPageSize: 20).isEmpty,
        isTrue,
      );
    });
  });

  group('投稿视频 → ContentItem', () {
    test('字段映射完整', () {
      final item = BiliContentParser.fromUserVideo(
        _videoJson(),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNotNull);
      expect(item!.platform, Platform.bilibili);
      expect(item.kind, ContentKind.video);
      expect(item.sourceId, 'bilibili:2267573');
      expect(item.authorName, '某UP主');
      expect(item.authorId, '2267573');
      expect(item.title.contains('某个视频标题'), isTrue);
      expect(item.summary.contains('<br>'), isFalse);
      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/archive/cover.jpg');
      expect(item.link, 'https://www.bilibili.com/video/BV1QmpE6aEA7');
      expect(item.videoRef?.bvid, 'BV1QmpE6aEA7');
      expect(item.videoRef?.aid, 117416285765897);
      expect(item.isPlayable, isTrue);
      expect(item.hasReliableTime, isTrue);
      expect(
        item.publishedAt,
        DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000, isUtc: true),
      );
    });

    test('id 与 RSS 路径同算法 —— 同一视频无论走哪条路 id 必须一致', () {
      final item = BiliContentParser.fromUserVideo(
        _videoJson(),
        sub: _sub(),
        fetchedAt: _now,
      );
      // RSSHub 的 bilibili 路由把视频页链接当作 guid。
      expect(
        item!.id,
        IdHash.itemId('bilibili', 'https://www.bilibili.com/video/BV1QmpE6aEA7'),
      );
    });

    test('created=0 时不给假时间（hasReliableTime=false，回落到抓取时间）', () {
      final item = BiliContentParser.fromUserVideo(
        _videoJson(created: 0),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.publishedAt, isNull);
      expect(item.hasReliableTime, isFalse);
      expect(item.sortKey, _now);
    });

    test('缺 bvid 但有 aid 时用 av 链接兜底', () {
      final json = _videoJson()..remove('bvid');
      final item = BiliContentParser.fromUserVideo(json, sub: _sub(), fetchedAt: _now);
      expect(item!.id, IdHash.itemId('bilibili', 'https://www.bilibili.com/video/av117416285765897'));
      expect(item.videoRef?.bvid, isNull);
      expect(item.isPlayable, isFalse, reason: '没有 bvid 就不该声称能播');
    });

    test('既无 bvid 又无 aid → 丢弃', () {
      expect(
        BiliContentParser.fromUserVideo(
          <String, dynamic>{'title': 'x'},
          sub: _sub(),
          fetchedAt: _now,
        ),
        isNull,
      );
      expect(BiliContentParser.fromUserVideo(null, sub: _sub(), fetchedAt: _now), isNull);
    });
  });

  group('UP 主动态 → ContentItem', () {
    test('视频动态：kind=video 且带 bvid', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNotNull);
      expect(item!.kind, ContentKind.video);
      expect(item.videoRef?.bvid, 'BV1dyn');
      expect(item.link, 'https://www.bilibili.com/video/BV1dyn');
      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/archive/dyn.jpg');
      expect(item.authorName, '某UP主');
      expect(item.publishedAt,
          DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000, isUtc: true));
    });

    test('图文动态：取首图当封面，kind=dynamic', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_DRAW',
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_DRAW',
            'draw': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{'src': '//i0.hdslb.com/bfs/new_dyn/1.jpg'},
                <String, dynamic>{'src': '//i0.hdslb.com/bfs/new_dyn/2.jpg'},
              ],
            },
          },
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.kind, ContentKind.dynamic);
      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/new_dyn/1.jpg');
      expect(item.videoRef, isNull);
      expect(item.isPlayable, isFalse);
    });

    test('纯文本动态：没有封面也不丢，标题回落正文', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_WORD',
          major: <String, dynamic>{'type': 'MAJOR_TYPE_NONE'},
          text: '今天只想说一句话',
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNotNull);
      expect(item!.coverUrl, isNull);
      expect(item.displayTitle.contains('今天只想说一句话'), isTrue);
      expect(item.summary.contains('今天只想说一句话'), isTrue);
    });

    test('转发动态：kind=repost', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(type: 'DYNAMIC_TYPE_FORWARD'),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.kind, ContentKind.repost);
    });

    test('缺 id_str → 丢弃（没有稳定 id 就没法做已读标记）', () {
      final json = _dynamicJson()..remove('id_str');
      expect(BiliContentParser.fromDynamic(json, sub: _sub(), fetchedAt: _now), isNull);
    });

    test('完全空白（无标题/正文/封面）→ 丢弃', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_WORD',
          major: <String, dynamic>{'type': 'MAJOR_TYPE_NONE'},
          text: '   ',
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNull);
    });

    test('纯图片动态：没有文字时标题如实标成 [图片]，条目不丢', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_DRAW',
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_DRAW',
            'draw': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{'src': '//i0.hdslb.com/bfs/new_dyn/pic.jpg'},
              ],
            },
          },
          text: '   ',
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNotNull);
      expect(item!.title, '[图片]');
      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/new_dyn/pic.jpg');
    });

    test('opus 形态动态：正文在 major.opus.summary.text 里也要能取到', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_DRAW',
          text: '', // 旧字段为空，模拟新版形态
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'title': '',
              'summary': <String, dynamic>{'text': '这是 opus 形态的正文'},
              'pics': <Object?>[
                <String, dynamic>{'url': '//i0.hdslb.com/bfs/opus/cover.jpg'},
              ],
            },
          },
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNotNull);
      expect(item!.summary.contains('opus 形态的正文'), isTrue);
      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/opus/cover.jpg');
    });

    test('非视频动态：id 用 t.bilibili.com 链接做 hash', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          idStr: '555',
          type: 'DYNAMIC_TYPE_WORD',
          major: <String, dynamic>{'type': 'MAJOR_TYPE_NONE'},
          text: '纯文本动态',
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.id, IdHash.itemId('bilibili', 'https://t.bilibili.com/555'));
    });

    test('视频类动态与投稿列表产出同一个 id —— 否则时间线会出现重复卡片', () {
      final fromFeed = BiliContentParser.fromUserVideo(
        _videoJson(bvid: 'BV1dyn'),
        sub: _sub(),
        fetchedAt: _now,
      );
      final fromDynamic = BiliContentParser.fromDynamic(
        _dynamicJson(idStr: '666'),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(fromFeed, isNotNull);
      expect(fromDynamic, isNotNull);
      expect(fromFeed!.id, fromDynamic!.id);
      expect(
        fromFeed.id,
        IdHash.itemId('bilibili', 'https://www.bilibili.com/video/BV1dyn'),
      );
    });
  });

  // 评论入口的取值**必须照抄动态自己声明的 basic 字段**。
  // 实测（.env/probe_dynamic_basic.py）：图文动态的 oid 是图片 id 而不是动态 id，
  // 拿动态 id 去凑只会 -404；视频投稿动态则要用 aid + type=1。
  group('评论入口（oid / type）', () {
    test('视频投稿动态：oid 是 aid，type=1', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_AV',
          commentIdStr: '117445276730927',
          commentType: 1,
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentOid, '117445276730927');
      expect(item.commentType, 1);
      expect(item.hasComments, isTrue);
    });

    test('图文动态：oid 是图片 id（与动态 id 不同），type=11', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          idStr: '1259405744065740856',
          type: 'DYNAMIC_TYPE_DRAW',
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'title': '图文动态',
              'summary': <String, dynamic>{'text': '正文'},
            },
          },
          commentIdStr: '412316884',
          commentType: 11,
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentOid, '412316884');
      // 关键点：**不是**动态 id —— 这正是早先按「动态 id + 17」猜测时会 -404 的地方。
      expect(item.commentOid, isNot('1259405744065740856'));
      expect(item.commentType, 11);
    });

    test('转发动态：oid 是动态 id_str（大整数按字符串保留），type=17', () {
      const idStr = '1259424959743131672';
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          idStr: idStr,
          type: 'DYNAMIC_TYPE_FORWARD',
          commentIdStr: idStr,
          commentType: 17,
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentOid, idStr);
      expect(item.commentType, 17);
      // 19 位大整数不做数值转换，字符串原样保留。
      expect(item.commentOid!.length, 19);
    });

    test('basic 缺失时回退到「动态 id + 17」，不产出空入口', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(idStr: '777', includeBasic: false),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentOid, '777');
      expect(item.commentType, 17);
    });

    test('投稿列表项：视频的评论入口是 aid + type=1', () {
      final item = BiliContentParser.fromUserVideo(
        _videoJson(),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentOid, '117416285765897');
      expect(item.commentType, 1);
      expect(item.hasComments, isTrue);
    });

    test('没有评论入口时 hasComments 为 false（UI 会说明而不是空转）', () {
      final item = ContentItem(
        id: 'x',
        platform: Platform.bilibili,
        kind: ContentKind.dynamic,
        sourceId: 's',
        authorName: 'a',
        title: 't',
        summary: '',
        link: '',
        fetchedAt: _now,
      );
      expect(item.hasComments, isFalse);
    });
  });

  // 图片列表的字段名是**实测**出来的（2026-10-16，`.env/probe_media_repost.py`
  // 与 `probe_media_repost2.py`，`feed/all` 连翻 6 页共 121 条真实动态）：
  // 新版在 `major.opus.pics[].url`，元素是 url/width/height/size/live_url/aigc/warning；
  // 旧版在 `major.draw.items[].src`（本批 0 次，仍要兼容）。
  // 照抄 `src` 会一条图都取不到 —— 这正是「多图只显示第一张 / 没图」的根因。
  group('动态图片列表（images）', () {
    test('opus.pics 9 张：images 长度 9 且全部是 https', () {
      final item = BiliContentParser.fromDynamic(
        _ninePicDynamic(),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNotNull);
      expect(item!.images.length, 9);
      for (final u in item.images) {
        expect(u.startsWith('https://'), isTrue, reason: '明文 http 在 Android 9+ 会直接裂图');
      }
      expect(item.images.first, 'https://i0.hdslb.com/bfs/new_dyn/pic1.jpg');
      expect(item.images.last, 'https://i0.hdslb.com/bfs/new_dyn/pic9.jpg');
      // coverUrl 的语义钉死成 images.first，时间线卡片因此零改动。
      expect(item.coverUrl, item.images.first);
      expect(item.hasMultipleImages, isTrue);
    });

    test('draw.items[].src 旧形态仍然兼容', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_DRAW',
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_DRAW',
            'draw': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{'src': '//i0.hdslb.com/bfs/new_dyn/a.jpg'},
                <String, dynamic>{'src': 'http://i0.hdslb.com/bfs/new_dyn/b.jpg'},
                <String, dynamic>{'src': 'https://i0.hdslb.com/bfs/new_dyn/c.jpg'},
              ],
            },
          },
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.images.length, 3);
      expect(item.images, <String>[
        'https://i0.hdslb.com/bfs/new_dyn/a.jpg',
        'https://i0.hdslb.com/bfs/new_dyn/b.jpg',
        'https://i0.hdslb.com/bfs/new_dyn/c.jpg',
      ]);
    });

    test('draw.items 里个别元素用 url 也能取到（个别接口版本的形态）', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_DRAW',
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_DRAW',
            'draw': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{'url': '//i0.hdslb.com/bfs/new_dyn/u.jpg'},
              ],
            },
          },
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.images, <String>['https://i0.hdslb.com/bfs/new_dyn/u.jpg']);
    });

    test('去重与空串过滤：同一张图出现两次只留一份', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_DRAW',
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'title': 't',
              'summary': <String, dynamic>{'text': 'text'},
              // 第 2、3 项与第 1 项同图（不同协议形态），第 4 项是空串，第 5 项不是 Map。
              'pics': <Object?>[
                <String, dynamic>{'url': 'http://i0.hdslb.com/x.jpg'},
                <String, dynamic>{'url': 'https://i0.hdslb.com/x.jpg'},
                <String, dynamic>{'url': 'http://i0.hdslb.com/x.jpg'},
                <String, dynamic>{'url': '   '},
                'not-a-map',
              ],
            },
          },
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.images, <String>['https://i0.hdslb.com/x.jpg']);
      expect(item.hasMultipleImages, isFalse);
    });

    test('opus 与 draw 同时存在时以 opus 为准，且不重复计入同一张', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_DRAW',
          major: <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'title': 't',
              'pics': <Object?>[
                <String, dynamic>{'url': 'https://i0.hdslb.com/same.jpg'},
                <String, dynamic>{'url': 'https://i0.hdslb.com/opus2.jpg'},
              ],
            },
            'draw': <String, dynamic>{
              'items': <Object?>[
                <String, dynamic>{'src': 'https://i0.hdslb.com/same.jpg'},
                <String, dynamic>{'src': 'https://i0.hdslb.com/draw2.jpg'},
              ],
            },
          },
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.images, <String>[
        'https://i0.hdslb.com/same.jpg',
        'https://i0.hdslb.com/opus2.jpg',
        'https://i0.hdslb.com/draw2.jpg',
      ]);
    });

    test('视频动态：images 只有封面那一张，coverUrl 与 videoRef.coverUrl 一致', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(idStr: '888'),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.images, <String>['https://i0.hdslb.com/bfs/archive/dyn.jpg']);
      expect(item.coverUrl, 'https://i0.hdslb.com/bfs/archive/dyn.jpg');
      expect(item.videoRef?.coverUrl, item.coverUrl);
      expect(item.hasMultipleImages, isFalse);
    });

    test('投稿视频（fromUserVideo）也填 images，封面可点开大图', () {
      final item = BiliContentParser.fromUserVideo(
        _videoJson(),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.images, <String>['https://i0.hdslb.com/bfs/archive/cover.jpg']);
    });

    test('投稿视频缺封面时 images 为空（不是含一个空串）', () {
      final json = _videoJson()..remove('pic');
      final item = BiliContentParser.fromUserVideo(json, sub: _sub(), fetchedAt: _now);
      expect(item!.images, isEmpty);
      expect(item.coverUrl, isNull);
    });

    test('无图无正文无标题：仍然按原语义丢弃', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(
          type: 'DYNAMIC_TYPE_WORD',
          major: <String, dynamic>{'type': 'MAJOR_TYPE_NONE'},
          text: '   ',
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNull);
    });

    test('有图但没有文字：条目不丢，标题是 [图片]（判定依据从首图换成全部图后语义不变）', () {
      final item = BiliContentParser.fromDynamic(
        _ninePicDynamic(idStr: '7777777777777777777'),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item, isNotNull);
      expect(item!.title, '九图动态');
    });
  });

  // 转发动态的原动态：实测 121 条里转发 36 条、`orig` **从未缺失**，
  // orig.type 分布 = DYNAMIC_TYPE_AV 31 / DYNAMIC_TYPE_DRAW 4 / DYNAMIC_TYPE_ARTICLE 1。
  group('转发动态 → origin（只展开一层）', () {
    test('orig 是视频动态：origin 的 bvid / 封面正确', () {
      final item = BiliContentParser.fromDynamic(
        _repostJson(
          orig: _originJson(
            idStr: '1350000000000000001',
            type: 'DYNAMIC_TYPE_AV',
            name: '被转发的UP',
            major: <String, dynamic>{
              'type': 'MAJOR_TYPE_ARCHIVE',
              'archive': <String, dynamic>{
                'bvid': 'BV1orig',
                'title': '原动态里的视频',
                'cover': '//i0.hdslb.com/bfs/archive/orig.jpg',
              },
            },
          ),
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.kind, ContentKind.repost);
      final origin = item.origin;
      expect(origin, isNotNull);
      expect(origin!.videoRef?.bvid, 'BV1orig');
      expect(origin.kind, ContentKind.video);
      expect(origin.authorName, '被转发的UP');
      expect(origin.images, <String>['https://i0.hdslb.com/bfs/archive/orig.jpg']);
    });

    test('orig 是图文动态：origin.images 拿到全部图片', () {
      final item = BiliContentParser.fromDynamic(
        _repostJson(
          orig: _originJson(
            idStr: '1350000000000000002',
            type: 'DYNAMIC_TYPE_DRAW',
            name: '图文原UP',
            major: <String, dynamic>{
              'type': 'MAJOR_TYPE_OPUS',
              'opus': <String, dynamic>{
                'title': '',
                'summary': <String, dynamic>{'text': '原动态图文正文'},
                'pics': <Object?>[
                  <String, dynamic>{'url': 'http://i0.hdslb.com/o1.jpg'},
                  <String, dynamic>{'url': 'http://i0.hdslb.com/o2.jpg'},
                ],
              },
            },
            // 实测：原动态的评论入口是空的。
            commentIdStr: '',
            commentType: 0,
          ),
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      final origin = item!.origin!;
      expect(origin.images.length, 2);
      expect(origin.images.first, 'https://i0.hdslb.com/o1.jpg');
      expect(origin.summary, '这是原动态正文');
      expect(origin.authorName, '图文原UP');
      // 原动态拿不到评论入口 → UI 落到既有的诚实兜底文案。
      expect(origin.hasComments, isFalse);
    });

    test('原动态正文为空时用 major.opus.summary.text 兜底（图文原动态的正文只在这）', () {
      final item = BiliContentParser.fromDynamic(
        _repostJson(
          orig: _originJson(
            idStr: '1350000000000000003',
            type: 'DYNAMIC_TYPE_DRAW',
            text: '',
            major: <String, dynamic>{
              'type': 'MAJOR_TYPE_OPUS',
              'opus': <String, dynamic>{
                'title': '',
                'summary': <String, dynamic>{'text': '正文只在 summary 里'},
                'pics': <Object?>[
                  <String, dynamic>{'url': 'http://i0.hdslb.com/o3.jpg'},
                ],
              },
            },
          ),
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.origin!.summary.contains('正文只在 summary 里'), isTrue);
    });

    test('orig 缺失 / 为 null / 非 Map / 空 Map → origin 为 null 且不抛异常', () {
      for (final raw in <Object?>[null, 'oops', 42, <String, dynamic>{}, <Object?>[]]) {
        final item = BiliContentParser.fromDynamic(
          _repostJson(orig: raw),
          sub: _sub(),
          fetchedAt: _now,
        );
        expect(item, isNotNull, reason: 'orig=$raw 时整条不该丢');
        expect(item!.kind, ContentKind.repost);
        expect(item.origin, isNull, reason: 'orig=$raw');
      }
    });

    test('连 orig 键都没有 → origin 为 null', () {
      final item = BiliContentParser.fromDynamic(
        _repostJson(orig: null, includeOrig: false),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.origin, isNull);
    });

    test('嵌套转发只展开一层：origin.origin 必须是 null', () {
      final item = BiliContentParser.fromDynamic(
        _repostJson(
          idStr: '2222222222222222223',
          orig: _originJson(
            idStr: '1350000000000000104',
            type: 'DYNAMIC_TYPE_FORWARD',
            // 中间这层是**另一个**视频，避免与主动态撞同一个 bvid 派生 id。
            major: <String, dynamic>{
              'type': 'MAJOR_TYPE_ARCHIVE',
              'archive': <String, dynamic>{
                'bvid': 'BV1mid',
                'title': '中间那层的视频',
                'cover': '//i0.hdslb.com/bfs/archive/mid.jpg',
              },
            },
            includeOrig: true,
            orig: _originJson(
              idStr: '1350000000000000105',
              type: 'DYNAMIC_TYPE_DRAW',
              major: <String, dynamic>{
                'type': 'MAJOR_TYPE_OPUS',
                'opus': <String, dynamic>{
                  'title': '最深那层',
                  'summary': <String, dynamic>{'text': '最深那层正文'},
                  'pics': <Object?>[
                    <String, dynamic>{'url': 'http://i0.hdslb.com/deep.jpg'},
                  ],
                },
              },
            ),
          ),
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.origin, isNotNull);
      expect(item.origin!.kind, ContentKind.repost);
      expect(item.origin!.origin, isNull,
          reason: 'depth 上限 1：再往下展开会让 JSON 与 UI 都不收敛');
    });

    test('转发同一条视频投稿（主动态与原动态 bvid 相同）时 origin 不能丢', () {
      // 这是一个**真实形态**：转发别人的视频投稿，看板里主动态与原动态都是
      // major.archive 且 bvid 一样 —— 于是两者算出来的 ContentItem.id **完全相同**。
      // 早期实现用 id 做自引用判定，把这种正常转发整块丢掉了（单测撞出来的）。
      final same = <String, dynamic>{
        'type': 'MAJOR_TYPE_ARCHIVE',
        'archive': <String, dynamic>{
          'bvid': 'BV1same',
          'title': '同一个视频',
          'cover': '//i0.hdslb.com/bfs/archive/same.jpg',
        },
      };
      // 主动态**自己也带**同一个视频的 major.archive（转发时服务端就是这么回的），
      // 所以两边的 id 都会走 bvid 分支、算出同一个 id。
      final top = _repostJson(
        idStr: '2222222222222222224',
        orig: _originJson(
          idStr: '1350000000000000106',
          type: 'DYNAMIC_TYPE_AV',
          name: '视频原UP',
          major: same,
        ),
      );
      ((top['modules'] as Map)['module_dynamic'] as Map)['major'] = same;

      final item = BiliContentParser.fromDynamic(
        top,
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.origin, isNotNull, reason: 'id 相同不等于同一条动态，不能用 id 判自引用');
      expect(item.id, item.origin!.id, reason: '两者确实是同一个视频，id 本就该相同');
      expect(item.origin!.authorName, '视频原UP');
    });

    test('原动态 id 与主动态相同 → 丢弃（防自引用）', () {
      const sameId = '1350000000000000006';
      final item = BiliContentParser.fromDynamic(
        _repostJson(
          idStr: sameId,
          orig: _originJson(idStr: sameId, text: '其实是同一条'),
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.origin, isNull);
    });

    test('非转发动态不会去读 orig（只有 repost 才展示原动态区块）', () {
      final base = _dynamicJson(
        idStr: '1350000000000000007',
        type: 'DYNAMIC_TYPE_DRAW',
        major: <String, dynamic>{
          'type': 'MAJOR_TYPE_OPUS',
          'opus': <String, dynamic>{
            'title': 't',
            'summary': <String, dynamic>{'text': 'x'},
            'pics': <Object?>[
              <String, dynamic>{'url': 'http://i0.hdslb.com/z.jpg'},
            ],
          },
        },
      );
      // 服务端偶尔在非转发条目上也带 orig —— 解析层照收，但 kind 不是 repost，
      // UI 不会渲染「原动态」区块。
      base['orig'] = _originJson(idStr: '1350000000000000008');
      final item = BiliContentParser.fromDynamic(base, sub: _sub(), fetchedAt: _now);
      expect(item!.kind, ContentKind.dynamic);
      expect(item.origin, isNotNull);
    });

    test('主动态与 origin 的评论入口互不影响（转发 17 / 原动态为空）', () {
      final item = BiliContentParser.fromDynamic(
        _repostJson(
          idStr: '1350000000000000009',
          orig: _originJson(
            idStr: '1350000000000000010',
            commentIdStr: '',
            commentType: 0,
          ),
        ),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentOid, '1350000000000000009');
      expect(item.commentType, 17);
      expect(item.hasComments, isTrue);
      expect(item.origin!.hasComments, isFalse);
    });
  });

  // 用户需求：「卡片显示真实评论数和点赞数」「B 站卡片显示博主头像」。
  //
  // 这几条盯的都是**数据层有没有真的取到**，而不是卡片画得对不对：
  // 卡片拿不到字段时只会「不显示数字 / 显示首字占位」，看起来像正常降级，
  // 所以只有这里能证明字段路径是对的。
  group('头像与计数（卡片数据来源）', () {
    test('头像取 module_author.face，并归一化成 https', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(face: 'http://i0.hdslb.com/bfs/face/a.jpg'),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.authorAvatar, 'https://i0.hdslb.com/bfs/face/a.jpg');
    });

    test('协议相对头像（//host/...）也能补成 https', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(face: '//i1.hdslb.com/bfs/face/b.jpg'),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.authorAvatar, 'https://i1.hdslb.com/bfs/face/b.jpg');
    });

    test('face 缺失时头像为 null（卡片退回首字占位，不显示裂图）', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(face: null),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.authorAvatar, isNull);
    });

    test('评论 / 点赞 / 转发取 module_stat 的 count', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(commentCount: 674, likeCount: 3765, forwardCount: 10),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentCount, 674);
      expect(item.likeCount, 3765);
      // 转发数在 B 站叫 forward（探针确认没有 repost 键）。
      expect(item.repostCount, 10);
    });

    test('module_stat 缺失时三个计数都是 null，不是 0', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(includeStat: false),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentCount, isNull);
      expect(item.likeCount, isNull);
      expect(item.repostCount, isNull);
    });

    test('计数确实是 0 时保留 0（与「没给」区分开）', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(commentCount: 0, likeCount: 0, forwardCount: 0),
        sub: _sub(),
        fetchedAt: _now,
      );
      expect(item!.commentCount, 0);
      expect(item.likeCount, 0);
      expect(item.repostCount, 0);
    });

    test('计数兼容「直接给 int」的旧形态', () {
      final base = _dynamicJson();
      final modules = base['modules'] as Map<String, dynamic>;
      modules['module_stat'] = <String, dynamic>{
        'comment': 12,
        'like': 34,
        'forward': 56,
      };
      final item = BiliContentParser.fromDynamic(base, sub: _sub(), fetchedAt: _now);
      expect(item!.commentCount, 12);
      expect(item.likeCount, 34);
      expect(item.repostCount, 56);
    });

    test('计数与头像能穿过缓存往返（toJson → fromJson 不丢）', () {
      final item = BiliContentParser.fromDynamic(
        _dynamicJson(commentCount: 7, likeCount: 88, forwardCount: 9),
        sub: _sub(),
        fetchedAt: _now,
      );
      final restored = ContentItem.fromJson(item!.toJson());
      expect(restored!.authorAvatar, item.authorAvatar);
      expect(restored.commentCount, 7);
      expect(restored.likeCount, 88);
      expect(restored.repostCount, 9);
    });

    test('旧缓存没有计数字段时回落 null（不显示假 0）', () {
      final item = BiliContentParser.fromDynamic(_dynamicJson(), sub: _sub(), fetchedAt: _now);
      final json = item!.toJson()
        ..remove('commentCount')
        ..remove('likeCount')
        ..remove('repostCount');
      final restored = ContentItem.fromJson(json);
      expect(restored!.commentCount, isNull);
      expect(restored.likeCount, isNull);
      expect(restored.repostCount, isNull);
    });
  });
}
