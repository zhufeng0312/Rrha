import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/repo/timeline_floor.dart';

/// 「显示下界」的离线验收。
///
/// 这套断言就是本方案想要拿到的**全部保证**，所以每条都必须能在真机上
/// 复现为可观察的现象：
/// - 可见列表严格倒序 → 用户看不到顺序错乱；
/// - 新页只追加在末尾 → 不可能出现「滚到一半闪一下」；
/// - 缓冲条目不丢 → floor 退过去之后能立刻补上，不用重新请求。

DateTime _t(int day, [int hour = 12]) => DateTime.utc(2026, 10, day, hour);

ContentItem _item(
  String id,
  Platform platform,
  DateTime t, {
  bool reliable = true,
}) =>
    ContentItem(
      id: id,
      platform: platform,
      kind: ContentKind.dynamic,
      sourceId: '${platform.key}:1',
      authorName: 'a',
      title: 't$id',
      summary: '',
      link: 'https://example.com/$id',
      fetchedAt: t,
      publishedAt: t,
      hasReliableTime: reliable,
    );

ContentItem _bili(String id, DateTime t) =>
    _item(id, Platform.bilibili, t);

ContentItem _weibo(String id, DateTime t) =>
    _item(id, Platform.weibo, t);

/// 按时间倒序（与 `mergeContinuing` 同口径）。
List<ContentItem> _sorted(List<ContentItem> items) =>
    List<ContentItem>.of(items)
      ..sort((a, b) => b.sortKey.compareTo(a.sortKey));

