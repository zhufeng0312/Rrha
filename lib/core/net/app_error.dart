import 'package:dio/dio.dart';

/// 错误分类。UI 依据它决定图标、文案与是否给重试按钮。
enum AppErrorKind {
  /// 连接失败 / DNS / TLS。
  network,

  /// 超时。
  timeout,

  /// 429：公共实例限流。
  rateLimited,

  /// 403：实例拒绝访问。
  forbidden,

  /// 404。
  notFound,

  /// 5xx。
  server,

  /// HTTP 200 但没有可用数据。
  empty,

  /// 解析失败。
  parse,

  /// 需要登录 / 风控校验失败（B 站 -352、-10403）。
  auth,

  /// 功能在本轮明确不支持（微博评论等）。
  unsupported,

  /// 请求被取消。
  cancelled,

  unknown,
}

/// 统一错误模型：所有网络/解析失败都必须转成它，禁止把原始异常抛到 UI。
class AppError implements Exception {
  const AppError(
    this.kind,
    this.message, {
    this.detail,
    this.statusCode,
    this.bizCode,
    this.retryable = false,
  });

  final AppErrorKind kind;

  /// 面向用户的中文文案。
  final String message;

  /// 面向排查的诊断信息（可折叠展示在「数据源状态」页）。
  final String? detail;

  final int? statusCode;

  /// 平台业务码（B 站 code 字段）。
  final int? bizCode;

  final bool retryable;

  // ------------------------------------------------------------ 命名构造

  factory AppError.network([String? detail]) => AppError(
        AppErrorKind.network,
        '网络不可用，请检查网络连接',
        detail: detail,
        retryable: true,
      );

  factory AppError.timeout([String? detail]) => AppError(
        AppErrorKind.timeout,
        '请求超时，请稍后重试',
        detail: detail,
        retryable: true,
      );

  /// 限流（429）。
  ///
  /// 【2026-10-22 改文案】原文案是「公共 RSSHub 实例限流，请稍后重试或更换实例」。
  /// RSSHub 已整条移除，**没有实例可换**了 —— 再让用户去「更换实例」等于给一个
  /// 做不到的指引。现在这话术用于「请求太频繁」，只引导「稍后重试」。
  factory AppError.rateLimited([String? detail]) => AppError(
        AppErrorKind.rateLimited,
        '请求过于频繁，请稍后重试',
        detail: detail,
        statusCode: 429,
        retryable: true,
      );

  /// 403。
  ///
  /// 同样改过文案：原来分「该实例未配置微博 Cookie」/「请在设置中更换实例」两路，
  /// 都建立在「存在可更换的 RSSHub 实例」这个前提上。现在只剩官方接口，
  /// 403 的真实含义是「平台拒绝了这次请求」（风控/登录态失效）。
  factory AppError.forbidden({String? detail, bool weiboRoute = false}) => AppError(
        AppErrorKind.forbidden,
        weiboRoute
            ? '微博拒绝了这次请求，请确认已登录微博后重试'
            : '平台拒绝了这次请求（403），请稍后重试',
        detail: detail,
        statusCode: 403,
        retryable: false,
      );

  factory AppError.notFound([String? detail]) => AppError(
        AppErrorKind.notFound,
        '资源不存在（404），请检查 UID 是否正确',
        detail: detail,
        statusCode: 404,
        retryable: false,
      );

  factory AppError.server([int? status, String? detail]) => AppError(
        AppErrorKind.server,
        '服务器错误（${status ?? 5}xx），请稍后重试',
        detail: detail,
        statusCode: status,
        retryable: true,
      );

  factory AppError.empty({String? detail, String? message}) => AppError(
        AppErrorKind.empty,
        message ?? '该源暂时没有返回内容',
        detail: detail,
        retryable: true,
      );

  factory AppError.parse([String? detail]) => AppError(
        AppErrorKind.parse,
        '内容解析失败',
        detail: detail,
        retryable: true,
      );

  factory AppError.cancelled() => const AppError(
        AppErrorKind.cancelled,
        '请求已取消',
      );

  factory AppError.unsupported(String message, {String? detail}) => AppError(
        AppErrorKind.unsupported,
        message,
        detail: detail,
      );

  factory AppError.bili(int? code, String message, {String? detail}) => AppError(
        AppErrorKind.auth,
        message,
        bizCode: code,
        detail: detail,
        retryable: code == -352 || code == -412,
      );

  // ------------------------------------------------------------ 映射

  /// 把 DioException 映射成 AppError。
  ///
  /// [weiboRoute] 为 true 时 403 使用微博专属文案（实例未配置 Cookie）。
  factory AppError.fromDio(DioException e, {bool weiboRoute = false}) {
    final status = e.response?.statusCode;
    final detail = '${e.requestOptions.method} ${e.requestOptions.uri}'
        '${status != null ? ' -> HTTP $status' : ''}'
        '${e.message != null ? ' (${e.message})' : ''}';

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return AppError.timeout(detail);
      case DioExceptionType.cancel:
        return AppError.cancelled();
      case DioExceptionType.badCertificate:
        return AppError.network('TLS 证书校验失败：$detail');
      case DioExceptionType.connectionError:
        return AppError.network(detail);
      case DioExceptionType.badResponse:
        return AppError.fromStatus(status, detail: detail, weiboRoute: weiboRoute);
      case DioExceptionType.unknown:
        // dio 在底层 socket 异常时也会落到这里。
        return AppError.network(detail);
    }
  }

  /// 把 HTTP 状态码映射成 AppError。
  ///
  /// 由于 Dio 的 `validateStatus` 被放宽到「< 500 都算正常响应」，
  /// 4xx 不会变成 DioException，需要由调用方显式调用本方法。
  factory AppError.fromStatus(
    int? status, {
    String? detail,
    bool weiboRoute = false,
  }) {
    if (status == null) return AppError.network(detail);
    if (status == 401) {
      return AppError(AppErrorKind.auth, '需要登录凭证', detail: detail, statusCode: 401);
    }
    if (status == 403) return AppError.forbidden(detail: detail, weiboRoute: weiboRoute);
    if (status == 412) {
      // B 站风控（HTTP 412，网关直接拦下、连 JSON 都没有）与业务码 -352/-412
      // 是同一类问题：换个签名往往就能过。文案要说明「已经重试过」，
      // 否则用户会以为 App 什么都没做，只能干等。
      return AppError(
        AppErrorKind.auth,
        'B 站风控拦截（HTTP 412），已自动重试',
        detail: detail,
        statusCode: 412,
        retryable: true,
      );
    }
    if (status == 404) return AppError.notFound(detail);
    if (status == 429) return AppError.rateLimited(detail);
    if (status == 503 || status == 502 || status == 504) return AppError.server(status, detail);
    if (status >= 500) return AppError.server(status, detail);
    if (status >= 400) {
      return AppError(
        AppErrorKind.unknown,
        '请求失败（HTTP $status）',
        detail: detail,
        statusCode: status,
      );
    }
    return AppError(
      AppErrorKind.unknown,
      '请求失败',
      detail: detail,
      statusCode: status,
    );
  }

  /// 是否应当向用户展示重试按钮。
  bool get showRetry => retryable && kind != AppErrorKind.unsupported;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}
