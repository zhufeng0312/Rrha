import 'package:dio/dio.dart';

import '../../core/net/app_error.dart';
import '../models/bili_session.dart';

/// 扫码登录的轮询状态。
///
/// 状态码是 B 站约定，已由 `tools/probe_bili_login.py` 实测确认：
/// `86101` 未扫码 / `86090` 已扫码待确认 / `86038` 二维码已过期 / `0` 登录成功。
enum QrPollState {
  /// 还没人扫码。
  waiting,

  /// 已扫码，等手机端点「确认登录」。
  scanned,

  /// 二维码过期，需要重新生成。
  expired,

  /// 登录成功，凭据已拿到。
  success,

  /// 既不是成功也不是已知状态（B 站将来加了新码时走这里）。
  ///
  /// 刻意**不**当成失败：轮询继续，界面提示「状态未知」即可，
  /// 免得 B 站一改码就把登录功能判死。
  unknown,
}

/// 一次扫码会话的「票」：二维码内容 + 轮询用的 key。
class QrCodeTicket {
  const QrCodeTicket({required this.url, required this.key});

  /// 二维码里编码的地址（B 站官方页面）。
  ///
  /// ⚠️ 二维码**必须在本地渲染**（本项目用 `qr_flutter`）。
  /// 绝不能把它丢给任何在线二维码生成服务 —— 那等于把登录入口交给第三方。
  final String url;

  /// 轮询凭据（qrcode_key）。它**不是**账号凭据，可以出现在界面与日志里。
  final String key;
}

/// 单次轮询的结果。
class QrPollResult {
  const QrPollResult({required this.state, this.message, this.session});

  final QrPollState state;

  /// 服务端给的可读文案（成功时一般是「扫码登录成功」）。
  final String? message;

  /// 仅 [QrPollState.success] 时非空。
  final BiliSession? session;
}

/// B 站扫码登录客户端。
///
/// 职责只有三件：申请二维码、轮询状态、用拿到的凭据确认身份。
/// **凭据的落地不在这里** —— 一律交给 `BiliCredentialStore`（系统钥匙串）。
class BiliLoginClient {
  BiliLoginClient({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// passport 域与 api 域不同，因此这里用绝对地址（Dio 会用绝对 URL 覆盖 baseUrl）。
  static const String generateUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';
  static const String pollUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll';
  static const String navUrl = 'https://api.bilibili.com/x/web-interface/nav';

  /// 二维码有效期约 180 秒，轮询间隔取 2 秒（与验证脚本一致）。
  static const Duration pollInterval = Duration(seconds: 2);
  static const Duration ticketTtl = Duration(seconds: 180);

  // ============================================================ 纯函数区
  // 下面两个 static 方法是刻意做成纯函数的：登录最容易出错的正是
  // 「状态码映射」与「从响应头抠凭据」这两处，而它们都可以离线单测。

  /// 轮询状态码 → [QrPollState]。
  static QrPollState stateFromCode(Object? code) {
    final c = code is num ? code.toInt() : int.tryParse('${code ?? ''}');
    switch (c) {
      case 0:
        return QrPollState.success;
      case 86101:
        return QrPollState.waiting;
      case 86090:
        return QrPollState.scanned;
      case 86038:
        return QrPollState.expired;
      default:
        return QrPollState.unknown;
    }
  }

  /// 从 `Set-Cookie` 响应头里取出账号凭据。
  ///
  /// B 站的扫码登录**不在 body 里回凭据**，而是靠 `Set-Cookie` 下发 ——
  /// 这是该接口最容易踩空的一点（body 里只有 `code` 与 `refresh_token`）。
  ///
  /// 返回 `null` 表示响应头里缺 `SESSDATA` / `bili_jct` / `DedeUserID`
  /// 中的任意一项（此时应当当作登录失败，而不是存一份残缺凭据）。
  static BiliSession? sessionFromCookies(
    List<String> setCookieHeaders, {
    String? refreshToken,
    DateTime? now,
  }) {
    final jar = <String, String>{};
    for (final line in setCookieHeaders) {
      // 一行形如：SESSDATA=xxxx; Path=/; Domain=.bilibili.com; HttpOnly
      final pair = line.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      jar[name] = value;
    }

    final sess = jar['SESSDATA'];
    final jct = jar['bili_jct'];
    final uid = jar['DedeUserID'];
    if (sess == null || jct == null || uid == null) return null;

    return BiliSession(
      sessData: sess,
      biliJct: jct,
      dedeUserId: uid,
      dedeUserIdCkMd5: jar['DedeUserID__ckMd5'],
      refreshToken: (refreshToken == null || refreshToken.isEmpty)
          ? null
          : refreshToken,
      obtainedAt: now ?? DateTime.now(),
    );
  }

  // ============================================================ 网络

  /// 申请一个新的二维码。
  Future<QrCodeTicket> generate() async {
    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(generateUrl);
    } on DioException catch (e) {
      throw AppError.fromDio(e);
    }

    final map = _unwrap(res, 'qrcode/generate');
    final data = map['data'];
    if (data is! Map) {
      throw AppError.parse('扫码登录：generate 响应缺少 data 字段');
    }
    final d = Map<String, dynamic>.from(data);
    final url = '${d['url'] ?? ''}'.trim();
    final key = '${d['qrcode_key'] ?? ''}'.trim();
    if (url.isEmpty || key.isEmpty) {
      throw AppError.parse('扫码登录：generate 未返回 url / qrcode_key');
    }
    return QrCodeTicket(url: url, key: key);
  }

  /// 轮询一次状态。
  ///
  /// **刻意不抛异常**：轮询过程中一次网络抖动不该中断整个登录流程，
  /// 调用方按 [QrPollResult.state] 决定继续还是收尾即可。
  Future<QrPollResult> poll(String key) async {
    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        pollUrl,
        queryParameters: <String, dynamic>{'qrcode_key': key},
      );
    } on DioException catch (e) {
      return QrPollResult(
        state: QrPollState.unknown,
        message: AppError.fromDio(e).message,
      );
    }

