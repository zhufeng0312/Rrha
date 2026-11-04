import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/net/app_error.dart';
import '../../core/utils/logger.dart';
import '../models/bili_user.dart';
import '../models/comment.dart';
import '../models/danmaku_item.dart';
import 'bili_codes.dart';
import 'bili_models.dart';
import 'comment_parser.dart';
import 'danmaku_parser.dart';
import 'wbi.dart';

/// B 站接口客户端。
///
/// 三件必须做对的事：
/// 1. **WBI 签名**：`playurl` / 评论接口缺签名会返回 -352；签名失败时
///    强刷一次密钥再重试（密钥会滚动更新）。
/// 2. **请求头**：真实浏览器 UA + `Referer: https://www.bilibili.com/`，
///    否则常见 403。
/// 3. **匿名设备指纹 buvid3**：从 `/x/frontend/finger/spi` 获取。
///    这是 B 站下发的**匿名设备标识**，不是账号凭证，且可在设置里关闭。
///
/// 阶段 1 起本客户端支持**带登录态**请求（见 [setAccountCookie]）：凭据由用户
/// 在 App 内**扫码登录**获得，只存在系统钥匙串里（`BiliCredentialStore`），
/// 这里仅在内存中拼进 Cookie 头。**绝不硬编码、绝不落盘、绝不写日志。**
class BiliClient {
  BiliClient({
    required Dio dio,
    bool useAnonymousFingerprint = true,
  })  : _dio = dio,
        _fingerprintEnabled = useAnonymousFingerprint;

  /// WBI 密钥缓存时长。密钥会滚动更新，12 小时是社区经验的保守值。
  static const Duration wbiTtl = Duration(hours: 12);

  final Dio _dio;

  bool _fingerprintEnabled;
  WbiKeys? _keys;
  String? _buvid3;

  /// 账号凭据拼成的 Cookie 串（阶段 1 引入）。
  ///
  /// 由 `biliClientProvider` 在登录态变化时注入。这是它在**网络层的唯一落点**：
  /// 只进内存，不落盘（落盘只走钥匙串）、不写日志、不进异常 detail。
  String? _accountCookie;

  bool get fingerprintEnabled => _fingerprintEnabled;

  /// 注入（或清除）账号凭据；传 `null` 即回到匿名请求。
  void setAccountCookie(String? cookie) {
    final v = cookie?.trim();
    _accountCookie = (v == null || v.isEmpty) ? null : v;
  }

  /// 当前是否带着账号凭据请求（供设置页展示状态，不泄露内容）。
  bool get hasAccountCookie => _accountCookie != null;

  /// 把账号凭据与匿名设备指纹拼成一个 `Cookie` 头。
  ///
  /// 抽成**纯函数**是为了可单测：Cookie 拼接顺序与分隔符（`'; '`）一旦写错，
  /// 症状是「登录了却依然 -352/未登录」，很难从现象反推回来。
  /// 返回 `null` 表示一个都不带（此时不应设置 Cookie 头）。
  static String? composeCookieHeader({String? account, String? buvid3}) {
    final parts = <String>[];
    if (account != null && account.trim().isNotEmpty) {
      parts.add(account.trim());
    }
    if (buvid3 != null && buvid3.trim().isNotEmpty) {
      parts.add('buvid3=${buvid3.trim()}');
    }
    return parts.isEmpty ? null : parts.join('; ');
  }

  void setFingerprintEnabled(bool value) {
    _fingerprintEnabled = value;
    if (!value) _buvid3 = null;
  }

  /// 供设置页展示当前签名状态。
  String get keyStatus {
    final k = _keys;
    if (k == null) return '未获取';
    final age = DateTime.now().difference(k.fetchedAt);
    return '已获取（${age.inMinutes} 分钟前）';
  }

  // ------------------------------------------------------------ 公开接口

  /// 视频详情：拿 aid / cid / 分 P / 统计。
  Future<BiliVideoInfo> videoInfo({String? bvid, int? aid}) async {
    final params = <String, dynamic>{};
    if (bvid != null && bvid.isNotEmpty) {
      params['bvid'] = bvid;
    } else if (aid != null && aid > 0) {
      params['aid'] = aid;
    } else {
      throw AppError.parse('缺少 bvid 或 aid，无法请求视频详情');
    }

    final json = await _get('/x/web-interface/view', params: params);
    final data = json['data'];
    if (data is! Map) {
      throw AppError.parse('view 接口缺少 data 字段');
    }
    return BiliVideoInfo.fromJson(Map<String, dynamic>.from(data));
  }

