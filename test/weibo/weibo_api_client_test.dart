import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/data/weibo/weibo_api_client.dart';

/// `WeiboApiClient` 的离线验收。
///
/// 用假的 Dio adapter 精确控制状态码与响应体，不联网。
/// 除功能分支外，这里还钉死两条**凭据安全**红线：
/// 1. cookie 确实进了请求头（否则接口在游客态恒 432）；
/// 2. cookie **绝不**出现在任何 [AppError] 的文案里。

/// 记录每次请求的 URL 与请求头，供断言使用。
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

/// 构造一个能返回指定响应的客户端。
({WeiboApiClient client, _FakeAdapter adapter}) _client(
  (int, String) Function(RequestOptions options) handler,
) {
  final Dio dio = Dio(
    BaseOptions(
      responseType: ResponseType.plain,
      validateStatus: (int? status) => status != null && status < 500,
    ),
  );
  final _FakeAdapter adapter = _FakeAdapter(handler);
  dio.httpClientAdapter = adapter;
  return (client: WeiboApiClient(dio: dio), adapter: adapter);
}

/// 一份实测形态的 getIndex 响应：3 张卡片（含 1 张 header 卡）。
const String _okBody = '{"ok":1,"data":{"cardlistInfo":{"total":321,'
    '"since_id":"4888888888888888"},"cards":['
    '{"card_type":9,"mblog":{"id":"1001","mid":"1001",'
    '"created_at":"Mon Aug 07 20:15:27 +0800 2023","text":"第一条",'
    '"user":{"id":1782488734,"screen_name":"张三"}}},'
    '{"card_type":9,"mblog":{"id":"1002","mid":"1002",'
    '"created_at":"Mon Aug 07 19:00:00 +0800 2023","text":"第二条",'
    '"user":{"id":1782488734,"screen_name":"张三"}}},'
    '{"card_type":11,"title":"header"}]}}';

