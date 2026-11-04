import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';

void main() {
  group('AppError.fromStatus', () {
    test('429 是限流，可重试（文案不再提「更换实例」）', () {
      final e = AppError.fromStatus(429);
      expect(e.kind, AppErrorKind.rateLimited);
      expect(e.message, '请求过于频繁，请稍后重试');
      expect(e.message, isNot(contains('实例')), reason: 'RSSHub 已移除，没有实例可换');
      expect(e.showRetry, isTrue);
    });

    test('403 文案按来源区分，且不再指引「更换实例」', () {
      expect(AppError.fromStatus(403).message, contains('403'));
      expect(
        AppError.fromStatus(403, weiboRoute: true).message,
        contains('微博'),
      );
      // 403 重试无意义，不给重试按钮。
      expect(AppError.fromStatus(403).showRetry, isFalse);
    });

    test('404 / 5xx / 其他 4xx', () {
      expect(AppError.fromStatus(404).kind, AppErrorKind.notFound);
      expect(AppError.fromStatus(404).showRetry, isFalse);
      expect(AppError.fromStatus(503).kind, AppErrorKind.server);
      expect(AppError.fromStatus(500).showRetry, isTrue);
      expect(AppError.fromStatus(418).kind, AppErrorKind.unknown);
    });

    test('412 有专属风控文案，且可重试', () {
      final e = AppError.fromStatus(412, detail: 'GET /x/v2/reply/wbi/main -> HTTP 412');
      expect(e.kind, AppErrorKind.auth);
      expect(e.statusCode, 412);
      expect(e.message, 'B 站风控拦截（HTTP 412），已自动重试');
      expect(e.retryable, isTrue);
      expect(e.showRetry, isTrue);
      // 不能落到泛化分支（旧行为），否则用户只看到「请求失败（HTTP 412）」。
      expect(e.message, isNot(contains('请求失败')));
    });

    test('null 状态码归为网络错误', () {
      expect(AppError.fromStatus(null).kind, AppErrorKind.network);
    });
  });

  group('AppError.fromDio', () {
    DioException make(DioExceptionType type, {int? status}) => DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: type,
          response: status == null
              ? null
              : Response<dynamic>(
                  requestOptions: RequestOptions(path: '/x'),
                  statusCode: status,
                ),
        );

    test('超时类', () {
      expect(
        AppError.fromDio(make(DioExceptionType.receiveTimeout)).kind,
        AppErrorKind.timeout,
      );
      expect(
        AppError.fromDio(make(DioExceptionType.connectionTimeout)).kind,
        AppErrorKind.timeout,
      );
      expect(
        AppError.fromDio(make(DioExceptionType.sendTimeout)).kind,
        AppErrorKind.timeout,
      );
    });

    test('连接错误与取消', () {
      expect(
        AppError.fromDio(make(DioExceptionType.connectionError)).kind,
        AppErrorKind.network,
      );
      expect(
        AppError.fromDio(make(DioExceptionType.cancel)).kind,
        AppErrorKind.cancelled,
      );
    });

    test('badResponse 按状态码映射', () {
      expect(
        AppError.fromDio(make(DioExceptionType.badResponse, status: 429)).kind,
        AppErrorKind.rateLimited,
      );
      expect(
        AppError.fromDio(make(DioExceptionType.badResponse, status: 500)).kind,
        AppErrorKind.server,
      );
      expect(
        AppError.fromDio(make(DioExceptionType.badResponse, status: 403),
                weiboRoute: true)
            .message,
        contains('微博'),
      );
    });

    test('detail 里带上了 URL 便于排查', () {
      final e = AppError.fromDio(make(DioExceptionType.connectionError));
      expect(e.detail, contains('/x'));
    });
  });

  group('语义约定', () {
    test('unsupported 不给重试按钮（微博评论之类）', () {
      final e = AppError.unsupported('微博评论未实现');
      expect(e.showRetry, isFalse);
      expect(e.kind, AppErrorKind.unsupported);
    });

    test('-352 风控码可重试（强刷 WBI 密钥后可能成功）', () {
      final e = AppError.bili(-352, 'B 站风控校验失败（-352）');
      expect(e.bizCode, -352);
      expect(e.retryable, isTrue);
    });

    test('toString 包含 detail', () {
      final e = AppError.network('GET https://x -> HTTP 0');
      expect(e.toString(), contains('GET https://x'));
    });
  });
}
