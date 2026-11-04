import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/repo/comment_repo.dart';
import 'package:rrha/features/comments/comment_controller.dart';
import 'package:rrha/features/comments/comment_section.dart';
import 'package:rrha/widgets/photo_grid.dart';

/// 微博评论**多图懒加载**的离线验收。
///
/// 钉死四条：
/// 1. **绝不在列表构建路径发请求**：`load()` / 构建 UI 都不得触发解析；
/// 2. 只有 `expandCommentPics`（用户点击）才调用解析器，且结果写回 `images`；
/// 3. 失败保留单图 + 可读提示（不整页崩、不重试）；
/// 4. B 站（`mixMediaIds` 恒空）走不到新路径。

const String _single =
    'https://wx2.sinaimg.cn/large/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg';

BiliComment _comment({
  String id = '5355280000000001',
  String message = 'steam上有人开发了一款缓解3d眩晕的插件',
  List<String> images = const <String>[_single],
  int imageCount = 3,
  List<String> mixMediaIds = const <String>[
    'http://t.cn/AXlmgHJ6',
    'http://t.cn/AXlmgHJS',
    'http://t.cn/AXlmgHJa',
  ],
}) =>
    BiliComment(
      id: id,
      uname: '_TOMARU_',
      message: message,
      images: images,
      imageCount: imageCount,
      mixMediaIds: mixMediaIds,
      platformKey: 'weibo',
    );

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

