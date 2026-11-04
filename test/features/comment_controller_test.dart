import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/repo/comment_repo.dart';
import 'package:rrha/features/comments/comment_controller.dart';

BiliComment _comment(int rpid, {int replyCount = 0, String? message}) =>
    BiliComment(
      // 模型主键已改为 String（微博评论 id 是 16 位字符串）。这里只调整构造，
      // 断言仍用兼容 getter `rpid` 的整数语义。
      id: '$rpid',
      uname: 'user$rpid',
      message: message ?? '评论 $rpid',
      replyCount: replyCount,
      like: rpid,
    );

class _FakeRepo implements CommentRepositoryLike {
  int loadFirstCalls = 0;
  int loadMoreCalls = 0;
  int loadRepliesCalls = 0;

  AppError? failFirst;
  AppError? failMore;
  AppError? failReplies;

  /// 第二页开始返回的内容。
  List<BiliComment> secondPage = <BiliComment>[_comment(3), _comment(4)];

  /// 最后一次透传给仓库层的评论入口参数。
  ///
  /// 用来钉住「动态评论的 type 不会在中间层被写成 1」这类静默错误。
  String? lastOid;
  int? lastType;

  @override
  Future<CommentPage> loadFirst({required CommentRequest req}) async {
    loadFirstCalls++;
    lastOid = req.oid;
    lastType = req.type;
    if (failFirst != null) throw failFirst!;
    return CommentPage(
      topComments: <BiliComment>[_comment(100)],
      comments: <BiliComment>[
        _comment(1, replyCount: 3),
        _comment(2),
      ],
      isEnd: false,
      nextCursor: 'CAESEDE4PAGE2',
      total: 42,
    );
  }

  @override
  Future<CommentPage> loadMore({
    required CommentRequest req,
    required String cursor,
  }) async {
    loadMoreCalls++;
    lastOid = req.oid;
    lastType = req.type;
    if (failMore != null) throw failMore!;
    return CommentPage(
      comments: secondPage,
      isEnd: true,
      nextCursor: null,
      total: 42,
    );
  }

  @override
  Future<SubCommentPage> loadReplies({
    required CommentRequest req,
    required String rootId,
    int page = 1,
  }) async {
    loadRepliesCalls++;
    lastOid = req.oid;
    lastType = req.type;
    if (failReplies != null) throw failReplies!;
    return SubCommentPage(
      comments: <BiliComment>[
        BiliComment(
          id: '${900 + page}',
          uname: 'sub',
          message: '楼中楼 $page',
          root: int.tryParse(rootId) ?? 0,
        ),
      ],
      hasMore: false,
      totalCount: 1,
    );
  }
}

/// 只回**一条指定楼层**的仓库（微博子评论测试用，不发任何请求）。
class _OverrideFirst implements CommentRepositoryLike {
  _OverrideFirst(this.floor);

  final BiliComment floor;

  @override
  Future<CommentPage> loadFirst({required CommentRequest req}) async =>
      CommentPage(comments: <BiliComment>[floor], isEnd: true, total: 1);

  @override
  Future<CommentPage> loadMore({
    required CommentRequest req,
    required String cursor,
  }) async =>
      const CommentPage(isEnd: true);

  @override
  Future<SubCommentPage> loadReplies({
    required CommentRequest req,
    required String rootId,
    int page = 1,
  }) async =>
      const SubCommentPage();
}

