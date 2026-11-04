import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/bili_models.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';

/// 「全部关注」动态流的一页：**游标**分页（不是页码），
/// 而且 `has_more` / `offset` 的组合决定「还能不能继续翻」。
///
/// 这里全部用真实抓到的形态（2026-10 实测）：
///     {"items": [...20 条], "offset": "CAESEDE4...", "has_more": true}
void main() {
  group('关注流首页解析', () {
    test('items / offset / has_more / update_num 全部取出', () {
      final feed = BiliFollowingFeed.fromJson(<String, dynamic>{
        'items': <Object?>[
          <String, dynamic>{'id_str': '1'},
          <String, dynamic>{'id_str': '2'},
        ],
        'offset': 'CAESEDE4MzUwODYzMDc0MTAyNjgiAggB',
        'has_more': true,
        'update_num': 3,
      });

      expect(feed.items.length, 2);
      expect(feed.nextOffset, 'CAESEDE4MzUwODYzMDc0MTAyNjgiAggB');
      expect(feed.hasMore, isTrue);
      expect(feed.updateNum, 3);
    });

    test('offset 为空串 → nextOffset 为 null（省得调用方判两次）', () {
      final feed = BiliFollowingFeed.fromJson(<String, dynamic>{
        'items': <Object?>[],
        'offset': '',
        'has_more': false,
      });
      expect(feed.nextOffset, isNull);
      expect(feed.hasMore, isFalse);
    });

    test('has_more 兼容 true / 1 两种编码', () {
      expect(
        BiliFollowingFeed.fromJson(<String, dynamic>{'has_more': true}).hasMore,
        isTrue,
      );
      expect(
        BiliFollowingFeed.fromJson(<String, dynamic>{'has_more': 1}).hasMore,
        isTrue,
      );
      expect(
        BiliFollowingFeed.fromJson(<String, dynamic>{'has_more': 0}).hasMore,
        isFalse,
      );
    });

    // 真机回归：服务端把 offset / update_num 都当成**字符串**返回，
    // 按 JSON 类型硬转会抛 `type 'String' is not a subtype of type 'num?'`，
    // 表现为整条时间线报「刷新失败」。字段形态取自 .env/probe_feed_types.py。
    test('字段是字符串时也能解析（真机实测形态）', () {
      final feed = BiliFollowingFeed.fromJson(<String, dynamic>{
        'items': <Object?>[
          <String, dynamic>{'id_str': '1'},
        ],
        'offset': '1259324277086224400',
        'has_more': true,
        'update_num': '0',
      });

      expect(feed.nextOffset, '1259324277086224400');
      expect(feed.updateNum, 0);
      expect(feed.hasMore, isTrue);
    });

    test('offset 是 19 位整数：必须按字符串保留，不能过 double', () {
      const idStr = '1259324277086224400';
      final feed = BiliFollowingFeed.fromJson(<String, dynamic>{
        'offset': idStr,
      });
      // 若中途转成 double，尾数会被抹成 ...224000 之类，回传就翻不动页。
      expect(feed.nextOffset, idStr);
      expect(feed.nextOffset, isNot(contains('e')));
    });

    test('offset 是数字形态时同样接受（其它端返回过 int）', () {
      final feed = BiliFollowingFeed.fromJson(<String, dynamic>{
        'offset': 12345,
      });
      expect(feed.nextOffset, '12345');
    });

    test('has_more 是字符串 "true" / "false" 时也能判定', () {
      expect(
        BiliFollowingFeed.fromJson(<String, dynamic>{'has_more': 'true'})
            .hasMore,
        isTrue,
      );
      expect(
        BiliFollowingFeed.fromJson(<String, dynamic>{'has_more': 'false'})
            .hasMore,
        isFalse,
      );
    });

    test('坏数据不抛异常：非 Map / items 类型不对都退化成空页', () {
      expect(BiliFollowingFeed.fromJson(null).items, isEmpty);
      expect(BiliFollowingFeed.fromJson('oops').items, isEmpty);
      expect(
        BiliFollowingFeed.fromJson(<String, dynamic>{'items': 'oops'}).items,
        isEmpty,
      );
    });

    test('toJson / fromJson 往返一致 —— 缓存靠它保存游标', () {
      const feed = BiliFollowingFeed(
        items: <Object?>[
          <String, dynamic>{'id_str': '9'},
        ],
        nextOffset: 'CURSOR',
        hasMore: true,
        updateNum: 7,
      );
      final back = BiliFollowingFeed.fromJson(feed.toJson());
      expect(back.nextOffset, 'CURSOR');
      expect(back.hasMore, isTrue);
      expect(back.updateNum, 7);
      expect(back.items.length, 1);
    });
  });

  group('分页边界（BiliFollowingFeedPage.isEnd）', () {
    test('hasMore=true 且有游标 → 还能翻', () {
      final page = BiliFollowingFeedPage(
        items: const [],
        fetchedAt: DateTime.utc(2026, 1, 1),
        nextOffset: 'CURSOR',
        hasMore: true,
      );
      expect(page.isEnd, isFalse);
    });

    test('hasMore=true 但游标缺失 → 视为到底（否则会无限请求同一页）', () {
      final page = BiliFollowingFeedPage(
        items: const [],
        fetchedAt: DateTime.utc(2026, 1, 1),
        hasMore: true,
      );
      expect(page.isEnd, isTrue);
    });

    test('hasMore=false → 到底，即使还带着游标', () {
      final page = BiliFollowingFeedPage(
        items: const [],
        fetchedAt: DateTime.utc(2026, 1, 1),
        nextOffset: 'CURSOR',
        hasMore: false,
      );
      expect(page.isEnd, isTrue);
    });
  });

  group('虚拟源的 sourceId', () {
    test('「全部关注」的 sourceId 与虚拟订阅 id 一致且稳定', () {
      expect(BiliTimelineSource.followingSourceId, 'bilibili:following');
      expect(
        BiliTimelineSource.followingSubscription.id,
        BiliTimelineSource.followingSourceId,
      );
    });

    test('虚拟源与真实订阅不会撞 id', () {
      // uid 用 'following'（不是数字 mid），正是为了避免与真实 UP 撞车。
      expect(
        int.tryParse(BiliTimelineSource.followingSubscription.uid),
        isNull,
      );
    });
  });
}
