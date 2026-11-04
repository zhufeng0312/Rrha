/// 微博**视频直链**探针（纯诊断，不是正式数据层）。
///
/// ## 为什么需要它
///
/// 视频直链挂在 `mblog.page_info.media_info`，但历史采样（31 条 mblog、
/// 8 条 `page_info`）里 **`media_info` 一次都没出现过**，全是 `webpage` /
/// `topic` 卡。所以 `weibo_parser.dart` 的 `_videoRefOf` 目前是**按候选键名猜的**，
/// 从未被真实样本验证过。
///
/// 本探针用 App 内 WebView 的登录 cookie 打真实视频，把
/// 「字段到底叫什么、直链要不要 Referer、封面/时长在哪」一次性钉死。
///
/// ## 请求纪律（硬上限，调用方改不动）
///
/// 间隔 ≥2.5s · 总请求 ≤[WeiboVideoProbe.maxRequests] · 单项超时 20s ·
/// **不重试**、**不做任何风控绕过**。
///
/// ## 凭据安全（硬约束）
///
/// cookie 只作为请求头出现：不进日志、不进结果对象、不进异常文案、不落盘。
/// 落盘的 Markdown 里只写 cookie **长度**。URL 一律脱敏（参数值全部打掉）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/content_item.dart';
import '../models/subscription.dart';
import '../models/video_ref.dart';
import 'weibo_parser.dart';

/// 移动端 UA：桌面 UA 会被微博重定向到 Visitor System。
const String _mobileUa =
    'Mozilla/5.0 (Linux; Android 16; BKQ-AN10) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Version/4.0 Chrome/120.0 Mobile Safari/537.36';

/// 一个探针结果。
class WeiboVideoProbeResult {
  const WeiboVideoProbeResult({
    required this.steps,
    required this.findings,
    required this.videoUrlKeys,
    required this.fieldTree,
  });

  /// 结论的输出顺序。
  ///
  /// `E2E` 排在最后：它是「把命中样本喂给真实解析器」的端到端结论，
  /// 必须紧跟在 Q1~Q6 之后才看得懂因果。
  static const List<String> _questionOrder = <String>[
    'Q1',
    'Q2',
    'Q3',
    'Q4',
    'Q5',
    'Q6',
    'E2E',
    'HIT',
  ];

  /// 每步一行：`T1 GET … → HTTP 200 · JSON · ok=1`。
  final List<String> steps;

  /// `Q1`..`Q6` → 结论。
  final Map<String, String> findings;

  /// 探到的「像视频地址」的字段路径。
  final List<String> videoUrlKeys;

  /// 摊平后的字段树（已脱敏）。
  final List<String> fieldTree;

  /// 面板展示用纯文本。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('=== 结论 ===');
    for (final String q in _questionOrder) {
      if (!findings.containsKey(q)) continue;
      buf.writeln('$q：${findings[q]}');
    }
    buf.writeln();
    buf.writeln('=== 视频地址候选字段 ===');
    if (videoUrlKeys.isEmpty) {
      buf.writeln('（无）');
    } else {
      for (final String k in videoUrlKeys) {
        buf.writeln('· $k');
      }
    }
    buf.writeln();
    buf.writeln('=== 请求过程 ===');
    for (final String s in steps) {
      buf.writeln(s);
    }
    if (fieldTree.isNotEmpty) {
      buf.writeln();
      buf.writeln('=== 字段树 ===');
      for (final String line in fieldTree) {
        buf.writeln(line);
      }
    }
    return buf.toString();
  }

  /// 落盘用 Markdown。**只写 cookie 长度**。
  String toMarkdown({required int cookieLength}) {
    final StringBuffer buf = StringBuffer();
    buf.writeln('# 微博视频直链探针报告');
    buf.writeln();
    buf.writeln('cookie 长度：$cookieLength（内容不记录）');
    buf.writeln();
    buf.writeln('## 结论');
    buf.writeln();
    for (final String q in _questionOrder) {
      if (!findings.containsKey(q)) continue;
      buf.writeln('- **$q**：${findings[q]}');
    }
    buf.writeln();
    buf.writeln('## 视频地址候选字段');
    buf.writeln();
    if (videoUrlKeys.isEmpty) {
      buf.writeln('（无）');
    } else {
      for (final String k in videoUrlKeys) {
        buf.writeln('- `$k`');
      }
    }
    buf.writeln();
    buf.writeln('## 请求过程');
    buf.writeln();
    buf.writeln('```');
    for (final String s in steps) {
      buf.writeln(s);
    }
    buf.writeln('```');
    if (fieldTree.isNotEmpty) {
      buf.writeln();
      buf.writeln('## 字段树');
      buf.writeln();
      buf.writeln('```');
      for (final String line in fieldTree) {
        buf.writeln(line);
      }
      buf.writeln('```');
    }
    return buf.toString();
  }
}

