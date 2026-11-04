import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/weibo_cookie_source.dart';
import 'package:rrha/data/weibo/weibo_comment_pic_resolver.dart';

/// `WeiboCommentPicResolver` 的离线验收（假 Dio，不联网）。
///
/// 覆盖三块：
/// 1. **纯函数**：http→https 升级、`<img src>` 提取、`bmiddle`→`large`、9 张上限；
/// 2. **仓库行为**：N 条短链 = N 个请求、返回 N 个地址、单条失败不影响其它；
/// 3. **缓存**：同一条评论第二次调用**不再发请求**（短码稳定）。
///
/// 全部钉住红线：**失败不重试**（请求数就是断言的一部分）。

/// 实测落地页（463 字节，正文唯一 `<img>`）。
String _landingPage(String src) => '<html>\n'
    '<head>\n'
    '<meta charset="UTF-8">\n'
    '<title>图片</title>\n'
    '</head>\n'
    '<body>\n'
    '\t<div class="wrap-box">\n'
    '\t\t<div class="img-box" style="max-height: 100%;">\n'
    '\t\t\t<img src="$src">\n'
    '\t\t</div>\n'
    '\t</div>\n'
    '</body>\n'
    '</html>\n';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  /// 返回 (statusCode, body)；抛异常 = 模拟网络失败。
  final (int, String) Function(RequestOptions options) handler;

  final List<RequestOptions> captured = <RequestOptions>[];

  int get callCount => captured.length;

  List<String> get urls =>
      captured.map((RequestOptions o) => o.uri.toString()).toList();

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
        Headers.contentTypeHeader: <String>['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

({WeiboCommentPicResolver resolver, _FakeAdapter adapter}) _resolver(
  (int, String) Function(RequestOptions options) handler, {
  String cookie = 'SUB=_2A25Ltest; SUBP=0033Wtest',
}) {
  final Dio dio = Dio(
    BaseOptions(
      responseType: ResponseType.plain,
      followRedirects: true,
      validateStatus: (int? s) => s != null && s < 400,
    ),
  );
  final _FakeAdapter adapter = _FakeAdapter(handler);
  dio.httpClientAdapter = adapter;
  return (
    resolver: WeiboCommentPicResolver(
      dio: dio,
      cookies: WeiboCookieSource(loader: () async => cookie),
    ),
    adapter: adapter,
  );
}

void main() {
  group('纯函数 · https 升级', () {
    test('http://t.cn/x → https://t.cn/x（接口给的就是 http）', () {
      expect(
        WeiboCommentPicResolver.httpsUrl('http://t.cn/AXlmgHJ6'),
        'https://t.cn/AXlmgHJ6',
      );
    });

    test('已经是 https 的保持不变', () {
      expect(
        WeiboCommentPicResolver.httpsUrl('https://t.cn/AXlmgHJ6'),
        'https://t.cn/AXlmgHJ6',
      );
    });

    test('无 scheme 的裸串按 https 补全；空串 / 陌生 scheme 返回空', () {
      expect(WeiboCommentPicResolver.httpsUrl('t.cn/AXlmgHJ6'),
          'https://t.cn/AXlmgHJ6');
      expect(WeiboCommentPicResolver.httpsUrl('   '), '');
      expect(
        WeiboCommentPicResolver.httpsUrl('javascript:alert(1)'),
        '',
        reason: '不认识的 scheme 不该被请求',
      );
    });
  });

  group('纯函数 · 从 HTML 提取 <img src>', () {
    test('双引号（实测落地页形态）', () {
      expect(
        WeiboCommentPicResolver.firstImgSrc(
          _landingPage('https://wx3.sinaimg.cn/bmiddle/abc.jpg'),
        ),
        'https://wx3.sinaimg.cn/bmiddle/abc.jpg',
      );
    });

    test('单引号', () {
      expect(
        WeiboCommentPicResolver.firstImgSrc(
          "<img src='https://wx1.sinaimg.cn/bmiddle/a.jpg'>",
        ),
        'https://wx1.sinaimg.cn/bmiddle/a.jpg',
      );
    });

    test('无引号', () {
      expect(
        WeiboCommentPicResolver.firstImgSrc(
          '<img src=https://wx2.sinaimg.cn/bmiddle/b.jpg>',
        ),
        'https://wx2.sinaimg.cn/bmiddle/b.jpg',
      );
    });

    test('src 带其它属性 / 属性顺序不同也能取到', () {
      expect(
        WeiboCommentPicResolver.firstImgSrc(
          '<img class="x" data-src="no.png" width=10 '
          'src="https://wx4.sinaimg.cn/bmiddle/c.jpg" alt="">',
        ),
        'https://wx4.sinaimg.cn/bmiddle/c.jpg',
      );
      expect(
        WeiboCommentPicResolver.firstImgSrc(
          '<img height="5" src="https://wx4.sinaimg.cn/bmiddle/d.jpg">',
        ),
        'https://wx4.sinaimg.cn/bmiddle/d.jpg',
      );
    });

    test('取第一个 <img>；没有 <img> / 空串返回 null', () {
      expect(
        WeiboCommentPicResolver.firstImgSrc(
          '<img src="https://a/x1.jpg"><img src="https://a/x2.jpg">',
        ),
        'https://a/x1.jpg',
      );
      expect(WeiboCommentPicResolver.firstImgSrc('<p>没有图</p>'), isNull);
      expect(WeiboCommentPicResolver.firstImgSrc(''), isNull);
    });

    test('HTML 实体 &amp; 还原、//host 补 https', () {
      expect(
        WeiboCommentPicResolver.firstImgSrc(
          '<img src="//wx3.sinaimg.cn/bmiddle/a.jpg?x=1&amp;y=2">',
        ),
        'https://wx3.sinaimg.cn/bmiddle/a.jpg?x=1&y=2',
      );
    });
  });

  group('纯函数 · bmiddle → large', () {
    test('只替换路径段 bmiddle', () {
      expect(
        WeiboCommentPicResolver.toOriginal(
          'https://wx3.sinaimg.cn/bmiddle/84395e04ly1ii67kl0dzkj20xw21swpi.jpg',
        ),
        'https://wx3.sinaimg.cn/large/84395e04ly1ii67kl0dzkj20xw21swpi.jpg',
      );
    });

    test('其它尺寸（orj360 / thumbnail / mw690）原样不动', () {
      for (final String u in <String>[
        'https://ss1.sinaimg.cn/orj360/a.jpg',
        'https://wx1.sinaimg.cn/thumbnail/b.jpg',
        'https://wx2.sinaimg.cn/mw690/c.jpg',
      ]) {
        expect(WeiboCommentPicResolver.toOriginal(u), u);
      }
    });

    test('已经是 large 的幂等', () {
      const String u = 'https://wx1.sinaimg.cn/large/a.jpg';
      expect(WeiboCommentPicResolver.toOriginal(u), u);
      expect(
        WeiboCommentPicResolver.toOriginal(WeiboCommentPicResolver.toOriginal(u)),
        u,
      );
    });
  });

  group('仓库 · N 条短链 = N 个请求', () {
    test('3 条短链 → 3 个请求、3 个原图地址，且 URL 都是 https', () async {
      final (:resolver, :adapter) = _resolver((RequestOptions o) {
        final String u = o.uri.toString();
        if (u.endsWith('/c1')) {
          return (200, _landingPage('https://wx3.sinaimg.cn/bmiddle/p1.jpg'));
        }
        if (u.endsWith('/c2')) {
          return (200, _landingPage('https://wx1.sinaimg.cn/bmiddle/p2.jpg'));
        }
        return (200, _landingPage('https://wx4.sinaimg.cn/bmiddle/p3.jpg'));
      });

      final List<String> out = await resolver.resolveCommentPics(
        <String>['http://t.cn/c1', 'http://t.cn/c2', 'http://t.cn/c3'],
        commentId: '5355280000000001',
      );

      expect(adapter.callCount, 3, reason: '每条短链 1 个请求');
      expect(out, <String>[
        'https://wx3.sinaimg.cn/large/p1.jpg',
        'https://wx1.sinaimg.cn/large/p2.jpg',
        'https://wx4.sinaimg.cn/large/p3.jpg',
      ]);
      expect(
        adapter.urls.every((String u) => u.startsWith('https://t.cn/')),
        isTrue,
        reason: 'http 在 Android 会被明文策略拦，必须升级成 https',
      );
    });

    test('单条失败不影响其它条（失败不重试）', () async {
      final (:resolver, :adapter) = _resolver((RequestOptions o) {
        final String u = o.uri.toString();
        if (u.endsWith('/bad')) return (403, '<html>403</html>');
        if (u.endsWith('/noimg')) return (200, '<html>没有图</html>');
        return (200, _landingPage('https://wx2.sinaimg.cn/bmiddle/ok.jpg'));
      });

      final List<String> out = await resolver.resolveCommentPics(
        <String>['http://t.cn/ok1', 'http://t.cn/bad', 'http://t.cn/noimg'],
        commentId: 'c-fail',
      );

      expect(out, <String>['https://wx2.sinaimg.cn/large/ok.jpg']);
      // 3 条各发 1 次，失败的两条**没有重试**。
      expect(adapter.callCount, 3, reason: '失败绝不重试');
    });

    test('全部失败 → 返回空列表（调用方降级回单图）', () async {
      final (:resolver, :adapter) = _resolver((_) => (500, 'boom'));

      final List<String> out = await resolver.resolveCommentPics(
        <String>['http://t.cn/x'],
        commentId: 'c-allbad',
      );

      expect(out, isEmpty);
      expect(adapter.callCount, 1);
    });

    test('同一评论第二次调用命中缓存，不再发请求', () async {
      final (:resolver, :adapter) = _resolver(
        (_) => (200, _landingPage('https://wx2.sinaimg.cn/bmiddle/c.jpg')),
      );
      const List<String> ids = <String>['http://t.cn/cache1'];

      final List<String> first = await resolver.resolveCommentPics(
        ids,
        commentId: 'c-cache',
      );
      expect(adapter.callCount, 1);
      expect(resolver.isCached('c-cache'), isTrue);

      final List<String> second = await resolver.resolveCommentPics(
        ids,
        commentId: 'c-cache',
      );

      expect(adapter.callCount, 1, reason: '缓存命中不能再发请求');
      expect(second, first);
    });

    test('空输入不发请求；9 张上限截断', () async {
      final (:resolver, :adapter) = _resolver((RequestOptions o) {
        // 每个短码给不同 pid，否则会被 `contains` 去重（那不是本用例要测的）。
        final String code = o.uri.pathSegments.last;
        return (
          200,
          _landingPage('https://wx2.sinaimg.cn/bmiddle/$code.jpg'),
        );
      });

      expect(await resolver.resolveCommentPics(const <String>[]), isEmpty);
      expect(adapter.callCount, 0);

      final List<String> many = <String>[
        for (int i = 0; i < 12; i++) 'http://t.cn/m$i',
      ];
      final List<String> out =
          await resolver.resolveCommentPics(many, commentId: 'c-many');

      expect(adapter.callCount, WeiboCommentPicResolver.maxPics);
      expect(out.length, WeiboCommentPicResolver.maxPics);
      expect(WeiboCommentPicResolver.maxPics, 9);
    });

    test('cookie 只进请求头，不出现在任何返回值里；空 cookie 不设头', () async {
      const String secret = 'SUB=_2A25LSECRET; SUBP=MUSTNOTLEAK';
      final (:resolver, :adapter) = _resolver(
        (_) => (200, _landingPage('https://wx2.sinaimg.cn/bmiddle/c.jpg')),
        cookie: secret,
      );

      final List<String> out = await resolver.resolveCommentPics(
        <String>['http://t.cn/ck'],
        commentId: 'c-cookie',
      );

      expect(adapter.captured.first.headers['Cookie'], secret);
      expect(out.join('|'), isNot(contains('SECRET')));
      expect(adapter.captured.first.headers['Referer'], contains('weibo.cn'));

      // 空 cookie：根本不该有 Cookie 头。
      final ({WeiboCommentPicResolver resolver, _FakeAdapter adapter}) noCookie =
          _resolver(
        (_) => (200, _landingPage('https://a/bmiddle/x.jpg')),
        cookie: '',
      );
      await noCookie.resolver.resolveCommentPics(
        <String>['http://t.cn/e'],
        commentId: 'c-nocookie',
      );
      expect(
        noCookie.adapter.captured.single.headers.containsKey('Cookie'),
        isFalse,
      );
    });

    test('重复短链只请求一次、结果去重', () async {
      final (:resolver, :adapter) = _resolver(
        (_) => (200, _landingPage('https://wx2.sinaimg.cn/bmiddle/dup.jpg')),
      );

      final List<String> out = await resolver.resolveCommentPics(
        <String>['http://t.cn/dup', 'http://t.cn/dup', 'http://t.cn/dup2'],
        commentId: 'c-dup',
      );

      // dup / dup2 两条不同短链 → 2 个请求；但落地页是同一张图 → 结果去重成 1 张。
      expect(adapter.callCount, 2);
      expect(out, <String>['https://wx2.sinaimg.cn/large/dup.jpg']);
    });
  });
}