    final status = res.statusCode ?? 0;
    if (status >= 400) {
      return QrPollResult(
        state: QrPollState.unknown,
        message: '扫码登录：poll 返回 HTTP $status',
      );
    }

    final raw = res.data;
    if (raw is! Map) {
      return const QrPollResult(
        state: QrPollState.unknown,
        message: '扫码登录：poll 返回了非 JSON 内容',
      );
    }

    final map = Map<String, dynamic>.from(raw);
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};

    // 关键：**状态码在 data.code 里**，外层 code 只表示「接口本身是否正常」。
    // 只读外层会永远得到「成功」，这是该接口的第二个易错点。
    final state = stateFromCode(data['code'] ?? map['code']);
    final msg = '${data['message'] ?? map['message'] ?? ''}'.trim();

    if (state != QrPollState.success) {
      return QrPollResult(state: state, message: msg.isEmpty ? null : msg);
    }

    final refresh = '${data['refresh_token'] ?? ''}'.trim();
    final session = sessionFromCookies(
      _setCookiesOf(res),
      refreshToken: refresh.isEmpty ? null : refresh,
    );
    if (session == null) {
      return const QrPollResult(
        state: QrPollState.unknown,
        message: '扫码登录：服务端已返回成功，但响应头里没有凭据（Set-Cookie 缺失）',
      );
    }
    return QrPollResult(
      state: QrPollState.success,
      message: msg.isEmpty ? null : msg,
      session: session,
    );
  }

  /// 用刚拿到的凭据确认登录态，并取回昵称 / mid（**仅用于界面展示**）。
  ///
  /// 这一步不是形式主义：扫码成功后凭据也可能因风控立即失效，
  /// 先确认再落库，能避免存进钥匙串一份「看起来登录了其实不能用」的凭据。
  Future<BiliSession> confirm(BiliSession session) async {
    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        navUrl,
        options: Options(
          headers: <String, String>{'Cookie': session.cookieHeader},
        ),
      );
    } on DioException catch (e) {
      throw AppError.fromDio(e);
    }

    final raw = res.data;
    if (raw is! Map) throw AppError.parse('确认登录态失败：nav 返回非 JSON');
    final map = Map<String, dynamic>.from(raw);
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};

    if (data['isLogin'] != true) {
      throw const AppError(
        AppErrorKind.auth,
        '扫码返回的凭据未被 B 站接受（isLogin=false），请重新扫码',
        retryable: true,
      );
    }

    final uname = '${data['uname'] ?? ''}'.trim();
    return session.copyWith(
      uname: uname.isEmpty ? null : uname,
      mid: data['mid'] is num ? (data['mid'] as num).toInt() : null,
    );
  }

  // ============================================================ 内部

  static List<String> _setCookiesOf(Response<dynamic> res) {
    // Dio 会把同名多值响应头收成 List<String>（B 站一次下发 4~5 个 Set-Cookie）。
    return res.headers['set-cookie'] ?? const <String>[];
  }

  Map<String, dynamic> _unwrap(Response<dynamic> res, String tag) {
    final status = res.statusCode ?? 0;
    if (status >= 400) {
      throw AppError.fromStatus(status, detail: 'GET $tag -> HTTP $status');
    }
    final raw = res.data;
    if (raw is! Map) throw AppError.parse('扫码登录：$tag 返回了非 JSON 内容');
    final map = Map<String, dynamic>.from(raw);
    final code = (map['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw AppError(
        AppErrorKind.unknown,
        '扫码登录失败（code=$code）：${map['message'] ?? '未知原因'}',
        detail: 'GET $tag',
        retryable: true,
      );
    }
    return map;
  }
}
