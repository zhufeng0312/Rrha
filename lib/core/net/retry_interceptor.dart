import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../utils/logger.dart';

/// 指数退避重试拦截器。
///
/// 只对「幂等 GET + 可恢复错误」重试，绝不重试 4xx：
/// - 429 是公共实例在明确拒绝我们，立刻重试只会加重限流（由 UI 提示换实例）；
/// - 403 重试无意义。
///
/// 重试次数通过 `RequestOptions.extra['__retryCount']` 记录，
/// 因此 `dio.fetch` 递归经过本拦截器时不会无限循环。
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this.dio,
    this.maxRetries = AppConfig.maxRetries,
    this.baseDelay = AppConfig.retryBaseDelay,
  });

  final Dio dio;
  final int maxRetries;
  final Duration baseDelay;

  static const String _countKey = '__retryCount';

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final count = (options.extra[_countKey] as int?) ?? 0;

    if (!_shouldRetry(err, options) || count >= maxRetries) {
      handler.next(err);
      return;
    }

    options.extra[_countKey] = count + 1;
    final delay = baseDelay * (count + 1);
    Log.w(
      'Retry',
      '${options.method} ${options.uri} 失败(${err.type.name})，'
      '${delay.inMilliseconds}ms 后重试 ${count + 1}/$maxRetries',
    );
    await Future<void>.delayed(delay);

    try {
      final response = await dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    } catch (e, st) {
      Log.e('Retry', '重试过程中出现非 Dio 异常', e, st);
      handler.next(err);
    }
  }

  bool _shouldRetry(DioException err, RequestOptions options) {
    if (options.method.toUpperCase() != 'GET') return false;

    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badResponse:
        final s = err.response?.statusCode ?? 0;
        return s >= 500; // 5xx 可重试；4xx 一律不重试
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return false;
    }
  }
}
