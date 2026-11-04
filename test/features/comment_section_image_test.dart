import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/repo/comment_repo.dart';
import 'package:rrha/features/comments/comment_controller.dart';
import 'package:rrha/features/comments/comment_section.dart';
import 'package:rrha/widgets/photo_grid.dart';

/// 评论区「配图渲染」的离线验收。
///
/// 关注的是**这一条图片有没有被渲染成 [PhotoGrid]**，不验网络：
/// `CachedImage` 在测试环境里取不到网图会走 errorWidget（灰底占位），
/// 那属于既有行为，与本改动无关。
///
/// 另外钉住红线：B 站评论（images 恒空）不应出现任何 [PhotoGrid]。

/// 假仓库：只回一页写死的评论，不发任何请求。
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

BiliComment _comment({
  String id = '1',
  String message = '看这张图',
  List<String> images = const <String>[],
  int imageCount = 0,
  List<BiliComment> replies = const <BiliComment>[],
}) =>
    BiliComment(
      id: id,
      uname: '若叶睦子米Mutsumi',
      message: message,
      images: images,
      imageCount: imageCount,
      replies: replies,
      replyCount: replies.length,
      repliesLoaded: replies.isNotEmpty,
    );

Future<void> _pump(
  WidgetTester tester,
  List<BiliComment> comments, {
  Platform platform = Platform.weibo,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        // 覆盖评论控制器：注入假仓库，绝不构造真实客户端 / 发网络请求。
        commentListProvider.overrideWith(
          (ref, args) => CommentListNotifier(
            repo: _FakeRepo(comments),
            args: args,
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CommentSection(
            oid: '5355066445792642',
            platform: platform,
            type: 1,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('带图片的评论渲染出 PhotoGrid', (tester) async {
    await _pump(
      tester,
      <BiliComment>[
        _comment(
          images: const <String>[
            'https://wx2.sinaimg.cn/large/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg',
          ],
          imageCount: 1,
        ),
      ],
    );

    expect(find.byType(PhotoGrid), findsOneWidget);
    expect(find.text('看这张图'), findsOneWidget);
    // 张数一致时不该出现「共 N 张」提示。
    expect(find.textContaining('接口仅提供'), findsNothing);
  });

  testWidgets('B 站评论（images 恒空）不渲染任何 PhotoGrid', (tester) async {
    await _pump(
      tester,
      <BiliComment>[_comment(message: 'B 站的一条纯文字评论')],
      platform: Platform.bilibili,
    );

    expect(find.byType(PhotoGrid), findsNothing);
    expect(find.text('B 站的一条纯文字评论'), findsOneWidget);
  });

  testWidgets('pic_num=3 但只有 1 张 → 显示「共 3 张（接口仅提供 1 张）」', (tester) async {
    await _pump(
      tester,
      <BiliComment>[
        _comment(
          images: const <String>['https://wx2.sinaimg.cn/large/a.jpg'],
          imageCount: 3,
        ),
      ],
    );

    expect(find.byType(PhotoGrid), findsOneWidget, reason: '只给 1 张就显示 1 张');
    expect(
      find.text('共 3 张（接口仅提供 1 张）'),
      findsOneWidget,
      reason: '如实告知，不假装支持多图',
    );
  });

  testWidgets('二级评论的图片也渲染（尺寸更小）', (tester) async {
    await _pump(
      tester,
      <BiliComment>[
        _comment(
          replies: <BiliComment>[
            _comment(
              id: '2',
              message: '楼中楼带图',
              images: const <String>['https://wx2.sinaimg.cn/large/b.jpg'],
              imageCount: 1,
            ),
          ],
        ),
      ],
    );

    // 楼中楼用 RichText（昵称 + 正文两段样式不同），find.text 抓不到，
    // 所以这里断言结构：整页只有一个 PhotoGrid，且它来自二级评论。
    expect(find.byType(PhotoGrid), findsOneWidget);
    expect(find.byType(RichText), findsWidgets);
  });

  testWidgets('点图片能打开全屏预览页', (tester) async {
    await _pump(
      tester,
      <BiliComment>[
        _comment(
          images: const <String>['https://wx2.sinaimg.cn/large/a.jpg'],
          imageCount: 1,
        ),
      ],
    );

    await tester.tap(find.byType(PhotoGrid));
    await tester.pumpAndSettle();

    // 预览页有页码（单图 = 1 / 1）与标题。
    expect(find.text('1 / 1'), findsOneWidget);
  });
}