  /// 取播放地址。
  ///
  /// 默认先请求单文件 MP4（体积小、播放器路径最省事），拿不到再请求 DASH。
  /// 两次都失败时抛可读错误——**绝不返回黑屏**。
  ///
  /// [preferDash] 为 true 时**跳过** MP4、直接取 DASH。用途：通道 A（ExoPlayer）
  /// 拉某个 MP4 单流失败时，那条 CDN 节点往往就是坏的，用同一个 URL 换播放器
  /// 也没用；而同一时刻 DASH 流通常挂在别的节点上（真机实测 BV1XUJe6KE31：
  /// MP4 节点超时、「Failed to open」，DASH 流带 Referer 返回 200）。
  Future<PlayUrlResult> playUrl({
    required String bvid,
    required int cid,
    int qn = AppConfig.preferredQuality,
    bool preferDash = false,
  }) async {
    final base = <String, dynamic>{
      'bvid': bvid,
      'cid': cid,
      'qn': qn,
      'fnver': 0,
      'fourk': 1,
    };

    if (!preferDash) {
      final mp4Json = await _get(
        '/x/player/wbi/playurl',
        params: <String, dynamic>{...base, 'fnval': 1},
      );
      final mp4 = PlayUrlResult.fromJson(mp4Json['data'], requestedQn: qn);
      if (mp4.channel != PlayChannel.none) return mp4;

      Log.d('BiliClient', 'fnval=1 未返回 durl，改请求 fnval=4048（DASH）');
    }

    final dashJson = await _get(
      '/x/player/wbi/playurl',
      params: <String, dynamic>{...base, 'fnval': 4048},
    );
    final dash = PlayUrlResult.fromJson(dashJson['data'], requestedQn: qn);
    if (dash.channel != PlayChannel.none) return dash;

    throw AppError.bili(
      null,
      '没有取到可播放的视频流（可能是付费、地区限制或仅登录可见的内容）',
      detail: 'bvid=$bvid cid=$cid qn=$qn preferDash=$preferDash',
    );
  }

  /// 弹幕：两条通道，任一成功即返回。
  ///
  /// 实测（2026-10）修正了两处旧假设：
  /// - `/x/v1/dm/list.so` 现在返回的是 **deflate 压缩的 XML**，不是 protobuf，
  ///   且 `comment.bilibili.com/{cid}.xml` 与它**同源**（字节完全一致）；
  /// - 两者都是**裸 deflate**（无 zlib 头），而 dart:io 只自动解压 gzip，
  ///   所以必须取字节并交给 `DanmakuParser.parseAuto` 统一处理。
  ///
  /// 【实机修复 · 2026-10-14】「0 条弹幕」不是错误。
  /// 视频没有任何弹幕是完全正常的（新稿件、冷门稿件、UP 主关闭弹幕都如此）。
  /// 此时接口返回的是 HTTP 200 + 合法的空 XML 骨架（141B）：
  ///     <i><chatserver>…</chatserver><chatid>…</chatid><mission>0</mission>…</i>
  /// 旧实现把这种「解析成功但 0 条」也累计进 failures 并最终抛
  /// AppErrorKind.empty（文案「弹幕加载失败」），导致播放页显示红色报错 + 重试，
  /// 而实际上一切正常。现在把「接口成功返回空集」与「接口失败」区分开：
  /// 只要至少有一条通道**成功拿到并解析了响应**，就返回空列表（UI 显示 0 弹幕），
  /// 只有所有通道都**请求/解析失败**时才抛错。
  Future<List<DanmakuItem>> danmaku({required int cid}) async {
    final failures = <String>[];

    // 只要有一条通道成功完成了「请求 + 解析」，就说明接口是通的；
    // 此时 0 条是真实结果，而不是故障。
    var anyChannelSucceeded = false;

    // 通道 1：/x/v1/dm/list.so
    try {
      final bytes = await _danmakuBytes(cid);
      if (bytes.isNotEmpty) {
        final items = DanmakuParser.sorted(DanmakuParser.parseAuto(bytes));
        anyChannelSucceeded = true;
        if (items.isNotEmpty) {
          Log.d('BiliClient', '弹幕通道 dm/list.so 成功：cid=$cid，${items.length} 条');
          return items;
        }
        Log.d('BiliClient', '弹幕通道 dm/list.so 成功但该稿件无弹幕：cid=$cid');
      } else {
        failures.add('dm/list.so 返回空响应');
      }
    } catch (e) {
      failures.add('dm/list.so: $e');
      Log.w('BiliClient', '弹幕通道 dm/list.so 失败（cid=$cid）：$e');
    }

    // 通道 2：comment.bilibili.com/{cid}.xml（独立兜底）
    try {
      final bytes = await _danmakuXmlBytes(cid);
      if (bytes.isNotEmpty) {
        final items = DanmakuParser.sorted(DanmakuParser.parseAuto(bytes));
        anyChannelSucceeded = true;
        if (items.isNotEmpty) {
          Log.d('BiliClient', '弹幕通道 comment.bilibili.com 成功：cid=$cid，${items.length} 条');
          return items;
        }
        Log.d('BiliClient', '弹幕通道 comment.bilibili.com 成功但该稿件无弹幕：cid=$cid');
      } else {
        failures.add('comment.bilibili.com 返回空响应');
      }
    } catch (e) {
      failures.add('comment.bilibili.com: $e');
      Log.w('BiliClient', '弹幕通道 comment.bilibili.com 失败（cid=$cid）：$e');
    }

    // 两条通道都请求/解析失败，才是真的故障。
    if (!anyChannelSucceeded) {
      throw AppError(
        AppErrorKind.empty,
        '弹幕加载失败（两个接口都没有返回可用数据），播放不受影响',
        detail: 'cid=$cid | ${failures.join(' ; ')}',
        retryable: true,
      );
    }

    // 接口正常，只是这个稿件确实没有弹幕。
    return const <DanmakuItem>[];
  }

