import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import 'weibo_parser.dart';
import 'weibo_web_urls.dart';

/// 一页博主时间线的原始产物。
///
/// 刻意不在这里转 [ContentItem]：解析要拿 `Subscription`（sourceId）与
/// `fetchedAt`（时间线的一次拉取时间），那是数据源层（`WeiboTimelineSource`）
/// 的职责。客户端只负责「把服务端给的东西原样搬回来」。
class WeiboPage {
  const WeiboPage({
    required this.mblogs,
    required this.sinceId,
    required this.total,
    required this.httpStatus,
  });

  /// 原始 mblog 列表（已按 `card_type == 9` 过滤），交给 `WeiboParser` 解析。
  ///
  /// 元素类型是 `Object?` 而不是 `Map`：解析器自己要容错（上游偶尔塞进
  /// 非 Map 的元素），在这里提前强转会把「一条畸形」升级成「整页失败」。
  final List<Object?> mblogs;

  /// 下一页游标；null = 服务端没给。
  ///
  /// **全程按字符串保存**：这是 19 位大整数，过 `int` / `double` 都会丢精度，
  /// 症状是第二页请求拿错位置、内容与第一页重复。
  final String? sinceId;

  /// `cardlistInfo.total`：博主微博总数（取不到时按 0）。
  final int total;

  /// HTTP 状态码。
  final int httpStatus;

  /// 本页是否一条都没有。
  bool get isEmpty => mblogs.isEmpty;
}

/// 一页「我关注的人」混合动态流的原始产物（`GET /feed/friends`）。
///
/// 与 [WeiboPage] 分开而不是复用它：两者的 `data` 结构不同（这里是裸
/// `data.statuses[]`，那边是 `data.cards[].mblog`），复用同一个类会让「这个列表
/// 到底是哪一种」变成调用方要猜的事 —— 而猜错的代价正是第一轮探针踩到的假阴性。
class WeiboFriendsPage {
  const WeiboFriendsPage({
    required this.statuses,
    required this.sinceId,
    required this.httpStatus,
    this.maxId,
  });

  /// 原始 status 列表，**每条直接就是 mblog 形状**（没有 `mblog` 外壳）。
  ///
  /// 元素类型是 `Object?`：解析器自己容错，这里提前强转会把「一条畸形」
  /// 升级成「整页失败」。
  final List<Object?> statuses;

  /// 服务端给的 `since_id`。
  ///
  /// ⚠️ **不要用它翻页**（详见 [parseFriendsPage] 的说明）：微博语义里
  /// `since_id` = 「只要比这个 id **更新**的内容」。把它当作「下一页」传回去，
  /// 服务端会返回 0 条（真机实测：`{"statuses":[],"sinceId":null}`）。
  ///
  /// 保留这个字段只为「如实记录服务端返回了什么」，翻页用 [maxId]。
  final String? sinceId;

  /// 向**更早**翻页的游标（微博关注流的正确分页参数）。
  ///
  /// 取 `data.max_id`，缺失时回退到本页**最后一条 status 的 id** ——
  /// 后者是微博分页的通用约定（`max_id` 语义就是「返回 id 小于它的内容」）。
  ///
  /// 全程按字符串保存：微博游标是大整数，过 `int` 会丢精度。
  final String? maxId;

  final int httpStatus;

  bool get isEmpty => statuses.isEmpty;
}

/// `m.weibo.cn/api/container/getIndex` 的客户端。
///
/// ## 为什么能用了
///
/// 该接口在**游客态**恒返回 432（WAF）。实测带上 m 站真实登录 cookie 后
/// 返回 200 + 11 条，且 `since_id` 翻页可用 —— 本类就是把那次实测固化成
/// 正式代码（诊断阶段的写法见 `weibo_api_diag.dart`，**不要改它**）。
///
/// ## 凭据安全（硬约束）
///
/// cookie 只出现在**请求头**里一次：
/// - 不进任何 `Log`（连长度都不写）；
/// - 不进 [AppError.detail] / [AppError.message]；
/// - 不进 [WeiboPage]。
///
/// ## 请求节制
///
/// 这里**不挂重试拦截器**（裸 `Dio`）：微博对密集请求会冷却，重试交给
/// 用户手上的下拉刷新。缓存与 TTL 在数据源层做（见 `WeiboTimelineSource`）。
class WeiboApiClient {
  WeiboApiClient({Dio? dio}) : _dio = dio ?? createDio();

  final Dio _dio;