void main() {
  group('controller · expandCommentPics', () {
    late _FakeRepo repo;
    late List<String> requested;
    late List<List<String>> calls;

    CommentListNotifier build({
      Future<List<String>> Function(List<String>, {String? commentId})? resolve,
    }) =>
        CommentListNotifier(
          repo: repo,
          args: const CommentArgs(
            oid: '5355066445792642',
            platform: Platform.weibo,
            type: 0,
          ),
          resolvePics: resolve,
        );

    Future<List<String>> defaultResolve(
      List<String> ids, {
      String? commentId,
    }) async {
      calls.add(ids);
      requested.addAll(ids);
      return const <String>[
        'https://wx3.sinaimg.cn/large/a.jpg',
        'https://wx1.sinaimg.cn/large/b.jpg',
        'https://wx4.sinaimg.cn/large/c.jpg',
      ];
    }

    setUp(() {
      repo = _FakeRepo(<BiliComment>[_comment()]);
      requested = <String>[];
      calls = <List<String>>[];
    });

    test('load() 期间**不发**任何解析请求（列表路径零请求）', () async {
      final CommentListNotifier n = build(resolve: defaultResolve);
      await n.load();

      expect(calls, isEmpty, reason: '列表构建路径绝不能触发短链解析');
      expect(n.state.resolvingPics, isEmpty);
      expect(n.state.items.single.images.length, 1, reason: '仍是接口给的单图');
    });

    test('点开 → 用解析结果替换 images（3 张）', () async {
      final CommentListNotifier n = build(resolve: defaultResolve);
      await n.load();

      await n.expandCommentPics(n.state.items.single);

      expect(calls.length, 1);
      expect(calls.single, <String>[
        'http://t.cn/AXlmgHJ6',
        'http://t.cn/AXlmgHJS',
        'http://t.cn/AXlmgHJa',
      ]);
      final BiliComment after = n.state.items.single;
      expect(after.images.length, 3);
      expect(after.images.first, 'https://wx3.sinaimg.cn/large/a.jpg');
      expect(after.imageCount, 3, reason: '张数角标不该丢');
      expect(after.mixMediaIds, isEmpty, reason: '展开过就不再需要短链线索');
      expect(n.state.expandedPics, contains('5355280000000001'));
      expect(n.state.resolvingPics, isEmpty);
      expect(n.state.picsError, isEmpty);
    });

    test('重复点击不再解析（已展开 / 解析中都是幂等的）', () async {
      final CommentListNotifier n = build(resolve: defaultResolve);
      await n.load();
      await n.expandCommentPics(n.state.items.single);
      await n.expandCommentPics(n.state.items.single);

      expect(calls.length, 1, reason: '同一条评论只解析一次');
    });

    test('解析失败 → 保留单图 + 可读提示，不整页崩', () async {
      final CommentListNotifier n = build(
        resolve: (List<String> ids, {String? commentId}) async => <String>[],
      );
      await n.load();

      await n.expandCommentPics(n.state.items.single);

      final BiliComment after = n.state.items.single;
      expect(after.images, <String>[_single], reason: '失败降级回单图');
      expect(n.state.picsError['5355280000000001'], isNotNull);
      expect(n.state.resolvingPics, isEmpty);
      expect(n.state.items.length, 1, reason: '评论本身不能被清掉');
    });

    test('没有注入解析器（B 站 / 单测）→ 空转，不发请求', () async {
      final CommentListNotifier n = build();
      await n.load();

      await n.expandCommentPics(n.state.items.single);

      expect(calls, isEmpty);
      expect(n.state.items.single.images.length, 1);
    });

    test('没有 mixMediaIds 的评论（单图 / B 站）→ 空转', () async {
      repo = _FakeRepo(<BiliComment>[
        _comment(mixMediaIds: const <String>[], imageCount: 1),
      ]);
      final CommentListNotifier n = build(resolve: defaultResolve);
      await n.load();

      await n.expandCommentPics(n.state.items.single);

      expect(calls, isEmpty);
      expect(n.state.items.single.images.length, 1);
    });
  });

  group('UI · 「共 N 张」可点击', () {
    Future<void> pump(
      WidgetTester tester,
      List<BiliComment> comments, {
      Platform platform = Platform.weibo,
      CommentPicResolver? resolve,
      void Function(CommentListNotifier n)? onReady,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            commentListProvider.overrideWith(
              (ref, args) => CommentListNotifier(
                repo: _FakeRepo(comments),
                args: args,
                resolvePics: resolve,
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

    testWidgets('多图评论显示可点击的「共 3 张 · 点此加载全部」', (tester) async {
      await pump(tester, <BiliComment>[_comment()]);

      expect(find.text('共 3 张 · 点此加载全部'), findsOneWidget);
      expect(find.textContaining('接口仅提供'), findsNothing);
      // 构建阶段只有单图：解析器没被调用（这里传 null 也不崩）。
      expect(find.byType(PhotoGrid), findsOneWidget);
    });

    testWidgets('点击后 → 九宫格 3 张，且不再显示「点此加载全部」', (tester) async {
      int calls = 0;
      await pump(
        tester,
        <BiliComment>[_comment()],
        resolve: (List<String> ids, {String? commentId}) async {
          calls++;
          return const <String>[
            'https://wx3.sinaimg.cn/large/a.jpg',
            'https://wx1.sinaimg.cn/large/b.jpg',
            'https://wx4.sinaimg.cn/large/c.jpg',
          ];
        },
      );

      expect(calls, 0, reason: '构建与首屏都不许发请求');

      await tester.tap(find.text('共 3 张 · 点此加载全部'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('共 3 张 · 点此加载全部'), findsNothing);
      expect(find.textContaining('接口仅提供'), findsNothing);
      expect(find.byType(PhotoGrid), findsOneWidget);
      // PhotoGrid 内部 3 张 → 三列九宫格（Wrap 里 3 个格子）。
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('解析失败 → 保留单图 + 可读错误文案', (tester) async {
      await pump(
        tester,
        <BiliComment>[_comment()],
        resolve: (List<String> ids, {String? commentId}) async => <String>[],
      );

      await tester.tap(find.text('共 3 张 · 点此加载全部'));
      await tester.pumpAndSettle();

      expect(find.text('多图加载失败，已保留现有图片'), findsOneWidget);
      expect(find.byType(PhotoGrid), findsOneWidget, reason: '单图仍在');
    });

    testWidgets('B 站：没有短链 → 保持只读文案，且不出现 PhotoGrid', (tester) async {
      await pump(
        tester,
        <BiliComment>[
          BiliComment(id: '1', uname: 'u', message: 'B 站纯文字评论'),
        ],
        platform: Platform.bilibili,
      );

      expect(find.byType(PhotoGrid), findsNothing);
      expect(find.textContaining('点此加载全部'), findsNothing);
      expect(find.text('B 站纯文字评论'), findsOneWidget);
    });
  });
}
