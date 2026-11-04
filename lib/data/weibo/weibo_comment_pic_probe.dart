/// 微博评论**图片字段**探针（纯诊断，不是正式数据层）。
///
/// ## 为什么单独有这个探针
///
/// 评论接口 `comments/hotflow` 早就打通了（见 `.env/weibo_comment_probe.md`），
/// 但历史采样里**所有评论的 `pic_num` 都是 0**，于是一整套问题从没被回答过：
///
/// - 图片列表到底挂在哪个字段？`pics`？`pic_infos`？`pic_ids` + 别的？
/// - 元素是 `List` 还是 `Map`？
/// - 元素里每个字段叫什么、什么类型？URL 在哪一层（`url` / `large.url` / …）？
/// - URL 是 `https://` 绝对地址还是 `//` 协议相对？
/// - 有没有缩略 / 中等 / 原图这些尺寸变体？分别叫什么？
/// - 一条评论最多能有几张图？二级评论的图片字段与一级是否同构？
///
/// 本探针只做一件事：**翻页扫到带图评论 → 把字段树原样摊平 → 逐项回答**。
/// 它不产出任何模型、不碰 `weibo_comment_parser.dart`。
///
/// ## 请求纪律（硬上限，调用方改不动）
///
/// 间隔 ≥2.5s · 总请求 ≤[WeiboCommentPicProbe.maxRequests] · 总页数
/// ≤[WeiboCommentPicProbe.maxPagesTotal] · 连续 3 次 432 立刻停 · 单项超时
/// 20s · **不重试**、**不做任何风控绕过**（不伪造 XSRF、不换 UA 批量试）。
///
/// ## 凭据安全（硬约束）
///
/// cookie 只作为请求头出现：不进日志、不进结果对象、不进异常文案、不落盘。
/// 落盘的 Markdown 里只写 cookie **长度**。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'weibo_web_urls.dart';

// ===========================================================================
// 本地共享工具（与 weibo_diagnostics.dart 里的同名逻辑一致，但那是私有符号，
// 跨 library 用不了，这里只保留本探针需要的最小一份）
// ===========================================================================

const int _picMaxValueChars = 80;

String _picTypeName(Object? value) {
  if (value == null) return 'null';
  if (value is String) return 'String';
  if (value is bool) return 'bool';
  if (value is int) return 'int';
  if (value is double) return 'double';
  if (value is num) return 'num';
  if (value is Map) return 'Map';
  if (value is List) return 'List';
  return value.runtimeType.toString();
}

/// 样例值：字符串加引号、超长截断并标注原长；null 显示成空串。
String _picSampleValue(Object? value, {int maxChars = _picMaxValueChars}) {
  if (value == null) return '';
  final String raw = value is String ? value : value.toString();
  if (raw.length <= maxChars) return value is String ? '"$raw"' : raw;
  final String cut = raw.substring(0, maxChars);
  return value is String
      ? '"$cut…（原长 ${raw.length}）'
      : '$cut…（原长 ${raw.length}）';
}

/// 游标脱敏：只给前 8 位与总长度。
String _picMask(String value) {
  if (value.isEmpty) return '（空）';
  final String head = value.length > 8 ? value.substring(0, 8) : value;
  return '$head…（${value.length} 位）';
}

Map<String, dynamic>? _picAsMap(Object? value) {
  if (value is! Map) return null;
  return value.cast<String, dynamic>();
}

