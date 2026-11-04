import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/models/danmaku_item.dart';
import 'package:rrha/data/models/subscription.dart';
import 'package:rrha/data/models/video_ref.dart';

ContentItem _item({
  String id = 'bilibili:abc',
  Platform platform = Platform.bilibili,
  ContentKind kind = ContentKind.video,
  String title = '标题',
  String summary = '正文',
  DateTime? publishedAt,
  DateTime? fetchedAt,
  VideoRef? videoRef,
  bool isNew = false,
  List<String> images = const <String>[],
  ContentItem? origin,
}) =>
    ContentItem(
      id: id,
      platform: platform,
      kind: kind,
      sourceId: '${platform.key}:2267573',
      authorName: 'UP',
      authorId: '2267573',
      title: title,
      summary: summary,
      coverUrl: 'https://x/c.jpg',
      images: images,
      origin: origin,
      publishedAt: publishedAt,
      fetchedAt: fetchedAt ?? DateTime.utc(2024, 10, 3),
      link: 'https://www.bilibili.com/video/BV1xx411c7mD',
      videoRef: videoRef ?? const VideoRef(bvid: 'BV1xx411c7mD', page: 2),
      rawGuid: 'BV1xx411c7mD',
      isNew: isNew,
    );

void main() {
  group('ContentItem JSON 往返', () {
    test('字段保持一致（缓存与降级都依赖它）', () {
      final item = _item(publishedAt: DateTime.utc(2024, 10, 2, 5));
      final restored = ContentItem.fromJson(item.toJson());

      expect(restored, isNotNull);
      expect(restored!.id, item.id);
      expect(restored.platform, Platform.bilibili);
      expect(restored.kind, ContentKind.video);
      expect(restored.sourceId, item.sourceId);
      expect(restored.title, item.title);
      expect(restored.summary, item.summary);
      expect(restored.coverUrl, item.coverUrl);
      expect(restored.publishedAt, item.publishedAt);
      expect(restored.fetchedAt, item.fetchedAt);
      expect(restored.link, item.link);
      expect(restored.videoRef?.bvid, 'BV1xx411c7mD');
      expect(restored.videoRef?.page, 2);
      expect(restored.isPlayable, isTrue);
    });

    test('缺时间与缺封面时也能往返', () {
      final item = _item(
        publishedAt: null,
        videoRef: const VideoRef(),
      );
      final restored = ContentItem.fromJson(item.toJson())!;
      expect(restored.publishedAt, isNull);
      expect(restored.coverUrl, 'https://x/c.jpg');
    });

    test('损坏数据返回 null 而不是抛异常', () {
      expect(ContentItem.fromJson(<String, dynamic>{}), isNull);
      expect(
        ContentItem.fromJson(<String, dynamic>{'id': 'x', 'platform': 'weird'}),
        isNull,
      );
    });
  });

  group('ContentItem 派生属性', () {
    test('displayTitle 在标题为空时回落正文首行', () {
      final item = _item(title: '', summary: '一段正文\n第二行');
      expect(item.displayTitle, '一段正文 第二行');
    });

    test('标题与正文都为空时给出兜底文案', () {
      expect(_item(title: '', summary: '').displayTitle, '（无标题）');
    });

    test('sortKey 在缺发布时间时回落抓取时间', () {
      final fetched = DateTime.utc(2024, 5, 1);
      final item = _item(publishedAt: null, fetchedAt: fetched);
      expect(item.sortKey, fetched);
    });

    test('微博：没有直链即视为不可播（不伪造播放能力）', () {
      final noVideo = _item(
        platform: Platform.weibo,
        kind: ContentKind.dynamic,
        videoRef: const VideoRef(coverUrl: 'https://x/c.jpg'),
      );
      expect(noVideo.isPlayable, isFalse);

      final withVideo = _item(
        platform: Platform.weibo,
        kind: ContentKind.video,
        videoRef: const VideoRef(directVideoUrl: 'https://x/a.mp4'),
      );
      expect(withVideo.isPlayable, isTrue);
    });

    test('B 站：有 bvid 才可播', () {
      expect(_item(videoRef: const VideoRef()).isPlayable, isFalse);
      expect(_item(videoRef: const VideoRef(bvid: 'BV1xx411c7mD')).isPlayable, isTrue);
    });

    test('copyWith 只改 isNew，其余字段保持', () {
      final item = _item();
      final updated = item.copyWith(isNew: true);
      expect(updated.isNew, isTrue);
      expect(updated.id, item.id);
      expect(updated.title, item.title);
      expect(item.isNew, isFalse, reason: '原对象不应被修改');
    });

    test('copyWith 保留 images 与 origin', () {
      final origin = _item(id: 'bilibili:origin', title: '原动态');
      final item = _item(
        images: const <String>['https://x/1.jpg', 'https://x/2.jpg'],
        origin: origin,
      );
      final updated = item.copyWith(isNew: true);
      expect(updated.images, item.images);
      expect(updated.origin?.id, 'bilibili:origin');
      expect(updated.copyWith(isNew: true).origin?.title, '原动态');
    });
  });

  // 图片列表与转发原动态是这一轮新增的模型字段。它们的持久化**必须**往返一致：
  // 时间线缓存走的是原始 JSON，但降级缓存与已读标记之外还有别的读法，
  // 一旦往返丢字段，表现是「重启后图片/原动态消失」这种很难归因的现象。
  group('ContentItem 新增字段（images / origin）', () {
    test('toJson / fromJson 往返保留 images', () {
      final item = _item(
        images: const <String>['https://x/1.jpg', 'https://x/2.jpg', 'https://x/3.jpg'],
      );
      final restored = ContentItem.fromJson(item.toJson())!;
      expect(restored.images, item.images);
      expect(restored.images.length, 3);
      expect(restored.coverUrl, item.coverUrl, reason: 'coverUrl 的语义不变');
    });

    test('toJson / fromJson 往返保留 origin（含它自己的 images 与视频信息）', () {
      final origin = ContentItem(
        id: 'bilibili:origin',
        platform: Platform.bilibili,
        kind: ContentKind.repost,
        sourceId: 'bilibili:2267573',
        authorName: '原UP',
        title: '原动态标题',
        summary: '原动态正文',
        link: 'https://t.bilibili.com/1350000000000000001',
        fetchedAt: DateTime.utc(2024, 10, 3),
        publishedAt: DateTime.utc(2024, 10, 2, 5),
        coverUrl: 'https://x/o1.jpg',
        images: const <String>['https://x/o1.jpg', 'https://x/o2.jpg'],
        videoRef: const VideoRef(bvid: 'BV1origin', aid: 42),
      );
      final item = _item(images: const <String>['https://x/c.jpg'], origin: origin);

      final restored = ContentItem.fromJson(item.toJson())!;
      expect(restored.origin, isNotNull);
      expect(restored.origin!.id, 'bilibili:origin');
      expect(restored.origin!.authorName, '原UP');
      expect(restored.origin!.summary, '原动态正文');
      expect(restored.origin!.images, origin.images);
      expect(restored.origin!.videoRef?.bvid, 'BV1origin');
      expect(restored.origin!.videoRef?.aid, 42);
      expect(restored.origin!.publishedAt, DateTime.utc(2024, 10, 2, 5));
      // 只展开一层：origin 的 origin 恒为 null，序列化不会无限递归。
      expect(restored.origin!.origin, isNull);
      expect(restored.origin!.toJson()['origin'], isNull);
    });

    test('旧数据缺 images / origin 键 → 回落空列表与 null，不判成损坏', () {
      final legacy = <String, dynamic>{
        'id': 'bilibili:legacy',
        'platform': 'bilibili',
        'kind': 'dynamic',
        'sourceId': 'bilibili:1',
        'authorName': 'UP',
        'title': '旧缓存条目',
        'summary': '正文',
        'coverUrl': 'https://x/old.jpg',
        'fetchedAt': DateTime.utc(2024, 10, 3).toIso8601String(),
        'link': 'https://t.bilibili.com/1',
      };
      final restored = ContentItem.fromJson(legacy);
      expect(restored, isNotNull);
      expect(restored!.images, isEmpty);
      expect(restored.origin, isNull);
      expect(restored.coverUrl, 'https://x/old.jpg');
      expect(restored.hasMultipleImages, isFalse);
    });

    test('images 里的脏数据被收敛（空串剔除、重复剔除、非字符串转字符串）', () {
      final restored = ContentItem.fromJson(<String, dynamic>{
        'id': 'bilibili:dirty',
        'platform': 'bilibili',
        'kind': 'dynamic',
        'images': <Object?>['https://x/a.jpg', '', '   ', 'https://x/a.jpg', 42, null],
        'fetchedAt': DateTime.utc(2024).toIso8601String(),
      })!;
      expect(restored.images, <String>['https://x/a.jpg', '42']);
    });

    test('images 不是 List（损坏数据）→ 空列表而不是抛异常', () {
      final restored = ContentItem.fromJson(<String, dynamic>{
        'id': 'bilibili:bad',
        'platform': 'bilibili',
        'kind': 'dynamic',
        'images': 'oops',
        'origin': 'also-oops',
        'fetchedAt': DateTime.utc(2024).toIso8601String(),
      })!;
      expect(restored.images, isEmpty);
      expect(restored.origin, isNull);
    });

    test('hasMultipleImages 只在真的多图时为 true', () {
      expect(_item(images: const <String>[]).hasMultipleImages, isFalse);
      expect(_item(images: const <String>['https://x/1.jpg']).hasMultipleImages, isFalse);
      expect(
        _item(images: const <String>['https://x/1.jpg', 'https://x/2.jpg'])
            .hasMultipleImages,
        isTrue,
      );
    });

    test('缺省构造不传 images 时是空列表而不是 null', () {
      final item = ContentItem(
        id: 'x',
        platform: Platform.bilibili,
        kind: ContentKind.dynamic,
        sourceId: 's',
        authorName: 'a',
        title: 't',
        summary: '',
        link: '',
        fetchedAt: DateTime.utc(2024),
      );
      expect(item.images, isEmpty);
      expect(item.origin, isNull);
      expect(item.images, isA<List<String>>());
    });
  });

  group('Platform / ContentKind', () {
    test('来源标签是需求指定的展示文案', () {
      expect(Platform.bilibili.label, 'Bilibili');
      expect(Platform.weibo.label, '微博');
    });

    test('fromKey 对未知值回落', () {
      expect(Platform.fromKey('bilibili'), Platform.bilibili);
      expect(Platform.fromKey('douyin'), isNull);
      expect(ContentKind.fromKey('video'), ContentKind.video);
      expect(ContentKind.fromKey(null), ContentKind.unknown);
    });
  });

  group('Subscription', () {
    test('id 是 platform:uid，与路由无关', () {
      final sub = Subscription(
        platform: Platform.bilibili,
        uid: '2267573',
        routes: <FeedRoute>{FeedRoute.bilibiliVideo},
        addedAt: DateTime.utc(2024),
      );
      expect(sub.id, 'bilibili:2267573');
      expect(sub.displayName, 'B 站 UP 2267573');
      expect(sub.copyWith(alias: '某 UP').displayName, '某 UP');
    });

    test('activeRoutes 为空时回落到平台默认路由', () {
      final sub = Subscription(
        platform: Platform.bilibili,
        uid: '1',
        routes: const <FeedRoute>{FeedRoute.weiboUser},
        addedAt: DateTime.utc(2024),
      );
      expect(
        sub.activeRoutes,
        <FeedRoute>[FeedRoute.bilibiliVideo, FeedRoute.bilibiliDynamic],
        reason: '跨平台的路由必须被过滤掉',
      );
    });

    test('JSON 往返', () {
      final sub = Subscription(
        platform: Platform.weibo,
        uid: '1234567890',
        routes: <FeedRoute>{FeedRoute.weiboUser},
        alias: '微博测试',
        addedAt: DateTime.utc(2024, 10, 1),
      );
      final restored = Subscription.fromJson(sub.toJson())!;
      expect(restored.id, sub.id);
      expect(restored.alias, '微博测试');
      expect(restored.routes, sub.routes);
      expect(restored.platform, Platform.weibo);
    });

    test('损坏数据返回 null / 回落默认路由', () {
      expect(Subscription.fromJson(<String, dynamic>{}), isNull);
      expect(
        Subscription.fromJson(<String, dynamic>{
          'platform': 'weibo',
          'uid': '123',
        })!.routes,
        <FeedRoute>{FeedRoute.weiboUser},
      );
    });

    test('相等性基于 id', () {
      final a = Subscription(
        platform: Platform.bilibili,
        uid: '1',
        routes: <FeedRoute>{FeedRoute.bilibiliVideo},
        addedAt: DateTime.utc(2024),
      );
      final b = Subscription(
        platform: Platform.bilibili,
        uid: '1',
        routes: <FeedRoute>{FeedRoute.bilibiliDynamic},
        alias: '换个别名',
        addedAt: DateTime.utc(2025),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('FeedRoute', () {
    test('path 按模板替换 uid', () {
      expect(
        FeedRoute.bilibiliVideo.path('2267573'),
        '/bilibili/user/video/2267573',
      );
      expect(
        FeedRoute.bilibiliDynamic.path('2267573'),
        '/bilibili/user/dynamic/2267573',
      );
      expect(FeedRoute.weiboUser.path('123'), '/weibo/user/123');
    });

    test('平台归属与默认路由', () {
      expect(FeedRoute.bilibiliVideo.platform, Platform.bilibili);
      expect(FeedRoute.weiboUser.platform, Platform.weibo);
      expect(
        FeedRoute.defaultsFor(Platform.bilibili),
        <FeedRoute>[FeedRoute.bilibiliVideo, FeedRoute.bilibiliDynamic],
      );
      expect(
        FeedRoute.defaultsFor(Platform.weibo),
        <FeedRoute>[FeedRoute.weiboUser],
      );
    });

    test('fromKey 往返', () {
      for (final route in FeedRoute.values) {
        expect(FeedRoute.fromKey(route.key), route);
      }
      expect(FeedRoute.fromKey('nope'), isNull);
    });
  });

  group('SourceStatus', () {
    test('copyWith 能打上错误也能清除错误', () {
      const status = SourceStatus(subscriptionId: 'bilibili:1');
      expect(status.hasError, isFalse);

      final failed = status.copyWith(error: '限流了');
      expect(failed.hasError, isTrue);
      expect(failed.error, '限流了');

      final recovered = failed.copyWith(clearError: true, itemCount: 20);
      expect(recovered.hasError, isFalse);
      expect(recovered.itemCount, 20);
    });
  });

  group('DanmakuMode', () {
    test('fromCode 映射与未知回落', () {
      expect(DanmakuMode.fromCode(1), DanmakuMode.scroll);
      expect(DanmakuMode.fromCode(4), DanmakuMode.bottom);
      expect(DanmakuMode.fromCode(5), DanmakuMode.top);
      expect(DanmakuMode.fromCode(6), DanmakuMode.reverse);
      expect(DanmakuMode.fromCode(8), DanmakuMode.code);
      expect(DanmakuMode.fromCode(999), DanmakuMode.unknown);
    });

    test('代码弹幕不渲染、高级弹幕降级为滚动', () {
      expect(DanmakuMode.code.isRenderable, isFalse);
      expect(DanmakuMode.unknown.isRenderable, isFalse);
      expect(DanmakuMode.advanced.isRenderable, isTrue);
      expect(DanmakuMode.advanced.isScrolling, isTrue);
      expect(DanmakuMode.top.isScrolling, isFalse);
    });
  });

  group('DanmakuItem', () {
    test('RGB 颜色被补成不透明 ARGB', () {
      const item = DanmakuItem(
        progressMs: 0,
        mode: DanmakuMode.scroll,
        fontSize: 25,
        color: 0xFF0000,
        text: 'x',
      );
      expect(item.argbColor, 0xFFFF0000);
    });

    test('已经是 ARGB 的颜色保持不变', () {
      const item = DanmakuItem(
        progressMs: 0,
        mode: DanmakuMode.scroll,
        fontSize: 25,
        color: 0x80FFFFFF,
        text: 'x',
      );
      expect(item.argbColor, 0x80FFFFFF);
    });
  });

  group('Comment 模型', () {
    test('CommentSort 的接口 mode 与展示名', () {
      expect(CommentSort.hot.mode, 3);
      expect(CommentSort.time.mode, 2);
      expect(CommentSort.hot.label, '热度');
      expect(CommentSort.time.label, '时间');
    });

    test('CommentPage.isEmpty 覆盖置顶与列表', () {
      expect(const CommentPage().isEmpty, isTrue);
      expect(
        const CommentPage(
          topComments: <BiliComment>[
            BiliComment(id: '1', uname: 'u', message: 'm'),
          ],
        ).isEmpty,
        isFalse,
      );
    });

    test('BiliComment.copyWith 更新楼中楼状态', () {
      const comment = BiliComment(id: '1', uname: 'u', message: 'm', replyCount: 2);
      final expanded = comment.copyWith(
        replies: <BiliComment>[
          const BiliComment(id: '2', uname: 's', message: 'sub', root: 1),
        ],
        repliesLoaded: true,
        repliesHasMore: false,
      );
      expect(expanded.replies.length, 1);
      expect(expanded.repliesLoaded, isTrue);
      expect(expanded.repliesHasMore, isFalse);
      expect(expanded.rpid, 1, reason: '原字段应保持');
    });

    test('ctime 转 DateTime，0 视为未知', () {
      const known = BiliComment(id: '1', uname: 'u', message: 'm', ctime: 1700000000);
      expect(known.createdAt, isNotNull);
      const unknown = BiliComment(id: '1', uname: 'u', message: 'm');
      expect(unknown.createdAt, isNull);
    });
  });
}
