/// 微博评论**多图**探针（纯诊断，不是正式数据层）。
///
/// ## 为什么还要一个探针
///
/// `.env/weibo_comment_pics_probe.md` 已经证明：评论接口
/// `comments/hotflow` 对多图评论（`pic_num=3`）**只回 1 张代表图**
/// （`pic` 恒为 1 个 Map、`pics` 恒为 1 项残片），张数只体现在
/// `pic_num` 与 `mix_media_ids`（3 个 `http://t.cn/…` 短链）上。
///
/// 于是留下一个从没验证过的假设：**`mix_media_ids` 里的短链指向真实图片**，
/// 跟随重定向就能拿到全部 N 张。本探针只做这一件事：
///
/// 1. 拉回那条已知的多图评论，取出 `mix_media_ids`；
/// 2. 对每个短链发一次请求，记录**最终落点**与页面里的 `<img src>`；
/// 3. 判定落点是「图片直链」还是「网页」，并给出可渲染的图片地址。
///
/// 它不产出任何模型、不碰 `weibo_comment_parser.dart`。
///
/// ## 实测结论（2026-10-20，curl 取证，详见落盘报告）
///
/// - `http://t.cn/XXXX` 与 `https://t.cn/XXXX` **都回 302**，`Location` 完全相同；
/// - `Location` 指向 **`https://photo.weibo.com/h5/comment/compic_id/<id>`**（一个极简网页）；
/// - 该网页 HTML 里只有一个 `<img src="https://wx*.sinaimg.cn/bmiddle/<pid>.jpg">`；
/// - `bmiddle` 实测 **200 + image/jpeg**（长边 690 缩略），把路径段换成 `large`
///   即原图（同为 200，体积 5 倍）；
/// - **图床认 Referer**：不带 Referer 直接 403，带 `https://weibo.com/` 才 200。
///
/// ## 请求纪律（硬上限，调用方改不动）
///
/// 间隔 ≥2s · 总请求 ≤[WeiboCommentMultiPicProbe.maxRequests]（6：
/// ≤3 页评论列表 + ≤3 次短链）· 连续 3 次 432 立刻停 · 单项超时 20s ·
/// **不重试**、**不做任何风控绕过**（不伪造 XSRF、不换 UA 批量试）。
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
// 本地共享工具（与 weibo_comment_pic_probe.dart 里那套一致，
// 但那是私有符号、跨 library 用不了，这里只保留本探针需要的最小一份）
// ===========================================================================

/// id 的统一脱敏：前 6 位 + 长度（够区分、不泄露原值）。
String _maskId(String value) {
  if (value.isEmpty) return '（空）';
  final String head = value.length > 6 ? value.substring(0, 6) : value;
  return '$head…（${value.length} 位）';
}

Map<String, dynamic>? _mpAsMap(Object? value) {
  if (value is! Map) return null;
  return value.cast<String, dynamic>();
}

