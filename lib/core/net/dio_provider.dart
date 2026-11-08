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

  /// **图片下载专用**的 Dio。
  ///
  /// ## 为什么不能复用 [createBiliDio]
  ///
  /// [createBiliDio] 的 BaseOptions 里写死了 B 站专属请求头：
  /// `Origin: https://www.bilibili.com`、`Accept: application/json`、
  /// `Referer: https://www.bilibili.com/`。
  /// 而图片缓存要同时下载 **B 站图床与微博图床** 的图片：
  ///
  /// - 微博图床（`*.sinaimg.cn`）收到 B 站 Referer **直接 403**
  ///   （2026-11-08 真机实测：`status=403 size=304`；换成 `weibo.com` 则 302 正常）；
  /// - `Accept: application/json` 对取图片没有意义，个别 CDN 还会按其做内容协商。
  ///
  /// 所以这里给一个**干净**的 Dio：不设 `baseUrl`（图片一律用绝对地址）、
  /// 不带 `Origin`/`Accept`、`validateStatus` 收回到「2xx/3xx 才算成功」，
  /// 让 4xx 直接抛 `DioException` —— 缓存层因此能在日志里看见失败原因，
  /// 而不是像之前那样被 `<500` 静默吞成一个 null。
  ///
  /// Referer 由调用方（`ImageCacheStore.refererFor`）**按域名**逐个设置。
  static Dio createImageDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.receiveTimeout,
        sendTimeout: AppConfig.sendTimeout,
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: <String, String>{
          'User-Agent': AppConfig.browserUserAgent,
        },
        validateStatus: (int? status) =>
            status != null && status >= 200 && status < 400,
      ),
    );
    dio.interceptors.add(RetryInterceptor(dio: dio));
    return dio;
  }
}