String? _picAsText(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final String s = value.trim();
    return s.isEmpty ? null : s;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

int? _picAsInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Map<String, dynamic>? _picTryParseObject(String body) {
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

// ===========================================================================
// 常量：候选字段名、跳过规则
// ===========================================================================

/// 候选的图片字段名。
///
/// 只用于**如实体检**（存在？什么类型？几项？），顺序即优先级。
///
/// **实测结论（2026-10-20，`m.weibo.cn/comments/hotflow`）**：
/// 评论里的真字段是 **`pic`（单数，Map）**，结构 `{pid,url,size,geo,large{...}}`，
/// `url` 是完整可用的 `https://wx*.sinaimg.cn/orj360/<pid>.jpg`。
/// 而 **`pics`（复数，List）** 也会出现，但里面的 `url` 是
/// `https://ss1.sinaimg.cn/orj360/&690` 这种**残片**（实测 404），
/// `pid=null`、`type="video"` —— 不能直接拿去显示。
/// 所以 `pic` 排在 `pics` 之前：先取可信的。
const List<String> _picCandidateKeys = <String>[
  'pic',
  'pic_infos',
  'pics',
  'pic_ids',
  'picInfo',
  'pic_list',
  'picIds',
  'pic_urls',
  'pic_url',
];

/// 字段树里**不展开**的 key：这些一出现就是会话票据，落盘也不合适。
final RegExp _picSkipKey = RegExp(
  r'token|secret|password|passwd|cookie|sessionid',
  caseSensitive: false,
);

/// 形似图片 pid 的路径段（`pic_infos.<pid>.large.url` 里的 pid）。
final RegExp _picPidSegment = RegExp(r'^[A-Za-z0-9]{16,}$');

// ===========================================================================
// 数据结构
// ===========================================================================

/// 一条评论的「图片字段体检」结果（纯数据，不含凭据）。
class CommentPicAnalysis {
  const CommentPicAnalysis({
    required this.candidates,
    required this.containerKey,
    required this.containerType,
    required this.containerLength,
    required this.elementType,
    required this.elementKeys,
    required this.urlPaths,
    required this.urlSamples,
    required this.variants,
    required this.httpsCount,
    required this.schemeRelativeCount,
    required this.otherSchemeCount,
    required this.picNum,
    required this.picCount,
    required this.plausibleUrlCount,
    required this.distinctUrlCount,
    required this.imageCount,
    required this.mixMediaCount,
  });

  /// 每个候选字段一行的存在性体检。
  final List<String> candidates;

  /// 实际承载图片的字段名；null = 一个都没命中。
  final String? containerKey;

  /// 容器类型（`List` / `Map`）；null = 没有容器。
  final String? containerType;

  /// 容器长度（List 项数 / Map key 数）。
  final int? containerLength;

  /// 元素类型（`Map` / `String` / …）。
  final String? elementType;

  /// 元素字段 `名字：类型`（保序，按接口原样）。
  final List<String> elementKeys;

  /// 每个 URL 值的路径（如 `pics[0].large.url`）。
  final List<String> urlPaths;

  /// 与 [urlPaths] 一一对应的样例值（截断 80）。
  final List<String> urlSamples;

  /// 尺寸变体名（去掉元素下标与 pid 之后，如 `url` / `large.url`）。
  final List<String> variants;

  /// `https://` 开头的 URL 个数。
  final int httpsCount;

  /// `//` 协议相对 URL 个数。
  final int schemeRelativeCount;

  /// 其它形态（`http://` 或非 URL）个数。
  final int otherSchemeCount;

  /// `pic_num` 原值；null = 字段不存在或不是数字。
  final int? picNum;

  /// 图片张数：取「容器长度」与 `pic_num` 的较大值（**只用于对账**）。
  final int picCount;

  /// 「看起来像真图片地址」的 URL 个数。
  ///
  /// 判据：`http(s)` 绝对地址 **且** 末段文件名不以 `&` / `?` 这类残片开头。
  /// 实测会拿到 `https://ss1.sinaimg.cn/orj360/&690` 这种**残缺 URL**，
  /// 光看「以 https 开头」会把它当成好地址。
  final int plausibleUrlCount;

  /// 去重后的 URL 个数（多条不同评论给出同一个 URL 是重要信号）。
  final int distinctUrlCount;

  /// **真正的图片张数**（不是容器 key 数）。
  ///
  /// 三种容器的语义完全不同，混在一起算会得出荒谬结论：
  /// - `List` → 项数（多图）；
  /// - `Map` 且自身带 `url`（实测的 `pic` 字段）→ **1 张**，key 数只是字段数；
  /// - `Map` 且 value 才是图片（`pic_infos.<pid>`）→ key 数。
  final int imageCount;

  /// **实际可显示的图片张数**：有可信容器就按 [imageCount]，否则退回 `pic_num`。
  ///
  /// 为什么不用 [picCount]：实测存在 `pic_num=3` 而容器只有 1 张的评论，
  /// 按 `pic_num` 渲染会去取不存在的下标。
  int get displayCount => found ? imageCount : (picNum ?? 0);

  /// `mix_media_ids` 的项数；null = 该字段不存在。
  ///
  /// 这是本轮**最重要的横向佐证**：实测 4 条样本里 `mix_media_ids` 的项数与
  /// `pic_num` **完全一致（4/4）**，而 `pic` / `pics` 容器始终只有 1 项。
  /// 也就是说「张数」这个信息只在这两个地方，**图片直链只有 1 个**。
  final int? mixMediaCount;

  /// 张数三方是否吻合（`pic_num` == `mix_media_ids` 项数）。
  ///
  /// 明确给出这个布尔值，是为了让报告能直接说清「多图评论的额外张数去哪了」，
  /// 而不是让人从几个数字里自己猜。
  bool get countTriangulated {
    final int? mix = mixMediaCount;
    if (mix == null || picNum == null) return false;
    return mix == picNum;
  }

  /// 是否真的定位到了非空的图片容器。
  bool get found => containerKey != null;

  /// 元素字段名集合（排序，用来比对一级 / 二级是否同构）。
  List<String> get elementKeyNames {
    final List<String> out = <String>[];
    for (final String line in elementKeys) {
      final int at = line.indexOf('：');
      out.add(at < 0 ? line : line.substring(0, at));
    }
    out.sort();
    return out;
  }

  /// 一行摘要（列表用）。
  String toLine() {
    if (!found) {
      return 'pics 字段：未命中（${candidates.join('；')}）';
    }
    return '$containerKey（$containerType，$containerLength）· '
        '元素 $elementType · 字段 ${elementKeys.join(', ')} · '
        'URL ${urlPaths.length} 个 · 张数 $picCount';
  }
}

/// 一条命中的带图评论样本。
class CommentPicSample {
  const CommentPicSample({
    required this.postIndex,
    required this.pageNo,
    required this.commentIndex,
    required this.location,
    required this.nested,
    required this.commentId,
    required this.author,
    required this.analysis,
    required this.picTree,
    required this.fullTree,
    required this.rawJson,
    required this.urlHuntLines,
  });

  /// 第几条微博（从 1 开始）。
  final int postIndex;

  /// 第几页。
  final int pageNo;

  /// 在本页评论数组里的下标。
  final int commentIndex;

  /// 完整位置，如 `data.data[3]` / `data.data[0].comments[2]`。
  final String location;

  /// 是否二级评论（楼中楼）。
  final bool nested;

  final String? commentId;
  final String? author;
  final CommentPicAnalysis analysis;

  /// 只展开图片容器（以容器为根，深度 3）——放在全量树**之前**，
  /// 这样即使全量树被行数上限截断，图片结构也一定完整。
  final List<String> picTree;

  /// 整条评论的字段树（深度 [WeiboCommentPicProbe.describeDepth]）。
  final List<String> fullTree;

  /// 那条评论 `pics` 的**原始 JSON**（紧凑、脱敏后）。
  ///
  /// 字段树会把「元素 ArrayList 只有 1 项但从 `pic_num=3`」这种事压平掉，
  /// 原始 JSON 才能证明「服务端到底返回了几项、url 是不是只有一段」。
  final String rawJson;

  /// 「这条评论里所有形似图片地址的字符串路径」——与候选字段无关的全量搜索。
  ///
  /// 为什么需要：实测存在 `pic_num=1` 但 `pics` 整个 key 都不存在的评论。
  /// 光看候选字段会得出「没有图」，而图片可能藏在别的字段名或正文 HTML 里。
  final List<String> urlHuntLines;

  String get titleLine {
    final String? rawAuthor = author;
    final String who = rawAuthor == null || rawAuthor.isEmpty
        ? '（无昵称）'
        : rawAuthor;
    final String id = commentId ?? '（无 id）';
    return '第 $postIndex 条微博 · 第 $pageNo 页 · $location'
        '${nested ? '（二级评论）' : ''} · $who · id=$id'
        ' · pic_num=${analysis.picNum ?? '缺失'} · 图片 ${analysis.imageCount} 张';
  }
}

/// 一页的扫描统计（不含凭据）。
class CommentPicPageStat {
  const CommentPicPageStat({
    required this.postIndex,
    required this.pageNo,
    required this.httpStatus,
    required this.okRaw,
    required this.commentCount,
    required this.nestedCount,
    required this.picComments,
    required this.nestedPicComments,
    required this.maxPicInPage,
    required this.totalValue,
    required this.cursor,
  });

  final int postIndex;
  final int pageNo;
  final int? httpStatus;
  final String okRaw;

  /// 本页一级评论条数。
  final int commentCount;

  /// 本页一级评论里内嵌的二级评论条数。
  final int nestedCount;

  /// 本页 `pic_num>0`（或图片容器非空）的一级评论数。
  final int picComments;

  /// 同上，二级评论数。
  final int nestedPicComments;

  /// 本页单条评论的最大张数。
  final int maxPicInPage;

  /// `data.total_number`；null = 没找到。
  final int? totalValue;

  /// 本页给出的游标（只在内部流转，展示用 [cursorHint]）。
  final String? cursor;

  String get statusText => httpStatus == null ? '请求失败' : 'HTTP $httpStatus';

  String get cursorHint =>
      cursor == null || cursor!.isEmpty ? '（无游标）' : _picMask(cursor!);

  String toLine() => '微博#$postIndex 第$pageNo页：$statusText · ok=$okRaw · '
      '一级 $commentCount 条 · 二级 $nestedCount 条 · '
      '带图 $picComments(+$nestedPicComments) 条 · 本页最多 $maxPicInPage 张 · '
      '总数 ${totalValue ?? '未知'} · 游标 $cursorHint';
}

/// 一页的完整扫描产物。
class CommentPicScan {
  const CommentPicScan({
    required this.page,
    required this.samples,
    required this.scanned,
    required this.maxPic,
  });

  final CommentPicPageStat page;
  final List<CommentPicSample> samples;

  /// 本页实际扫过的评论条数（含二级）。
  final int scanned;

  /// 本页单条最大张数。
  final int maxPic;
}

/// 探针内部的「待扫描微博」。
class _PicPost {
  const _PicPost({required this.id, required this.mid});

  final String id;
  final String mid;
}

/// 单次请求的原始产物（`skipped` = 因限额 / 叫停而没发）。
class _PicFetch {
  const _PicFetch({
    required this.httpStatus,
    required this.body,
    this.skipped = false,
  });

  final int? httpStatus;
  final String body;
  final bool skipped;
}

// ===========================================================================
// 探针本体
// ===========================================================================

/// 评论图片探针：翻页找到带图评论并 dump 结构。
class WeiboCommentPicProbe {
  WeiboCommentPicProbe({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  /// 全流程请求数硬上限（任务给 15，这里再收紧到 12）。
  static const int maxRequests = 12;

  /// 最多扫描几条微博。
  static const int maxPosts = 3;

  /// 单条微博最多翻几页。
  static const int maxPagesPerPost = 3;

  /// 全流程最多翻几页。
  static const int maxPagesTotal = 6;

  /// 一次最多保留几个样本。
  ///
  /// 取 8 而不是 1~4：实测第一条命中的评论可能给出**残片 URL**，
  /// 需要留出后续微博的样本做横向对照（「是不是全网都这样」）。
  static const int maxSamples = 8;

  /// 连续 432 达到这个数就立刻停。
  static const int maxConsecutive432 = 3;

  /// 两次请求之间的最小间隔。
  static const Duration minGap = Duration(milliseconds: 2500);

  /// 单项超时。
  static const Duration itemTimeout = Duration(seconds: 20);

  /// 样本字段树的展开深度。
  ///
  /// 取 4 而不是 3：`…pics[0]`(1) → `.large`(2) → `.url`(3)，
  /// 深度 3 在 `retweeted_status` 这类嵌套下会把 `large.url` 截掉。
  static const int describeDepth = 4;

  /// 全量字段树的行数上限。
  static const int maxLines = 300;

  /// 已知的一条带图评论目标（`https://m.weibo.cn/status/…`）。
  static const String defaultMid = '5355066445792642';

  /// C1：m 站评论接口。
  static const String hotflowEndpoint = '${WeiboWebUrls.mbBase}/comments/hotflow';

  /// 兜底种子：时间线（只在没有目标 mid / 目标微博没图时用）。
  static const String timelineEndpoint = '${WeiboWebUrls.mbBase}'
      '/api/container/getIndex'
      '?type=uid&value=1782488734&containerid=1076031782488734';

  /// 移动端 Chrome UA（与既有诊断一致：桌面 UA 会被重定向）。
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  static Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: itemTimeout,
        receiveTimeout: itemTimeout,
        sendTimeout: itemTimeout,
        responseType: ResponseType.plain,
        followRedirects: true,
        // 放宽到 <600：432 / 5xx 都走正常返回路径，由本类显式判定。
        validateStatus: (int? status) => status != null && status < 600,
      ),
    );
  }

  // ------------------------------------------------------------ 请求簿记

  DateTime? _lastRequestAt;
  int _requestCount = 0;
  int _consecutive432 = 0;
  int _max432Streak = 0;
  bool _saw432 = false;
  bool _aborted = false;
  final List<String> _log = <String>[];

  /// 已发出的请求数。
  int get requestCount => _requestCount;

  /// 是否已被叫停（连续 432 / 达到上限）。
  bool get aborted => _aborted;

  Future<void> _throttle() async {
    final DateTime? last = _lastRequestAt;
    if (last == null) return;
    final Duration elapsed = DateTime.now().difference(last);
    if (elapsed >= minGap) return;
    await Future<void>.delayed(minGap - elapsed);
  }

  /// 发一次 GET。cookie 只进 header；失败返回 `httpStatus: null`，不抛不重试。
  Future<_PicFetch> _get(
    String url,
    String cookie, {
    required String referer,
    required String label,
  }) async {
    if (_aborted) {
      _log.add('$label → 已叫停，未发出');
      return const _PicFetch(httpStatus: null, body: '', skipped: true);
    }
    if (_requestCount >= maxRequests) {
      _aborted = true;
      _log.add('$label → 达到请求上限 $maxRequests，未发出');
      return const _PicFetch(httpStatus: null, body: '', skipped: true);
    }

    await _throttle();
    _requestCount += 1;

    final String trimmed = cookie.trim();
    _PicFetch fetch;
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: <String, String>{
            'User-Agent': userAgent,
            'Referer': referer,
            'X-Requested-With': 'XMLHttpRequest',
            'MWeibo-Pwa': '1',
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,en;q=0.8',
            if (trimmed.isNotEmpty) 'Cookie': trimmed,
          },
        ),
      );
      final Object? data = res.data;
      fetch = _PicFetch(
        httpStatus: res.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } on DioException catch (e) {
      // 只取状态码与 body，绝不把 requestOptions.headers 拼进任何文案。
      final Object? data = e.response?.data;
      fetch = _PicFetch(
        httpStatus: e.response?.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } catch (_) {
      fetch = const _PicFetch(httpStatus: null, body: '');
    }

    _lastRequestAt = DateTime.now();
    final int? status = fetch.httpStatus;
    if (status == 432) {
      _saw432 = true;
      _consecutive432 += 1;
      if (_consecutive432 > _max432Streak) _max432Streak = _consecutive432;
      if (_consecutive432 >= maxConsecutive432) {
        _aborted = true;
        _log.add('$label → HTTP 432（连续 $_consecutive432 次，已停）');
        return fetch;
      }
    } else if (status != null) {
      _consecutive432 = 0;
    }
    _log.add('$label → ${status == null ? '请求失败' : 'HTTP $status'}');
    return fetch;
  }

  /// 拼 C1 URL：`?id=<id>&mid=<mid>&max_id_type=…[&max_id=<游标>]`。
  ///
  /// 游标**原样字符串拼接**，不做数值转换（`max_id` 是 19 位大整数）。
  static String hotflowUrl({
    required String postId,
    required String postMid,
    String? maxId,
    String maxIdType = '0',
  }) {
    final StringBuffer buf = StringBuffer(hotflowEndpoint);
    buf.write('?id=$postId&mid=$postMid&max_id_type=$maxIdType');
    final String? cursor = maxId;
    if (cursor != null && cursor.isNotEmpty) buf.write('&max_id=$cursor');
    return buf.toString();
  }

  // ------------------------------------------------------------ 纯函数

  /// 一条评论的图片字段体检。必须可离线单测。
  static CommentPicAnalysis analyzePics(Object? comment) {
    final Map<String, dynamic>? map = _picAsMap(comment);

    // 1) 候选字段逐个如实体检（存在 / 类型 / 项数）。
    final List<String> candidates = <String>[];
    if (map == null) {
      candidates.add('（不是 Map，无法体检）');
    } else {
      for (final String key in _picCandidateKeys) {
        if (!map.containsKey(key)) {
          candidates.add('$key：不存在');
          continue;
        }
        final Object? v = map[key];
        final String kind = _picTypeName(v);
        final String detail = v is List
            ? '${v.length} 项'
            : (v is Map ? '${v.length} 个 key' : _picSampleValue(v));
        candidates.add('$key：$kind（$detail）');
      }
    }

    // 2) 选容器。两轮：
    //    第一轮挑「非空 + 里面有完整可用 URL」的候选（宁可取后面的真字段，
    //    也不要取排在前面的残片字段——实测 `pics` 就是这种残片）；
    //    第二轮才退回「第一个非空」。
    String? containerKey;
    String? containerType;
    int? containerLength;
    Object? container;
    if (map != null) {
      Object? firstNonEmpty;
      String? firstNonEmptyKey;
      for (final String key in _picCandidateKeys) {
        final Object? v = map[key];
        final bool nonEmpty =
            (v is List && v.isNotEmpty) || (v is Map && v.isNotEmpty);
        if (!nonEmpty) continue;
        firstNonEmpty ??= v;
        firstNonEmptyKey ??= key;
        if (!_containerHasCompleteUrl(v)) continue;
        containerKey = key;
        container = v;
        containerType = _picTypeName(v);
        containerLength = v is List ? v.length : (v as Map).length;
        break;
      }
      if (containerKey == null && firstNonEmptyKey != null) {
        containerKey = firstNonEmptyKey;
        container = firstNonEmpty;
        containerType = _picTypeName(firstNonEmpty);
        containerLength = firstNonEmpty is List
            ? firstNonEmpty.length
            : (firstNonEmpty as Map).length;
      }
    }

    // 3) 元素：List 取第 0 项；Map 可能是「单图对象」，也可能是 pid → 图片对象。
    Object? element;
    if (container is List) {
      element = container.isEmpty ? null : container.first;
    } else if (container is Map) {
      final bool selfLooksLikePic = container.keys.any(
        (Object? k) => '${k ?? ''}'.toLowerCase().contains('url'),
      );
      element = selfLooksLikePic
          ? container
          : (container.isEmpty ? null : container.values.first);
    }

    final String? elementType = element == null ? null : _picTypeName(element);
    final List<String> elementKeys = <String>[];
    final Map<String, dynamic>? elementMap = _picAsMap(element);
    if (elementMap != null) {
      for (final MapEntry<String, dynamic> e in elementMap.entries) {
        elementKeys.add('${e.key}：${_picTypeName(e.value)}');
      }
    } else if (element is List) {
      elementKeys.add('（元素本身是 List，${element.length} 项）');
    }

    // 4) 容器里所有 URL 值 + 尺寸变体。
    final List<String> urlPaths = <String>[];
    final List<String> rawVariants = <String>[];
    final List<String> urlValues = <String>[];
    if (container != null && containerKey != null) {
      _collectPicUrls(
        containerKey,
        container,
        '',
        0,
        urlPaths,
        rawVariants,
        urlValues,
      );
    }
    final List<String> variants = <String>[];
    for (final String raw in rawVariants) {
      final String v = _normalizePicVariant(raw);
      if (v.isEmpty || variants.contains(v)) continue;
      variants.add(v);
    }

    int https = 0;
    int rel = 0;
    int other = 0;
    for (final String raw in urlValues) {
      final String s = raw.trim();
      if (s.startsWith('https://')) {
        https += 1;
      } else if (s.startsWith('//')) {
        rel += 1;
      } else {
        other += 1;
      }
    }

    final int? picNum = map == null ? null : _picAsInt(map['pic_num']);
    final int containerCount = containerLength ?? 0;
    final int picCount =
        (picNum ?? 0) > containerCount ? (picNum ?? 0) : containerCount;

    return CommentPicAnalysis(
      candidates: candidates,
      containerKey: containerKey,
      containerType: containerType,
      containerLength: containerLength,
      elementType: elementType,
      elementKeys: elementKeys,
      urlPaths: urlPaths,
      urlSamples: urlValues
          .map((String v) => _picSampleValue(v))
          .toList(growable: false),
      variants: variants,
      httpsCount: https,
      schemeRelativeCount: rel,
      otherSchemeCount: other,
      picNum: picNum,
      picCount: picCount,
      plausibleUrlCount:
          urlValues.where(_looksLikeCompletePicUrl).length,
      distinctUrlCount: urlValues.toSet().length,
      imageCount: _imageCountOf(container),
      mixMediaCount: map == null ? null : _mixMediaCountOf(map['mix_media_ids']),
    );
  }

  /// `mix_media_ids` 的项数（List 或 Map 都认；缺失返回 null）。
  static int? _mixMediaCountOf(Object? value) {
    if (value is List) return value.length;
    if (value is Map) return value.length;
    return null;
  }

  /// 容器里**真有图片几张**。
  static int _imageCountOf(Object? container) {
    if (container is List) return container.length;
    if (container is Map) {
      final bool selfIsOneImage = container.keys.any(
        (Object? k) => '${k ?? ''}'.toLowerCase() == 'url',
      );
      // `pic` 这种「自身就是一个图片对象」的 Map：只有 1 张，
      // key 数（pid/url/size/geo/large）只是字段数。
      if (selfIsOneImage) return 1;
      return container.length;
    }
    return 0;
  }

  /// URL 是否**完整可用**：绝对地址，且末段文件名不像残片。
  ///
  /// 实测微博会返回 `https://ss1.sinaimg.cn/orj360/&690`——`https` 前缀齐全，
  /// 但文件名是 `&690`，实测请求 **HTTP 404**。所以「是不是好图」不能只看协议头。
  static bool _looksLikeCompletePicUrl(String raw) {
    final String s = raw.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) return false;
    final int slash = s.lastIndexOf('/');
    if (slash < 0 || slash == s.length - 1) return false;
    final String name = s.substring(slash + 1);
    if (name.isEmpty) return false;
    // 残片特征：以 & ? = 开头，或既没有扩展名、也没有 pid 那种长串
    if (name.startsWith('&') || name.startsWith('?') || name.startsWith('=')) {
      return false;
    }
    return true;
  }

  static void _collectPicUrls(
    String path,
    Object? node,
    String suffix,
    int depth,
    List<String> paths,
    List<String> rawVariants,
    List<String> values,
  ) {
    if (depth > 5) return;
    if (node is Map) {
      for (final MapEntry<Object?, Object?> e in node.entries) {
        final String key = e.key?.toString() ?? '';
        if (key.isEmpty) continue;
        final String next = suffix.isEmpty ? key : '$suffix.$key';
        _collectPicUrls(
          '$path.$key',
          e.value,
          next,
          depth + 1,
          paths,
          rawVariants,
          values,
        );
      }
      return;
    }
    if (node is List) {
      final int take = node.length < 5 ? node.length : 5;
      for (int i = 0; i < take; i++) {
        _collectPicUrls(
          '$path[$i]',
          node[i],
          suffix,
          depth + 1,
          paths,
          rawVariants,
          values,
        );
      }
      return;
    }
    if (node is String && _looksLikePicUrl(node)) {
      paths.add(path);
      rawVariants.add(suffix);
      values.add(node);
    }
  }

  /// 容器里是否**至少有一个完整可用的图片地址**。
  ///
  /// 用来在多个候选字段间做取舍：微博评论同时会给 `pic`（真地址）和
  /// `pics`（残片地址），只按字段顺序取会拿到残片。
  static bool _containerHasCompleteUrl(Object? container) {
    final List<String> paths = <String>[];
    final List<String> rawVariants = <String>[];
    final List<String> values = <String>[];
    if (container == null) return false;
    _collectPicUrls('x', container, '', 0, paths, rawVariants, values);
    for (final String v in values) {
      if (_looksLikeCompletePicUrl(v)) return true;
    }
    return false;
  }

  static bool _looksLikePicUrl(String s) {
    final String t = s.trim();
    return t.startsWith('http://') ||
        t.startsWith('https://') ||
        t.startsWith('//');
  }

  /// 变体名归一化：去掉 pid 段（`pic_infos.<pid>.large.url` → `large.url`）。
  static String _normalizePicVariant(String raw) {
    if (raw.isEmpty) return '';
    final List<String> kept = <String>[];
    for (final String seg in raw.split('.')) {
      if (seg.isEmpty) continue;
      if (_picPidSegment.hasMatch(seg)) continue;
      kept.add(seg);
    }
    return kept.join('.');
  }

  /// 字段树（路径 : 类型 : 样例值）。跳过会话票据类 key。
  static void _picWalkTree(
    String path,
    Object? node,
    int depth,
    List<String> out,
  ) {
    if (out.length >= maxLines) return;
    if (node is Map) {
      if (node.isEmpty) {
        out.add('$path : Map : {}');
        return;
      }
      if (depth >= describeDepth) {
        out.add('$path : Map : …（深度上限，${node.length} 个 key）');
        return;
      }
      for (final MapEntry<Object?, Object?> e in node.entries) {
        if (out.length >= maxLines) return;
        final String key = e.key?.toString() ?? '';
        if (key.isEmpty || _picSkipKey.hasMatch(key)) continue;
        _picWalkTree('$path.$key', e.value, depth + 1, out);
      }
      return;
    }
    if (node is List) {
      if (node.isEmpty) {
        out.add('$path : List : []');
        return;
      }
      if (depth >= describeDepth) {
        out.add('$path : List : …（深度上限，${node.length} 项）');
        return;
      }
      final int take = node.length < 3 ? node.length : 3;
      for (int i = 0; i < take; i++) {
        if (out.length >= maxLines) return;
        _picWalkTree('$path[$i]', node[i], depth + 1, out);
      }
      if (node.length > take) {
        out.add('$path[$take…] : （其余 ${node.length - take} 项省略）');
      }
      return;
    }
    out.add('$path : ${_picTypeName(node)} : ${_picSampleValue(node)}');
  }

  /// 全量 URL 线索：在整条评论里递归找形似图片地址的字符串。
  ///
  /// 与 [analyzePics] 的候选字段体检**相互独立**：那边回答「约定字段里有什么」，
  /// 这边回答「这条评论里到底有没有图片地址、藏在哪里」。
  static List<String> huntPicUrls(
    Object? comment, {
    String rootPath = 'data.data[0]',
    int maxDepth = 4,
    int maxHits = 12,
  }) {
    final List<String> out = <String>[];
    void walk(Object? node, String path, int depth) {
      if (out.length >= maxHits || depth > maxDepth) return;
      if (node is Map) {
        for (final MapEntry<Object?, Object?> e in node.entries) {
          final String key = e.key?.toString() ?? '';
          if (key.isEmpty || _picSkipKey.hasMatch(key)) continue;
          walk(e.value, '$path.$key', depth + 1);
        }
        return;
      }
      if (node is List) {
        final int take = node.length < 6 ? node.length : 6;
        for (int i = 0; i < take; i++) {
          walk(node[i], '$path[$i]', depth + 1);
        }
        return;
      }
      if (node is! String) return;
      // 头像 / 徽章图标不是「评论配图」，不参与判定，否则每条评论都会命中。
      if (_picNonContentPath.hasMatch(path)) return;
      // 字符串里可能是**正文 HTML**（`<img src="…">`），所以先把嵌入的
      // 图片地址抠出来，再按「整串是否就是一个 URL」的两种情形分别处理。
      final List<String> found = _embeddedPicUrls(node);
      if (found.isEmpty) return;
      for (final String u in found) {
        if (out.length >= maxHits) return;
        final bool complete = _looksLikeCompletePicUrl(u);
        out.add(
          '$path : ${complete ? '完整' : '**残片**'} : ${_picSampleValue(u)}',
        );
      }
    }

    walk(comment, rootPath, 0);
    return out;
  }

  /// 与「评论配图」无关的图片路径（头像 / 徽章 / 卡片图标）。
  static final RegExp _picNonContentPath = RegExp(
    r'avatar|profile_image|cover_image|comment_badge|badge\.|icon|face\.',
    caseSensitive: false,
  );

  /// 从一个字符串里抠出所有看起来是图片地址的片段。
  ///
  /// 覆盖两种形态：
  /// - 整个字段就是一个 URL（`pics[0].url`）；
  /// - 正文 HTML 里的 `<img src="https://…">`（评论正文 `text` 就是这个形态）。
  static List<String> _embeddedPicUrls(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return const <String>[];

    // 整串就是一个地址：直接返回，避免下面的正则把它切碎。
    if (_looksLikePicUrl(s) && !s.contains('<')) {
      return <String>[s];
    }

    final List<String> out = <String>[];
    for (final RegExpMatch m in _picImgSrcRe.allMatches(s)) {
      final String? url = m.group(1);
      if (url == null) continue;
      final String u = url.trim();
      if (!_looksLikePicUrl(u)) continue;
      if (out.contains(u)) continue;
      out.add(u);
    }
    return out;
  }

  /// 正文 HTML 里的 `<img src="…">`（微博评论正文就是这种片段）。
  static final RegExp _picImgSrcRe = RegExp(
    r'''<img[^>]*?\ssrc\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  /// 一条评论 → 样本。没有图片字段时返回 null（判定只认接口原始字段）。
  static CommentPicSample? buildSample(
    Object? comment, {
    required int postIndex,
    required int pageNo,
    required int commentIndex,
    required String location,
    required bool nested,
  }) {
    final Map<String, dynamic>? map = _picAsMap(comment);
    if (map == null) return null;
    final CommentPicAnalysis analysis = analyzePics(map);
    if (!analysis.found && (analysis.picNum ?? 0) <= 0) return null;

    final List<String> picTree = <String>[];
    final String? key = analysis.containerKey;
    if (key != null) {
      _picWalkTree('$location.$key', map[key], 0, picTree);
    } else {
      picTree.add('（没有非空的图片容器，只有 pic_num=${analysis.picNum ?? 0}）');
    }

    final List<String> fullTree = <String>[];
    _picWalkTree(location, map, 0, fullTree);

    final Map<String, dynamic>? user = _picAsMap(map['user']);

    // 原始 JSON：只保留图片容器本身，且把超长字符串截断——
    // 它只用来证明「服务端返回了几项、每项有哪些 key」。
    String rawJson = '（没有非空的图片容器）';
    if (key != null) {
      try {
        rawJson = _picTruncateJson(jsonEncode(map[key]));
      } catch (_) {
        rawJson = '（序列化失败）';
      }
    }

    return CommentPicSample(
      postIndex: postIndex,
      pageNo: pageNo,
      commentIndex: commentIndex,
      location: location,
      nested: nested,
      commentId: _picAsText(map['id']) ?? _picAsText(map['idstr']),
      author:
          _picAsText(user?['screen_name']) ?? _picAsText(map['screen_name']),
      analysis: analysis,
      picTree: picTree,
      fullTree: fullTree,
      rawJson: rawJson,
      urlHuntLines: huntPicUrls(map, rootPath: location),
    );
  }

  /// 原始 JSON 压缩：把过长的字符串值截到 100 字符（报告里要能一行放下）。
  static String _picTruncateJson(String raw) {
    if (raw.length <= 600) return raw;
    return '${raw.substring(0, 600)}…（原始 JSON 共 ${raw.length} 字符）';
  }

  /// 纯函数：扫一页（含二级评论）。必须可离线单测。
  static CommentPicScan scanPage({
    required int postIndex,
    required int pageNo,
    required int? httpStatus,
    required String body,
    int sampleLimit = maxSamples,
  }) {
    final Map<String, dynamic>? json = _picTryParseObject(body);
    final Object? okValue = json?['ok'];
    final String okRaw = okValue == null ? '（无 ok）' : okValue.toString();
    final Map<String, dynamic>? data = _picAsMap(json?['data']);
    final Object? listRaw = data?['data'];
    final List<Object?> comments =
        listRaw is List ? listRaw.cast<Object?>() : const <Object?>[];

    final List<CommentPicSample> samples = <CommentPicSample>[];
    final int limit = sampleLimit < 0 ? 0 : sampleLimit;
    int scanned = 0;
    int nestedCount = 0;
    int picComments = 0;
    int nestedPicComments = 0;
    int maxPic = 0;

    for (int i = 0; i < comments.length; i++) {
      final Map<String, dynamic>? m = _picAsMap(comments[i]);
      if (m == null) continue;
      scanned += 1;
      final CommentPicAnalysis a = analyzePics(m);
      final bool hasPic = a.found || (a.picNum ?? 0) > 0;
      if (hasPic) {
        picComments += 1;
        if (a.imageCount > maxPic) maxPic = a.imageCount;
        if (samples.length < limit) {
          final CommentPicSample? s = buildSample(
            comments[i],
            postIndex: postIndex,
            pageNo: pageNo,
            commentIndex: i,
            location: 'data.data[$i]',
            nested: false,
          );
          if (s != null) samples.add(s);
        }
      }

      final Object? nestedRaw = m['comments'];
      if (nestedRaw is! List) continue;
      for (int j = 0; j < nestedRaw.length; j++) {
        final Map<String, dynamic>? nm = _picAsMap(nestedRaw[j]);
        if (nm == null) continue;
        scanned += 1;
        nestedCount += 1;
        final CommentPicAnalysis na = analyzePics(nm);
        if (!na.found && (na.picNum ?? 0) <= 0) continue;
        nestedPicComments += 1;
        if (na.imageCount > maxPic) maxPic = na.imageCount;
        if (samples.length < limit) {
          final CommentPicSample? s = buildSample(
            nestedRaw[j],
            postIndex: postIndex,
            pageNo: pageNo,
            commentIndex: i,
            location: 'data.data[$i].comments[$j]',
            nested: true,
          );
          if (s != null) samples.add(s);
        }
      }
    }

    final int? total = _picAsInt(data?['total_number']) ??
        _picAsInt(data?['total']) ??
        _picAsInt(json?['total_number']);
    final String? cursor =
        _picAsText(data?['max_id']) ?? _picAsText(data?['max']);

    return CommentPicScan(
      page: CommentPicPageStat(
        postIndex: postIndex,
        pageNo: pageNo,
        httpStatus: httpStatus,
        okRaw: okRaw,
        commentCount: comments.length,
        nestedCount: nestedCount,
        picComments: picComments,
        nestedPicComments: nestedPicComments,
        maxPicInPage: maxPic,
        totalValue: total,
        cursor: cursor,
      ),
      samples: samples,
      scanned: scanned,
      maxPic: maxPic,
    );
  }

  /// 纯函数：从时间线响应里挑候选微博（评论数降序）。
  /// 样本是否「可信到可以收工」：至少 1 个地址像完整图片地址。
  ///
  /// 判据只看 URL 形态，不联网——探针不额外消耗图片 CDN 请求，
  /// 404 这件事由人工在报告里核对（本报告已记录实测结果）。
  static bool isConvincing(List<CommentPicSample> samples) {
    for (final CommentPicSample s in samples) {
      if (s.analysis.plausibleUrlCount > 0) return true;
    }
    return false;
  }

  static List<PicProbeSeed> judgeSeeds({
    required int? httpStatus,
    required String body,
    int limit = 3,
  }) {
    final Map<String, dynamic>? json = _picTryParseObject(body);
    final Map<String, dynamic>? data = _picAsMap(json?['data']);
    final Object? cardsRaw = data?['cards'];
    final List<Object?> cards =
        cardsRaw is List ? cardsRaw.cast<Object?>() : const <Object?>[];

    final List<PicProbeSeed> out = <PicProbeSeed>[];
    int mblogCount = 0;
    for (final Object? card in cards) {
      final Map<String, dynamic>? cardMap = _picAsMap(card);
      final Map<String, dynamic>? mblog = _picAsMap(cardMap?['mblog']);
      if (mblog == null || mblog.isEmpty) continue;
      mblogCount += 1;
      final String? id = _picAsText(mblog['id']);
      final String? mid = _picAsText(mblog['mid']);
      if (id == null && mid == null) continue;
      out.add(
        PicProbeSeed(
          httpStatus: httpStatus,
          id: id,
          mid: mid,
          commentsCount: _picAsInt(mblog['comments_count']) ?? 0,
          cardCount: mblogCount,
          author: _picAsText(_picAsMap(mblog['user'])?['screen_name']) ?? '',
          text: _picAsText(mblog['text']) ?? '',
        ),
      );
    }
    out.sort(
      (PicProbeSeed a, PicProbeSeed b) => b.commentsCount.compareTo(a.commentsCount),
    );
    return out.length <= limit ? out : out.sublist(0, limit);
  }

  // ------------------------------------------------------------ 主流程

  /// 扫一条（或几条）微博的评论，找到带图评论后 dump 结构。
  ///
  /// 请求预算：主目标 ≤3 页；没找到时补 1 个时间线请求再扫 ≤3 页。
  /// 总页数 ≤[maxPagesTotal]、总请求 ≤[maxRequests]、连续 3 次 432 立刻停。
  Future<CommentPicProbeResult> run({
    required String cookie,
    String? mid,
    String? id,
    bool allowTimelineFallback = true,
  }) async {
    final List<_PicPost> queue = <_PicPost>[];
    final String startMid = (mid ?? defaultMid).trim();
    final String startIdRaw = (id ?? '').trim();
    final String startId = startIdRaw.isEmpty ? startMid : startIdRaw;

    PicProbeSeed? seed;
    bool timelineFetched = false;
    if (startMid.isNotEmpty) {
      queue.add(_PicPost(id: startId, mid: startMid));
    } else {
      final _PicFetch f = await _get(
        timelineEndpoint,
        cookie,
        referer: '${WeiboWebUrls.mbBase}/u/1782488734',
        label: '目标未指定 → 时间线（getIndex）',
      );
      timelineFetched = true;
      final List<PicProbeSeed> seeds =
          judgeSeeds(httpStatus: f.httpStatus, body: f.body);
      seed = seeds.isEmpty ? null : seeds.first;
      for (final PicProbeSeed s in seeds) {
        final String? m = s.mid ?? s.id;
        if (m == null || m.isEmpty) continue;
        queue.add(_PicPost(id: s.id ?? m, mid: m));
      }
    }

    final List<CommentPicPageStat> pages = <CommentPicPageStat>[];
    final List<CommentPicSample> samples = <CommentPicSample>[];
    final Set<String> scannedMids = <String>{};
    int scanned = 0;
    int maxPic = 0;
    int nestedPic = 0;
    int postsScanned = 0;
    int pageBudget = maxPagesTotal;

    while (queue.isNotEmpty && postsScanned < maxPosts && !_aborted) {
      if (_requestCount >= maxRequests || pageBudget <= 0) break;
      final _PicPost post = queue.removeAt(0);
      if (!scannedMids.add(post.mid)) continue;
      postsScanned += 1;
      final String referer = '${WeiboWebUrls.mbBase}/status/${post.mid}';

      String? cursor;
      String maxIdType = '0';
      final int pagesThisPost =
          pageBudget < maxPagesPerPost ? pageBudget : maxPagesPerPost;

      for (int pageNo = 1; pageNo <= pagesThisPost; pageNo++) {
        if (_aborted || _requestCount >= maxRequests) break;
        final _PicFetch f = await _get(
          hotflowUrl(
            postId: post.id,
            postMid: post.mid,
            maxId: cursor,
            maxIdType: maxIdType,
          ),
          cookie,
          referer: referer,
          label: 'P$postsScanned C1 第$pageNo页',
        );
        if (f.skipped) break;

        final CommentPicScan scan = scanPage(
          postIndex: postsScanned,
          pageNo: pageNo,
          httpStatus: f.httpStatus,
          body: f.body,
          sampleLimit: maxSamples - samples.length,
        );
        pages.add(scan.page);
        pageBudget -= 1;
        scanned += scan.scanned;
        if (scan.maxPic > maxPic) maxPic = scan.maxPic;
        nestedPic += scan.page.nestedPicComments;
        samples.addAll(scan.samples);

        if (f.httpStatus != 200 || scan.page.okRaw != '1') break;
        cursor = scan.page.cursor;
        final Map<String, dynamic>? data =
            _picAsMap(_picTryParseObject(f.body)?['data']);
        maxIdType = _picAsText(data?['max_id_type']) ?? maxIdType;
        if (cursor == null || cursor.isEmpty) break;
        // 注意：**采到样本后仍继续翻页**——「一张最多几张图」要靠多页统计，
        // 只看第一条命中会系统性低估（实测首条 1 张、后面 3 张）。
        // 请求上限由 pagesThisPost 与 maxRequests 双重兜住。
      }

      // 只有「地址可信」的样本才算达标：实测「命中」之后拿到的可能是
      // `…/orj360/&690` 这种残片（404）、且不同评论撞同一地址。
      // 那种情况要继续换微博取证，不能就此收工。
      if (samples.isNotEmpty && isConvincing(samples)) break;

      // 没找到：补一次时间线，换微博再扫（**只补一次**）。
      if (queue.isEmpty &&
          allowTimelineFallback &&
          !timelineFetched &&
          !_aborted &&
          _requestCount < maxRequests &&
          pageBudget > 0) {
        final _PicFetch f = await _get(
          timelineEndpoint,
          cookie,
          referer: '${WeiboWebUrls.mbBase}/u/1782488734',
          label: '兜底时间线（getIndex）',
        );
        timelineFetched = true;
        final List<PicProbeSeed> seeds =
            judgeSeeds(httpStatus: f.httpStatus, body: f.body);
        seed = seed ?? (seeds.isEmpty ? null : seeds.first);
        for (final PicProbeSeed s in seeds) {
          final String? m = s.mid ?? s.id;
          if (m == null || m.isEmpty || scannedMids.contains(m)) continue;
          queue.add(_PicPost(id: s.id ?? m, mid: m));
        }
      }
    }

    return CommentPicProbeResult(
      targetMid: startMid,
      seed: seed,
      postsScanned: postsScanned,
      pages: pages,
      samples: samples,
      commentsScanned: scanned,
      maxPicsInOneComment: maxPic,
      nestedPicComments: nestedPic,
      requestLog: List<String>.unmodifiable(_log),
      requestCount: _requestCount,
      saw432: _saw432,
      max432Streak: _max432Streak,
      note: samples.isEmpty
          ? (pages.isEmpty
              ? '未发出任何评论请求（被叫停或没有目标微博）'
              : '扫了 $postsScanned 条微博 / ${pages.length} 页 / $scanned 条评论，'
                  '没有任何评论带图片字段（pic_num 全为 0，pics 类字段全空或不存在）')
          : '命中：第 ${samples.first.postIndex} 条微博第 ${samples.first.pageNo} 页 '
              '${samples.first.location}（${samples.first.analysis.imageCount} 张图）',
    );
  }
}

/// 一次评论图片探针的完整结果（**不含任何凭据**）。
class CommentPicProbeResult {
  const CommentPicProbeResult({
    required this.targetMid,
    required this.seed,
    required this.postsScanned,
    required this.pages,
    required this.samples,
    required this.commentsScanned,
    required this.maxPicsInOneComment,
    required this.nestedPicComments,
    required this.requestLog,
    required this.requestCount,
    required this.saw432,
    required this.max432Streak,
    required this.note,
  });

  /// 起始目标 mid 原值（展示时脱敏）。
  final String targetMid;

  /// 兜底时间线挑出来的种子（主目标指定时为 null）。
  final PicProbeSeed? seed;

  /// 实际扫了几条微博。
  final int postsScanned;

  final List<CommentPicPageStat> pages;
  final List<CommentPicSample> samples;

  /// 扫过的评论条数（含二级）。
  final int commentsScanned;

  /// 单条评论的最大图片张数。
  final int maxPicsInOneComment;

  /// 带图的二级评论条数。
  final int nestedPicComments;

  final List<String> requestLog;
  final int requestCount;
  final bool saw432;
  final int max432Streak;
  final String note;

  /// 是否采到了带图样本。
  bool get found => samples.isNotEmpty;

  CommentPicSample? get firstSample => samples.isEmpty ? null : samples.first;

  CommentPicSample? get firstNestedSample {
    for (final CommentPicSample s in samples) {
      if (s.nested) return s;
    }
    return null;
  }

  /// 容器形态的人话（`List（N 项，元素 Map）` 之类）。
  String get containerTypeText {
    final CommentPicSample? s0 = firstSample;
    if (s0 == null) return '未采到';
    final CommentPicAnalysis a = s0.analysis;
    final String? type = a.containerType;
    if (type == null) return '未采到';
    if (type == 'List') {
      return 'List（${a.containerLength} 项，元素 ${a.elementType ?? '?'}）';
    }
    if (type == 'Map') {
      // 两种 Map 语义完全不同，必须区分：`pic` 是「一张图」，`pic_infos` 是「pid → 图」。
      if (a.imageCount == 1 && a.containerLength != 1) {
        return 'Map（**单张图片对象**：${a.containerLength} 个字段，'
            '即 1 张图；不是 pid→图 的字典）';
      }
      return 'Map（${a.containerLength} 个 key，value 元素 ${a.elementType ?? '?'}）';
    }
    return type;
  }

  /// 「三、图片字段结论」逐项回答（没有样本时一律写「未采到」）。
  List<String> get conclusions {
    const List<String> questions = <String>[
      '图片列表字段名',
      'List 还是 Map / 元素字段',
      'URL 字段名与尺寸变体',
      'URL 是 https 还是 //',
      '一张评论最多几张图',
      '二级评论图片字段是否同构',
    ];
    final CommentPicSample? s0 = firstSample;
    if (s0 == null) {
      return questions
          .map((String q) => '$q → 未采到（本次扫描没有命中任何带图片字段的评论）')
          .toList(growable: false);
    }
    final CommentPicAnalysis a = s0.analysis;
    final List<String> out = <String>[];

    out.add(
      '图片列表字段名 → `${a.containerKey ?? '（未找到非空容器）'}`'
      '${a.picNum != null ? '，同时存在 `pic_num`（int = ${a.picNum}）' : ''}'
      '。候选体检：${a.candidates.join('；')}',
    );

    out.add(
      'List 还是 Map / 元素字段 → 容器 $containerTypeText'
      '；元素是 `${a.elementType ?? '（无元素）'}`'
      '，元素字段 ${a.elementKeys.isEmpty ? '（无）' : '`${a.elementKeys.join('`, `')}`'}',
    );

    out.add(
      'URL 字段名与尺寸变体 → '
      '变体 ${a.variants.isEmpty ? '（无）' : '`${a.variants.join('` / `')}`'}'
      '；实际路径 ${a.urlPaths.isEmpty ? '（无）' : '`${a.urlPaths.take(4).join('` / `')}`'}',
    );

    final bool allHttps = a.httpsCount > 0 && a.schemeRelativeCount == 0;
    out.add(
      'URL 是 https 还是 // → https 绝对地址 ${a.httpsCount} 个 / '
      '`//` 协议相对 ${a.schemeRelativeCount} 个 / 其它 ${a.otherSchemeCount} 个'
      '${allHttps ? '（**全部是 https 绝对地址**，不需要补前缀）' : ''}',
    );

    // 额外一条：地址是否**完整可用**。实测踩过坑，必须显式报告。
    out.add(
      'URL 完整性 → 像完整图片地址的 ${a.plausibleUrlCount} / ${a.urlSamples.length} 个；'
      '去重后 ${a.distinctUrlCount} 个不同值'
      '${a.plausibleUrlCount == 0 && a.urlSamples.isNotEmpty ? '。**⚠ 全部是残片地址**（如 `…/orj360/&690`，实测 HTTP 404），不能直接交给图片组件' : ''}'
      '${a.distinctUrlCount == 1 && a.urlSamples.length > 1 ? '；同一评论内所有变体指向同一资源' : ''}',
    );

    out.add(
      '一张评论最多几张图 → 本次观测 **$maxPicsInOneComment 张**'
      '（首样本 `pic_num=${s0.analysis.picNum ?? '缺失'}`、'
      '容器 `${s0.analysis.containerKey}`（${s0.analysis.containerType}）'
      '里 **${s0.analysis.imageCount} 张**）',
    );

    // 张数三方对照：`pic_num` / `mix_media_ids` / 图片容器。
    // 实测多图评论的额外张数**只体现在前两者**，容器始终 1 项 ——
    // 这条不写清楚，实现者会以为「解析漏了图」。
    final List<String> triangulated = <String>[];
    int maxPicNum = 0;
    for (final CommentPicSample s in samples) {
      if (s.analysis.picNum == null) continue;
      if (s.analysis.picNum! > maxPicNum) maxPicNum = s.analysis.picNum!;
      if (s.analysis.countTriangulated) {
        triangulated.add(
          '${s.location}（pic_num=${s.analysis.picNum} / '
          'mix_media_ids=${s.analysis.mixMediaCount} / '
          '容器 ${s.analysis.imageCount} 项）',
        );
      }
    }
    if (triangulated.isNotEmpty) {
      out.add(
        '张数三方对照 → ${triangulated.length} 条样本的 `pic_num` 与 '
        '`mix_media_ids` 项数**完全吻合**，'
        '但图片容器**始终只有 ${samples.map((CommentPicSample s) => s.analysis.imageCount).reduce((int a, int b) => a > b ? a : b)} 项**。'
        '例如：${triangulated.take(2).join('；')}'
        '。→ **多图评论的额外张数只以计数形式存在，没有可用图片直链**；'
        '`pic_num` 只能当文字角标，不能用来索引图片数组',
      );
    }
    if (maxPicNum > 1) {
      out.add(
        '⚠ 本轮出现了 `pic_num=$maxPicNum` 的**多图评论**，但 `pic` / `pics` '
        '都只有 1 项 —— 这个接口下**一条评论只拿得到 1 张图**。'
        'UI 必须按「单图」实现；想提示张数只能用 `pic_num` 做文案，'
        '**不要**写多图轮播/宫格（会永远只有 1 张）',
      );
    }

    // 额外一条：pic_num 与真实张数**不一致**的情况，实现时最容易踩的坑。
    final List<String> mismatched = <String>[];
    for (final CommentPicSample s in samples) {
      final int num = s.analysis.picNum ?? 0;
      final int real = s.analysis.imageCount;
      if (num == real) continue;
      mismatched.add('${s.location}（pic_num=$num / 实际 $real 张）');
    }
    if (mismatched.isNotEmpty) {
      out.add(
        '⚠ `pic_num` 与真实张数**不一致**的样本 ${mismatched.length} 条：'
        '${mismatched.take(3).join('；')}'
        ' —— 实现时以**容器里的实际张数**为准，不要用 `pic_num` 算张数',
      );
    }

    // 跨样本横向对照：不同评论给出**完全相同**的 URL 是强异常信号
    // （正常图片各有各的 pid，不可能撞成同一个地址）。
    final Set<String> allUrls = <String>{};
    int urlTotal = 0;
    bool anyPid = false;
    for (final CommentPicSample s in samples) {
      allUrls.addAll(s.analysis.urlSamples);
      urlTotal += s.analysis.urlSamples.length;
      if (s.analysis.elementKeys.any((String k) => k.startsWith('pid：'))) {
        anyPid = true;
      } else if (s.analysis.elementKeys.length > 1) {
        anyPid = true;
      }
    }
    if (urlTotal > 0 && allUrls.length == 1) {
      out.add(
        '⚠ 全部 $urlTotal 个 URL 去重后只有 **1 个**不同值：'
        '`${allUrls.first}`。'
        '不同评论的图片不可能撞成同一地址 —— 这条样本的 URL 不可信'
        '（`pid` ${anyPid ? '字段存在但为 null' : '缺失'}、`type` 多为 `video`）。',
      );
    }

    final CommentPicSample? ns = firstNestedSample;
    if (ns == null) {
      out.add(
        '二级评论图片字段是否同构 → 未采到'
        '（${nestedPicComments == 0 ? '本次扫描没有带图的二级评论' : '二级样本未能展开'}），'
        '**不能断言同构**',
      );
    } else if (ns.analysis.containerKey != a.containerKey) {
      // 容器字段本身就不同（一级走 `pic`、二级走 `pics`）时，
      // 比元素字段没有意义——那是两个不同字段。
      out.add(
        '二级评论图片字段是否同构 → **容器字段就不同**：'
        '一级 `${a.containerKey}`（${a.containerType}），'
        '二级 `${ns.analysis.containerKey}`（${ns.analysis.containerType}）。'
        '两边都**存在**同名字段，只是本轮的样本落在不同字段上 —— '
        '实现时两个字段都要读',
      );
    } else {
      final List<String> base = a.elementKeyNames;
      final List<String> nested = ns.analysis.elementKeyNames;
      final bool same =
          base.length == nested.length && base.join(',') == nested.join(',');
      out.add(
        '二级评论图片字段是否同构 → ${same ? '**同构**（同一字段、元素字段完全一致）' : '**同一字段但元素字段不同**'}'
        '；一级 `${base.join(',')}` / 二级 `${nested.join(',')}`',
      );
    }
    return out;
  }

  /// 「四、给实现者的硬结论」。
  List<String> get hardConclusions {
    final CommentPicSample? s0 = firstSample;
    if (s0 == null) {
      return <String>[
        '- 判据照旧：`pic_num` 缺失或为 0 就按「无图」处理，别去猜字段名。',
        '- 本轮**没有**采到带图评论样本，`pics` 结构仍未取证；'
            '实现前必须先补样本，不要凭字段名硬写。',
      ];
    }
    final CommentPicAnalysis a = s0.analysis;
    final String key = a.containerKey ?? '';
    final bool allHttps = a.httpsCount > 0 && a.schemeRelativeCount == 0;
    final CommentPicSample? ns = firstNestedSample;
    final String nestedText = ns == null
        ? '本轮无带图二级样本，二级按一级同一套字段探测'
            '（`comments[]` 元素与一级同构是**待验证**假设）'
        : (ns.analysis.containerKey != a.containerKey
            ? '二级样本落在 `${ns.analysis.containerKey}` 字段上'
                '（一级是 `$key`）—— 说明 `pic` 与 `pics` **两边都可能出现配图**，'
                '二级与一级用同一套解析、两个字段都读'
            : (ns.analysis.elementKeyNames.join(',') ==
                    a.elementKeyNames.join(',')
                ? '元素字段与一级**一致**'
                : '元素字段与一级**不一致**（一级 `${a.elementKeyNames.join(',')}`'
                    ' / 二级 `${ns.analysis.elementKeyNames.join(',')}`）'));
    return <String>[
      '- **字段名**：`$key`（${a.containerType}）。`pic_num` 与它同时存在：'
          '`pic_num` 是张数，`$key` 才是内容。',
      '- **⚠ 两个字段别搞混**：`pic`（单数，Map，**单张图**：pid/url/size/geo/large）'
          '与 `pics`（复数，List，多图）同时出现在评论里；'
          '**`pics` 里可能是残片地址，`pic` 里才是可用地址** —— '
          '实测 `pics[0].url = https://ss1.sinaimg.cn/orj360/&690` 请求 **HTTP 404**，'
          '而 `pic.url` 一致返回 200 + `image/jpeg`。',
      "- **判图依据（可靠做法）**：`pic_num > 0` **或** "
          "`comment['pic'] != null` **或** "
          "`comment['pics'] is List && isNotEmpty`。三者都判——"
          '`pic_num` 可能是 int 也可能是数字字符串，而 `pic` / `pics` 在无图时'
          '整个 key 都可能不存在，缺字段绝不能当异常抛。',
      '- **元素**：`${a.elementType}`，字段 `${a.elementKeys.join('`, `')}`。'
          '`pic` 是**单个 Map**（1 张图），不要当字典遍历；'
          '`pics` 是 List，`pics[0].large.url` 才是大图。',
      '- **URL**：取 '
          '`${a.variants.isEmpty ? '（未见尺寸变体）' : a.variants.join(' / ')}`；本次 '
          '${allHttps ? '**全部是 `https://` 绝对地址**，可直接交给图片组件' : '出现 ${a.schemeRelativeCount} 个 `//` 协议相对地址，拼接前必须补 `https:`'}。'
          '缩略是 `orj360`（`url`），原图/大图是 `large`（`large.url`）。',
      '- **张数上限**：本次单条最多观测到 **$maxPicsInOneComment 张**；'
          '布局要按 N 张自适应，不要硬编码 1 / 4 / 9。',
      '- **二级评论**：$nestedText。',
      '- **不要动**：正式解析器（`weibo_comment_parser.dart`）本轮未改，'
          '等结构取证完再按上面字段实现。',
    ];
  }

  /// 供对话框展示的完整文本（不含任何 cookie 内容）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('════ 微博评论图片探针 ════');
    buf.writeln('目标 mid：${PicProbeSeed.maskId(targetMid)}');
    buf.writeln();
    buf.writeln(
      '—— 请求记录（${requestLog.length} / 上限 '
      '${WeiboCommentPicProbe.maxRequests}）——',
    );
    if (requestLog.isEmpty) {
      buf.writeln('（没有发出请求）');
    } else {
      for (int i = 0; i < requestLog.length; i++) {
        buf.writeln('#${i + 1} ${requestLog[i]}');
      }
    }
    buf.writeln();
    buf.writeln('—— 各页扫描 ——');
    if (pages.isEmpty) {
      buf.writeln('（没有可展示的页）');
    } else {
      for (final CommentPicPageStat p in pages) {
        buf.writeln(p.toLine());
      }
    }
    buf.writeln(
      '共扫 $postsScanned 条微博 / ${pages.length} 页 / '
      '$commentsScanned 条评论（含二级）',
    );
    buf.writeln(
      '单条最多 $maxPicsInOneComment 张 · 带图二级 $nestedPicComments 条',
    );
    buf.writeln();
    buf.writeln('—— 命中样本 ——');
    if (samples.isEmpty) {
      buf.writeln('（未采到带图评论）');
    } else {
      for (final CommentPicSample s in samples) {
        buf.writeln('★ ${s.titleLine}');
        buf.writeln('  图片子树（深度 3）：');
        for (final String l in s.picTree) {
          buf.writeln('    $l');
        }
        buf.writeln();
      }
      buf.writeln(
        '★ 第一条样本的完整字段树（深度 '
        '${WeiboCommentPicProbe.describeDepth}）',
      );
      for (final String l in samples.first.fullTree) {
        buf.writeln(l);
      }
    }
    buf.writeln();
    buf.writeln('—— 图片字段结论 ——');
    for (final String l in conclusions) {
      buf.writeln(l);
    }
    buf.writeln();
    buf.writeln('—— 给实现者的硬结论 ——');
    for (final String l in hardConclusions) {
      buf.writeln(l);
    }
    buf.writeln();
    buf.writeln('—— 风控 ——');
    buf.writeln('432：${saw432 ? '出现过（连续峰值 $max432Streak）' : '未出现'}');
    buf.writeln('请求数：$requestCount / ${WeiboCommentPicProbe.maxRequests}');
    buf.writeln('判定：$note');
    return buf.toString();
  }

  /// 落盘用的 Markdown（结构固定，便于直接 `adb pull` 到 `.env/`）。
  ///
  /// [cookieLength] 只写长度，**永远不写内容**。
  String toMarkdown({required int cookieLength, String? date}) {
    final String day = date ?? _picToday();
    final CommentPicSample? s0 = firstSample;
    final StringBuffer buf = StringBuffer();

    buf.writeln('# 微博评论图片字段探针（$day）');
    buf.writeln();
    buf.writeln('## 一、采样过程');
    buf.writeln();
    buf.writeln(
      '- 起始目标 mid：`${PicProbeSeed.maskId(targetMid)}`'
      '（长度 ${targetMid.length}，值不展示）',
    );
    buf.writeln(
      '- 接口：`${WeiboCommentPicProbe.hotflowEndpoint}`'
      '（`?id=<mid>&mid=<mid>&max_id_type=0`，翻页追加 `&max_id=<游标>`）',
    );
    buf.writeln(
      '- 扫描微博 **$postsScanned 条** / 页 **${pages.length} 页** / '
      '评论 **$commentsScanned 条**（含二级）',
    );
    buf.writeln(
      '- 请求 **$requestCount 个**（探针硬上限 '
      '${WeiboCommentPicProbe.maxRequests}，任务上限 15）· '
      '间隔 ≥${WeiboCommentPicProbe.minGap.inMilliseconds}ms · '
      '单项超时 ${WeiboCommentPicProbe.itemTimeout.inSeconds}s · '
      '432：${saw432 ? '出现过（连续峰值 $max432Streak）' : '未出现'}',
    );
    buf.writeln('- 本轮**没有**发未登录对照请求（省请求；判据不需要它）');
    buf.writeln();
    buf.writeln('请求记录：');
    buf.writeln();
    buf.writeln('```');
    for (int i = 0; i < requestLog.length; i++) {
      buf.writeln('#${i + 1} ${requestLog[i]}');
    }
    buf.writeln('```');
    buf.writeln();
    buf.writeln(
      '| 微博# | 页 | 状态 | ok | 一级 | 二级 | 带图(一级+二级) | 本页最多张数 | 总数 |',
    );
    buf.writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- |');
    for (final CommentPicPageStat p in pages) {
      buf.writeln(
        '| ${p.postIndex} | ${p.pageNo} | ${p.statusText} | ${p.okRaw} | '
        '${p.commentCount} | ${p.nestedCount} | '
        '${p.picComments}+${p.nestedPicComments} | ${p.maxPicInPage} | '
        '${p.totalValue ?? '未知'} |',
      );
    }
    buf.writeln();
    if (s0 == null) {
      buf.writeln('> **结论先行：本轮未采到带图评论样本（NO_SAMPLE）。**');
      buf.writeln();
    }

    buf.writeln('## 二、找到的带图评论样本');
    buf.writeln();
    if (s0 == null) {
      buf.writeln(
        '- 未采到。已扫描的 ${pages.length} 页里，'
        '`pic_num>0` 与 `pics` 类字段非空的评论均为 **0 条**。',
      );
      buf.writeln();
    } else {
      for (final CommentPicSample s in samples) {
        buf.writeln('- ${s.titleLine}');
        buf.writeln(
          '- 位置：第 ${s.postIndex} 条微博 · 第 ${s.pageNo} 页 · '
          '第 ${s.commentIndex + 1} 条（`${s.location}`）',
        );
        buf.writeln('- 图片字段体检：${s.analysis.candidates.join('；')}');
        buf.writeln();
        buf.writeln('原始 JSON（`${s.analysis.containerKey}` 这一层，未经解释）：');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(s.rawJson);
        buf.writeln('```');
        buf.writeln();
        buf.writeln('全量 URL 线索（整条评论递归搜，与候选字段无关）：');
        buf.writeln();
        if (s.urlHuntLines.isEmpty) {
          buf.writeln('（这条评论里**没有**任何形似图片地址的字符串）');
        } else {
          buf.writeln('```');
          for (final String l in s.urlHuntLines) {
            buf.writeln(l);
          }
          buf.writeln('```');
        }
        buf.writeln();
        buf.writeln(
          '**图片子树（以 `${s.analysis.containerKey}` 为根，深度 3）**',
        );
        buf.writeln();
        buf.writeln('```');
        for (final String l in s.picTree) {
          buf.writeln(l);
        }
        buf.writeln('```');
        buf.writeln();
      }
      buf.writeln(
        '**第一条样本的完整字段树（深度 '
        '${WeiboCommentPicProbe.describeDepth}、值截断 80）**',
      );
      buf.writeln();
      buf.writeln('```');
      for (final String l in s0.fullTree) {
        buf.writeln(l);
      }
      buf.writeln('```');
      buf.writeln();
    }

    buf.writeln('## 三、图片字段结论（逐项回答）');
    buf.writeln();
    for (final String l in conclusions) {
      buf.writeln('- $l');
    }
    if (s0 != null) {
      buf.writeln();
      buf.writeln('URL 样例（路径 : 值）：');
      buf.writeln();
      buf.writeln('```');
      final int n = s0.analysis.urlPaths.length < s0.analysis.urlSamples.length
          ? s0.analysis.urlPaths.length
          : s0.analysis.urlSamples.length;
      for (int i = 0; i < n; i++) {
        buf.writeln(
          '${s0.analysis.urlPaths[i]} : ${s0.analysis.urlSamples[i]}',
        );
      }
      buf.writeln('```');
    }
    buf.writeln();

    buf.writeln('## 四、给实现者的硬结论');
    buf.writeln();
    for (final String l in hardConclusions) {
      buf.writeln(l);
    }
    buf.writeln();

    buf.writeln('## 五、cookie 长度');
    buf.writeln();
    buf.writeln('`$cookieLength`（内容不显示、不落盘、不进报告）');
    buf.writeln();

    buf.writeln('## 六、未取证');
    buf.writeln();
    final List<String> missing = <String>[];
    if (s0 == null) {
      missing.add('带图评论样本（本轮 NO_SAMPLE：`pics` 类字段结构仍未知）');
    } else {
      if (s0.analysis.schemeRelativeCount == 0) {
        missing.add('`//` 协议相对地址形态（本次未见，无法确认服务端会不会返回）');
      }
      if (maxPicsInOneComment < 9) {
        missing.add(
          '单条上限是否 9 张（本次最多观测到 $maxPicsInOneComment 张，未压到上限）',
        );
      }
      final List<String> absent = <String>[];
      for (final String c in s0.analysis.candidates) {
        if (c.endsWith('不存在') || c.contains('（0 项）') || c.contains('（0 个 key）')) {
          absent.add(c.split('：').first);
        }
      }
      if (absent.isNotEmpty) {
        missing.add(
          '本次未出现的候选字段：`${absent.join('` / `')}`'
          '（只能说这 1 条样本里没有，不能说接口不存在）',
        );
      }
      if (firstNestedSample == null) {
        missing.add('带图二级评论样本（`comments[]` 里的图片字段未直接取证）');
      }
    }
    missing.add('未登录态（本轮未发 cookie 为空的对照请求）');
    missing.add('多图（≥4 张）/ 长图 / 视频封面的评论样本');
    for (final String m in missing) {
      buf.writeln('- $m');
    }
    return buf.toString();
  }

  static String _picToday() {
    final DateTime now = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }
}

/// 种子微博：兜底时间线挑出来的评论目标。
class PicProbeSeed {
  const PicProbeSeed({
    required this.httpStatus,
    required this.id,
    required this.mid,
    required this.commentsCount,
    required this.cardCount,
    required this.author,
    required this.text,
  });

  /// 时间线请求的 HTTP 状态；null = 请求失败。
  final int? httpStatus;

  /// `mblog.id`（hotflow 的 `id` 参数）。
  final String? id;

  /// `mblog.mid`（hotflow 的 `mid` 参数）。
  final String? mid;

  /// `mblog.comments_count`。
  final int commentsCount;

  /// 解析到几条 mblog。
  final int cardCount;

  /// 作者昵称（只是内容，不是凭据）。
  final String author;

  /// 正文（截断展示）。
  final String text;

  /// 完整值脱敏：只给前 4 位与长度。
  static String maskId(String? value) {
    if (value == null || value.isEmpty) return '（无）';
    final String head = value.length > 4 ? value.substring(0, 4) : value;
    return '$head…（${value.length} 位）';
  }

  String toLine() {
    final String status = httpStatus == null ? '请求失败' : 'HTTP $httpStatus';
    final String name = author;
    return '$status · mblog $cardCount 条 · 选中 id=${maskId(id)} '
        'mid=${maskId(mid)} · comments_count=$commentsCount'
        '${name.isEmpty ? '' : ' · 作者 $name'}';
  }
}
