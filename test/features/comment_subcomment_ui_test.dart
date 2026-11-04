import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/repo/comment_repo.dart';
import 'package:rrha/features/comments/comment_controller.dart';
import 'package:rrha/features/comments/comment_section.dart';

/// 微博**子评论展开**的离线 UI 验收（照用户给的参考设计）。
///
/// 钉死五条：
/// 1. 未展开时**只渲染前 2 条**子评论；
/// 2. 那行是 `...... 共 N 条回复 >`（三个点是文本、箭头是 `>` 文本）；
/// 3. 点开展示**全部已加载**的，行变成 `收起 ^`；
/// 4. `total_number=68` 而只拉到 12 条时，显示「已显示全部 12 条」，
///    **绝不能**把 68 当分母；
/// 5. B 站仍是「查看 N 条回复」的老交互（红线）。
class _FakeRepo implements CommentRepositoryLike {
  _FakeRepo(this.comments);

  final List<BiliComment> comments;

  @override
  Future<CommentPage> loadFirst({required CommentRequest req}) async =>
      CommentPage(comments: comments, isEnd: true, total: comments.length);

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

BiliComment _sub(int i) => BiliComment(
      id: 'sub-$i',
      uname: '子评论用户$i',
      message: '子评论正文 $i',
    );

BiliComment _floor({
  List<BiliComment>? replies,
  int totalReplies = 68,
  String? replyCursor = '145767900000000',
  bool repliesLoaded = false,
  int replyCount = 2,
}) =>
    BiliComment(
      id: '5355080000000001',
      uname: '_warma_',
      message: '晕3D 的一条一级评论',
      platformKey: 'weibo',
      replyCount: replyCount,
      replies: replies ?? <BiliComment>[_sub(0), _sub(1)],
      repliesLoaded: repliesLoaded,
      totalReplies: totalReplies,
      replyCursor: replyCursor,
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<BiliComment> comments,
  Platform platform = Platform.weibo,
  ChildRepliesLoader? loader,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        commentListProvider.overrideWith(
          (ref, args) => CommentListNotifier(
            repo: _FakeRepo(comments),
            args: args,
            loadChildReplies: loader,
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CommentSection(
            oid: '5355066445792642',
            platform: platform,
            type: platform == Platform.weibo ? 0 : 1,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 点到视线内再 tap。
///
/// 12 条子评论会把「收起 ^」这行推到 800x600 测试视口之外，
/// 不先滚过去的话 tap 会静默落空（hit test 警告）。
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('微博子评论（参考设计）', () {
    testWidgets('未展开：只显示前 2 条 + 「...... 共 68 条回复 >」', (tester) async {
      final List<BiliComment> subs = <BiliComment>[for (int i = 0; i < 10; i++) _sub(i)];
      await _pump(
        tester,
        comments: <BiliComment>[
          _floor(replies: subs, replyCount: subs.length),
        ],
      );

      // 只渲染前 2 条 —— 第 3 条及其后都不该出现。
      expect(find.text('子评论正文 0'), findsOneWidget);
      expect(find.text('子评论正文 1'), findsOneWidget);
      expect(find.text('子评论正文 2'), findsNothing);
      expect(find.text('子评论正文 9'), findsNothing);

      // 那行的文案：三个点 + 「共 N 条回复」+ `>`（都是文本，不是图标）。
      expect(find.text('...... 共 68 条回复 >'), findsOneWidget);
    });

    testWidgets('totalReplies 为 0 但 replies 非空 → 用 replies.length 兜底', (tester) async {
      await _pump(
        tester,
        comments: <BiliComment>[
          _floor(totalReplies: 0, replyCount: 2),
        ],
      );
      expect(find.text('...... 共 2 条回复 >'), findsOneWidget);
    });

    testWidgets('点击 → 展开显示全部已加载的，行变成「收起 ^」', (tester) async {
      final List<BiliComment> subs = <BiliComment>[for (int i = 0; i < 10; i++) _sub(i)];
      await _pump(
        tester,
        comments: <BiliComment>[
          _floor(replies: subs, replyCount: subs.length),
        ],
        // 不给 loader：这一条只验「点开展开态渲染全部」，不验网络。
      );

      // 首帧必须是**未展开**：即便 replies 里已有 10 条，也只能显示前 2 条 + 那一行。
      expect(find.text('子评论正文 2'), findsNothing);
      expect(find.text('...... 共 68 条回复 >'), findsOneWidget);

      await _tapVisible(tester, find.text('...... 共 68 条回复 >'));

      expect(find.text('子评论正文 9'), findsOneWidget);
      expect(find.text('收起 ^'), findsOneWidget);
      expect(find.text('...... 共 68 条回复 >'), findsNothing);
    });

    testWidgets('repliesLoaded 已为 true 也不能让楼层一进页面就是展开态', (tester) async {
      // 真机复现过的 bug：解析层把内嵌 2 条标成 repliesLoaded=true，
      // 早先拿它当展开开关 → 楼层首帧就是「收起 ^」，
      // `...... 共 N 条回复 >` 那行永远不出现，用户点不到。
      await _pump(
        tester,
        comments: <BiliComment>[
          _floor(
            replies: <BiliComment>[_sub(0), _sub(1)],
            repliesLoaded: true,
            replyCount: 2,
          ),
        ],
      );

      expect(
        find.text('...... 共 68 条回复 >'),
        findsOneWidget,
        reason: '必须给出可点的那一行，否则功能等于不存在',
      );
      expect(find.text('收起 ^'), findsNothing);
      expect(find.text('子评论正文 0'), findsOneWidget, reason: '未展开也显示前 2 条');
      expect(find.text('子评论正文 1'), findsOneWidget);
    });

    testWidgets('已到底且 12 < 68 → 补一行「已显示全部 12 条」', (tester) async {
      final List<BiliComment> subs = <BiliComment>[for (int i = 0; i < 12; i++) _sub(i)];
      await _pump(
        tester,
        comments: <BiliComment>[
          _floor(replies: subs, replyCount: 12, repliesLoaded: true),
        ],
        loader: ({
          required String cid,
          String? maxId,
          String? mid,
        }) async {
          // 一进来就到底：0 条。
          return (items: const <BiliComment>[], nextCursor: null);
        },
      );

      // 直接点展开（首帧就是未展开态），走一次真实的状态机，
      // 这样 repliesAllLoaded 才会被置上。
      await _tapVisible(tester, find.text('...... 共 68 条回复 >'));

      expect(find.text('收起 ^'), findsOneWidget);
      expect(
        find.text('已显示全部 12 条'),
        findsOneWidget,
        reason: '如实告知：接口只给到 12 条，不假装拉全了 68 条',
      );
      // 绝不能出现「12/68」这种把声称总数当分母的进度文案。
      expect(find.textContaining('/68'), findsNothing);
      expect(find.textContaining('68/'), findsNothing);
    });

    testWidgets('展开后拉到更多 → 显示超过 2 条（核心验收）', (tester) async {
      await _pump(
        tester,
        comments: <BiliComment>[_floor()],
        loader: ({
          required String cid,
          String? maxId,
          String? mid,
        }) async {
          // 第 1 页 10 条（含内嵌的 2 条）→ 之后到底。
          return (
            items: <BiliComment>[for (int i = 0; i < 10; i++) _sub(i)],
            nextCursor: null,
          );
        },
      );

      // 未展开：2 条。
      expect(find.text('子评论正文 2'), findsNothing);

      await _tapVisible(tester, find.text('...... 共 68 条回复 >'));

      // 展开后：10 条（去重后，内嵌 2 条是子集）。
      expect(find.text('子评论正文 9'), findsOneWidget);
      expect(find.text('收起 ^'), findsOneWidget);
      expect(find.text('已显示全部 10 条'), findsOneWidget);
    });

    testWidgets('失败：保留已展开内容 + 可读错误，不整页崩', (tester) async {
      await _pump(
        tester,
        comments: <BiliComment>[_floor()],
        loader: ({
          required String cid,
          String? maxId,
          String? mid,
        }) async {
          throw Exception('boom');
        },
      );

      await _tapVisible(tester, find.text('...... 共 68 条回复 >'));

      // 内嵌的 2 条仍在（已展开）。
      expect(find.text('子评论正文 0'), findsOneWidget);
      expect(find.text('子评论正文 1'), findsOneWidget);
      expect(find.text('收起 ^'), findsOneWidget);
      // 一行可读错误。
      expect(find.textContaining('子评论加载失败'), findsOneWidget);
    });

    testWidgets('子评论样式：24px 头像 + 昵称 + 正文 + 时间', (tester) async {
      await _pump(
        tester,
        comments: <BiliComment>[
          _floor(
            replies: <BiliComment>[
              BiliComment(
                id: 'sub-0',
                uname: '子评论用户0',
                message: '子评论正文 0',
                avatar: 'https://wx1.sinaimg.cn/orj480/a.jpg',
                createdAtOverride: DateTime.now().subtract(const Duration(hours: 2)),
                like: 7,
              ),
            ],
            totalReplies: 68,
          ),
        ],
      );

      expect(find.text('子评论用户0'), findsOneWidget);
      expect(find.text('子评论正文 0'), findsOneWidget);
      // 时间与点赞数都渲染在底部一行。
      expect(find.text('7'), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_outlined), findsWidgets);
    });
  });

  // ---------------------------------------------------------------- B 站红线
  group('B 站零变化', () {
    testWidgets('仍是「查看 N 条回复」，不是两段式', (tester) async {
      await _pump(
        tester,
        platform: Platform.bilibili,
        comments: <BiliComment>[
          BiliComment(
            id: '1',
            uname: 'bili-user',
            message: 'B 站的一条评论',
            replyCount: 5,
            replies: <BiliComment>[_sub(0), _sub(1)],
            // 注意：B 站不会设置 totalReplies / replyCursor。
          ),
        ],
      );

      expect(find.text('查看 5 条回复'), findsOneWidget);
      // 两段式的任何文案都不该出现。
      expect(find.textContaining('条回复 >'), findsNothing);
      expect(find.text('收起 ^'), findsNothing);
      expect(find.textContaining('已显示全部'), findsNothing);
    });
  });
}