  /// 主评论列表（游标分页）。
  ///
  /// [oid] 与 [type] 是一对，必须来自**同一条内容自己声明的**评论入口：
  /// 视频投稿 = (aid, 1)，图文动态 = (图片/opus id, 11)，转发动态 = (动态 id_str, 17)。
  /// 混用会得到 `-404 啥都木有`（拿动态 id 当视频 oid 就是这种症状），
  /// 所以 `oid` 用 String 承载，解析层负责把正确取值带过来。
  ///
  /// `pagination_str` 的包装**只在这里发生**（见 [paginationStr]）：
  /// 解析层交回来的 [CommentPage.nextCursor] 是裸游标串。
  Future<CommentPage> comments({
    required String oid,
    int type = 1,
    CommentSort sort = CommentSort.hot,
    String? cursor,
    int upMid = 0,
  }) async {
    final params = <String, dynamic>{
      'oid': oid,
      'type': type,
      'mode': sort.mode,
      'pagination_str': paginationStr(cursor),
      'plat': 1,
      'seek_rpid': '',
      'web_location': 1315875,
    };

    final json = await _get('/x/v2/reply/wbi/main', params: params);
    return CommentParser.parseMain(json, upMid: upMid);
  }

  /// 把裸游标包装成 B 站要求的 `pagination_str`。
  ///
  /// B 站只认 `{"offset":"..."}` 这一种形态；直接把裸游标串当参数发出去会被判
  /// `-400 请求参数有误` —— 真机上「加载更多」报的就是这个错。空游标代表第一页。
  ///
  /// ⚠️ **必须用 `jsonEncode` 的紧凑产物（冒号后无空格）**：实测
  /// `{"offset": ""}`（带空格）会被判 `-403`。因此全工程只有这一处负责包装，
  /// 不要在别处再拼一遍、也不要在这里"美化"输出。
  static String paginationStr(String? cursor) {
    final c = cursor?.trim() ?? '';
    return jsonEncode(<String, String>{'offset': c});
  }

  /// 楼中楼。`oid` / `type` 与主评论同一套取值。
  Future<SubCommentPage> replies({
    required String oid,
    required int root,
    int type = 1,
    int pn = 1,
    int upMid = 0,
  }) async {
    final params = <String, dynamic>{
      'oid': oid,
      'type': type,
      'root': root,
      'ps': AppConfig.subCommentPageSize,
      'pn': pn,
    };
    final json = await _get('/x/v2/reply/reply', params: params);
    return CommentParser.parseReplies(
      json,
      upMid: upMid,
      pageSize: AppConfig.subCommentPageSize,
    );
  }

  // ------------------------------------------------------------ 关注与主页

