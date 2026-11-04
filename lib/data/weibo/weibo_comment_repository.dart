import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../core/net/weibo_cookie_source.dart';
import '../models/comment.dart';
import '../repo/comment_repo.dart';
import 'weibo_comment_parser.dart';
import 'weibo_web_urls.dart';

/// 微博评论仓库（`m.weibo.cn/comments/hotflow`）。
///
/// ## 接口形态（实测）
///
/// ```
/// https://m.weibo.cn/comments/hotflow?id=<mid>&mid=<mid>&max_id_type=0
/// 第 2 页起追加 &max_id=<游标>（原样拼接）
/// ```
///
/// ## 反直觉但必须遵守的两条
///
/// 1. **hotflow 不要求登录**：cookie 为空时同样是 `200 + ok:1 + 20 条`。
///    所以这里**绝不**用「432 = 未登录」那套时间线经验来判定评论；
///    拿不到数据先怀疑解析 / 参数。cookie 为空也照发（只是不带 Cookie 头）。
/// 2. **请求不挂重试拦截器**（裸 [Dio]，与 `WeiboApiClient` 一致）：
///    微博对密集请求会冷却，重试交给用户手上的「加载更多」按钮。
///
/// ## 凭据安全（硬约束）
///
/// cookie 只出现在请求头里一次：不进日志、不进 [AppError] 文案、不落盘。
class WeiboCommentRepository implements CommentRepositoryLike {
  WeiboCommentRepository({Dio? dio, WeiboCookieSource? cookies})
      : _dio = dio ?? createDio(),
        _cookies = cookies ?? WeiboCookieSource();

  final Dio _dio;
  final WeiboCookieSource _cookies;

  /// 接口路径（参数另行拼接）。
  static const String endpoint = '${WeiboWebUrls.mbBase}/comments/hotflow';

  /// **子评论**（二级回复）接口路径。
  ///
  /// 一级接口内嵌的 `comments[]` 恒为前 2 条，完整回复只能走这个接口
  /// （实测见 `.env/weibo_subcomment_probe.md`）。
  static const String childEndpoint =
      '${WeiboWebUrls.mbBase}/comments/hotflowChild';

  /// 单次展开最多拉几页（防止「声称 68 条」把请求打爆）。
  static const int maxChildPages = 3;