void main() {
  group('水位计算', () {
    test('取该平台最旧一条的时间', () {
      final items = <ContentItem>[
        _bili('b1', _t(26)),
        _bili('b2', _t(24)),
        _weibo('w1', _t(10)),
      ];

      expect(
        TimelineFloor.watermark(
          items: items,
          platform: Platform.bilibili,
          exhausted: false,
        ),
        _t(24),
      );
      expect(
        TimelineFloor.watermark(
          items: items,
          platform: Platform.weibo,
          exhausted: false,
        ),
        _t(10),
      );
    });

    test('已到底 → null（不构成约束，否则更早的区间会被自己锁住）', () {
      final items = <ContentItem>[_bili('b1', _t(24)), _weibo('w1', _t(10))];
      expect(
        TimelineFloor.watermark(
          items: items,
          platform: Platform.weibo,
          exhausted: true,
        ),
        isNull,
      );
    });

    test('该平台一条都没有 → null（未登录时不能把 floor 顶到现在）', () {
      final items = <ContentItem>[_weibo('w1', _t(10))];
      expect(
        TimelineFloor.watermark(
          items: items,
          platform: Platform.bilibili,
          exhausted: false,
        ),
        isNull,
      );
    });

    test('时间不可信的条目不参与水位计算', () {
      final items = <ContentItem>[
        _bili('b1', _t(26)),
        // 时间不可信：sortKey 是抓取时间，拿它当水位会把 floor 顶到现在。
        _item('b-bad', Platform.bilibili, _t(1), reliable: false),
      ];
      expect(
        TimelineFloor.watermark(
          items: items,
          platform: Platform.bilibili,
          exhausted: false,
        ),
        _t(26),
      );
    });
  });

  group('floor = 两侧水位里较晚的那个', () {
    test('B 站只拉到 10-24、微博拉到 09-02 → floor 取 10-24，微博被扣住', () {
      // 这就是真机上的实际数字：两侧水位差近两个月。
      final all = _sorted(<ContentItem>[
        _bili('b1', _t(26, 10)),
        _bili('b2', _t(25, 10)),
        _bili('b3', _t(24, 11)), // B 站水位
        _weibo('w1', _t(26, 9)),
        _weibo('w2', _t(20)),
        _weibo('w3', _t(15)),
        _weibo('w4', _t(2)), // 微博水位
      ]);

      final split = TimelineFloor.split(
        all: all,
        biliExhausted: false,
        weiboExhausted: false,
      );

      expect(split.floor, _t(24, 11), reason: '取较晚的那侧');
      expect(
        split.visible.map((e) => e.id),
        <String>['b1', 'w1', 'b2', 'b3'],
        reason: '只有 10-24 之后的内容两侧都完整，可见（且仍严格倒序）',
      );
      expect(
        split.buffered.map((e) => e.id),
        <String>['w2', 'w3', 'w4'],
        reason: '9-02~10-24 这段 B 站还没拉到，微博必须先扣住',
      );
    });

    test('两侧水位相同 → 全部可见，缓冲为空', () {
      final all = _sorted(<ContentItem>[
        _bili('b1', _t(26)),
        _weibo('w1', _t(26)),
        _bili('b2', _t(25)),
        _weibo('w2', _t(25)),
      ]);
      final split = TimelineFloor.split(
        all: all,
        biliExhausted: false,
        weiboExhausted: false,
      );
      expect(split.buffered, isEmpty);
      expect(split.visible.length, 4);
    });

    test('一侧已到底 → 不再约束，允许出现真实的纯单一平台段', () {
      // 微博已经翻完（9 月以前真的没有微博），此时纯 B 站段是**真实**的。
      final all = _sorted(<ContentItem>[
        _bili('b1', _t(26)),
        _bili('b2', _t(20)),
        _bili('b3', _t(10)),
        _weibo('w1', _t(26, 9)),
      ]);
      final split = TimelineFloor.split(
        all: all,
        biliExhausted: false,
        weiboExhausted: true,
      );
      expect(split.floor, _t(10), reason: '只剩 B 站的水位');
      expect(split.buffered, isEmpty);
      expect(split.visible.length, 4);
    });

    test('只有一侧有数据（未登录 B 站）→ 不设限，全部可见', () {
      final all = _sorted(<ContentItem>[
        _weibo('w1', _t(26)),
        _weibo('w2', _t(10)),
        _weibo('w3', _t(2)),
      ]);
      final split = TimelineFloor.split(
        all: all,
        biliExhausted: false,
        weiboExhausted: false,
      );
      expect(split.floor, _t(2));
      expect(split.buffered, isEmpty, reason: '没有另一侧，不该扣任何东西');
      expect(split.visible.length, 3);
    });

    test('两侧都没有数据 → floor 为 null，不崩', () {
      final split = TimelineFloor.split(
        all: const <ContentItem>[],
        biliExhausted: false,
        weiboExhausted: false,
      );
      expect(split.floor, isNull);
      expect(split.visible, isEmpty);
      expect(split.buffered, isEmpty);
    });
  });

  group('结构性保证', () {
    test('可见列表严格按时间倒序', () {
      final all = _sorted(<ContentItem>[
        for (var d = 26; d >= 1; d--) _bili('b$d', _t(d)),
        for (var d = 26; d >= 1; d -= 3) _weibo('w$d', _t(d)),
      ]);
      final split = TimelineFloor.split(
        all: all,
        biliExhausted: false,
        weiboExhausted: false,
      );

      for (var i = 1; i < split.visible.length; i++) {
        expect(
          split.visible[i - 1].sortKey.isBefore(split.visible[i].sortKey),
          isFalse,
          reason: '第 $i 条比前一条更晚',
        );
      }
    });

    test('缓冲一定比可见更旧（floor 两侧严格分离）', () {
      final all = _sorted(<ContentItem>[
        for (var d = 26; d >= 1; d--) _bili('b$d', _t(d)),
        for (var d = 26; d >= 1; d -= 3) _weibo('w$d', _t(d)),
      ]);
      final split = TimelineFloor.split(
        all: all,
        biliExhausted: false,
        weiboExhausted: false,
      );
      expect(split.buffered, isNotEmpty);
      expect(split.visible.last.sortKey.isBefore(split.buffered.first.sortKey),
          isFalse);
    });

    test('新一页只会追加在末尾：已显示条目的相对位置不变', () {
      // 模拟第一轮：B 站 10-26~10-24，微博 10-26~09-02。
      final page1 = _sorted(<ContentItem>[
        _bili('b1', _t(26, 12)),
        _bili('b2', _t(25, 12)),
        _bili('b3', _t(24, 12)),
        _weibo('w1', _t(26, 8)),
        _weibo('w2', _t(10)),
      ]);
      final first = TimelineFloor.split(
        all: page1,
        biliExhausted: false,
        weiboExhausted: false,
      );
      expect(first.floor, _t(24, 12));
      final List<String> before =
          first.visible.map((e) => e.id).toList();

      // 第二轮：B 站又翻了 4 天（10-23~10-20），微博照旧提前翻到 9 月。
      final page2 = <ContentItem>[
        _bili('b4', _t(23, 12)),
        _bili('b5', _t(21, 12)),
        _bili('b6', _t(20, 12)),
        _weibo('w3', _t(5)),
      ];
      final all2 = _sorted(<ContentItem>[...page1, ...page2]);
      final second = TimelineFloor.split(
        all: all2,
        biliExhausted: false,
        weiboExhausted: false,
        previousFloor: first.floor,
      );

      final List<String> after =
          second.visible.map((e) => e.id).toList();

      expect(second.floor, _t(20, 12), reason: 'floor 跟着 B 站退到 10-20');
      expect(after.length, greaterThan(before.length));

      // 关键断言：原可见序列必须是新序列的**前缀** ——
      // 也就是「只追加，不插队」，这正是「不会闪」的形式化表述。
      expect(
        after.sublist(0, before.length),
        before,
        reason: '已显示条目不许换位、不许被插入新条目',
      );
      // 而且新条目全部在末尾；w2(10-10) 仍比 floor(10-20) 旧，继续留在缓冲里。
      expect(
        after.sublist(before.length),
        <String>['b4', 'b5', 'b6'],
      );
      expect(
        second.buffered.map((e) => e.id),
        <String>['w2', 'w3'],
        reason: '微博已预取到更深处，floor 还没退过去就先扣着',
      );
    });

    test('floor 单调：水位异常变新时也不许把已显示条目藏起来', () {
      final page1 = _sorted(<ContentItem>[
        _bili('b1', _t(26)),
        _bili('b2', _t(20)),
        _weibo('w1', _t(19)),
      ]);
      final first = TimelineFloor.split(
        all: page1,
        biliExhausted: false,
        weiboExhausted: false,
      );
      expect(first.floor, _t(20));

      // 极端情况：新一页只带回「很新」的条目，两侧水位都变新了。
      final page2 = _sorted(<ContentItem>[
        ...page1,
        _bili('b-new', _t(26, 20)),
        _weibo('w-new', _t(26, 19)),
      ]);
      final second = TimelineFloor.split(
        all: page2,
        biliExhausted: false,
        weiboExhausted: false,
        previousFloor: first.floor,
      );

      expect(second.floor, _t(20), reason: 'floor 只能往更旧走');
      expect(
        second.visible.map((e) => e.id),
        containsAll(<String>['b1', 'b2']),
        reason: '第一轮已显示过的条目绝不消失',
      );
    });
  });

  group('缓冲是预取，不是丢弃', () {
    test('floor 退过缓冲区间后，那些条目按原顺序回到可见列表', () {
      // 第一轮：微博已经翻到 9-02（缓冲），B 站只到 10-24。
      final page1 = _sorted(<ContentItem>[
        _bili('b1', _t(26)),
        _bili('b2', _t(24)),
        _weibo('w1', _t(25)),
        _weibo('w2', _t(15)),
        _weibo('w3', _t(2)),
      ]);
      final first = TimelineFloor.split(
        all: page1,
        biliExhausted: false,
        weiboExhausted: false,
      );
      expect(
        first.buffered.map((e) => e.id),
        <String>['w2', 'w3'],
      );

      // 第二轮：B 站翻到了 10-01，比微博（10-02）更深。
      // 于是**约束换边**：这次是微博拖住了 floor，B 站最新的 b5 被扣住。
      final page2 = _sorted(<ContentItem>[
        ...page1,
        _bili('b3', _t(20)),
        _bili('b4', _t(10)),
        _bili('b5', _t(1)),
      ]);
      final second = TimelineFloor.split(
        all: page2,
        biliExhausted: false,
        weiboExhausted: false,
        previousFloor: first.floor,
      );

      expect(second.floor, _t(2), reason: '水位较晚的一侧变成微博');
      expect(second.buffered.map((e) => e.id), <String>['b5']);
      expect(
        second.visible.map((e) => e.id),
        <String>['b1', 'w1', 'b2', 'b3', 'w2', 'b4', 'w3'],
        reason: '第一轮被扣住的 w2/w3 已放出，队列仍然严格时间倒序',
      );

      // 第一轮被扣住的两条确实回到了可见列表 —— 这就是「缓冲是预取」。
      expect(
        second.visible.map((e) => e.id),
        containsAll(<String>['w2', 'w3']),
      );
    });
  });
}
