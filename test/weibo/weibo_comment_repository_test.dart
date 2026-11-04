import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/data/models/comment.dart';
import 'package:rrha/data/models/content_item.dart';
import 'package:rrha/data/weibo/weibo_comment_repository.dart';

/// `WeiboCommentRepository` 的离线验收（假 Dio，不联网）。
///
/// 除了功能分支，这里钉死两条**反直觉 / 安全**的事实：
/// 1. **hotflow 不要求登录**：cookie 为空也要真的发请求，且**不能**报「未登录」；
/// 2. cookie 只进请求头，**绝不**出现在任何 [AppError] 文案里。

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  /// 返回 (statusCode, body)。
  final (int, String) Function(RequestOptions options) handler;

  final List<RequestOptions> captured = <RequestOptions>[];

  int get callCount => captured.length;

  RequestOptions get last => captured.last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    final (int status, String body) = handler(options);
    return ResponseBody.fromString(
      body,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 构造一个能返回指定响应的仓库。
({WeiboCommentRepository repo, _FakeAdapter adapter}) _repo(
  (int, String) Function(RequestOptions options) handler, {
  String cookie = 'SUB=_2A25Ltest; SUBP=0033Wtest',
}) {
  final Dio dio = Dio(
    BaseOptions(
      responseType: ResponseType.plain,
      validateStatus: (int? status) => status != null && status < 500,
    ),
  );
  final _FakeAdapter adapter = _FakeAdapter(handler);
  dio.httpClientAdapter = adapter;
  return (
    repo: WeiboCommentRepository(
      dio: dio,
      cookies: WeiboCookieSource(loader: () async => cookie),
    ),
    adapter: adapter,
  );
}

/// 一份实测形态的 hotflow 响应（1 条一级评论 + 1 条内嵌楼中楼）。
String _body({int maxId = 182712657086119}) =>
    '{"ok":1,"data":{"data":[{"created_at":"Mon Aug 07 20:15:58 +0800 2023",'
    '"id":"4932195724034522","rootid":"4932195724034522","floor_number":6,'
    '"text":"你确定是偶尔直播？<span class=\\"url-icon\\"><img alt=\\"[怒]\\" '
    'src=\\"https://face.t.sinajs.cn/t4/x.png\\"></span>",'
    '"like_count":1276,"readtimetype":"comment",'
    '"user":{"id":6611538293,"screen_name":"若叶睦子米Mutsumi",'
    '"avatar_hd":"https://wx1.sinaimg.cn/orj480/hd.jpg"},'
    '"comments":[{"created_at":"Mon Aug 07 20:17:27 +0800 2023",'
    '"id":"4932196097852372","rootid":"4932195724034522",'
    '"text":"<span class=\\"url-icon\\"><img alt=\\"[害羞]\\" '
    'src=\\"https://face.t.sinajs.cn/t4/y.png\\"></span>",'
    '"user":{"id":1782488734,"screen_name":"warma"}}]}],'
    '"max":999999999999999,"max_id":$maxId,"max_id_type":0,'
    '"status":0,"total_number":788}}';

const CommentRequest _req = CommentRequest(
  platform: Platform.weibo,
  oid: '4932195589819028',
  type: 0,
);

void main() {
  group('正常响应', () {
    test('200 → 返回评论、总数与游标正确', () async {
      final (:repo, :adapter) = _repo((_) => (200, _body()));

      final CommentPage page = await repo.loadFirst(req: _req);

      expect(adapter.callCount, 1);
      expect(page.comments.length, 1);
      expect(page.total, 788);
      expect(page.nextCursor, '182712657086119');
      expect(page.isEnd, isFalse);

      final BiliComment c = page.comments.single;
      expect(c.id, '4932195724034522');
      expect(c.uname, '若叶睦子米Mutsumi');
      expect(c.message, '你确定是偶尔直播？[怒]');
      expect(c.like, 1276);
      expect(c.createdAt, isNotNull);
      // 内嵌楼中楼直接可用。
      expect(c.replies.length, 1);
      expect(c.repliesLoaded, isTrue);
      expect(c.replies.single.message, '[害羞]');
    });

    test('URL 形态：id / mid / max_id_type 都在，首页不带 max_id', () async {
      final (:repo, :adapter) = _repo((_) => (200, _body()));

      await repo.loadFirst(req: _req);

      final String url = adapter.last.uri.toString();
      expect(url, startsWith(WeiboCommentRepository.endpoint));
      expect(url, contains('id=4932195589819028'));
      expect(url, contains('mid=4932195589819028'));
      expect(url, contains('max_id_type=0'));
      expect(url, isNot(contains('max_id=')));
    });

    test('第二页 URL 里带 max_id（原样拼接，不做数值加工）', () async {
      final (:repo, :adapter) = _repo((_) => (200, _body()));

      await repo.loadMore(req: _req, cursor: '182712657086119');

      final String url = adapter.last.uri.toString();
      expect(url, contains('max_id=182712657086119'));
      expect(url, contains('max_id_type=0'), reason: '翻页必须同时带 max_id_type');
    });
  });

  group('凭据', () {
    test('cookie 为空时**仍然发起请求**，且不报「未登录」', () async {
      // 反直觉但实测成立：hotflow 不要求登录（未登录同样 200 + 20 条）。
      final (:repo, :adapter) = _repo(
        (_) => (200, _body()),
        cookie: '',
      );

      final CommentPage page = await repo.loadFirst(req: _req);

      expect(adapter.callCount, 1, reason: '没有 cookie 也必须真的去请求');
      expect(page.comments, isNotEmpty, reason: '未登录也能拿到评论');
      // 空 cookie 时干脆不设 Cookie 头。
      expect(adapter.last.headers.containsKey('Cookie'), isFalse);
    });

    test('有 cookie 时进 Cookie 头，其它头也齐全', () async {
      const String cookie = 'SUB=_2A25Ltest; SUBP=0033Wtest; _T_WM=777';
      final (:repo, :adapter) = _repo((_) => (200, _body()), cookie: cookie);

      await repo.loadFirst(req: _req);

      final Map<String, dynamic> headers = adapter.last.headers;
      expect(headers['Cookie'], cookie);
      expect(headers['User-Agent'], WeiboCommentRepository.userAgent);
      expect(headers['X-Requested-With'], 'XMLHttpRequest');
      expect(headers['MWeibo-Pwa'], '1');
      expect(headers['Referer'], contains('/status/4932195589819028'));
    });

    test('cookie 绝不出现在错误文案里（432 也一样）', () async {
      const String secret = 'SUB=_2A25LSECRET; SUBP=MUSTNOTLEAK';
      final (:repo, :adapter) = _repo(
        (_) => (432, '{"ok":0}'),
        cookie: secret,
      );

      await expectLater(
        repo.loadFirst(req: _req),
        throwsA(
          isA<AppError>()
              .having((AppError e) => e.message, 'message',
                  isNot(contains('SECRET')))
              .having((AppError e) => e.detail ?? '', 'detail',
                  isNot(contains('SECRET'))),
        ),
      );
      expect(adapter.callCount, 1);
    });
  });

  group('错误映射（中文文案）', () {
    test('432 → 风控文案，但**不说**「未登录」', () async {
      final (:repo, :adapter) = _repo((_) => (432, ''));

      try {
        await repo.loadFirst(req: _req);
        fail('应当抛 AppError');
      } on AppError catch (e) {
        expect(e.statusCode, 432);
        expect(e.message, contains('432'));
        expect(e.message, isNot(contains('登录')), reason: 'hotflow 不需要登录');
        expect(e.showRetry, isTrue);
      }
    });

    test('500 → server 错误且可重试', () async {
      final (:repo, :adapter) = _repo((_) => (500, ''));

      try {
        await repo.loadFirst(req: _req);
        fail('应当抛 AppError');
      } on AppError catch (e) {
        expect(e.kind, AppErrorKind.server);
        expect(e.showRetry, isTrue);
      }
    });

    test('200 但不是 JSON → parse 错误（不静默返回空页）', () async {
      final (:repo, :adapter) = _repo((_) => (200, '<html>抗爬</html>'));

      try {
        await repo.loadFirst(req: _req);
        fail('应当抛 AppError');
      } on AppError catch (e) {
        expect(e.kind, AppErrorKind.parse);
      }
    });

    test('空 mid 直接返回空页，不发请求', () async {
      final (:repo, :adapter) = _repo((_) => (200, _body()));

      final CommentPage page = await repo.loadFirst(
        req: const CommentRequest(platform: Platform.weibo, oid: ''),
      );

      expect(page.comments, isEmpty);
      expect(page.isEnd, isTrue);
      expect(adapter.callCount, 0);
    });
  });

  group('楼中楼', () {
    test('微博没有第二个接口：loadReplies 返回空页且不发请求', () async {
      final (:repo, :adapter) = _repo((_) => (200, _body()));

      final SubCommentPage page = await repo.loadReplies(
        req: _req,
        rootId: '4932195724034522',
      );

      expect(page.comments, isEmpty);
      expect(page.hasMore, isFalse);
      expect(adapter.callCount, 0, reason: '内嵌楼中楼不该触发第二个请求');
    });
  });

  // =========================================================== 子评论接口
  //
  // `comments/hotflowChild` 与一级接口有两处**结构性差异**（实测）：
  // 1. 列表路径是 `data`（直接是 List），不是 `data.data`；
  // 2. 响应里**没有**游标字段 —— 游标由调用方把一级节点的 `max_id` 传进来。
  group('loadChildReplies（hotflowChild）', () {
    /// 子评论响应：`data` 直接是数组（10 条，照探针第 1 页）。
    String childBody({int count = 10, String prefix = 'sub'}) {
      final String items = List<String>.generate(
        count,
        (int i) => '{"id":"$prefix-$i","rootid":"4932195724034522",'
            '"text":"回复 $i","created_at":"Sat Oct 17 19:00:03 +0800 2026",'
            '"user":{"screen_name":"u$i"}}',
      ).join(',');
      // 关键：`data` 是数组，不是对象。
      return '{"ok":1,"data":[$items]}';
    }

    test('第 1 页：URL 只带 cid + max_id_type，解析出 10 条', () async {
      final (:repo, :adapter) = _repo((_) => (200, childBody()));

      final ({List<BiliComment> items, String? nextCursor}) page =
          await repo.loadChildReplies(cid: '4932195724034522');

      expect(adapter.callCount, 1);
      expect(
        adapter.last.uri.toString(),
        startsWith(WeiboCommentRepository.childEndpoint),
      );
      final String url = adapter.last.uri.toString();
      expect(url, contains('cid=4932195724034522'));
      expect(url, contains('max_id_type=0'));
      expect(url, isNot(contains('max_id=')), reason: '首页不带游标');
      expect(url, isNot(contains('mid=')), reason: '子接口不吃 mid');

      expect(page.items.length, 10, reason: '列表在 data（直接 List），不是 data.data');
      expect(page.items.first.id, 'sub-0');
      expect(page.items.first.uname, 'u0');
    });

    test('续拉：&max_id= 原样拼接，返回同一游标供继续', () async {
      final (:repo, :adapter) = _repo((_) => (200, childBody(count: 2)));

      final ({List<BiliComment> items, String? nextCursor}) page =
          await repo.loadChildReplies(
        cid: '4932195724034522',
        maxId: '145767900000000',
      );

      expect(
        adapter.last.uri.toString(),
        contains('max_id=145767900000000'),
        reason: '游标原样拼接，不做数值加工',
      );
      expect(page.items.length, 2);
      // 接口不给新游标 → 把进来的游标交回去（下一次即「继续往下」）。
      expect(page.nextCursor, '145767900000000');
    });

    test('终止条件：本页 0 条 → nextCursor 为 null（到底）', () async {
      final (:repo, :adapter) = _repo((_) => (200, childBody(count: 0)));

      final ({List<BiliComment> items, String? nextCursor}) page =
          await repo.loadChildReplies(
        cid: '4932195724034522',
        maxId: '145767900000000',
      );

      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull, reason: '0 条就是到底，不再给游标');
    });

    test('没传游标又没内容 → nextCursor 为 null（不会伪造游标）', () async {
      final (:repo, :adapter) = _repo((_) => (200, childBody(count: 0)));

      final ({List<BiliComment> items, String? nextCursor}) page =
          await repo.loadChildReplies(cid: '4932195724034522');

      expect(page.nextCursor, isNull);
    });

    test('cid 为空 → 空结果且不发请求', () async {
      final (:repo, :adapter) = _repo((_) => (200, childBody()));

      final ({List<BiliComment> items, String? nextCursor}) page =
          await repo.loadChildReplies(cid: '   ');

      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
      expect(adapter.callCount, 0);
    });

    test('cookie 进 Cookie 头，且不出现在错误文案里', () async {
      const String secret = 'SUB=_2A25LCHILDSECRET; SUBP=MUSTNOTLEAK';
      final (:repo, :adapter) = _repo((_) => (200, childBody()), cookie: secret);

      await repo.loadChildReplies(cid: '4932195724034522');
      expect(adapter.last.headers['Cookie'], secret);

      // 失败路径：432 的文案里不能漏 cookie。
      final ({WeiboCommentRepository repo, _FakeAdapter adapter}) failing =
          _repo((_) => (432, ''), cookie: secret);
      try {
        await failing.repo.loadChildReplies(cid: '4932195724034522');
        fail('应当抛 AppError');
      } on AppError catch (e) {
        expect(e.message, isNot(contains('SECRET')));
        expect(e.detail ?? '', isNot(contains('SECRET')));
        expect(e.message, contains('432'));
      }
    });
    test('失败不重试：500 只发一次请求，抛可读 AppError', () async {
      final (:repo, :adapter) = _repo((_) => (500, ''));

      await expectLater(
        repo.loadChildReplies(cid: '4932195724034522'),
        throwsA(isA<AppError>()),
      );
      expect(adapter.callCount, 1, reason: '绝不自动重试');
    });

    test('200 但不是 JSON → parse 错误（不静默返回空列表）', () async {
      final (:repo, :adapter) = _repo((_) => (200, '<html>抗爬</html>'));

      try {
        await repo.loadChildReplies(cid: '4932195724034522');
        fail('应当抛 AppError');
      } on AppError catch (e) {
        expect(e.kind, AppErrorKind.parse);
      }
    });

    test('纯函数 buildChildUrl（离线钉住 URL 形态）', () {
      expect(
        WeiboCommentRepository.buildChildUrl(cid: 'abc'),
        '${WeiboCommentRepository.childEndpoint}?cid=abc&max_id_type=0',
      );
      expect(
        WeiboCommentRepository.buildChildUrl(cid: 'abc', maxId: ' 145 '),
        contains('&max_id=145'),
      );
      // 空游标不拼。
      expect(
        WeiboCommentRepository.buildChildUrl(cid: 'abc', maxId: '  '),
        isNot(contains('max_id=')),
      );
    });
  });
}