  /// 「我关注的动态流」：**一个请求**拿回所有关注 UP 的最新更新。
  ///
  /// 需要登录态 + WBI 签名。分页靠 [offset] 游标（把上一页返回的 offset 原样传回），
  /// `page` 只是页码计数，服务端两者都会参考。
  ///
  /// 实测（2026-10）：首页 20 条、涉及 13 个 UP 主，`has_more=true`；
  /// 第二页 21 条且与首页 0 重复。这正是时间线「方案 C」的取数入口 ——
  /// 6 个订阅源原本要打 12 个请求，现在一次一个。
  Future<BiliFollowingFeed> followingFeed({
    String? offset,
    int page = 1,
  }) async {
    final params = <String, dynamic>{
      'type': 'all',
      'page': page,
      'timezone_offset': -480,
      'platform': 'web',
      'features': 'itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote',
    };
    final off = offset?.trim();
    if (off != null && off.isNotEmpty) params['offset'] = off;

    final json = await _get('/x/polymer/web-dynamic/v1/feed/all', params: params);
    return BiliFollowingFeed.fromJson(json['data']);
  }

  /// 「我关注的 UP 主」分页列表。
  ///
  /// **需要登录态**：未登录时 B 站返回 `-101`（账号未登录）/ `-400`。
  /// 该接口**不需要 WBI 签名**（阶段 0 实测：带上 Cookie 直接请求即 `code=0`）。
  Future<BiliFollowingPage> followings({
    required int mid,
    int pn = 1,
    int ps = AppConfig.followingPageSize,
    String order = 'desc',
  }) async {
    if (mid <= 0) {
      throw AppError.parse('关注列表：缺少有效的 mid（账号 uid）');
    }
    final json = await _get(
      '/x/relation/followings',
      params: <String, dynamic>{
        'vmid': mid,
        'pn': pn,
        'ps': ps,
        'order': order,
        'order_type': 'attention',
      },
      wbi: false,
    );
    return BiliFollowingPage.fromJson(
      json,
      requestedPage: pn,
      requestedPageSize: ps,
    );
  }

  /// 某个 UP 主的最新投稿，返回**原始** `vlist` 项。
  ///
  /// 刻意不在这里转 [ContentItem]：那是 `BiliContentParser` 的职责，
  /// 与 RSS 侧「client 只取原文、parser 负责映射」的分工保持一致
  /// （也让字段映射可以脱离网络单测）。
  ///
  /// 需要 WBI 签名。
  Future<List<Object?>> userVideoItems({
    required int mid,
    int pn = 1,
    int ps = AppConfig.userVideoFetchLimit,
  }) async {
    final json = await _get(
      '/x/space/wbi/arc/search',
      params: <String, dynamic>{
        'mid': mid,
        'ps': ps,
        'pn': pn,
        'order': 'pubdate',
        'tid': 0,
        'platform': 'web',
        'web_location': 1550101,
      },
    );
    final data = json['data'];
    if (data is! Map) return const <Object?>[];
    final list = Map<String, dynamic>.from(data)['list'];
    if (list is! Map) return const <Object?>[];
    final vlist = Map<String, dynamic>.from(list)['vlist'];
    return vlist is List ? vlist : const <Object?>[];
  }

  /// 某个 UP 主的动态，返回**原始** `items`。
  ///
  /// 需要 WBI 签名 + 登录态。
  Future<List<Object?>> userDynamicItems({
    required int mid,
    String? offset,
  }) async {
    final params = <String, dynamic>{
      'host_mid': mid,
      'timezone_offset': -480,
      'platform': 'web',
      'features': 'itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote',
    };
    final off = offset?.trim();
    if (off != null && off.isNotEmpty) params['offset'] = off;

    final json = await _get(
      '/x/polymer/web-dynamic/v1/feed/space',
      params: params,
    );
    final data = json['data'];
    if (data is! Map) return const <Object?>[];
    final items = Map<String, dynamic>.from(data)['items'];
    return items is List ? items : const <Object?>[];
  }

  /// 单条动态详情（`/x/polymer/web-dynamic/v1/detail`），返回**原始 item**。
  ///
  /// ## 为什么需要它（2026-11-02 实测）
  ///
  /// 用户在浏览器里复制来的 `https://www.bilibili.com/opus/<id>` 里那个 id
  /// **不能**直接当评论接口的 `oid`：拿它配 `type=11` 或 `type=17` 都返回
  /// `-404 啥都木有`（探针 `.env/probe_bili_opus_comment_entry.py` 实证）。
  ///
  /// 正确入口在 `item.basic` 里：
  /// ```
  /// comment_id_str = "414185073"   ← 真正的 oid
  /// comment_type   = 11            ← 与它配对
  /// ```
  /// 用这组值去打 `/x/v2/reply/wbi/main` 才拿到 20 条评论（含图片）。
  ///
  /// [id] 就是 opus 链接里那段数字（它与 `item.id_str` 相同）。
  Future<Object?> dynamicDetail(String id) async {
    final json = await _get(
      '/x/polymer/web-dynamic/v1/detail',
      params: <String, dynamic>{
        'id': id,
        'features': 'itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote',
      },
    );
    final data = json['data'];
    if (data is! Map) return null;
    return Map<String, dynamic>.from(data)['item'];
  }