  /// 移动端 Chrome UA：桌面 UA 会被 `m.weibo.cn` 重定向。
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// 裸 Dio：**不挂重试拦截器**（见类注释）。
  ///
  /// `validateStatus` 放宽到 `<500`，让 432 走正常返回路径由本类显式映射成
  /// 可读文案，而不是变成一个笼统的 DioException。
  static Dio createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.receiveTimeout,
        sendTimeout: AppConfig.sendTimeout,
        responseType: ResponseType.plain,
        followRedirects: true,
        validateStatus: (int? status) => status != null && status < 500,
      ),
    );
  }

  // ------------------------------------------------------------ 接口实现

  @override
  Future<CommentPage> loadFirst({required CommentRequest req}) =>
      _fetch(req: req, cursor: null);

  @override
  Future<CommentPage> loadMore({
    required CommentRequest req,
    required String cursor,
  }) =>
      _fetch(req: req, cursor: cursor);

  /// 微博的楼中楼**内嵌**在首页响应里（解析阶段已经填进 `replies`），
  /// 没有第二个接口。这里返回空页是**正确行为**，不是未实现：
  /// Controller 对已加载（`repliesLoaded == true`）的楼层只会做「收起」，
  /// 不会走到这里。
  ///
  /// ⚠️ 真正拉完整二级回复走 [loadChildReplies]（另一个接口、另一套结构）。
  @override
  Future<SubCommentPage> loadReplies({
    required CommentRequest req,
    required String rootId,
    int page = 1,
  }) async =>
      const SubCommentPage();

  /// 拉**一页**子评论（二级回复）。返回本页结果 + 下一页游标（null = 到底）。
  ///
  /// ## 两个必须守住的结构性事实（实测，见 `.env/weibo_subcomment_probe.md`）
  ///
  /// 1. **列表路径是 `data`（直接是 List）**，不是一级接口的 `data.data`；
  /// 2. **响应里没有任何游标字段** —— 续拉游标由**调用方**把一级节点的
  ///    `max_id`（即 [BiliComment.replyCursor]）传进来。
  ///
  /// ## 终止条件（以探针报告为准，不自行发明）
  ///
  /// - 本页 **0 条** → 到底（`nextCursor == null`）；
  /// - 本页有内容 → 把**同一个游标**再交回去（接口没有给出新游标，
  ///   下一次用同样的 `max_id` 参数就是「继续往下」的语义，
  ///   实测第 1 页 10 条 → 第 2 页 2 条且**零重复**）。
  ///
  /// `nextCursor` 返回的是「下一次请求该带的游标」，不含「还能不能再要」
  /// 的判断 —— 那个上限（[maxChildPages]）在 controller 里。
  ///
  /// 失败抛中文 [AppError]，**不重试**（重试交给用户手上的再次点击）。
  /// cookie 不传 [CommentRequest]：只有 `cid` 与游标是必要的，
  /// Referer 用不到 mid（子评论接口不校验它）。
  Future<({List<BiliComment> items, String? nextCursor})> loadChildReplies({
    required String cid,
    String? maxId,
    String? mid,
  }) async {
    final String id = cid.trim();
    if (id.isEmpty) {
      return (items: const <BiliComment>[], nextCursor: null);
    }

    final String cookie = await _cookies.read();
    final String url = buildChildUrl(cid: id, maxId: maxId);

    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        url,
        options: Options(headers: childHeaders(cookie: cookie, mid: mid)),
      );
    } on DioException catch (e) {
      throw mapDioError(e);
    } catch (_) {
      throw AppError.network();
    }

    final int status = res.statusCode ?? 0;
    if (status != 200) throw mapHttpStatus(status);

    final Object? decoded = _decode(res.data);
    if (decoded == null) {
      // HTML 与「非法 JSON」分开报：前者说明**请求头不对**（多半缺 Referer，
      // 服务端把它当普通网页处理），后者才是响应体本身坏了。
      //
      // detail 里带**响应体前 200 字符**（不是 cookie，也不是请求头）：
      // 真机 diagnose 时没有别的观测手段 —— profile 包看不到 print，
      // 而「返回了什么」正是判断根因的唯一线索。
      final String preview = _preview(res.data, 200);
      throw AppError.parse(
        looksLikeHtml(res.data)
            ? '微博子评论返回网页而非数据（请求头被当普通浏览器访问）· $preview'
            : '微博子评论返回的不是合法 JSON · $preview',
      );
    }
    final List<BiliComment>? items =
        WeiboCommentParser.parseChildPage(decoded);
    if (items == null) {
      // ── 业务错误码要单独认，不能一律当「结构异常」──────────────
      //
      // 真机实测：`hotflowChild` 在「这条评论没有可见的更多回复」时返回
      // `{"ok":1,"errno":100011,"msg":"暂无数据","data":null}`，
      // 这是**正常的「没有更多」**，不是错误。当错误抛会让用户看到红字，
      // 而实际上「展开后维持内嵌的 2 条」就是正确表现。
      //
      // 其余 errno（参数不合法等）才按真正的失败处理。
      final Map<String, dynamic> root =
          (decoded is Map) ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
      final int? errno = _asIntLoose(root['errno']);
      if (errno == _errnoNoMoreData) {
        // 暂无更多回复：与「本页 0 条」等价 —— 到底，且不报错。
        return (items: const <BiliComment>[], nextCursor: null);
      }
      // 结构异常时同样带上实际形态：「data 是 List 还是 Map」一眼就能分辨。
      throw AppError.parse(
        '微博子评论响应结构异常 · ${_shapeOf(decoded)}',
      );
    }

    // 到底：本页 0 条。否则把游标原样交回去续拉（接口不给新游标）。
    final String cursor = (maxId ?? '').trim();
    final String? next = items.isEmpty ? null : (cursor.isEmpty ? null : cursor);
    return (items: items, nextCursor: next);
  }

  // ------------------------------------------------------------ 请求

  Future<CommentPage> _fetch({
    required CommentRequest req,
    required String? cursor,
  }) async {
    final String mid = req.oid.trim();
    if (mid.isEmpty) {
      return const CommentPage(isEnd: true);
    }

    final String cookie = await _cookies.read();
    final String url = buildUrl(mid: mid, cursor: cursor);

    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        url,
        options: Options(headers: headers(mid: mid, cookie: cookie)),
      );
    } on DioException catch (e) {
      throw mapDioError(e);
    } catch (_) {
      // 适配器抛出的裸异常：给可读的网络文案，不把栈信息抛到 UI。
      throw AppError.network();
    }

    final int status = res.statusCode ?? 0;
    if (status != 200) throw mapHttpStatus(status);

    final Object? decoded = _decode(res.data);
    if (decoded == null) {
      throw AppError.parse('微博评论返回的不是合法 JSON');
    }
    return WeiboCommentParser.parsePage(decoded);
  }

  // ------------------------------------------------------------ 纯函数（可离线单测）

  /// 拼请求 URL。`max_id` **原样拼接**，不做数值/编码加工。
  static String buildUrl({required String mid, String? cursor}) {
    final StringBuffer buf = StringBuffer(endpoint);
    buf.write('?id=$mid&mid=$mid&max_id_type=0');
    final String c = (cursor ?? '').trim();
    if (c.isNotEmpty) buf.write('&max_id=$c');
    return buf.toString();
  }

  /// 子评论 URL：`?cid=<一级评论 id>&max_id_type=0`（无 `id` / `mid`）。
  ///
  /// 续拉时追加 `&max_id=<原样>`。`cid` 是一级评论的 **id**（不是 mid）。
  static String buildChildUrl({required String cid, String? maxId}) {
    final StringBuffer buf = StringBuffer(childEndpoint);
    buf.write('?cid=$cid&max_id_type=0');
    final String c = (maxId ?? '').trim();
    if (c.isNotEmpty) buf.write('&max_id=$c');
    return buf.toString();
  }

  /// 请求头。
  ///
  /// `Referer` 指向这条微博本身；`X-Requested-With` / `MWeibo-Pwa` 缺失时
  /// 服务端会按普通网页处理（返回 HTML，表现为「200 但解析不出东西」）。
  ///
  /// cookie 为空时**不设置** Cookie 头 —— 但请求照发：hotflow 不要求登录，
  /// 未登录同样能拿到首页评论（见 `.env/weibo_comment_probe.md` 第五节）。
  static Map<String, String> headers({
    required String mid,
    required String cookie,
  }) {
    final String trimmed = cookie.trim();
    return <String, String>{
      'User-Agent': userAgent,
      'Referer': '${WeiboWebUrls.mbBase}/status/$mid',
      'X-Requested-With': 'XMLHttpRequest',
      'MWeibo-Pwa': '1',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (trimmed.isNotEmpty) 'Cookie': trimmed,
    };
  }

  /// 子评论接口的请求头。
  ///
  /// ## 两个都必需（真机各踩过一次）
  ///
  /// 1. **`Referer` 指向微博详情页**。缺了它服务端按普通网页处理。
  /// 2. **`X-Requested-With` + `MWeibo-Pwa`**。这两枚是微博 Web 端发 AJAX 时
  ///    必带的标记；缺了它们，即使 Referer 正确，服务端**仍然返回整页 HTML**
  ///    （真机实测：`<!DOCTYPE html>…h5.sinaimg.cn…`），JSON 解析必然失败。
  ///
  /// 这两条合起来才是「让接口认为自己在被浏览器 XHR 调用」。早先只在
  /// `headers()`（一级评论）里带齐，`childHeaders` 漏了 AJAX 标记，于是
  /// 打开「共 N 条回复」只会看到「内容解析失败」。
  ///
  /// [mid] 是**所属微博**的 id（不是一级评论 `cid`），用于拼 Referer；
  /// 拿不到时退化成站点根地址。
  ///
  /// cookie 同样只在请求头里出现一次：不进日志 / 文案 / 异常 detail。
  static Map<String, String> childHeaders({
    required String cookie,
    String? mid,
  }) {
    final String trimmed = cookie.trim();
    final String m = (mid ?? '').trim();
    final String referer =
        m.isEmpty ? '${WeiboWebUrls.mbBase}/' : '${WeiboWebUrls.mbBase}/status/$m';
    return <String, String>{
      'User-Agent': userAgent,
      'Referer': referer,
      // ↓ 这两枚缺一不可：没有它们，服务端会把请求当普通网页访问并回 HTML。
      'X-Requested-With': 'XMLHttpRequest',
      'MWeibo-Pwa': '1',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (trimmed.isNotEmpty) 'Cookie': trimmed,
    };
  }

  /// HTTP 状态码 → [AppError]（中文文案）。
  /// 432 是微博 WAF 的专属状态码，单独给文案；但**不要**把它解释成
  /// 「未登录」—— 评论接口不需要登录，432 只代表风控冷却。
  static AppError mapHttpStatus(int status) {
    if (status == 432) {
      return const AppError(
        AppErrorKind.forbidden,
        '微博评论接口被风控拦截（HTTP 432），请稍后重试',
        detail: 'HTTP 432',
        statusCode: 432,
        retryable: true,
      );
    }
    if (status == 401 || status == 403) {
      return AppError(
        AppErrorKind.auth,
        '微博评论接口拒绝访问（HTTP $status），请稍后重试',
        detail: 'HTTP $status',
        statusCode: status,
        retryable: false,
      );
    }
    if (status == 404) {
      return AppError(
        AppErrorKind.notFound,
        '这条微博不存在或已被删除（HTTP 404）',
        detail: 'HTTP 404',
        statusCode: 404,
      );
    }
    if (status >= 500) return AppError.server(status, 'HTTP $status');
    return AppError(
      AppErrorKind.unknown,
      '微博评论请求失败（HTTP $status）',
      detail: 'HTTP $status',
      statusCode: status,
      retryable: status == 429,
    );
  }

  /// [DioException] → [AppError]。
  ///
  /// **绝不**用 `AppError.fromDio`：它会把 `requestOptions` 拼进 detail，
  /// 而请求头里有 cookie。这里只按类型 / 状态码给最粗的结论。
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
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return AppError.network();
    }
  }

  /// 响应体 → JSON 对象；失败返回 null（调用方转成「解析失败」）。
  ///
  /// `responseType: plain` 下通常已经是 String，但注入的假 Dio / 拦截器
  /// 可能换成别的类型，这里不做假设。
  static Object? _decode(Object? data) {
    if (data == null) return null;
    if (data is Map) return data;
    if (data is List) return null;
    final String text = data is String ? data : data.toString();
    if (text.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(text);
      return decoded is Map ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 微博「暂无数据」的业务码：表示这条评论**没有更多可见回复**。
  ///
  /// 真机实测（`.env` 探针与真机诊断都验证过）：
  /// `{"ok":1,"errno":100011,"msg":"暂无数据","data":null}`。
  /// 这是正常终止信号，**不是**失败 —— 当成错误会把红字甩给用户，
  /// 而正确表现是「展开后维持内嵌的 2 条」。
  static const int _errnoNoMoreData = 100011;

  /// 容错取 int：服务端有时给数字、有时给数字字符串。
  static int? _asIntLoose(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// 判断响应体**看起来像 HTML**（而不是 JSON）。
  /// 为什么要单独判：微博在缺少 `Referer` 时会把接口当**普通网页**处理，
  /// 返回 200 + 一整页 HTML。这时的表现是「解析失败」，但根因是**请求头不对**，
  /// 而不是数据脏。分开报错能省掉一轮真机排查（本项目已经为此花过一轮）。
  ///
  /// 只做形态判断，**不包含响应内容**（避免把页面正文带进异常文案）。
  static bool looksLikeHtml(Object? data) {
    final String text = data is String ? data : (data?.toString() ?? '');
    final String head = text.trimLeft();
    if (head.isEmpty) return false;
    final String first = head.length > 200 ? head.substring(0, 200) : head;
    final String lower = first.toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.contains('<head>') ||
        lower.contains('<body') ||
        lower.contains('sina visitor system');
  }

  /// 响应体前 [max] 个字符（压成一行，便于塞进异常 detail 显示在界面上）。
  ///
  /// **只用于诊断**：内容来自接口响应，不含 cookie / 请求头。
  static String _preview(Object? data, int max) {
    final String text = data is String ? data : (data?.toString() ?? '');
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty) return '(空响应体)';
    return oneLine.length > max ? '${oneLine.substring(0, max)}…' : oneLine;
  }

  /// 已解析 JSON 的**形态摘要**：顶层是不是对象、有没有 `data`、`data` 是什么类型。
  ///
  /// 结构异常时最想知道的就是「服务端到底给了什么壳」，这里直接给结论。
  /// 顺带把微博标准的错误字段（`errno` / `msg`）带出来 —— 接口报错时
  /// `data` 恒为 null，只有这两个字段能说明原因（例如 cid 不合法）。
  static String _shapeOf(Object? decoded) {
    if (decoded is! Map) return '顶层=${decoded.runtimeType}';
    final String top =
        'Map(${(decoded.keys.take(6).map((Object? k) => '$k')).join(',')})';
    final Object? inner = decoded['data'];
    final String innerShape = inner is List
        ? 'List(${inner.length})'
        : (inner?.runtimeType.toString() ?? 'null');
    final Object? errno = decoded['errno'];
    final Object? msg = decoded['msg'];
    final String err = (errno == null && msg == null)
        ? ''
        : ' · errno=$errno${msg == null ? '' : ' · msg=${_preview(msg, 80)}'}';
    return '顶层=$top · data=$innerShape$err';
  }
}
