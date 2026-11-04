import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'retry_interceptor.dart';

/// 网络层工厂。
///
/// [createBiliDio]：请求 B 站 API，注入 Referer/Origin/UA（缺少 Referer
/// 时 playurl 常见 403）。
///
/// 曾经还有一个 [createRssDio]（响应类型 plain 以保留 XML 原文），用于拉
/// RSSHub。2026-10-22 RSSHub 链路整体移除后一并删除 —— 现在没有任何模块
/// 需要「按纯文本读响应」。
///
/// `validateStatus` 放宽到「< 500 都算正常响应」，目的是让 4xx
/// 走正常返回路径，由我们显式映射成带中文文案的 AppError，
/// 而不是让 dio 抛一个信息量很低的 BadResponse。
class DioFactory {
  DioFactory._();

  static Dio createBiliDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.bilibili.com',
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.receiveTimeout,
        sendTimeout: AppConfig.sendTimeout,
        responseType: ResponseType.json,
        followRedirects: true,
        headers: <String, String>{
          'User-Agent': AppConfig.browserUserAgent,
          'Referer': 'https://www.bilibili.com/',
          'Origin': 'https://www.bilibili.com',
          'Accept': 'application/json, text/plain, */*',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
        validateStatus: (int? status) => status != null && status < 500,
      ),
    );
    dio.interceptors.add(RetryInterceptor(dio: dio));
    return dio;
  }
}