  /// 当前登录账号的 mid（从 `/x/web-interface/nav` 取）。  ///  /// 关注列表接口必须带 `vmid`，而 vmid 就是自己的 mid，
  /// 所以「拉我关注的人」这条链路第一步是先问出自己是谁。
  Future<int> currentMid() async {
    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        '/x/web-interface/nav',
        options: Options(headers: await _buildHeaders()),
      );
    } on DioException catch (e) {
      throw AppError.fromDio(e);
    }
    final raw = res.data;
    if (raw is! Map) throw AppError.parse('nav 返回了非 JSON 内容');
    final map = Map<String, dynamic>.from(raw);
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : const <String, dynamic>{};

    final mid = (data['mid'] as num?)?.toInt() ?? 0;
    if (data['isLogin'] != true || mid <= 0) {
      throw const AppError(
        AppErrorKind.auth,
        '需要先登录 B 站账号（设置 → B 站账号 → 扫码登录）',
        retryable: false,
      );
    }
    return mid;
  }

  // ------------------------------------------------------------ 网络底层

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? params,
    bool wbi = true,
    bool retryOnRisk = true,
  }) async {
    try {
      return await _getOnce(path, params: params, wbi: wbi);
    } on AppError catch (e) {
      if (wbi && retryOnRisk && isRiskFailure(e)) {
        Log.w(
          'BiliClient',
          '$path 命中风控（${e.statusCode != null ? 'HTTP ${e.statusCode}' : 'code ${e.bizCode}'}），'
          '强刷 WBI 密钥后重试一次',
        );
        await _refreshKeys();
        return _getOnce(path, params: params, wbi: wbi);
      }
      rethrow;
    }
  }

  /// 是否属于「强刷 WBI 密钥后值得再试一次」的风控失败。
  ///
  /// 必须同时覆盖两种形态，否则真机上会表现成两种不同的偶发故障：
  /// - **业务码** -352 / -412：接口正常返回，`code` 字段报风控；
  /// - **HTTP 412**：网关在业务层之前就拦掉（响应里根本没有 JSON），
  ///   走的是 [_unwrap] 的 `status >= 400` 分支。早先只判业务码，于是这类
  ///   412 既不重试、文案也落到泛化分支，用户只看到「请求失败（HTTP 412）」。
  static bool isRiskFailure(AppError e) =>
      BiliCodes.isRiskCode(e.bizCode) || e.statusCode == 412;

  Future<Map<String, dynamic>> _getOnce(
    String path, {
    Map<String, dynamic>? params,
    required bool wbi,
  }) async {
    final p = <String, dynamic>{...?params};
    var target = path;

    if (wbi) {
      final keys = await _ensureKeys();
      target = '$path?${WbiSigner.sign(params: p, imgKey: keys.imgKey, subKey: keys.subKey)}';
    } else if (p.isNotEmpty) {
      final qs = p.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent('${e.value}')}')
          .join('&');
      target = '$path?$qs';
    }

    final headers = await _buildHeaders();
    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(target, options: Options(headers: headers));
    } on DioException catch (e) {
      throw AppError.fromDio(e);
    }
    return _unwrap(res, path);
  }

  Map<String, dynamic> _unwrap(Response<dynamic> res, String path) {
    final status = res.statusCode ?? 0;
    if (status >= 400) {
      throw AppError.fromStatus(status, detail: 'GET $path -> HTTP $status');
    }
    final raw = res.data;
    if (raw is! Map) {
      throw AppError.parse('B 站接口返回了非 JSON 内容（$path）');
    }
    final map = Map<String, dynamic>.from(raw);
    final code = (map['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw BiliCodes.toError(code, map['message']?.toString(), detail: 'GET $path');
    }
    return map;
  }

  // ------------------------------------------------------------ WBI 密钥

  Future<WbiKeys> _ensureKeys() async {
    final cached = _keys;
    if (cached != null && !cached.isExpired(wbiTtl)) return cached;
    return _refreshKeys();
  }

  /// 重新获取 WBI 密钥。
  ///
  /// 关键细节：**未登录时 nav 接口返回 `code: -101`，但 `data.wbi_img`
  /// 仍然存在**。所以这里不能照搬「code != 0 即失败」的判断，必须先尝试
  /// 提取密钥，提取不到才按错误码报错。
  Future<WbiKeys> _refreshKeys() async {
    const path = '/x/web-interface/nav';
    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        path,
        options: Options(headers: await _buildHeaders()),
      );
    } on DioException catch (e) {
      throw AppError.fromDio(e);
    }

    final status = res.statusCode ?? 0;
    if (status >= 400) {
      throw AppError.fromStatus(status, detail: 'GET $path -> HTTP $status');
    }

    final raw = res.data;
    if (raw is! Map) {
      throw AppError.parse('nav 接口返回了非 JSON 内容');
    }
    final map = Map<String, dynamic>.from(raw);

    final keys = WbiKeys.fromNavData(map['data']);
    if (keys != null) {
      _keys = keys;
      Log.d('BiliClient', 'WBI 密钥已更新');
      return keys;
    }

    final code = (map['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw BiliCodes.toError(code, map['message']?.toString(), detail: 'GET $path');
    }
    throw AppError.parse('无法从 nav 接口解析 WBI 密钥（wbi_img 缺失）');
  }

  // ------------------------------------------------------------ 设备指纹

  Future<Map<String, String>> _buildHeaders() async {
    final headers = <String, String>{};

    // 账号凭据优先：登录后 B 站按 SESSDATA 识别身份；
    // buvid3 只是匿名设备指纹，两者并存用 '; ' 拼接（浏览器也是这么做的）。
    final cookie = composeCookieHeader(
      account: _accountCookie,
      buvid3: await _ensureBuvid(),
    );
    if (cookie != null) {
      headers['Cookie'] = cookie;
    }
    return headers;
  }

  /// 获取匿名设备指纹（buvid3）。失败不阻断请求，只记日志。
  Future<String?> _ensureBuvid() async {
    if (!_fingerprintEnabled) return null;
    final cached = _buvid3;
    if (cached != null) return cached;

    try {
      final res = await _dio.get<dynamic>(
        '/x/frontend/finger/spi',
        options: Options(
          headers: <String, String>{
            'User-Agent': AppConfig.browserUserAgent,
            'Referer': 'https://www.bilibili.com/',
          },
        ),
      );
      final raw = res.data;
      if (raw is Map) {
        final data = raw['data'];
        if (data is Map) {
          final b3 = data['b_3']?.toString();
          if (b3 != null && b3.isNotEmpty) {
            _buvid3 = b3;
            return b3;
          }
        }
      }
    } on DioException catch (e) {
      Log.w('BiliClient', '获取匿名设备指纹失败：${e.message}');
    } catch (e) {
      Log.w('BiliClient', '获取匿名设备指纹异常：$e');
    }
    return null;
  }

  // ------------------------------------------------------------ 弹幕原始请求

  Future<Uint8List> _danmakuBytes(int cid) async {
    Response<List<int>> res;
    try {
      res = await _dio.get<List<int>>(
        '/x/v1/dm/list.so',
        queryParameters: <String, dynamic>{'oid': cid},
        options: Options(
          responseType: ResponseType.bytes,
          headers: await _buildHeaders(),
        ),
      );
    } on DioException catch (e) {
      throw AppError.fromDio(e);
    }
    final status = res.statusCode ?? 0;
    if (status >= 400) {
      throw AppError.fromStatus(
        status,
        detail: 'GET /x/v1/dm/list.so?oid=$cid -> HTTP $status',
      );
    }
    return Uint8List.fromList(res.data ?? const <int>[]);
  }

  /// 兜底通道同样取**字节**而非字符串。
  ///
  /// 该接口也返回 `Content-Encoding: deflate`（裸 deflate），而 dart:io 只自动
  /// 解压 gzip，所以必须把原始字节交给 [DanmakuParser.maybeInflate]。
  Future<Uint8List> _danmakuXmlBytes(int cid) async {
    final url = 'https://comment.bilibili.com/$cid.xml';
    Response<List<int>> res;
    try {
      res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: await _buildHeaders(),
        ),
      );
    } on DioException catch (e) {
      throw AppError.fromDio(e);
    }
    final status = res.statusCode ?? 0;
    if (status >= 400) {
      throw AppError.fromStatus(status, detail: 'GET $url -> HTTP $status');
    }
    return Uint8List.fromList(res.data ?? const <int>[]);
  }
}