void main() {
  group('正常响应', () {
    test('200 + 合法 JSON → mblogs 非空、sinceId 与 total 正确', () async {
      final (:client, :adapter) = _client((_) => (200, _okBody));

      final WeiboPage page = await client.userTimeline(
        uid: '1782488734',
        cookie: 'SUB=abc; SUBP=def',
      );

      expect(page.httpStatus, 200);
      // header 卡（card_type=11）必须被剔掉，只留两条博文卡。
      expect(page.mblogs.length, 2);
      expect(page.sinceId, '4888888888888888');
      expect(page.total, 321);
      expect(page.isEmpty, isFalse);
      expect(adapter.callCount, 1);
    });

    test('请求头里带 UA / Referer / X-Requested-With / MWeibo-Pwa', () async {
      final (:client, :adapter) = _client((_) => (200, _okBody));

      await client.userTimeline(uid: '1782488734', cookie: 'SUB=abc');

      final Map<String, dynamic> headers = adapter.last.headers;
      expect(headers['User-Agent'], WeiboApiClient.userAgent);
      expect(headers['Referer'], 'https://m.weibo.cn/u/1782488734');
      expect(headers['X-Requested-With'], 'XMLHttpRequest');
      expect(headers['MWeibo-Pwa'], '1');
      expect(headers['Accept'], contains('application/json'));
    });

    test('cookie 确实进了 Cookie 请求头', () async {
      const String cookie = 'SUB=_2A25Ltest; SUBP=0033Wtest; _T_WM=777';
      final (:client, :adapter) = _client((_) => (200, _okBody));

      await client.userTimeline(uid: '1782488734', cookie: cookie);

      expect(adapter.last.headers['Cookie'], cookie);
    });

    test('cookie 为空时不设置 Cookie 头（不发一个必然 432 的请求头）', () async {
      final (:client, :adapter) = _client((_) => (200, _okBody));

      await client.userTimeline(uid: '1782488734', cookie: '   ');

      expect(adapter.last.headers.containsKey('Cookie'), isFalse);
    });
  });

  group('URL 与翻页', () {
    test('首屏 URL 含 type=uid / value / containerid=107603<uid>', () async {
      final (:client, :adapter) = _client((_) => (200, _okBody));

      await client.userTimeline(uid: '1782488734', cookie: 'SUB=abc');

      final String url = adapter.last.uri.toString();
      expect(url, contains('/api/container/getIndex'));
      expect(url, contains('type=uid'));
      expect(url, contains('value=1782488734'));
      expect(url, contains('containerid=1076031782488734'));
      expect(url, isNot(contains('since_id=')));
    });

    test('带 sinceId 时 URL 里确实有 since_id=', () async {
      final (:client, :adapter) = _client((_) => (200, _okBody));

      await client.userTimeline(
        uid: '1782488734',
        cookie: 'SUB=abc',
        sinceId: '4888888888888888',
      );

      final String url = adapter.last.uri.toString();
      expect(url, contains('since_id=4888888888888888'));
      // 19 位游标必须原样保留：过 int/double 会丢精度。
      expect(url, isNot(contains('4.888888888888889E')));
    });

    test('buildUrl 是纯函数：空白游标被忽略', () {
      expect(
        WeiboApiClient.buildUrl(uid: '42'),
        '${WeiboApiClient.endpoint}?type=uid&value=42&containerid=10760342',
      );
      expect(
        WeiboApiClient.buildUrl(uid: '42', sinceId: '   '),
        isNot(contains('since_id')),
      );
      expect(
        WeiboApiClient.buildUrl(uid: '42', sinceId: '9'),
        endsWith('&since_id=9'),
      );
    });
  });

  group('错误映射', () {
    test('HTTP 432 → AppError 且 message 含 432、retryable', () async {
      final (:client, :adapter) = _client((_) => (432, ''));

      final Object? thrown = await _capture(
        () => client.userTimeline(uid: '1782488734', cookie: 'SUB=abc'),
      );

      expect(thrown, isA<AppError>());
      final AppError e = thrown! as AppError;
      expect(e.message, contains('432'));
      expect(e.kind, AppErrorKind.forbidden);
      expect(e.retryable, isTrue);
      expect(adapter.callCount, 1);
    });

    test('200 + {"ok":-100} → kind 是 auth，提示重新登录', () async {
      final (:client, adapter: _) = _client((_) => (200, '{"ok":-100}'));

      final Object? thrown = await _capture(
        () => client.userTimeline(uid: '1782488734', cookie: 'SUB=abc'),
      );

      expect(thrown, isA<AppError>());
      final AppError e = thrown! as AppError;
      expect(e.kind, AppErrorKind.auth);
      expect(e.message, contains('登录'));
      expect(e.retryable, isFalse);
    });

    test('200 + 响应体里有 passport 登录跳转 → 同样判定为登录失效', () async {
      const String body = '{"ok":1,"data":{"url":'
          '"https://passport.weibo.com/sso/signin?entry=miniblog"}}';
      final (:client, adapter: _) = _client((_) => (200, body));

      final Object? thrown = await _capture(
        () => client.userTimeline(uid: '1782488734', cookie: 'SUB=abc'),
      );

      expect(thrown, isA<AppError>());
      expect((thrown! as AppError).kind, AppErrorKind.auth);
    });

    test('其它 4xx（如 404）→ 可读的通用错误，带状态码', () async {
      final (:client, adapter: _) = _client((_) => (404, 'not found'));

      final Object? thrown = await _capture(
        () => client.userTimeline(uid: '1782488734', cookie: 'SUB=abc'),
      );

      expect(thrown, isA<AppError>());
      final AppError e = thrown! as AppError;
      expect(e.message, contains('404'));
      expect(e.statusCode, 404);
    });

    test('5xx：validateStatus 放宽到 <500，500 会走 DioException 分支', () async {
      final (:client, adapter: _) = _client((_) => (503, ''));

      final Object? thrown = await _capture(
        () => client.userTimeline(uid: '1782488734', cookie: 'SUB=abc'),
      );

      expect(thrown, isA<AppError>());
      final AppError e = thrown! as AppError;
      expect(e.kind, AppErrorKind.server);
      expect(e.retryable, isTrue);
    });
  });

  group('非法 JSON', () {
    test('200 + 非法 JSON → 不崩，返回空 mblogs（本片钉住的契约）', () async {
      final (:client, adapter: _) = _client((_) => (200, '<html>风控页</html>'));

      final WeiboPage page = await client.userTimeline(
        uid: '1782488734',
        cookie: 'SUB=abc',
      );

      // 契约：**返回空结果而不是抛异常** —— 上游偶尔回 HTML 抗风控页，
      // 抛异常会让整条时间线红一片，空结果会落到既有「没有内容」文案。
      expect(page.httpStatus, 200);
      expect(page.mblogs, isEmpty);
      expect(page.sinceId, isNull);
      expect(page.total, 0);
    });
  });

  group('凭据安全', () {
    test('cookie 不出现在 AppError 的 message / detail 里', () async {
      const String cookie = 'SUB=_2A25LSECRETVALUE; SUBP=TOPSECRET';
      final (:client, adapter: _) = _client((_) => (432, ''));

      final Object? thrown = await _capture(
        () => client.userTimeline(uid: '1782488734', cookie: cookie),
      );

      final AppError e = thrown! as AppError;
      expect(e.message, isNot(contains('SECRET')));
      expect(e.detail ?? '', isNot(contains('SECRET')));
      expect(e.toString(), isNot(contains('SECRET')));
    });

    test('登录失效错误的文案也不含 cookie', () async {
      const String cookie = 'SUB=_2A25LSECRETVALUE';
      final (:client, adapter: _) = _client((_) => (200, '{"ok":-100}'));

      final Object? thrown = await _capture(
        () => client.userTimeline(uid: '1782488734', cookie: cookie),
      );

      expect((thrown! as AppError).toString(), isNot(contains('SECRET')));
    });
  });

  group('游标抽取（四级回退）', () {
    test('data.cardlistInfo.since_id 优先', () {
      expect(
        WeiboApiClient.extractSinceId(<String, dynamic>{
          'data': <String, dynamic>{
            'cardlistInfo': <String, dynamic>{'since_id': '111'},
            'since_id': '222',
          },
          'since_id': '444',
        }),
        '111',
      );
    });

    test('data.cardlistInfo 缺失时退 data.since_id', () {
      expect(
        WeiboApiClient.extractSinceId(<String, dynamic>{
          'data': <String, dynamic>{'since_id': '222'},
          'since_id': '444',
        }),
        '222',
      );
    });

    test('再退顶层 cardlistInfo.since_id，最后退顶层 since_id', () {
      expect(
        WeiboApiClient.extractSinceId(<String, dynamic>{
          'cardlistInfo': <String, dynamic>{'since_id': '333'},
          'since_id': '444',
        }),
        '333',
      );
      expect(
        WeiboApiClient.extractSinceId(<String, dynamic>{'since_id': '444'}),
        '444',
      );
    });

    test('全都取不到 → null；数字形态原样转字符串', () {
      expect(WeiboApiClient.extractSinceId(<String, dynamic>{}), isNull);
      expect(
        WeiboApiClient.extractSinceId(<String, dynamic>{
          'data': <String, dynamic>{
            'cardlistInfo': <String, dynamic>{'since_id': 12345},
          },
        }),
        '12345',
      );
    });

    test('total 缺失按 0', () {
      expect(WeiboApiClient.extractTotal(<String, dynamic>{}), 0);
      expect(
        WeiboApiClient.extractTotal(<String, dynamic>{
          'data': <String, dynamic>{'total': 7},
        }),
        7,
      );
    });
  });
}

/// 捕获同步/异步异常，避免每个用例都写一遍 try/catch。
Future<Object?> _capture(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } catch (e) {
    return e;
  }
}