void main() {
  late _FakeRepo repo;
  late CommentListNotifier notifier;
  setUp(() {
    repo = _FakeRepo();
    notifier = CommentListNotifier(
      repo: repo,
      args: const CommentArgs(oid: '123', upMid: 999),
    );
  });

  group('首屏加载', () {
    test('成功：置顶与列表分开存放，游标被保存', () async {
      await notifier.load();
      final state = notifier.state;

      expect(state.loading, isFalse);
      expect(state.initialized, isTrue);
      expect(state.top.length, 1);
      expect(state.items.length, 2);
      expect(state.cursor, 'CAESEDE4PAGE2');
      expect(state.isEnd, isFalse);
      expect(state.total, 42);
      expect(state.displayCount, 42);
    });

    test('重复调用不会重复请求（除非 force）', () async {
      await notifier.load();
      await notifier.load();
      expect(repo.loadFirstCalls, 1);

      await notifier.load(force: true);
      expect(repo.loadFirstCalls, 2);
    });

    test('失败：保留可读错误，供 UI 显示重试按钮', () async {
      repo.failFirst = AppError.rateLimited();
      await notifier.load();
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.error!.kind, AppErrorKind.rateLimited);
      expect(notifier.state.error!.showRetry, isTrue);
      expect(notifier.state.items, isEmpty);
    });
  });

  group('加载更多', () {
    test('追加而不是覆盖，并更新 isEnd', () async {
      await notifier.load();
      await notifier.loadMore();

      final state = notifier.state;
      expect(state.items.length, 4);
      expect(state.items.map((e) => e.rpid).toList(), <int>[1, 2, 3, 4]);
      expect(state.isEnd, isTrue);
      expect(repo.loadMoreCalls, 1);
    });

    test('isEnd 之后不再请求', () async {
      await notifier.load();
      await notifier.loadMore();
      await notifier.loadMore();
      expect(repo.loadMoreCalls, 1);
    });

    test('分页失败：保留已有内容，只暴露错误', () async {
      await notifier.load();
      repo.failMore = AppError.server(503);
      await notifier.loadMore();

      expect(notifier.state.items.length, 2, reason: '已有内容不能被清空');
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.loadingMore, isFalse);

      // 重试成功
      repo.failMore = null;
      await notifier.loadMore();
      expect(notifier.state.items.length, 4);
      expect(notifier.state.error, isNull);
    });
  });

  group('排序切换', () {
    test('重置游标并重新拉取', () async {
      await notifier.load();
      expect(notifier.state.sort, CommentSort.hot);

      await notifier.changeSort(CommentSort.time);
      expect(notifier.state.sort, CommentSort.time);
      expect(repo.loadFirstCalls, 2);
      expect(notifier.state.items.length, 2, reason: '不应保留旧排序的结果');
    });

    test('相同排序不重复请求', () async {
      await notifier.load();
      await notifier.changeSort(CommentSort.hot);
      expect(repo.loadFirstCalls, 1);
    });
  });

  group('楼中楼', () {
    test('展开时拉取并挂到对应楼层', () async {
      await notifier.load();
      final target = notifier.state.items.first;
      await notifier.toggleReplies(target);

      final updated = notifier.state.items.first;
      expect(updated.repliesLoaded, isTrue);
      expect(updated.replies.length, 1);
      expect(updated.replies.first.root, target.rpid);
      expect(notifier.state.loadingReplies, isEmpty);
    });

    test('再次点击收起（不重复请求）', () async {
      await notifier.load();
      final target = notifier.state.items.first;
      await notifier.toggleReplies(target);
      await notifier.toggleReplies(notifier.state.items.first);

      expect(repo.loadRepliesCalls, 1);
      expect(notifier.state.items.first.replies, isEmpty);
    });

    /// 真机缺陷：收起后文字不变、而且再也展不开。
    ///
    /// 根因：收起时只清空了 `replies`，`repliesLoaded` 仍是 true。
    /// UI 判据就是这个标记 → 一直显示「收起回复」，再点又走收起分支。
    /// 所以收起必须**同时**把标记复位（上面那条老测试只断言了
    /// `replies.isEmpty`，没能发现这个问题）。
    test('收起后 repliesLoaded 必须复位（否则 UI 永远显示「收起回复」）',
        () async {
      await notifier.load();
      await notifier.toggleReplies(notifier.state.items.first);
      expect(notifier.state.items.first.repliesLoaded, isTrue);

      await notifier.toggleReplies(notifier.state.items.first);

      final collapsed = notifier.state.items.first;
      expect(collapsed.replies, isEmpty);
      expect(
        collapsed.repliesLoaded,
        isFalse,
        reason: '不复位这个标记，UI 永远显示「收起回复」且再也展不开',
      );
      expect(collapsed.repliesHasMore, isFalse);
    });

    /// 收→展→收→展 的完整往返（B 站：每次展开重新请求）。
    test('B 站：收起后能再次展开（往返两次都成功）', () async {
      await notifier.load();

      // 第一次展开
      await notifier.toggleReplies(notifier.state.items.first);
      expect(notifier.state.items.first.replies, isNotEmpty);

      // 收起
      await notifier.toggleReplies(notifier.state.items.first);
      expect(notifier.state.items.first.replies, isEmpty);
      expect(notifier.state.items.first.repliesLoaded, isFalse);

      // 第二次展开：必须真的能展开（这正是用户报的点不回来的问题）
      await notifier.toggleReplies(notifier.state.items.first);
      expect(
        notifier.state.items.first.replies,
        isNotEmpty,
        reason: '收起之后必须还能再展开',
      );
      expect(notifier.state.items.first.repliesLoaded, isTrue);
      expect(repo.loadRepliesCalls, 2, reason: 'B 站每次展开都重新请求');

      // 再收一次，确认可以无限往返（不是只修好了第一次）
      await notifier.toggleReplies(notifier.state.items.first);
      expect(notifier.state.items.first.replies, isEmpty);
      expect(notifier.state.items.first.repliesLoaded, isFalse);
    });

    test('失败：记录在 repliesError，不影响其它楼层', () async {
      await notifier.load();
      repo.failReplies = AppError.bili(-352, '风控');
      final target = notifier.state.items.first;
      await notifier.toggleReplies(target);

      // 失败记录的 key 现在是评论主键（String id），断言语义不变：
      // 「失败被记在**这一层**上，且不影响其它楼层」。
      expect(notifier.state.repliesError.containsKey(target.id), isTrue);
      expect(notifier.state.loadingReplies, isEmpty);
      expect(notifier.state.items.length, 2);
    });
  });

  // =========================================================== 微博子评论展开
  //
  // 需求：微博子评论**默认只显示 2 条**（hotflow 内嵌的就是前 2 条），
  // 点「…… 共 N 条回复 >」要能展开**完整内容**，而完整内容只能靠
  // `comments/hotflowChild` 分页拉。
  //
  // 这里的假 loader 完整模拟探针实测：第 1 页 10 条（前 2 条与内嵌重合）、
  // 第 2 页 2 条、之后 0 条（到底）。total_number 声称 68。
  group('微博子评论（两段式展开 + 分页补全）', () {
    /// 一条「内嵌 2 条、声称 68 条、带游标」的微博一级评论。
    BiliComment weiboFloor({
      String id = '5355080000000001',
      int totalReplies = 68,
      String? replyCursor = '145767900000000',
      List<BiliComment>? embedded,
    }) =>
        BiliComment(
          id: id,
          uname: '_warma_',
          message: '晕3D',
          platformKey: 'weibo',
          replyCount: (embedded ?? const <BiliComment>[]).length,
          replies: embedded ??
              <BiliComment>[
                BiliComment(id: 'sub-0', uname: 'a', message: '内嵌一'),
                BiliComment(id: 'sub-1', uname: 'b', message: '内嵌二'),
              ],
          repliesLoaded: false,
          totalReplies: totalReplies,
          replyCursor: replyCursor,
        );

    /// 假 loader 收到的调用记录（`{cid, maxId}`）。
    late List<({String cid, String? maxId})> calls;

    CommentListNotifier build({
      ChildRepliesLoader? loader,
      BiliComment? floor,
    }) {
      calls = <({String cid, String? maxId})>[];
      return CommentListNotifier(
        repo: _OverrideFirst(floor ?? weiboFloor()),
        args: const CommentArgs(
          oid: '5355066445792642',
          platform: Platform.weibo,
          type: 0,
        ),
        loadChildReplies: loader,
      );
    }

    /// 探针形态的 loader：第 1 页 10 条（前 2 条 = 内嵌）、第 2 页 2 条、之后空。
    ChildRepliesLoader probeLikeLoader({bool failOnCall = false}) =>
        ({
          required String cid,
          String? maxId,
          String? mid,
        }) async {
          calls.add((cid: cid, maxId: maxId));
          if (failOnCall) throw AppError.network();
          if (calls.length == 1) {
            return (
              items: <BiliComment>[
                for (int i = 0; i < 10; i++)
                  BiliComment(id: 'sub-$i', uname: 'u$i', message: '第1页 $i'),
              ],
              nextCursor: '145767900000000',
            );
          }
          if (calls.length == 2) {
            return (
              items: <BiliComment>[
                BiliComment(id: 'sub-10', uname: 'u10', message: '第2页 10'),
                BiliComment(id: 'sub-11', uname: 'u11', message: '第2页 11'),
              ],
              nextCursor: '145767900000000',
            );
          }
          // 第 3 次：0 条 → 到底。
          return (items: const <BiliComment>[], nextCursor: null);
        };

    test('点展开：优先用内嵌 2 条立即显示（不等网络）', () async {
      final Completer<void> gate = Completer<void>();
      // loader 卡在 gate 上：用来证明「先显示，后补全」。
      Future<({List<BiliComment> items, String? nextCursor})> slow({
        required String cid,
        String? maxId,
        String? mid,
      }) async {
        calls.add((cid: cid, maxId: maxId));
        await gate.future;
        return (items: const <BiliComment>[], nextCursor: null);
      }

      final CommentListNotifier n = build(loader: slow);
      await n.load();
      final Future<void> pending = n.toggleReplies(n.state.items.first);

      // 网络还没回来，但内容已经可见了。
      expect(
        n.state.expandedReplies,
        contains('5355080000000001'),
        reason: '点一下就要展开（交互标记立刻置上，不等网络）',
      );
      expect(n.state.items.first.replies.length, 2, reason: '先显示内嵌的 2 条');
      expect(n.state.loadingReplies, contains('5355080000000001'));

      gate.complete();
      await pending;
      expect(n.state.loadingReplies, isEmpty);
    });

    test('合并去重：内嵌 2 条 + 第 1 页 10 条 → 10 条（内嵌是子集）', () async {
      final CommentListNotifier n = build(
        loader: ({
          required String cid,
          String? maxId,
          String? mid,
        }) async {
          calls.add((cid: cid, maxId: maxId));
          return (
            items: <BiliComment>[
              for (int i = 0; i < 10; i++)
                BiliComment(id: 'sub-$i', uname: 'u$i', message: '第1页 $i'),
            ],
            nextCursor: null,
          );
        },
      );

      await n.load();
      await n.toggleReplies(n.state.items.first);

      final BiliComment after = n.state.items.first;
      expect(after.replies.length, 10, reason: '2 + 10 去重后必须还是 10，不是 12');
      expect(
        after.replies.map((BiliComment c) => c.id).toList(),
        <String>[for (int i = 0; i < 10; i++) 'sub-$i'],
        reason: '保留先到的顺序，且不重复',
      );
    });

    test('续拉到到底：10 + 2 = 12 条，且标记 repliesAllLoaded', () async {
      final CommentListNotifier n = build(loader: probeLikeLoader());
      await n.load();
      await n.toggleReplies(n.state.items.first);

      final BiliComment after = n.state.items.first;
      expect(after.replies.length, 12, reason: '第 1 页 10 + 第 2 页 2');
      expect(n.state.repliesAllLoaded, contains('5355080000000001'));
      expect(n.state.repliesCursor['5355080000000001'], isNull, reason: '到底 = 没游标');
      expect(n.state.loadingReplies, isEmpty);
      expect(n.state.repliesError, isEmpty);
      // 第 1 次**不带**游标（探针实测：带了一级节点游标会回 errno=100011「暂无数据」），
      // 第 2 次才开始用游标续拉，第 3 次探测到底（共 3 页上限）。
      expect(calls.length, 3);
      expect(
        calls.first.maxId,
        isNull,
        reason: '首屏必须不带 max_id，否则服务端回「暂无数据」',
      );
      expect(calls[1].maxId, isNotNull, reason: '第 2 页开始带游标续拉');
    });

    test('最多只拉 3 页（声称 68 条也不会打爆）', () async {
      // 每次都给 10 条 + 一个游标，永远不会自然到底。
      final CommentListNotifier n = build(
        loader: ({
          required String cid,
          String? maxId,
          String? mid,
        }) async {
          calls.add((cid: cid, maxId: maxId));
          final int page = calls.length;
          return (
            items: <BiliComment>[
              for (int i = 0; i < 10; i++)
                BiliComment(id: 'p$page-$i', uname: 'u', message: 'x'),
            ],
            nextCursor: 'cursor-$page',
          );
        },
      );

      await n.load();
      await n.toggleReplies(n.state.items.first);

      expect(calls.length, 3, reason: '页数上限是 3');
      expect(n.state.loadingReplies, isEmpty);
      // 3 页都拉完仍有游标 → 没到底，游标留给下次。
      expect(n.state.repliesAllLoaded, isNot(contains('5355080000000001')));
      expect(n.state.repliesCursor['5355080000000001'], 'cursor-3');
    });

    test('失败不重试：只发 1 次请求，保留已显示内容 + 可读错误', () async {
      final CommentListNotifier n = build(loader: probeLikeLoader(failOnCall: true));
      await n.load();
      await n.toggleReplies(n.state.items.first);

      expect(calls.length, 1, reason: '失败绝不自动重试');
      final BiliComment after = n.state.items.first;
      expect(
        n.state.expandedReplies,
        contains('5355080000000001'),
        reason: '已展开的内容要留着（交互标记不能回滚）',
      );
      expect(after.replies.length, 2, reason: '内嵌 2 条还在');
      expect(n.state.repliesError['5355080000000001'], isNotNull);
      expect(n.state.loadingReplies, isEmpty);

      // 再次点击 = 收起；再展开时**不会**自动重试（错误标记还在 → 守卫拦住）。
      await n.toggleReplies(n.state.items.first);
      expect(n.state.expandedReplies, isNot(contains('5355080000000001')));
      await n.toggleReplies(n.state.items.first);
      expect(
        n.state.expandedReplies,
        contains('5355080000000001'),
        reason: '再点还是能展开（只是不再重试网络）',
      );
      expect(calls.length, 1, reason: '同一楼层失败后不再自动重试');
    });

    test('再次点击 = 收起：内容不清空，且不再发请求', () async {
      final CommentListNotifier n = build(loader: probeLikeLoader());
      await n.load();
      await n.toggleReplies(n.state.items.first);
      final int callsAfterExpand = calls.length;
      expect(n.state.items.first.replies.length, 12);

      await n.toggleReplies(n.state.items.first);

      expect(n.state.expandedReplies, isNot(contains('5355080000000001')));
      expect(
        n.state.items.first.replies.length,
        12,
        reason: '收起只切交互标记，列表要留着（再展开是纯本地切换）',
      );
      expect(calls.length, callsAfterExpand, reason: '收起不发请求');

      // 再展开：不再请求（已到底）。
      await n.toggleReplies(n.state.items.first);
      expect(n.state.expandedReplies, contains('5355080000000001'));
      expect(calls.length, callsAfterExpand, reason: '已到底的楼层不再请求');
    });

    test('没有游标（内嵌就是全部）→ 标记到底，且不发请求', () async {
      final CommentListNotifier n = build(
        loader: probeLikeLoader(),
        floor: weiboFloor(replyCursor: null, totalReplies: 2),
      );
      await n.load();
      await n.toggleReplies(n.state.items.first);

      expect(calls, isEmpty, reason: '没有游标就没有可续拉的东西');
      expect(n.state.repliesAllLoaded, contains('5355080000000001'));
    });

    test('未注入 loader（B 站 / 纯状态机）→ 只用内嵌内容，绝不发请求', () async {
      final CommentListNotifier n = build();
      await n.load();
      await n.toggleReplies(n.state.items.first);

      expect(calls, isEmpty);
      expect(n.state.items.first.replies.length, 2);
      expect(n.state.loadingReplies, isEmpty);
    });

    test('列表构建路径零请求：load() 不碰子评论接口', () async {
      final CommentListNotifier n = build(loader: probeLikeLoader());
      await n.load();

      expect(calls, isEmpty, reason: '只有用户点展开才允许发请求');
      expect(n.state.items.first.repliesLoaded, isFalse);
    });

    // ⚠️ 最关键的一条语义锁定：total_number=68，但接口只给 12 条。
    // 绝不能拿 68 当分母/进度 —— 否则永远卡在 12/68，按钮也永远不消失。
    test('totalReplies=68 但只拉到 12 条：到底标记以**实拉条数**为准', () async {
      final CommentListNotifier n = build(loader: probeLikeLoader());
      await n.load();

      final BiliComment floor = n.state.items.first;
      expect(floor.totalReplies, 68, reason: '文案用的 N');

      await n.toggleReplies(floor);

      final BiliComment after = n.state.items.first;
      // 实拉 12 条 —— 不是 68。
      expect(after.replies.length, 12);
      expect(after.replies.length, lessThan(after.totalReplies));
      // 「到底」由**接口没内容了**判定，与声称总数无关。
      expect(
        n.state.repliesAllLoaded,
        contains(after.id),
        reason: '已经到底了，即便 12 < 68',
      );
      // 没有任何「进度分母」字段被 68 污染：游标就是 null（到底）。
      expect(n.state.repliesCursor[after.id], isNull);
      // 加载状态已退出（不会因为 12 < 68 而永远转圈）。
      expect(n.state.loadingReplies, isEmpty);
    });
  });

  test('displayCount 在 total 为 0 时回落到已加载条数', () async {
    final emptyRepo = _FakeRepo();
    final n = CommentListNotifier(
      repo: emptyRepo,
      args: const CommentArgs(oid: '1'),
    );
    await n.load();
    expect(n.state.displayCount, greaterThan(0));
  });

  group('动态评论区（oid + type 透传）', () {
    test('图文动态：oid 与 type=11 一路传到仓库层', () async {
      final dynamicRepo = _FakeRepo();
      final n = CommentListNotifier(
        repo: dynamicRepo,
        args: const CommentArgs(oid: '412320369', type: 11),
      );

      await n.load();
      expect(dynamicRepo.lastOid, '412320369');
      expect(dynamicRepo.lastType, 11, reason: '图文动态必须是 11，退化成 1 会 -404');

      await n.loadMore();
      expect(dynamicRepo.lastOid, '412320369');
      expect(dynamicRepo.lastType, 11, reason: '翻页也必须带上同一个 type');

      await n.toggleReplies(n.state.items.first);
      expect(dynamicRepo.lastType, 11, reason: '楼中楼同样要带 type');
    });

    test('转发动态：type=17 且 oid 是 19 位 id_str（不做数值转换）', () async {
      const idStr = '1259424959743131672';
      final dynamicRepo = _FakeRepo();
      final n = CommentListNotifier(
        repo: dynamicRepo,
        args: const CommentArgs(oid: idStr, type: 17),
      );

      await n.load();
      expect(dynamicRepo.lastOid, idStr);
      expect(dynamicRepo.lastType, 17);
    });

    test('视频评论保持 type=1（回归）', () async {
      await notifier.load();
      expect(repo.lastType, 1);
      expect(repo.lastOid, '123');
    });

    test('不同 oid / type 的评论状态互不串用', () {
      const video = CommentArgs(oid: '123', type: 1);
      const dynamic = CommentArgs(oid: '123', type: 11);
      const sameAgain = CommentArgs(oid: '123', type: 1);

      expect(video == dynamic, isFalse, reason: '同 oid 不同 type 是两套评论区');
      expect(video == sameAgain, isTrue);
      expect(video.hashCode == dynamic.hashCode, isFalse);
    });
  });

  // 微博的楼中楼**内嵌**在首页响应里（`loadReplies` 返回空页），
  // 所以它的「收起再展开」必须是纯本地状态切换 —— 一旦像 B 站那样去请求，
  // 拿回来的是空页，用户会看到「回复凭空消失」。
  group('微博楼中楼（内嵌，收起后靠暂存恢复）', () {
    late _FakeRepo weiboRepo;
    late CommentListNotifier n;

    setUp(() {
      weiboRepo = _FakeRepo();
      n = CommentListNotifier(
        repo: weiboRepo,
        args: const CommentArgs(oid: '5354385849713417', platform: Platform.weibo),
      );
    });

    test('完整往返：展开 → 收起 → 再展开，第二次仍能看到回复', () async {
      await n.load();

      // 让第一条呈现「微博内嵌已加载」形态。
      final List<BiliComment> seeded = List<BiliComment>.from(n.state.items);
      final List<BiliComment> embedded = <BiliComment>[
        BiliComment(id: 's1', uname: 'sub', message: '楼中楼一'),
        BiliComment(id: 's2', uname: 'sub', message: '楼中楼二'),
      ];
      seeded[0] = seeded[0].copyWith(replies: embedded, repliesLoaded: true);

      // 首次点击 = **展开**（`repliesLoaded` 早已是 true，但交互标记还没置上）。
      await n.toggleReplies(seeded[0]);

      final afterExpand = n.state.items.first;
      expect(
        n.state.expandedReplies,
        contains(seeded[0].id),
        reason: '点击要把交互标记置上',
      );
      // 微博的 replies **永远不清空**（数据留着，UI 靠交互标记决定渲染几条）。
      expect(afterExpand.replies.length, 2);

      // 再点一次 = 收起。
      await n.toggleReplies(n.state.items.first);
      expect(
        n.state.expandedReplies,
        isNot(contains(seeded[0].id)),
        reason: '收起后必须去掉交互标记，否则文字一直是「收起 ^」',
      );
      expect(
        n.state.items.first.replies.length,
        2,
        reason: '收起不清空列表（再展开要能立刻恢复）',
      );

      // 第三次点击 = 再展开：应恢复可见，且**不发请求**。
      final int callsBefore = weiboRepo.loadRepliesCalls;
      await n.toggleReplies(n.state.items.first);

      final reopened = n.state.items.first;
      expect(n.state.expandedReplies, contains(reopened.id));
      expect(
        reopened.replies.length,
        2,
        reason: '微博的楼中楼必须原样恢复，不能变成空列表',
      );
      expect(reopened.replies.first.message, '楼中楼一');
      expect(
        weiboRepo.loadRepliesCalls,
        callsBefore,
        reason: '微博没有单独拉楼中楼的接口，展开不能再发请求',
      );
    });
  });
}