  /// 移动端 Chrome UA：桌面 UA 会被 `m.weibo.cn` 重定向。
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// 接口路径（不含 uid 相关参数）。
  static const String endpoint = '${WeiboWebUrls.mbBase}/api/container/getIndex';

  /// 默认 Dio：裸实例，**不挂重试拦截器**（见类注释的「请求节制」）。
  ///
  /// 公开出来是为了让调用方（provider / 测试）能复用同一套 BaseOptions，
  /// 而不是各自再抄一遍超时与 `validateStatus`。
  static Dio createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.receiveTimeout,
        sendTimeout: AppConfig.sendTimeout,
        responseType: ResponseType.plain,
        followRedirects: true,
        // 放宽到 <500：让 432 走正常返回路径，由本类显式判定；
        // 5xx 仍然抛 DioException，交给统一的错误映射。
        validateStatus: (int? status) => status != null && status < 500,
      ),
    );
  }

  /// 拉一页博主时间线。cookie 只放 header。
  ///
  /// [uid] 必须是纯数字（调用方 `WeiboTimelineSource` 已经校验过；这里再兜
  /// 一次是为了防止把任意字符串拼进 URL）。
  Future<WeiboPage> userTimeline({
    required String uid,
    required String cookie,
    String? sinceId,
  }) async {
    final String url = buildUrl(uid: uid, sinceId: sinceId);

    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        url,
        options: Options(headers: requestHeaders(uid: uid, cookie: cookie)),
      );
    } on DioException catch (e) {
      throw mapDioError(e);
    } catch (_) {
      // 任何非 Dio 的意外（例如适配器抛出的裸异常）：给可读的网络文案。
      throw AppError.network();
    }

    final int status = res.statusCode ?? 0;
    final String body = _bodyOf(res.data);

    if (status != 200) throw mapHttpStatus(status);

    return parsePage(status: status, body: body);
  }

  // ------------------------------------------------------------ 纯函数（可离线单测）

  /// 拉一页「我关注的人」的混合动态流（`GET /feed/friends`）。
  ///
  /// 与 [userTimeline] 的三点差异，全部来自真机探针结论：
  /// - 路径是 `/feed/friends`，**没有** `containerid`/`value` 这类参数；
  /// - 解析走 `data.statuses[]`（见 [parseFriendsPage]）；
  /// - 翻页游标用 `since_id`，**原样拼进 query**（不做数值转换）。
  ///
  /// cookie 同样只放请求头；未登录时服务端给 432 + 空 body，由 [mapHttpStatus]
  /// 转成可读文案（数据源层会先判空 cookie，根本不会发这个请求）。
  Future<WeiboFriendsPage> friendsFeed({
    required String cookie,
    String? maxId,
  }) async {
    final String url = buildFriendsUrl(maxId: maxId);

    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        url,
        options: Options(headers: friendsHeaders(cookie: cookie)),
      );
    } on DioException catch (e) {
      throw mapDioError(e);
    } catch (_) {
      throw AppError.network();
    }

    final int status = res.statusCode ?? 0;
    final String body = _bodyOf(res.data);

    if (status != 200) throw mapHttpStatus(status);

    return parseFriendsPage(status: status, body: body);
  }

  /// 拼「关注流」请求 URL。
  ///
  /// ## 为什么是 `max_id` 而不是 `since_id`（真机事故 2026-10-26）
  ///
  /// 微博的两个游标语义**相反**：
  /// - `since_id` = 「只要比这个 id **更新**的」→ 用于「看看有没有新微博」；
  /// - `max_id`   = 「只要比这个 id **更旧**的」→ 这才是**向下翻页**。
  ///
  /// 早先实现把服务端返回的 `since_id` 当作下一页游标传回去，于是第 2 页
  /// 起服务端恒返回 `{"statuses":[],"sinceId":null}`（0 条，HTTP 仍 200）。
  /// 真机表现：时间线翻页处「只剩 B 站内容」，用户以为列表断层了。
  ///
  /// 游标**原样拼接**：它是大整数，数值化会丢精度、编码可能改变形态。
  static String buildFriendsUrl({String? maxId}) {
    const String base = '${WeiboWebUrls.mbBase}/feed/friends';
    final String cursor = (maxId ?? '').trim();
    if (cursor.isEmpty) return base;
    return '$base?max_id=$cursor';
  }

  /// 「关注流」的请求头。
  ///
  /// 与 [requestHeaders] 同一套必需头（漏掉 `X-Requested-With` / `MWeibo-Pwa`
  /// 时服务端会按普通网页处理并返回 HTML，表现为「200 但解析不出内容」），
  /// 差异只有 Referer：这里是 m 站首页的关注 tab，不是某个博主页。
  static Map<String, String> friendsHeaders({required String cookie}) {
    final String trimmed = cookie.trim();
    return <String, String>{
      'User-Agent': userAgent,
      'Referer': '${WeiboWebUrls.mbBase}/',
      'X-Requested-With': 'XMLHttpRequest',
      'MWeibo-Pwa': '1',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (trimmed.isNotEmpty) 'Cookie': trimmed,
    };
  }

  /// 把一次 200 的关注流响应体整理成 [WeiboFriendsPage]。
  ///
  /// 判定顺序与 [parsePage] 一致：
  /// 1. `ok == -100` 或响应里出现 passport 登录跳转 → auth 错误；
  /// 2. 非法 JSON → **空结果而不是抛异常**（抗风控 HTML 不该让整页变红）；
  /// 3. 正常 → 抽 `data.statuses[]` 与游标。
  static WeiboFriendsPage parseFriendsPage({
    required int status,
    required String body,
  }) {
    final Map<String, dynamic>? json = _tryParseObject(body);

    if (_isLoginExpired(json, body)) {
      throw const AppError(
        AppErrorKind.auth,
        '微博登录已失效，请到「微博」页面重新登录',
        retryable: false,
      );
    }

    if (json == null) {
      return WeiboFriendsPage(
        statuses: const <Object?>[],
        sinceId: null,
        maxId: null,
        httpStatus: status,
      );
    }

    final List<Object?> statuses = WeiboParser.extractStatuses(json);
    return WeiboFriendsPage(
      statuses: statuses,
      sinceId: extractFriendsSinceId(json),
      // 翻页游标必须从**本页实际内容**里算，才能保证「下一批更旧」。
      maxId: extractFriendsMaxId(json, statuses: statuses),
      httpStatus: status,
    );
  }

  /// 关注流的**翻页**游标（向更早）。
  ///
  /// 优先 `data.max_id`；服务端没给时回退到**本页最后一条 status 的 id** ——
  /// `max_id` 的语义就是「返回 id 小于它的内容」，拿最后一条的 id 当下界是
  /// 微博分页的通用做法，也是这个接口唯一可靠的推进方式。
  ///
  /// ⚠️ **绝不回退到 `since_id`**：那是「更新的方向」，传回去必然 0 条。
  static String? extractFriendsMaxId(
    Map<String, dynamic> json, {
    List<Object?> statuses = const <Object?>[],
  }) {
    final Map<String, dynamic>? data = _asMap(json['data']);
    final List<String?> candidates = <String?>[
      _asCursor(data?['max_id']),
      _asCursor(json['max_id']),
      // 最后一条的 id 兜底：等价于「从这里往更早翻」。
      _lastStatusId(statuses),
    ];
    for (final String? candidate in candidates) {
      if (candidate != null && candidate.isNotEmpty) return candidate;
    }
    return null;
  }

  /// 一页 statuses 里最后一条的 id（用作 `max_id` 兜底）。
  ///
  /// 服务端给的 statuses 是「新 → 旧」倒序，所以最后一条就是本页最旧的那条。
  static String? _lastStatusId(List<Object?> statuses) {
    for (int i = statuses.length - 1; i >= 0; i--) {
      final Object? s = statuses[i];
      if (s is Map) {
        final String? id = _asCursor(s['id']) ?? _asCursor(s['mid']);
        if (id != null && id.isNotEmpty) return id;
      }
    }
    return null;
  }

  /// 关注流的 `since_id`（仅作记录，**不用于翻页**）。
  ///
  /// 保留是为了如实反映服务端返回；翻页一律用 [extractFriendsMaxId]。
  static String? extractFriendsSinceId(Map<String, dynamic> json) {
    final Map<String, dynamic>? data = _asMap(json['data']);
    return _asCursor(data?['since_id']) ?? _asCursor(json['since_id']);
  }

  /// 拼请求 URL。
  ///
  /// 注意 `since_id` **原样拼接**，不做任何数值/编码转换：它是 19 位游标，
  /// 换成数值会丢精度；编码则可能改变服务端要的形态。
  static String buildUrl({required String uid, String? sinceId}) {
    final String base =
        '$endpoint?type=uid&value=$uid&containerid=107603$uid';
    final String cursor = (sinceId ?? '').trim();
    if (cursor.isEmpty) return base;
    return '$base&since_id=$cursor';
  }

  /// 请求头（与 `weibo_api_diag.dart` 的写法保持一致）。
  ///
  /// 漏掉 `X-Requested-With` 或 `MWeibo-Pwa` 时，服务端会按普通网页处理并
  /// 返回 HTML，表现为「状态码 200 但解析不出任何内容」。
  static Map<String, String> requestHeaders({
    required String uid,
    required String cookie,
  }) {
    final String trimmed = cookie.trim();
    return <String, String>{
      'User-Agent': userAgent,
      'Referer': '${WeiboWebUrls.mbBase}/u/$uid',
      'X-Requested-With': 'XMLHttpRequest',
      'MWeibo-Pwa': '1',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (trimmed.isNotEmpty) 'Cookie': trimmed,
    };
  }

  /// HTTP 状态码 → [AppError]。
  ///
  /// 432 是微博 WAF 的专属状态码，必须单独给文案（用户看不懂「432」，
  /// 但「被风控拦截，请稍后重试」他能理解并照做）。
  static AppError mapHttpStatus(int status) {
    if (status == 432) {
      return const AppError(
        AppErrorKind.forbidden,
        '微博接口被风控拦截（HTTP 432），请稍后重试',
        detail: 'HTTP 432',
        statusCode: 432,
        retryable: true,
      );
    }
    if (status == 401 || status == 403) {
      return AppError(
        AppErrorKind.auth,
        '微博接口拒绝访问（HTTP $status），请到「微博」页面重新登录',
        detail: 'HTTP $status',
        statusCode: status,
        retryable: false,
      );
    }
    if (status >= 500) return AppError.server(status, 'HTTP $status');
    if (status >= 400) {
      return AppError(
        AppErrorKind.unknown,
        '微博接口请求失败（HTTP $status）',
        detail: 'HTTP $status',
        statusCode: status,
        // 429 属于「等一会儿可能就好」，其它 4xx 重试也没用。
        retryable: status == 429,
      );
    }
    return AppError(
      AppErrorKind.unknown,
      '微博接口请求失败（HTTP $status）',
      detail: 'HTTP $status',
      statusCode: status,
      retryable: true,
    );
  }

  /// [DioException] → [AppError]。
  ///
  /// **绝不**使用 `AppError.fromDio`：它会把 `requestOptions` 拼进 detail，
  /// 而将来一旦有人在 requestOptions 里塞 header 摘要，cookie 就会顺着
  /// 「数据源状态」页露出来。这里只按类型给最粗的结论。
  static AppError mapDioError(DioException e) {
    final int? status = e.response?.statusCode;
    if (status != null) return mapHttpStatus(status);
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return AppError.timeout();
      case DioExceptionType.cancel:
        return AppError.cancelled();
      case DioExceptionType.badCertificate:
        return AppError.network('TLS 证书校验失败');
      case DioExceptionType.connectionError:
        return AppError.network();
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return AppError.network();
    }
  }

  /// 把一次 200 响应体整理成 [WeiboPage]。
  ///
  /// 三条判定按优先级：
  /// 1. `ok == -100` 或响应里出现 `passport.weibo.com/sso/signin` → 登录失效；
  /// 2. 非法 JSON → **返回空 mblogs 而不是抛异常**（上游偶尔给 HTML 抗风控页；
  ///    抛异常会让整条时间线红一片，而空结果会落到「该源没有内容」的既有文案；
  ///    这一条已由单测钉住）；
  /// 3. 正常 → 抽 mblogs / since_id / total。
  static WeiboPage parsePage({required int status, required String body}) {
    final Map<String, dynamic>? json = _tryParseObject(body);

    if (_isLoginExpired(json, body)) {
      throw const AppError(
        AppErrorKind.auth,
        '微博登录已失效，请到「微博」页面重新登录',
        retryable: false,
      );
    }

    if (json == null) {
      // 见方法注释第 2 条：非法 JSON 不抛。
      return WeiboPage(
        mblogs: const <Object?>[],
        sinceId: null,
        total: 0,
        httpStatus: status,
      );
    }

    return WeiboPage(
      mblogs: WeiboParser.extractMblogs(json),
      sinceId: extractSinceId(json),
      total: extractTotal(json),
      httpStatus: status,
    );
  }

  /// 从已解码的 JSON 里取分页游标。
  ///
  /// 四级回退（与 `weibo_api_diag.dart` 的 `extractSinceId` 判定顺序一致）：
  /// `data.cardlistInfo.since_id` → `data.since_id` →
  /// `cardlistInfo.since_id` → 顶层 `since_id`。
  ///
  /// 刻意**没有**直接调用诊断文件里的那一个：诊断工具不该成为生产链路的依赖
  /// （它随时可能被裁掉），而这段逻辑只有四行。两份的对外行为必须保持一致，
  /// 改一边时记得对照另一边。
  static String? extractSinceId(Map<String, dynamic> json) {
    final Map<String, dynamic>? data = _asMap(json['data']);
    final Map<String, dynamic>? cardlistInfo =
        _asMap(data?['cardlistInfo']) ?? _asMap(json['cardlistInfo']);

    final List<String?> candidates = <String?>[
      _asCursor(cardlistInfo?['since_id']),
      _asCursor(data?['since_id']),
      _asCursor(_asMap(json['cardlistInfo'])?['since_id']),
      _asCursor(json['since_id']),
    ];
    for (final String? candidate in candidates) {
      if (candidate != null && candidate.isNotEmpty) return candidate;
    }
    return null;
  }

  /// 取 `cardlistInfo.total`（缺失时回退 `data.total`，再缺失按 0）。
  static int extractTotal(Map<String, dynamic> json) {
    final Map<String, dynamic>? data = _asMap(json['data']);
    final Map<String, dynamic>? cardlistInfo =
        _asMap(data?['cardlistInfo']) ?? _asMap(json['cardlistInfo']);
    final Object? raw = cardlistInfo?['total'] ?? data?['total'];
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  // ------------------------------------------------------------ 内部

  /// 登录失效判定：`ok == -100`，或响应体里出现 passport 的登录跳转地址。
  ///
  /// 后者是服务端在 cookie 半失效（SSO 票据过期但域 cookie 还在）时的形态：
  /// HTTP 200、`ok` 可能仍是 1，但 data 里全是登录跳转。
  static bool _isLoginExpired(Map<String, dynamic>? json, String body) {
    final Object? okValue = json?['ok'];
    final int? okFlag = okValue is num
        ? okValue.toInt()
        : (okValue is String ? int.tryParse(okValue.trim()) : null);
    if (okFlag == -100) return true;
    return body.contains('passport.weibo.com/sso/signin');
  }

  /// 游标只做字符串化，**绝不**走数值转换（见 [WeiboPage.sinceId] 的注释）。
  ///
  /// ⚠️ **拒绝非正数**：微博在「到底了」时会返回 `max_id: 0`。若把它当合法
  /// 游标传回去，服务端会当作「不限制」并重新返回**最新一批**——游标链就此
  /// 回绕，同一批微博被反复拉取、反复插进时间线（真机缺陷 2026-10-26：
  /// 「只剩微博、数量越来越多、闪回后 B 站更少」）。
  /// 所以 `0` / 负数一律视为「没有下一页」。
  static String? _asCursor(Object? value) {
    if (value == null) return null;
    if (value is String) {
      final String s = value.trim();
      if (s.isEmpty) return null;
      if (_isZeroOrNegative(s)) return null;
      return s;
    }
    if (value is num) {
      if (value <= 0) return null;
      // 游标是大整数，num→String 可能带 `.0`，先按整型处理。
      if (value is int) return value.toString();
      if (value == value.roundToDouble()) return value.toInt().toString();
      return value.toString();
    }
    return null;
  }

  /// 游标字符串是否代表「0 或负数」（即到底了）。
  static bool _isZeroOrNegative(String s) {
    final String t = s.startsWith('-') ? s.substring(1) : s;
    if (t.isEmpty) return false;
    // 全是 0（`0` / `00` / `0000`）才算 0；`0` 开头但后面有非零位的不算。
    if (s.startsWith('-')) return true;
    for (int i = 0; i < t.length; i++) {
      if (t[i] != '0') return false;
    }
    return true;
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is! Map) return null;
    return value.cast<String, dynamic>();
  }

  static Map<String, dynamic>? _tryParseObject(String body) {
    if (body.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 响应体统一转成字符串。`ResponseType.plain` 下通常已经是 String，
  /// 但注入的假 Dio / 拦截器可能换成别的类型，这里不做假设。
  static String _bodyOf(Object? data) {
    if (data == null) return '';
    if (data is String) return data;
    return data.toString();
  }
}