/// 微博视频直链探针。
class WeiboVideoProbe {
  WeiboVideoProbe({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 20),
                // 432 等状态码要走正常返回路径，由本类显式判定。
                validateStatus: (int? s) => s != null && s < 500,
              ),
            );

  final Dio _dio;

  /// 硬上限：总请求数。
  static const int maxRequests = 6;

  /// 请求间隔。
  static const Duration gap = Duration(milliseconds: 2500);

  /// 默认 fid（用户提供的真实样本）。
  static const String defaultFid = '1034:5358370303967334';

  int _used = 0;
  DateTime? _lastAt;

  Future<WeiboVideoProbeResult> run({
    required String cookie,
    String fid = defaultFid,
    String? uid,
    /// 命中样本时把**真实解析结果**交出去（诊断面板据此提供
    /// 「打开这条视频详情页」按钮，用于真机验证整条链路）。
    void Function(ContentItem item)? onHitItem,
  }) async {
    final List<String> steps = <String>[];
    final Map<String, String> findings = <String, String>{};
    final List<String> videoUrlKeys = <String>[];
    final List<String> fieldTree = <String>[];

    final String trimmed = cookie.trim();
    final String digits = fid.contains(':') ? fid.split(':').last : fid;

    Object? mblogJson;
    Object? playinfoJson;
    Object? pageInfoFromTimeline;
    Map<Object?, Object?>? hitMblog;

    // ---- T1：从**产品实际使用的接口**扫真实视频微博 ----
    //
    // 为什么不再靠 fid 猜 id：实测 `statuses/show?id=<16 位>` 与
    // `?id=<整串 fid>` 都返回 `ok=0`（该 id 不在这套接口的命名空间里），
    // 而 `tv/api/component` 在 m 站 cookie 下返回 **302**（它是主站域接口）。
    // 与其继续猜「这条视频的 mid 是什么」，不如直接翻博主时间线找真的视频微博 ——
    // 那正是 App 拿数据的地方，命中即是可直接复用的样本。
    if (uid != null && uid.isNotEmpty) {
      const String ua = 'Mozilla/5.0';
      for (int page = 0; page < 2; page++) {
        if (_used >= maxRequests) break;
        final String url = page == 0
            ? 'https://m.weibo.cn/api/container/getIndex'
                '?type=uid&value=$uid&containerid=107603$uid'
            : 'https://m.weibo.cn/api/container/getIndex'
                '?type=uid&value=$uid&containerid=107603$uid';
        final Map<String, dynamic>? json = await _getJson(
          url,
          cookie: trimmed,
          referer: 'https://m.weibo.cn/u/$uid',
          tag: 'T1 getIndex 第${page + 1}页（$ua）',
          steps: steps,
        );
        if (json == null) break;
        final Map<Object?, Object?>? found = _findVideoMblog(json);
        if (found != null) {
          hitMblog = found;
          pageInfoFromTimeline = found['page_info'];
          steps.add('T1 → 命中含 page_info 的 mblog ✅');
          break;
        }
        steps.add('T1 第${page + 1}页 → 本页无 page_info');
      }
    }

    // ---- 端到端：把命中样本喂给**真实解析器**，验证卡片拿到的字段 ----
    //
    // 这一步是「探针结论 → 产品行为」的桥梁：前面摊平字段只能证明接口给了什么，
    // 这里才能证明 `WeiboParser` 确实把它取出来了（封面 / 时长 / 直链）。
    if (hitMblog != null) {
      // 把命中的 mid 记下来：要在真机上直接打开这条视频做验证，需要它。
      // mid 是公开标识（就是 status URL 里那串），不含任何凭据。
      final Object? hitMid = hitMblog['mid'] ?? hitMblog['id'];
      if (hitMid != null) {
        findings['HIT'] = 'mid=$hitMid';
      }
      final ContentItem? item = WeiboParser.fromMblog(
        hitMblog,
        sub: Subscription(
          platform: Platform.weibo,
          uid: uid ?? '0',
          routes: const <FeedRoute>{FeedRoute.weiboUser},
          alias: '探针',
          addedAt: DateTime.now().toUtc(),
        ),
        fetchedAt: DateTime.now().toUtc(),
      );
      if (item == null) {
        findings['E2E'] = '❌ 真实解析器返回 null（这条 mblog 被判成脏数据）';
      } else {
        final VideoRef? ref = item.videoRef;
        findings['E2E'] = 'kind=${item.kind.name} · '
            '直链=${ref?.directVideoUrl == null ? '❌ 无' : '✅ 有'} · '
            '封面=${ref?.coverUrl == null ? '❌ 无' : '✅ 有'} · '
            '时长=${ref?.duration?.inSeconds ?? '❌ 无'}s · '
            '竖屏=${ref?.isVertical ?? '未知'}';
        // 交给调用方去做真机验证（打开详情页）。
        onHitItem?.call(item);
      }
    }

    // ---- T2：直接按 mid 查（保留为兜底，日志会如实记 ok/errno）----
    if (pageInfoFromTimeline == null && _used < maxRequests) {
      final Map<String, dynamic>? t2 = await _getJson(
        'https://m.weibo.cn/api/statuses/show?id=$digits',
        cookie: trimmed,
        referer: 'https://m.weibo.cn/',
        tag: 'T2 statuses/show?id=${_mask(digits)}',
        steps: steps,
      );
      mblogJson = _mblogOf(t2);
    }

    // ---- T3：weibo.com/tv/api/component（记录真实跳转）----
    if (pageInfoFromTimeline == null &&
        mblogJson == null &&
        _used < maxRequests) {
      final String page = Uri.encodeComponent('/tv/show/$fid');
      final String body = 'data=${Uri.encodeQueryComponent(
        jsonEncode(<String, Object?>{
          'Component_Play_Playinfo': <String, Object?>{'oid': fid},
        }),
      )}';
      final Map<String, dynamic>? t3 = await _postJson(
        'https://weibo.com/tv/api/component?page=$page',
        body: body,
        cookie: trimmed,
        referer: 'https://weibo.com/tv/show/$fid',
        tag: 'T3 POST tv/api/component',
        steps: steps,
      );
      playinfoJson = _playinfoOf(t3);
      if (playinfoJson is Map && playinfoJson.isNotEmpty) {
        findings['Q6'] = 'component 在有 cookie 时返回 JSON，'
            'Playinfo 共 ${playinfoJson.length} 个 key：'
            '${playinfoJson.keys.take(40).join(', ')}';
      } else {
        findings['Q6'] = t3 == null
            ? '未拿到 JSON（见 steps）'
            : '拿到 JSON 但没有 Component_Play_Playinfo';
      }
    }

    // ---- 摊平字段 ----
    final Object? root = pageInfoFromTimeline ??
        (mblogJson is Map ? mblogJson['page_info'] : null) ??
        playinfoJson;    if (root is Map && root.isNotEmpty) {
      final bool isMediaInfo = root.containsKey('media_info') ||
          root.containsKey('type');
      _flatten(root, isMediaInfo ? 'page_info' : 'Playinfo', fieldTree,
          videoUrlKeys, 0);
      _answerQuestions(root, findings, videoUrlKeys,
          fromComponent: playinfoJson != null && !isMediaInfo);
    } else {
      findings.putIfAbsent('Q1', () => '未拿到含 page_info 的 mblog（见 steps）');
      findings.putIfAbsent('Q2', () => '因 Q1 未打通，无法判定');
      findings.putIfAbsent('Q3', () => '因 Q1 未打通，无法判定');
      findings.putIfAbsent('Q5', () => '因 Q1 未打通，无法判定');
    }

    // ---- Q4：直链可达性 ----
    await _probeDirectLinks(fieldTree, steps, findings, cookie: trimmed);

    return WeiboVideoProbeResult(
      steps: steps,
      findings: findings,
      videoUrlKeys: videoUrlKeys,
      fieldTree: fieldTree,
    );
  }

  // ------------------------------------------------------------------ 内部

  /// 从一页 `getIndex` 响应里找**第一个含 `page_info` 的 mblog**，返回该
  /// **完整 mblog**（不是只返 page_info —— 拿到整条才能顺带跑一次真实解析，
  /// 端到端验证「卡片能否拿到封面/时长/直链」）。找不到返回 null。
  ///
  /// 只认 `page_info` 非空且是 Map 的：`webpage`/`topic` 卡也带 `page_info`，
  /// 但它们同样是**真实样本**（能验证「哪些卡没有 media_info」），所以这里
  /// 不筛 `type`，由 `_answerQuestions` 分层回答。
  Map<Object?, Object?>? _findVideoMblog(Map<String, dynamic> json) {
    final Object? data = json['data'];
    if (data is! Map) return null;
    final Object? cards = data['cards'];
    if (cards is! List) return null;
    for (final Object? card in cards) {
      if (card is! Map) continue;
      final Object? mblog = card['mblog'];
      if (mblog is! Map) continue;
      final Object? pi = mblog['page_info'];
      if (pi is Map && pi.isNotEmpty) return mblog;
    }
    return null;
  }

  /// 从 mblog JSON 里取出 mblog 本体。
  Object? _mblogOf(Map<String, dynamic>? json) {
    if (json == null) return null;
    // `statuses/show` 的正文就是 mblog 本体（有的版本裹一层 data）。
    if (json['page_info'] != null || json['text'] != null) return json;
    final Object? data = json['data'];
    if (data is Map && (data['page_info'] != null || data['text'] != null)) {
      return data;
    }
    return null;
  }

  Object? _playinfoOf(Map<String, dynamic>? json) {
    if (json == null) return null;
    final Object? data = json['data'];
    if (data is Map) {
      final Object? c = data['Component_Play_Playinfo'];
      if (c is Map) return c;
    }
    final Object? c = json['Component_Play_Playinfo'];
    if (c is Map) return c;
    return null;
  }

  Map<String, String> _headers({required String cookie, required String referer}) {
    return <String, String>{
      'User-Agent': _mobileUa,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer,
      'X-Requested-With': 'XMLHttpRequest',
      'MWeibo-Pwa': '1',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
  }

  Future<void> _throttle() async {
    final DateTime? last = _lastAt;
    if (last != null) {
      final Duration elapsed = DateTime.now().difference(last);
      if (elapsed < gap) await Future<void>.delayed(gap - elapsed);
    }
  }

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    required String cookie,
    required String referer,
    required String tag,
    required List<String> steps,
  }) {
    return _request(
      () => _dio.get<dynamic>(
        url,
        options: Options(headers: _headers(cookie: cookie, referer: referer)),
      ),
      tag: tag,
      steps: steps,
    );
  }

  Future<Map<String, dynamic>?> _postJson(
    String url, {
    required String body,
    required String cookie,
    required String referer,
    required String tag,
    required List<String> steps,
  }) {
    return _request(
      () => _dio.post<dynamic>(
        url,
        data: body,
        options: Options(
          headers: <String, String>{
            ..._headers(cookie: cookie, referer: referer),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      ),
      tag: tag,
      steps: steps,
    );
  }

  Future<Map<String, dynamic>?> _request(
    Future<Response<dynamic>> Function() send, {
    required String tag,
    required List<String> steps,
  }) async {
    if (_used >= maxRequests) {
      steps.add('$tag → 跳过（已达 $maxRequests 次上限）');
      return null;
    }
    await _throttle();
    _used++;
    _lastAt = DateTime.now();

    try {
      final Response<dynamic> res = await send();
      final int status = res.statusCode ?? 0;
      final String body = _bodyOf(res.data);
      final Map<String, dynamic>? json = _tryJson(body);
      final String shape = json != null
          ? 'JSON · ok=${json['ok'] ?? '—'} · errno=${json['errno'] ?? '—'}'
          : '非 JSON · ${_head(body)}';
      steps.add('$tag → HTTP $status · $shape');
      return json;
    } catch (e) {
      // 不记录 cookie / 请求头，只记异常类型。
      steps.add('$tag → 异常 ${e.runtimeType}');
      return null;
    }
  }

  static String _bodyOf(Object? data) {
    if (data is String) return data;
    if (data == null) return '';
    try {
      return jsonEncode(data);
    } catch (_) {
      return data.toString();
    }
  }

  static Map<String, dynamic>? _tryJson(String body) {
    final String s = body.trim();
    if (s.isEmpty || !(s.startsWith('{') || s.startsWith('['))) return null;
    try {
      final Object? decoded = jsonDecode(s);
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _head(String body) {
    final String one = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 80 ? one : '${one.substring(0, 80)}…';
  }

  /// 递归摊平字段树，同时收集「像视频地址」的键。
  void _flatten(
    Object? node,
    String path,
    List<String> out,
    List<String> videoKeys,
    int depth,
  ) {
    if (depth > 4) return;
    final String pad = '  ' * depth;
    if (node is Map) {
      for (final MapEntry<Object?, Object?> e in node.entries) {
        final String key = e.key.toString();
        final String p = '$path.$key';
        final Object? v = e.value;
        if (v is Map) {
          out.add('$pad$key : Map(${v.length})');
          _flatten(v, p, out, videoKeys, depth + 1);
        } else if (v is List) {
          out.add('$pad$key : List(${v.length})');
          if (v.isNotEmpty) _flatten(v.first, '$p[0]', out, videoKeys, depth + 1);
        } else if (v is String) {
          if (v.startsWith('http')) {
            out.add('$pad$key : String(len=${v.length}) ${_redact(v)}');
            if (_looksVideoKey(key) && !videoKeys.contains(p)) videoKeys.add(p);
            // 未脱敏直链只留在内存里供 Q4 测试；绝不进结果对象、绝不落盘。
            if (_looksPlayable(key, v) && !_rawVideoUrls.contains(v)) {
              _rawVideoUrls.add(v);
            }
          } else {
            final String s = v.length <= 60 ? v : '${v.substring(0, 60)}…';
            out.add('$pad$key : String = $s');
            if (_looksVideoKey(key) && s.contains('http') && !videoKeys.contains(p)) {
              videoKeys.add(p);
            }
          }
        } else {
          out.add('$pad$key : ${v.runtimeType} = $v');
        }
      }
    } else if (node is List) {
      for (int i = 0; i < node.length && i < 3; i++) {
        _flatten(node[i], '$path[$i]', out, videoKeys, depth + 1);
      }
    }
  }

  static bool _looksVideoKey(String key) {
    final String k = key.toLowerCase();
    return k.contains('stream') ||
        k.contains('mp4') ||
        k.contains('m3u8') ||
        k.contains('video') ||
        k.contains('play') ||
        k == 'urls' ||
        k.contains('hd') ||
        k.contains('sd');
  }

  /// 是否**可直接交给播放器**的地址：必须带视频扩展名或落在视频 CDN 上。
  ///
  /// 不能只按 key 名判定：`pics[].url` 也是 http 地址，拿它去测 Referer
  /// 只会得到一张图的状态码，把结论带偏。
  static bool _looksPlayable(String key, String url) {
    final String u = url.toLowerCase();
    if (u.contains('.mp4') || u.contains('.m3u8')) return true;
    if (u.contains('weibocdn.com') &&
        (key.toLowerCase().contains('stream') ||
            key.toLowerCase().contains('mp4') ||
            key.toLowerCase().contains('url'))) {
      return true;
    }
    return false;
  }

  /// URL 脱敏：只留 scheme/host/路径前缀 + 参数名，值全部打掉。
  static String _redact(String url) {
    final Uri? u = Uri.tryParse(url.trim());
    if (u == null) return '<不可解析>';
    final String p =
        u.path.length <= 60 ? u.path : '${u.path.substring(0, 60)}…';
    final String names = (u.queryParameters.keys.toList()..sort()).join(',');
    return '${u.scheme}://${u.host}$p${names.isEmpty ? '' : '?$names'}';
  }

  static String _mask(String v) {
    if (v.isEmpty) return '（空）';
    final String head = v.length > 6 ? v.substring(0, 6) : v;
    return '$head…（${v.length} 位）';
  }

  /// 回答 Q1/Q2/Q3/Q5。
  void _answerQuestions(
    Map<Object?, Object?> root,
    Map<String, String> findings,
    List<String> videoUrlKeys, {
    required bool fromComponent,
  }) {
    if (fromComponent) {
      // component 的根就是 Playinfo，字段直接平铺。
      final String? cover = _firstKey(root, <String>[
        'cover_image',
        'cover',
        'cover_image_phone',
        'big_pic_info',
      ]);
      final String? duration = _firstKey(root, <String>[
        'duration',
        'duration_time',
        'length',
      ]);
      findings['Q1'] = 'component 端点直接返回 Playinfo，无 page_info 概念';
      findings['Q2'] = 'Playinfo 共 ${root.length} 个 key';
      findings['Q3'] = videoUrlKeys.isEmpty
          ? '未在 Playinfo 里找到像视频地址的字段'
          : '候选：${videoUrlKeys.join(' , ')}';
      findings['Q5'] =
          '封面=${cover ?? '未出现'} · 时长=${duration ?? '未出现'}';
      return;
    }

    final Object? type = root['type'];
    final Object? mediaInfo = root['media_info'];
    findings['Q1'] = 'page_info 存在，type=${type ?? '（缺）'}';
    if (mediaInfo is Map && mediaInfo.isNotEmpty) {
      findings['Q2'] =
          'media_info 共 ${mediaInfo.length} 个 key：${mediaInfo.keys.join(', ')}';
      final String? cover = _firstKey(mediaInfo, <String>[
        'cover_url',
        'cover',
        'big_pic_info',
        'thumbnail',
      ]);
      final String? duration = _firstKey(mediaInfo, <String>[
        'duration',
        'duration_time',
        'length',
      ]);
      findings['Q5'] = '封面=${cover ?? '未出现'} · 时长=${duration ?? '未出现'}';
    } else {
      findings['Q2'] = 'page_info 里没有 media_info（可能是外链/超话卡）';
      findings['Q5'] = '因无 media_info，无法判定';
    }
    findings['Q3'] = videoUrlKeys.isEmpty
        ? '未找到像视频地址的字段'
        : '候选：${videoUrlKeys.join(' , ')}';
  }

  static String? _firstKey(Map<Object?, Object?> map, List<String> keys) {
    for (final String k in keys) {
      if (map.containsKey(k)) return k;
    }
    return null;
  }

  /// Q4：对前两个候选直链做「无 Referer / 带 Referer」对照。
  ///
  /// 只读响应头（`ResponseType.stream` 拿不到就退化成普通 GET 但不落盘）。
  Future<void> _probeDirectLinks(
    List<String> fieldTree,
    List<String> steps,
    Map<String, String> findings, {
    required String cookie,
  }) async {
    // 字段树里的直链已被脱敏，不能用来发请求 —— 所以这里从原文重新取。
    // 为了不把真链带进结果对象，我们只在本次方法内临时使用。
    final List<String> urls = _rawVideoUrls;
    if (urls.isEmpty) {
      findings['Q4'] = '没有拿到可用直链，无法测试 Referer 要求';
      return;
    }
    final String first = urls.first;
    final String scheme = Uri.tryParse(first)?.scheme ?? '?';
    final bool signed = (Uri.tryParse(first)?.queryParameters.isNotEmpty) ?? false;

    final String? noRef = await _headStatus(first, referer: null, tag: 'X1 无 Referer');
    final String? withRef = _used < maxRequests
        ? await _headStatus(first, referer: 'https://weibo.com/', tag: 'X2 带 Referer')
        : '跳过（上限）';

    findings['Q4'] = 'scheme=$scheme · 带签名参数=${signed ? '有' : '无'} · '
        '无 Referer=$noRef · 带 Referer=$withRef';

    // 其它候选只记录档位名，不发请求（守上限）。
    if (urls.length > 1) {
      steps.add('其余 ${urls.length - 1} 个候选直链未测（守请求上限）');
    }
    // 显式说明：字段树里的直链已脱敏。
    if (fieldTree.isNotEmpty) {
      steps.add('字段树中的直链已脱敏（只留 host + 参数名）');
    }
  }

  /// 本次运行中临时收集的**未脱敏**直链（绝不出现在结果对象里）。
  final List<String> _rawVideoUrls = <String>[];

  Future<String?> _headStatus(
    String url, {
    required String? referer,
    required String tag,
  }) async {
    if (_used >= maxRequests) return '跳过（上限）';
    await _throttle();
    _used++;
    _lastAt = DateTime.now();
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, String>{
            'User-Agent': _mobileUa,
            if (referer != null) 'Referer': referer,
          },
          validateStatus: (int? s) => s != null && s < 500,
        ),
      );
      final String ct = res.headers.value('content-type') ?? '—';
      final String cl = res.headers.value('content-length') ?? '—';
      return 'HTTP ${res.statusCode} · $ct · len=$cl';
    } catch (e) {
      return '异常 ${e.runtimeType}';
    }
  }
}