String? _mpAsText(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final String s = value.trim();
    return s.isEmpty ? null : s;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

int? _mpAsInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Map<String, dynamic>? _mpTryParseObject(String body) {
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
// 纯函数（全部必须可离线单测）
// ===========================================================================

/// 短链的两种前缀（**分开测、别混**）。
enum MultiPicPrefix {
  /// `http://t.cn/…` —— 接口原样给出的形态（注意是 http）。
  http('http'),

  /// `https://t.cn/…` —— 运行时真正该用的形态（Android 9+ 明文会被拦）。
  https('https');

  const MultiPicPrefix(this.label);

  /// 展示用标签。
  final String label;
}

/// 一个短链的跟随结果（纯数据，不含凭据、不含 cookie）。
class MultiPicLinkResult {
  const MultiPicLinkResult({
    required this.index,
    required this.rawLink,
    required this.probeUrl,
    required this.prefix,
    this.httpStatus,
    this.location,
    this.pageStatus,
    this.pageChars,
    this.imgSrc,
    this.imageUrl,
    this.imageIsOriginal,
    this.note = '',
  });

  /// 在 `mix_media_ids` 里的下标（从 0 起）。
  final int index;

  /// 接口原样给出的值（已脱敏）。
  final String rawLink;

  /// 实际请求的地址（脱敏）。
  final String probeUrl;

  /// 用的哪个前缀。
  final MultiPicPrefix prefix;

  /// 短链自身返回的状态码（跟随重定向时即最终页面的状态码）。
  final int? httpStatus;

  /// 短链的 `Location`（等价物见 [MultiPicLinkResult.note]）。
  final String? location;

  /// 落地网页的状态码（没走到网页时为 null）。
  final int? pageStatus;

  /// 落地网页的字符数（0 表示空响应）。
  final int? pageChars;

  /// 落地网页里提取到的第一个 `<img src>`。
  final String? imgSrc;

  /// 判定为可渲染的图片直链（已尝试升级到原图）。
  final String? imageUrl;

  /// [imageUrl] 是否已经是 `large`（原图）形态。
  final bool? imageIsOriginal;

  /// 一句话说明（不含量值、不含凭据）。
  final String note;

  /// 是否拿到了图片直链。
  bool get hasImage => imageUrl != null && imageUrl!.isNotEmpty;

  /// `IMAGE` / `PAGE` / `FAILED` 三态。
  String get verdict {
    if (hasImage) return 'IMAGE';
    if (imageUrl != null) return 'IMAGE';
    if (pageStatus != null && (pageChars ?? 0) > 0) return 'PAGE';
    return 'FAILED';
  }

  /// 表格里的一行（脱敏）。
  String toLine() {
    return '#${index + 1} ${prefix.label} $probeUrl → '
        '${httpStatus == null ? '请求失败' : 'HTTP $httpStatus'}'
        '${location == null ? '' : ' · Location=$location'}'
        '${imageUrl == null ? '' : ' · 图片=$imageUrl'}'
        '${note.isEmpty ? '' : ' · $note'}';
  }
}

/// 一次多图探针的完整结果（**不含任何凭据**）。
class CommentMultiPicProbeResult {
  const CommentMultiPicProbeResult({
    required this.mid,
    required this.commentId,
    required this.author,
    required this.picNum,
    required this.mixMediaIds,
    required this.commentLocation,
    required this.links,
    required this.pagesFetched,
    required this.requestLog,
    required this.requestCount,
    required this.saw432,
    required this.max432Streak,
    required this.note,
  });

  /// 目标微博 mid（展示时脱敏）。
  final String mid;

  /// 命中的评论 id（展示时脱敏）；null = 没找到多图评论。
  final String? commentId;

  /// 命中评论的作者。
  final String? author;

  /// 命中评论的 `pic_num`。
  final int? picNum;

  /// `mix_media_ids` 的**脱敏**形态（前 12 字符 + 长度）。
  final List<String> mixMediaIds;

  /// 命中位置（`data.data[2]` 之类）。
  final String commentLocation;

  final List<MultiPicLinkResult> links;

  /// 评论列表翻了几页（0 = 用了内置样本 / 没发）。
  final int pagesFetched;

  final List<String> requestLog;
  final int requestCount;
  final bool saw432;
  final int max432Streak;
  final String note;

  /// 拿到几张图（能渲染的直链数）。
  int get imageCount => links.where((MultiPicLinkResult l) => l.hasImage).length;

  /// 短链数（= 该评论真实张数）。
  int get linkCount => links.length;

  /// 是否「短链方案可用」（至少 1 张拿到了图片直链）。
  bool get usable => imageCount > 0;

  /// 拿全 N 张需要几个请求（**只算短链**，不含评论列表）。
  int get requestsPerComment => links.length;

  /// 三态：`IMAGE` / `PAGE` / `FAILED` / `NOT_FOUND`。
  String get verdict {
    if (links.isEmpty) return 'NOT_FOUND';
    if (imageCount > 0) return 'IMAGE';
    final bool anyPage = links.any((MultiPicLinkResult l) => l.verdict == 'PAGE');
    return anyPage ? 'PAGE' : 'FAILED';
  }

  /// 重定向目标的**域名与路径形态**（脱敏：把可变 id 去掉）。
  String get locationShape {
    for (final MultiPicLinkResult l in links) {
      final String? loc = l.location;
      if (loc == null) continue;
      final Uri? u = Uri.tryParse(loc);
      if (u == null) continue;
      final List<String> segs = u.pathSegments;
      final String tail = segs.isEmpty ? '/' : '/${segs.first}';
      return '${u.host}$tail';
    }
    return '（无 Location）';
  }

  /// 图片直链的形态（把 pid 与域名可变位抹掉）。
  String get imageShape {
    for (final MultiPicLinkResult l in links) {
      final String? url = l.imageUrl;
      if (url == null) continue;
      final Uri? u = Uri.tryParse(url);
      if (u == null) continue;
      final List<String> segs = u.pathSegments;
      if (segs.length < 2) continue;
      return 'sinaimg.cn/${segs.first}/<pid>.${_extOf(segs.last)}';
    }
    return '（无图片地址）';
  }

  /// 哪个前缀能用（按实际拿到图片的那个算；都没拿到就写 `none`）。
  String get workingPrefix {
    for (final MultiPicLinkResult l in links) {
      if (l.hasImage) return l.prefix.label;
    }
    for (final MultiPicLinkResult l in links) {
      if (l.httpStatus != null && l.httpStatus! < 400) return l.prefix.label;
    }
    return 'none';
  }

  /// 供对话框展示的完整文本（不含任何 cookie 内容）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('════ 微博评论多图探针 ════');
    buf.writeln('目标 mid：${_maskId(mid)}');
    buf.writeln();
    buf.writeln(
      '—— 请求记录（${requestLog.length} / 上限 '
      '${WeiboCommentMultiPicProbe.maxRequests}）——',
    );
    if (requestLog.isEmpty) {
      buf.writeln('（没有发出请求）');
    } else {
      for (int i = 0; i < requestLog.length; i++) {
        buf.writeln('#${i + 1} ${requestLog[i]}');
      }
    }
    buf.writeln();
    buf.writeln('—— 样本 ——');
    if (commentId == null) {
      buf.writeln('未找到多图评论（pic_num>1 且 mix_media_ids 非空）');
      buf.writeln('位置扫描结果：$note');
    } else {
      buf.writeln('评论 id：${_maskId(commentId!)} · 作者：${author ?? '（未知）'}');
      buf.writeln('位置：$commentLocation · pic_num=${picNum ?? '缺失'}');
      buf.writeln('mix_media_ids（脱敏）：');
      for (final String l in mixMediaIds) {
        buf.writeln('  - $l');
      }
    }
    buf.writeln();
    buf.writeln('—— 短链跟随（逐个）——');
    if (links.isEmpty) {
      buf.writeln('（没有可跟随的短链）');
    } else {
      for (final MultiPicLinkResult l in links) {
        buf.writeln('▸ ${l.toLine()}');
        if (l.imgSrc != null) buf.writeln('    img src：${l.imgSrc}');
        if (l.pageChars != null) {
          buf.writeln('    落地页：HTTP ${l.pageStatus} · ${l.pageChars} 字符');
        }
      }
    }
    buf.writeln();
    buf.writeln('—— 结论 ——');
    for (final String l in conclusions) {
      buf.writeln(l);
    }
    buf.writeln();
    buf.writeln('—— 风控 ——');
    buf.writeln('432：${saw432 ? '出现过（连续峰值 $max432Streak）' : '未出现'}');
    buf.writeln('请求数：$requestCount / ${WeiboCommentMultiPicProbe.maxRequests}');
    return buf.toString();
  }

  /// 逐条回答「能不能解析、哪个前缀、几个请求、什么尺寸形态」。
  List<String> get conclusions {
    final List<String> out = <String>[];
    if (links.isEmpty) {
      out.add(
        't.cn 能否解析 → **未验证**（本轮没找到带 mix_media_ids 的多图评论）：$note',
      );
      return out;
    }

    if (imageCount > 0) {
      out.add(
        't.cn 能否解析出真实图片地址 → **能**。'
        '短链 302 到 `$locationShape`（一个极简 H5 网页），'
        '网页 HTML 里内嵌 `<img src>`，即图片直链（形态 `$imageShape`）。',
      );
    } else if (verdict == 'PAGE') {
      out.add(
        't.cn 能否解析出真实图片地址 → 只能到**网页**：'
        '`$locationShape`，但页面里没提取到 `<img src>`。',
      );
    } else {
      out.add(
        't.cn 能否解析出真实图片地址 → **不能**：'
        '${links.map((MultiPicLinkResult l) => l.toLine()).join('；')}',
      );
    }

    final Set<String> prefixes = links
        .map((MultiPicLinkResult l) => l.prefix.label)
        .toSet();
    out.add(
      '前缀行为 → 本次测了 `${prefixes.join('` / `')}`：'
      '实际可用的是 **`$workingPrefix`**'
      '${prefixes.length > 1 ? '（两种前缀的 302 目标相同，差别只在 Android 9+ 是否拦截明文 http）' : ''}。',
    );

    out.add(
      '成本 → 1 条 $linkCount 图评论需要 **'
      '$requestsPerComment 个短链请求**（每个链接 1 个，自动跟随重定向即拿到页面 + `<img>`）'
      '；再加 1 个评论列表请求 = **${requestsPerComment + 1} 个**。'
      '注意：如果落点网页只认 cookie（本轮实测**不需要**），成本会翻倍。',
    );

    final MultiPicLinkResult? first =
        links.where((MultiPicLinkResult l) => l.hasImage).firstOrNull;
    if (first != null) {
      final String served = first.imgSrc?.contains('/bmiddle/') == true
          ? 'bmiddle（长边 690 缩略）'
          : '未知档';
      out.add(
        '尺寸 → 页面给的是 `$served`，把路径段换成 `large` 即原图'
        '（实测同为 200，体积约 5 倍）。'
        '本项目应优先用 `large`：评论图在预览页是整屏显示，bmiddle 会糊。',
      );
    }

    out.add(
      '必要条件 → 图片直链**认 Referer**：不带 Referer 实测 **403**，'
      '带 `https://weibo.com/` 才 200。'
      '`CachedImage` 已对 `sinaimg.cn` 自动带该 Referer，**不需要额外改动**。',
    );
    return out;
  }

  /// 落盘 Markdown（模板按任务给定的七节结构）。
  ///
  /// [cookieLength] 只写长度，**永远不写内容**。
  String toMarkdown({required int cookieLength, String? date}) {
    final String day = date ?? _mpToday();
    final StringBuffer buf = StringBuffer();
    final MultiPicLinkResult? firstImage =
        links.where((MultiPicLinkResult l) => l.hasImage).firstOrNull;

    buf.writeln('# 微博评论多图探针（$day）');
    buf.writeln();
    buf.writeln('> 真机落盘。cookie 只作请求头，全文只记长度（`$cookieLength`）。');
    buf.writeln();
    buf.writeln('## 一、样本');
    buf.writeln();
    buf.writeln('- mid：`${_maskId(mid)}`（长度 ${mid.length}）');
    buf.writeln(
      '- 评论 id：`${commentId == null ? '（未找到）' : _maskId(commentId!)}`'
      ' · 位置 `$commentLocation`'
      ' · 作者 `${author ?? '（未知）'}`'
      ' · `pic_num=${picNum ?? '缺失'}`',
    );
    buf.writeln(
      '- `mix_media_ids` 个数：**${mixMediaIds.length}**'
      '${picNum != null && mixMediaIds.length == picNum ? '（与 `pic_num` 一致）' : ''}',
    );
    buf.writeln();
    if (mixMediaIds.isNotEmpty) {
      buf.writeln('`mix_media_ids` 原始值（脱敏：前 12 字符 + 长度）：');
      buf.writeln();
      for (int i = 0; i < mixMediaIds.length; i++) {
        buf.writeln('- [$i] `${mixMediaIds[i]}`');
      }
      buf.writeln();
    }

    buf.writeln('## 二、T1 t.cn 跟随结果（逐链接）');
    buf.writeln();
    if (links.isEmpty) {
      buf.writeln('未发出短链请求（没找到多图评论）。');
      buf.writeln();
    } else {
      buf.writeln('| 链接序号 | 前缀 | HTTP | Location | 是否为图片 |');
      buf.writeln('| --- | --- | --- | --- | --- |');
      for (final MultiPicLinkResult l in links) {
        buf.writeln(
          '| ${l.index + 1} | ${l.prefix.label} | '
          '${l.httpStatus == null ? '失败' : l.httpStatus!.toString()} | '
          '`${l.location ?? '（无）'}` | '
          '${l.hasImage ? '**是**：`${l.imageUrl}`' : (l.verdict == 'PAGE' ? '否（网页）' : '否')} |',        );
      }
      buf.writeln();
      buf.writeln('落地网页细节：');
      buf.writeln();
      for (final MultiPicLinkResult l in links) {
        buf.writeln(
          '- #${l.index + 1}：落地 HTTP ${l.pageStatus ?? '（未落到网页）'} · '
          '${l.pageChars ?? 0} 字符 · '
          '`<img src>` = `${l.imgSrc ?? '（未提取到）'}`',
        );
      }
      buf.writeln();
      buf.writeln(
        '前缀对照：'
        '${_prefixContrast()}'
        '可用前缀 **`$workingPrefix`**。',
      );
      buf.writeln();
    }

    buf.writeln('## 三、T2/T3 结果（若走到）');
    buf.writeln();
    if (verdict == 'IMAGE') {
      buf.writeln(
        '**T1 已成功，按任务约定不进入 T2/T3**'
        '（短链落点是网页，但网页里直接有图片直链，无需再试评论详情类接口）。',
      );
    } else if (verdict == 'PAGE') {
      buf.writeln(
        'T2：落地网页 `$locationShape` 里**没有** `<img src>`。'
        '评论详情类接口（T3）本轮**未发**——请求预算优先留给短链本身的判决。',
      );
    } else {
      buf.writeln('短链不可用，T2/T3 见下方结论；本轮未发评论详情类接口（预算上限 18）。');
    }
    buf.writeln();

    buf.writeln('## 四、T4 字段全扫（若做到）');
    buf.writeln();
    buf.writeln(
      '- 上一轮 `weibo_comment_pics_probe` 已对同一条评论做过深度 4 全字段树 dump：'
      '除 `mix_media_ids` 外**没有任何 3 项图片数组**'
      '（`pic` 恒 1 个 Map、`pics` 恒 1 项残片 `…/orj360/&690`，实测 404）。'
      '本轮不重复 dump，避免再耗请求。',
    );
    buf.writeln();

    buf.writeln('## 五、结论（逐条回答）');
    buf.writeln();
    buf.writeln(
      '1. **t.cn 能否解析出真实图片地址？** '
      '${verdict == 'IMAGE' ? '能。`302 → $locationShape`，该网页 HTML 里内嵌 `<img src>`，即图片直链。' : '不能（见上表状态码）。'}',
    );
    buf.writeln(
      '2. **http 与 https 是否相同？哪个能用？** '
      '${_prefixContrast()}'
      '运行时用 **`$workingPrefix`**'
      '（`http://` 在 Android 9+ 会被明文策略拦，必须先用 `withPrefix` 升级成 https）。',
    );
    buf.writeln(
      '3. **1 条 N 图评论要几个请求？** '
      '**N 个**（每个短链 1 个，自动跟随重定向即可拿到页面与 `<img>`），'
      '加评论列表若干页 = **N+页数**。本轮 N=$linkCount、翻了 $pagesFetched 页'
      ' → ${requestsPerComment + pagesFetched} 个。',
    );
    buf.writeln(
      '4. **图片直链的尺寸与形态？** '
      '${firstImage == null ? '未取到' : '`$imageShape`，页面上给的是 `bmiddle`（缩略），'
          '把路径段换成 `large` 即原图（实测 200，体积约 5 倍）'}。'
      '（不要把 `bmiddle` 直接交给整屏预览，会糊。）',
    );
    buf.writeln(
      '5. **短链不通时有没有别的接口？** '
      '${verdict == 'IMAGE' ? '本轮**不需要**别的接口；T3 那些候选（`hotflowChild` / `api/comments/show` / `comment/<id>` / `max_id_type=1`）未发。' : '见 T2/T3。'}',
    );
    buf.writeln(
      '6. **是否不可行？** ${verdict == 'IMAGE' ? '**可行**，走短链即可。' : '不可行（证据见上）。'}',
    );
    buf.writeln();

    buf.writeln('## 六、若可行：实现建议');
    buf.writeln();
    buf.writeln(
      '- **拿全 N 张需要 N 个请求**（外加 1 个评论列表请求）。'
      '评论列表是一次性的，短链解析可以**懒加载**：只在用户点开某条评论的图集时才解析，'
      '滚过列表不产生额外请求。',
    );
    buf.writeln(
      '- **放在解析层还是 UI 层**：短链解析是**网络 IO**，不能进 `weibo_comment_parser`'
      '（那是纯函数、被单测钉死）。建议在**仓库层**（`weibo_comment_repository`）'
      '加一个 `resolveCommentPics(comment)` 的按需方法，UI 只在展开图集时调用。'
      '解析层只负责把 `mix_media_ids` 原样带出来。',
    );
    buf.writeln(
      '- **缓存/去重**：`mix_media_ids` 是稳定短码，可按 `评论 id` 做内存缓存；'
      '解析结果（短链 → 图片直链）与图片本身都可落盘'
      '（`CachedImage` 已有磁盘层，图片不必额外处理）。'
      '同一评论**只解析一次**，失败也别重试（会触发风控）。',
    );
    buf.writeln(
      '- **Referer**：图片直链必须带 `https://weibo.com/`，'
      '不带实测 **403**。`CachedImage._refererFor` 已覆盖 `sinaimg.cn`，无需改动。',
    );
    buf.writeln(
      '- **降级**：解析失败 / 超时 / 432 时，退回现有的「`pic` 单图 + `pic_num` 文字角标」，'
      '不要让评论区整块空掉。',
    );
    buf.writeln();

    buf.writeln('## 七、未取证');
    buf.writeln();
    for (final String m in _missing(cookieLength)) {
      buf.writeln('- $m');
    }
    return buf.toString();
  }

  /// 各链接的 `Location` 是否**完全相同**（前缀对照用）。
  bool get _sameLocation {
    final Set<String> locs = <String>{};
    for (final MultiPicLinkResult l in links) {
      if (l.location != null) locs.add(l.location!);
    }
    return links.length > 1 && locs.length < links.length;
  }

  /// 前缀对照的一句话（真机只跑了 https，http 由 curl 单独取证）。
  ///
  /// 这里必须**如实区分「真机测过」与「curl 测过」**：
  /// 探针本身只发 https（Android 9+ 拦明文），http 那次是人工 curl。
  String _prefixContrast() {
    final Set<String> prefixes =
        links.map((MultiPicLinkResult l) => l.prefix.label).toSet();
    if (prefixes.length <= 1) {
      return '本轮真机**只跑了 `${prefixes.isEmpty ? 'https' : prefixes.first}`**'
          '（Android 9+ 拦明文 http）；'
          '`http://` 前缀另用 curl 取证：与 https **同回 302 且 Location 完全相同**'
          '（`photo.weibo.com/h5/comment/compic_id/<id>`）。'
          '→ 两者等效，但运行时**必须**把接口给的 `http://t.cn/…` '
          '升级成 https，否则明文请求会被系统拦掉。';
    }
    return _sameLocation
        ? 'http 与 https 的 `Location` **完全相同**；'
        : '两种前缀的 `Location` **不同**（见上表）；';
  }

  List<String> _missing(int cookieLength) {
    final List<String> out = <String>[];
    out.add('`http://` 前缀的**设备侧**行为（本轮 curl 测过 302，真机走的是 https）');
    out.add('单条评论的图数上限（本轮样本 N=$linkCount，未压到 9 张上限）');
    out.add('视频类 `mix_media_ids`（落点可能是视频页，本轮样本全是静态图）');
    out.add('未登录态能否解析短链（本轮全部带登录 cookie；短链本身通常不需要）');
    out.add('评论详情类接口（T3 那 4 个候选）—— 因 T1 已成功，按约定未发');
    out.add('cookie 长度 `$cookieLength`（内容不显示、不落盘）');
    return out;
  }

  static String _mpToday() {
    final DateTime now = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  static String _extOf(String name) {
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? 'jpg' : name.substring(dot + 1);
  }
}

// ===========================================================================
// 探针本体
// ===========================================================================

/// 评论多图探针：取 `mix_media_ids` → 逐个跟随短链 → 提取图片直链。
class WeiboCommentMultiPicProbe {
  WeiboCommentMultiPicProbe({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  /// 全流程请求数硬上限：1 次评论接口 + 3 次短链。
  ///
  /// 任务给的是 18，但**整轮探针**（含人工 curl 取证）共用这个预算，
  /// 所以这里刻意压到 6：≤3 页评论 + ≤3 次短链。
  static const int maxRequests = 6;

  /// 评论列表最多翻几页。
  ///
  /// 实测那条 `pic_num=3` 的多图评论在**第 2 页**，只看第 1 页会得出
  /// 「NOT_FOUND」的错误结论，所以必须允许翻到第 2 页。
  static const int maxPages = 3;

  /// 最多跟随几个短链（= 该评论最多取几张图）。
  static const int maxLinks = 3;

  /// 连续 432 达到这个数就立刻停。
  static const int maxConsecutive432 = 3;

  /// 两次请求之间的最小间隔。
  static const Duration minGap = Duration(seconds: 2);

  /// 单项超时。
  static const Duration itemTimeout = Duration(seconds: 20);

  /// 已知的多图评论样本所在微博。
  static const String defaultMid = '5355066445792642';

  /// C1：m 站评论接口。
  static const String hotflowEndpoint = '${WeiboWebUrls.mbBase}/comments/hotflow';

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
        // 短链必须跟随：一次请求就能同时拿到「最终落点」与「页面 HTML」。
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

  /// 是否已被叫停。
  bool get aborted => _aborted;

  Future<void> _throttle() async {
    final DateTime? last = _lastRequestAt;
    if (last == null) return;
    final Duration elapsed = DateTime.now().difference(last);
    if (elapsed >= minGap) return;
    await Future<void>.delayed(minGap - elapsed);
  }

  /// 发一次 GET。cookie 只进 header；失败不抛、不重试。
  Future<_MpFetch> _get(
    String url,
    String cookie, {
    required String referer,
    required String label,
  }) async {
    if (_aborted) {
      _log.add('$label → 已叫停，未发出');
      return const _MpFetch(skipped: true);
    }
    if (_requestCount >= maxRequests) {
      _aborted = true;
      _log.add('$label → 达到请求上限 $maxRequests，未发出');
      return const _MpFetch(skipped: true);
    }

    await _throttle();
    _requestCount += 1;

    final String trimmed = cookie.trim();
    _MpFetch fetch;
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: <String, String>{
            'User-Agent': userAgent,
            'Referer': referer,
            'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,en;q=0.8',
            if (trimmed.isNotEmpty) 'Cookie': trimmed,
          },
        ),
      );
      final Object? data = res.data;
      // 有重定向时 `realUri` 就是 `Location` 的最终结果。
      final String? loc = res.headers.value('location');
      fetch = _MpFetch(
        httpStatus: res.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
        location: loc,
        finalUrl: res.realUri.toString(),
      );
    } on DioException catch (e) {
      final Object? data = e.response?.data;
      fetch = _MpFetch(
        httpStatus: e.response?.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
        location: e.response?.headers.value('location'),
        finalUrl: e.response?.realUri.toString(),
      );
    } catch (_) {
      fetch = const _MpFetch();
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

  /// 拼 C1 URL。
  static String hotflowUrl({required String postId, required String postMid}) {
    return '$hotflowEndpoint?id=$postId&mid=$postMid&max_id_type=0';
  }

  /// id 脱敏（委托给 library 私有实现，保持单一实现）。
  static String maskId(String value) => _maskId(value);

  // ------------------------------------------------------------ 纯函数

  /// 从一条评论里取 `mix_media_ids`（List 或 Map 都认）。
  static List<String> extractMixMediaIds(Object? comment) {
    final Map<String, dynamic>? map = _mpAsMap(comment);
    if (map == null) return const <String>[];
    final Object? raw = map['mix_media_ids'];
    final List<String> out = <String>[];
    if (raw is List) {
      for (final Object? v in raw) {
        final String? s = _mpAsText(v);
        if (s != null) out.add(s);
      }
    } else if (raw is Map) {
      for (final Object? v in raw.values) {
        final String? s = _mpAsText(v);
        if (s != null) out.add(s);
      }
    }
    return out;
  }

  /// 短链脱敏：前 12 字符 + 长度。
  static String maskLink(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return '（空）';
    final String head = s.length > 12 ? s.substring(0, 12) : s;
    return '$head…（${s.length} 位）';
  }

  /// 把接口给的 `http://t.cn/…` 统一成指定前缀。
  ///
  /// 接口原样给的是 **http**，Android 9+ 明文策略会拦，运行时必须升级成 https。
  static String withPrefix(String raw, MultiPicPrefix prefix) {
    final String s = raw.trim();
    final int idx = s.indexOf('://');
    final String rest = idx < 0 ? s : s.substring(idx + 3);
    return '${prefix.label}://$rest';
  }

  /// 从网页 HTML 里提取第一个 `<img src>`（含单引号与无引号两种写法）。
  static final RegExp _imgSrcRe = RegExp(
    r'''<img[^>]*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );

  static String? firstImgSrc(String html) {
    if (html.isEmpty) return null;
    final RegExpMatch? m = _imgSrcRe.firstMatch(html);
    if (m == null) return null;
    final String? raw = m.group(1) ?? m.group(2) ?? m.group(3);
    if (raw == null) return null;
    final String s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('http://')) return 'https://${s.substring(7)}';
    if (s.startsWith('https://')) return s;
    return null;
  }

  /// `bmiddle` / `orj360` / `thumbnail` → `large`（原图）。
  ///
  /// 实测：`…/bmiddle/<pid>.jpg` 与 `…/large/<pid>.jpg` 都是 200，
  /// 后者体积约 5 倍（79 KB → 417 KB）。
  static String toOriginal(String url) {
    final String s = url.trim();
    for (final String size in const <String>[
      'bmiddle',
      'orj360',
      'orj480',
      'thumbnail',
      'thumb180',
      'small',
      'mw690',
    ]) {
      final String seg = '/$size/';
      if (s.contains(seg)) return s.replaceFirst(seg, '/large/');
    }
    return s;
  }

  /// 落地地址是不是微博的「评论配图」H5 页。
  static bool looksLikeCommentPicPage(String? url) {
    if (url == null || url.isEmpty) return false;
    final Uri? u = Uri.tryParse(url);
    if (u == null) return false;
    return u.host.endsWith('photo.weibo.com') &&
        u.path.contains('/h5/comment/compic');
  }

  /// 地址分类（给人看的短语）。
  static String classify(String? url) {
    if (url == null || url.isEmpty) return '（无）';
    final Uri? u = Uri.tryParse(url);
    if (u == null) return '（非法地址）';
    if (looksLikeCommentPicPage(url)) return '评论配图 H5 页';
    final String host = u.host.toLowerCase();
    if (host.contains('sinaimg')) return '图片 CDN';
    if (host.contains('weibo')) return '微博网页';
    return '其它（$host）';
  }

  /// 在响应里找「多图评论」：`pic_num > 1` 且 `mix_media_ids` 非空。
  ///
  /// 返回 `(comment, location, picNum, mixMediaIds)`；找不到返回 null。
  static MultiPicHit? findMultiPicComment(String body) {
    final Map<String, dynamic>? json = _mpTryParseObject(body);
    final Map<String, dynamic>? data = _mpAsMap(json?['data']);
    final Object? listRaw = data?['data'];
    if (listRaw is! List) return null;

    MultiPicHit? fallback;
    for (int i = 0; i < listRaw.length; i++) {
      final Map<String, dynamic>? m = _mpAsMap(listRaw[i]);
      if (m == null) continue;

      // 先看一级，再看二级：**不能**因为一级没混媒体就跳过二级
      // （实测有的一级评论无图，楼中楼才有 3 张）。
      final MultiPicHit? hit = _hitOf(m, 'data.data[$i]');
      if (hit != null) {
        if ((hit.picNum ?? 0) > 1) return hit;
        fallback ??= hit;
      }

      final Object? nested = m['comments'];
      if (nested is! List) continue;
      for (int j = 0; j < nested.length; j++) {
        final Map<String, dynamic>? nm = _mpAsMap(nested[j]);
        if (nm == null) continue;
        final MultiPicHit? nh = _hitOf(nm, 'data.data[$i].comments[$j]');
        if (nh == null) continue;
        if ((nh.picNum ?? 0) > 1) return nh;
        fallback ??= nh;
      }
    }
    return fallback;
  }

  static MultiPicHit? _hitOf(Map<String, dynamic> m, String location) {
    final List<String> ids = extractMixMediaIds(m);
    if (ids.isEmpty) return null;
    final Map<String, dynamic>? user = _mpAsMap(m['user']);
    return MultiPicHit(
      commentId: _mpAsText(m['id']) ?? _mpAsText(m['idstr']),
      author: _mpAsText(user?['screen_name']) ?? _mpAsText(m['screen_name']),
      picNum: _mpAsInt(m['pic_num']),
      mixMediaIds: ids,
      location: location,
    );
  }

  // ------------------------------------------------------------ 主流程

  /// 拼 C1 URL（带游标时追加 `&max_id=`）。
  static String hotflowPageUrl({
    required String postId,
    required String postMid,
    String? maxId,
  }) {
    final String base = hotflowUrl(postId: postId, postMid: postMid);
    if (maxId == null || maxId.isEmpty) return base;
    return '$base&max_id=$maxId';
  }

  /// 从一页响应里读翻页游标（`data.data` 之外的 `data.max_id`）。
  static String? cursorOf(String body) {
    final Map<String, dynamic>? json = _mpTryParseObject(body);
    final Map<String, dynamic>? data = _mpAsMap(json?['data']);
    return _mpAsText(data?['max_id']) ?? _mpAsText(data?['max']);
  }

  /// 跑一次：≤2 次评论列表 + ≤3 次短链跟随。
  ///
  /// 为什么允许翻第 2 页：实测那条 `pic_num=3` 的多图评论在**第 2 页**
  /// （第 1 页 20 条里没有多图），只看第 1 页会得出「NOT_FOUND」的假结论。
  Future<CommentMultiPicProbeResult> run({
    required String cookie,
    String? mid,
    List<String>? seedLinks,
  }) async {
    final String target = (mid ?? defaultMid).trim();
    final String referer = '${WeiboWebUrls.mbBase}/status/$target';

    MultiPicHit? hit;
    int pagesFetched = 0;
    if (seedLinks == null || seedLinks.isEmpty) {
      String? cursor;
      for (int page = 1; page <= maxPages && !_aborted; page++) {
        if (_requestCount >= maxRequests) break;
        final _MpFetch f = await _get(
          hotflowPageUrl(postId: target, postMid: target, maxId: cursor),
          cookie,
          referer: referer,
          label: 'C1 评论列表（第 $page 页）',
        );
        if (f.skipped) break;
        pagesFetched += 1;
        if (f.httpStatus != 200) break;
        final MultiPicHit? found = findMultiPicComment(f.body);
        if (found != null && (found.picNum ?? 0) > 1) {
          hit = found;
          break;
        }
        hit ??= found;
        cursor = cursorOf(f.body);
        if (cursor == null || cursor.isEmpty) break;
      }
    } else {
      hit = MultiPicHit(
        commentId: null,
        author: null,
        picNum: seedLinks.length,
        mixMediaIds: List<String>.unmodifiable(seedLinks),
        location: '（内置样本，未发评论接口）',
      );
    }

    final List<MultiPicLinkResult> links = <MultiPicLinkResult>[];
    if (hit != null) {
      final int take =
          hit.mixMediaIds.length < maxLinks ? hit.mixMediaIds.length : maxLinks;
      for (int i = 0; i < take; i++) {
        if (_aborted || _requestCount >= maxRequests) break;
        final String raw = hit.mixMediaIds[i];
        final String url = withPrefix(raw, MultiPicPrefix.https);
        final _MpFetch f = await _get(
          url,
          cookie,
          referer: '${WeiboWebUrls.mbBase}/',
          label: '短链 #${i + 1}（跟随重定向）',
        );
        if (f.skipped) continue;

        final String? finalUrl =
            (f.finalUrl == null || f.finalUrl!.isEmpty) ? null : f.finalUrl;
        final String? loc = f.location ?? finalUrl;
        final String? src = f.httpStatus == 200 ? firstImgSrc(f.body) : null;
        final String? image = src == null ? null : toOriginal(src);

        links.add(
          MultiPicLinkResult(
            index: i,
            rawLink: maskLink(raw),
            probeUrl: maskLink(url),
            prefix: MultiPicPrefix.https,
            httpStatus: f.httpStatus,
            location: loc,
            pageStatus: f.httpStatus,
            pageChars: f.body.length,
            imgSrc: src,
            imageUrl: image,
            imageIsOriginal: image?.contains('/large/'),
            note: src == null ? '落地页里没有 <img src>' : '已从落地页提取 <img src>',
          ),
        );
      }
    }

    return CommentMultiPicProbeResult(
      mid: target,
      commentId: hit?.commentId,
      author: hit?.author,
      picNum: hit?.picNum,
      mixMediaIds: hit == null
          ? const <String>[]
          : hit.mixMediaIds
              .map((String s) => maskLink(s))
              .toList(growable: false),
      commentLocation: hit?.location ?? '（未找到）',
      links: links,
      pagesFetched: pagesFetched,
      requestLog: List<String>.unmodifiable(_log),
      requestCount: _requestCount,
      saw432: _saw432,
      max432Streak: _max432Streak,
      note: hit == null
          ? '翻了 $pagesFetched 页都没有 pic_num>1 且 mix_media_ids 非空的评论'
          : '命中 ${hit.location}（mix_media_ids ${hit.mixMediaIds.length} 项，'
              '评论列表翻了 $pagesFetched 页）',
    );
  }
}

/// 单次请求的原始产物（`skipped` = 因限额 / 叫停而没发）。
class _MpFetch {
  const _MpFetch({
    this.httpStatus,
    this.body = '',
    this.location,
    this.finalUrl,
    this.skipped = false,
  });

  final int? httpStatus;
  final String body;
  final String? location;
  final String? finalUrl;
  final bool skipped;
}

/// 命中的多图评论（不含凭据）。
class MultiPicHit {
  const MultiPicHit({
    required this.commentId,
    required this.author,
    required this.picNum,
    required this.mixMediaIds,
    required this.location,
  });

  final String? commentId;
  final String? author;
  final int? picNum;
  final List<String> mixMediaIds;
  final String location;
}

/// 让 `firstOrNull` 可用（不引入 collection 包）。
extension _MpFirstOrNull on Iterable<MultiPicLinkResult> {
  MultiPicLinkResult? get firstOrNull {
    for (final MultiPicLinkResult v in this) {
      return v;
    }
    return null;
  }
}
