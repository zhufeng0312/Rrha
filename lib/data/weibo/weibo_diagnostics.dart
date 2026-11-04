/// 微博诊断工具合集：接口自检 / 分页测试 / 字段结构 dump / 深度采样 /
/// 关注列表探针 / 评论探针。
///
/// **纯诊断代码，不是正式数据层。** 正式功能（时间线、评论、订阅名回填）在
/// `weibo_api_client.dart`、`weibo_comment_repository.dart` 等处，与本文件无关；
/// 本文件也不被它们依赖。
///
/// ## 合并说明（纯重构，行为零变化）
///
/// 这三块能力原先是 `weibo_api_diag.dart` / `weibo_following_probe.dart` /
/// `weibo_comment_probe.dart` 三个文件，字段树展开、脱敏、类型名、样例值截断、
/// JSON 解析各写了一遍。现在合并到此文件，重复实现收敛到顶部的共享工具，
/// 对外符号与输出格式一字未改。
///
/// ## 凭据安全（硬约束，所有链路一致）
///
/// cookie 只作为请求头出现：不进日志、不进结果对象、不进异常文案、不落盘。
/// 结果里连长度都不带；界面上由调用方单独显示长度。
///
/// ## 请求节制（硬上限，调用方改不动）
///
/// 每条链路都刻意**不挂重试拦截器**（裸 `Dio`），也**不做任何风控绕过**：
/// 不伪造 `XSRF-TOKEN`、不换 UA、不重试轰炸。

library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'weibo_web_urls.dart';

// ===========================================================================
// 共享工具（合并前这三份诊断代码各写了一遍，这里只保留**一份实现**）
//
// 三份文件原本各自带一套字段树展开 (`_walk` / `_walkMblog`)、脱敏 (`_mask`)、
// 类型名 (`_typeName`)、样例值截断 (`_sampleValue`)、JSON 解析
// (`_tryParseObject`)。它们的差异都在参数上（深度 / 行数 / List 展开条数 /
// null 文案），所以这里把差异参数化，输出逐字节保持原样。
// ===========================================================================

/// 单值截断长度（三份原实现都是 80）。
const int _diagMaxValueChars = 80;

/// 类型名：`String` / `int` / `Map` / `List` …（三份原实现逐字一致）。
String _diagTypeName(Object? value) {
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

/// 样例值：字符串加引号；超长截断并标注原长。
///
/// [nullText] 区分两路历史行为：接口自检把 null 写成 `null`，两条探针
/// 写成空串——合并时保留各自既有输出。
String _diagSampleValue(
  Object? value, {
  String nullText = 'null',
  int maxChars = _diagMaxValueChars,
}) {
  if (value == null) return nullText;
  final String raw = value is String ? value : value.toString();
  if (raw.length <= maxChars) return value is String ? '"$raw"' : raw;
  final String cut = raw.substring(0, maxChars);
  return value is String
      ? '"$cut…（原长 ${raw.length}）'
      : '$cut…（原长 ${raw.length}）';
}

/// 探针语义的样例值：null 显示成空串（关注列表 / 评论探针的历史行为）。
String _diagProbeSampleValue(Object? value) =>
    _diagSampleValue(value, nullText: '');

/// 卡片类型分布文本（原三处 `_countsText` 逐字一致）。
String _diagCountsText(Map<String, int> counts) {
  if (counts.isEmpty) return '（无）';
  final List<String> keys = counts.keys.toList()..sort();
  return keys.map((String k) => 'card_type=$k × ${counts[k]}').join(' / ');
}

/// 游标脱敏：只给前 8 位与总长度，够人眼比对「有没有变」，不还原全值。
String _diagMask(String value) {
  if (value.isEmpty) return '（空）';
  final String head = value.length > 8 ? value.substring(0, 8) : value;
  return '$head…（${value.length} 位）';
}

/// 响应体摘要：压平空白后截断到 160 字。
String _diagHeadOf(String body) {
  final String flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= 160) return flat;
  return '${flat.substring(0, 160)}…';
}

List<String> _diagSortedKeys(Map<String, dynamic>? map) {
  if (map == null) return const <String>[];
  return <String>[...map.keys]..sort();
}

Map<String, dynamic>? _diagAsMap(Object? value) {
  if (value is! Map) return null;
  return value.cast<String, dynamic>();
}

String? _diagAsText(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final String s = value.trim();
    return s.isEmpty ? null : s;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

int? _diagAsInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Map<String, dynamic>? _diagTryParseObject(String body) {
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

/// 字段树展开（三份原 `_walk` / `_walkMblog` 的公共实现）。
///
/// 全部差异都参数化，保证每一路的输出与合并前**完全一致**：
/// - [maxLines]：行数上限（22 / 200）；
/// - [maxDepth]：深度上限（2 / 3 / 4）；
/// - [maxListItems]：同层 List 只展开前 N 项，<=0 表示全部展开；
/// - [capListDepth]：List 分支是否也判断深度上限——关注列表探针的历史实现
///   **不**判断，合并后必须保持；
/// - [sampleNullText]：标量 null 的样例值文本。
///
/// 空容器单独成行（否则「有没有这个字段」就看不出来了），标量一律成行。
void _diagWalkTree(
  String path,
  Object? node,
  int depth,
  List<String> out, {
  required int maxLines,
  required int maxDepth,
  required int maxListItems,
  bool capListDepth = true,
  String sampleNullText = 'null',
}) {
  if (out.length >= maxLines) return;

  if (node is Map) {
    if (node.isEmpty) {
      out.add('$path : Map : {}');
      return;
    }
    if (depth >= maxDepth) {
      out.add('$path : Map : …（深度上限，${node.length} 个 key）');
      return;
    }
    for (final MapEntry<Object?, Object?> entry in node.entries) {
      if (out.length >= maxLines) return;
      final String key = entry.key?.toString() ?? '';
      if (key.isEmpty) continue;
      _diagWalkTree(
        '$path.$key',
        entry.value,
        depth + 1,
        out,
        maxLines: maxLines,
        maxDepth: maxDepth,
        maxListItems: maxListItems,
        capListDepth: capListDepth,
        sampleNullText: sampleNullText,
      );
    }
    return;
  }

  if (node is List) {
    if (node.isEmpty) {
      out.add('$path : List : []');
      return;
    }
    if (capListDepth && depth >= maxDepth) {
      out.add('$path : List : …（深度上限，${node.length} 项）');
      return;
    }
    final int take = maxListItems <= 0
        ? node.length
        : (node.length < maxListItems ? node.length : maxListItems);
    for (int i = 0; i < take; i++) {
      if (out.length >= maxLines) return;
      _diagWalkTree(
        '$path[$i]',
        node[i],
        depth + 1,
        out,
        maxLines: maxLines,
        maxDepth: maxDepth,
        maxListItems: maxListItems,
        capListDepth: capListDepth,
        sampleNullText: sampleNullText,
      );
    }
    return;
  }

  out.add(
    '$path : ${_diagTypeName(node)} : '
    '${_diagSampleValue(node, nullText: sampleNullText)}',
  );
}


/// 一次接口自检的结果。
///
/// 只带「能不能用」的结论与计数，**不含任何 cookie 内容**——凭据安全是硬约束。
class WeiboApiDiagResult {
  const WeiboApiDiagResult({
    required this.httpStatus,
    required this.cardCount,
    required this.ok,
    required this.note,
  });

  /// HTTP 状态码；null 表示请求本身失败（断网 / 超时 / DNS 等）。
  final int? httpStatus;

  /// 响应里 `data.cards` 中含 `mblog` 字段的卡片数。
  final int cardCount;

  /// 是否判定为「接口可用」。
  final bool ok;

  /// 人话结论，如「接口可用」「WAF 拦截（432）」「仍要求登录（-100）」。
  final String note;
}

/// 一次「分页测试」的结果：两页对比。
///
/// 只带状态码、卡片计数、游标**长度可辨但不完整**的摘要与差异统计，
/// **不含任何 cookie 内容**——凭据安全是硬约束。
///
/// `since_id` 是 19 位大整数形式的字符串，这里**全程按字符串保存**：
/// 过 `int`/`double` 会丢精度，导致第 2 页请求拿错游标。
class WeiboPagingDiagResult {
  const WeiboPagingDiagResult({
    required this.page1Status,
    required this.page1Cards,
    required this.sinceIdFromPage1,
    required this.page2Status,
    required this.page2Cards,
    required this.duplicateCount,
    required this.newCount,
    required this.sinceIdFromPage2,
    required this.cursorAdvanced,
    required this.note,
  });

  /// 第 1 页 HTTP 状态；0 表示请求本身失败（断网 / 超时）。
  final int page1Status;

  /// 第 1 页含 `mblog` 的卡片数。
  final int page1Cards;

  /// 第 1 页响应里取到的游标；null = 没这个字段。
  final String? sinceIdFromPage1;

  /// 第 2 页 HTTP 状态；0 = 没发出去（第 1 页没有游标）或请求失败。
  final int page2Status;

  /// 第 2 页含 `mblog` 的卡片数。
  final int page2Cards;

  /// 两页 `mblog` id 的交集大小。
  final int duplicateCount;

  /// 第 2 页里第 1 页没出现过的条数。
  final int newCount;

  /// 第 2 页响应里取到的游标。
  final String? sinceIdFromPage2;

  /// 第 2 页游标是否与第 1 页不同。
  final bool cursorAdvanced;

  /// 人话结论，如「分页可用：第 2 页 10 条全部为新内容」。
  final String note;

  /// 游标摘要：只给长度与前 8 位，够人眼比对，且能区分「有/无」。
  String get page1CursorHint => _cursorHint(sinceIdFromPage1);

  /// 第 2 页游标摘要，规则同上。
  String get page2CursorHint => _cursorHint(sinceIdFromPage2);

  static String _cursorHint(String? sinceId) {
    if (sinceId == null) return '缺失';
    final String head = sinceId.length > 8 ? sinceId.substring(0, 8) : sinceId;
    return '$head…（${sinceId.length} 位）';
  }
}

/// 一次「字段结构 dump」的结果：只描述**结构**，不含 cookie。
///
/// 目的：把 `mblog` 每个字段的真实位置 / 类型 / 样例值摊平成人能读的文本，
/// 供写解析器时对照。它**不是**数据层：没有任何 ContentItem 映射。
class WeiboStructureDump {
  const WeiboStructureDump({
    required this.httpStatus,
    required this.cardTotal,
    required this.cardTypeCounts,
    required this.mblogLines,
    required this.emptyMblogCount,
    required this.cardlistInfoKeys,
    required this.sinceIdPresent,
    required this.note,
  });

  /// HTTP 状态；null 表示请求本身失败（断网 / 超时 / DNS）。
  final int? httpStatus;

  /// `data.cards` 的元素总数（含不含 mblog 的卡片）。
  final int cardTotal;

  /// `cards[].card_type` 的分布：key 是 card_type 的字符串形态。
  final Map<String, int> cardTypeCounts;

  /// [WeiboApiDiag.describeMblog] 的输出行；没有可用 mblog 时为空列表。
  final List<String> mblogLines;

  /// 有 `card` 但 `card.mblog` 缺失或为 null 的卡片数。
  final int emptyMblogCount;

  /// `data.cardlistInfo` 的 key 列表（排好序，便于比对总量字段名）。
  final List<String> cardlistInfoKeys;

  /// 响应里是否存在 `since_id` 游标（只报有无，不报值）。
  final bool sinceIdPresent;

  /// 人话结论。
  final String note;

  /// 供对话框展示的完整文本（不含任何 cookie 内容）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('状态：${httpStatus == null ? '请求失败' : 'HTTP $httpStatus'}');
    buf.writeln('卡片总数：$cardTotal（无 mblog 的卡片 $emptyMblogCount 条）');
    buf.writeln('card_type 分布：${_diagCountsText(cardTypeCounts)}');
    buf.writeln('cardlistInfo keys：'
        '${cardlistInfoKeys.isEmpty ? '（无）' : cardlistInfoKeys.join(', ')}');
    buf.writeln('since_id：${sinceIdPresent ? '存在' : '缺失'}');
    buf.writeln('判定：$note');
    buf.writeln('—— mblog 字段树 ——');
    if (mblogLines.isEmpty) {
      buf.writeln('（没有可展示的 mblog）');
    } else {
      for (final String line in mblogLines) {
        buf.writeln(line);
      }
    }
    return buf.toString();
  }

}

/// 一条 mblog 的「富媒体类型」标记，只用于**分类采样**，不是正式解析。
///
/// 判定严格按接口里的原始字段来，**绝不用别的字段硬凑**：
/// - [hasPics]：`mblog.pic_num > 0`（有配图）
/// - [hasRetweeted]：`mblog.retweeted_status != null`（是转发）
/// - [hasPageInfo]：`mblog.page_info != null`（视频 / 文章 / 卡片）
/// - [isLongText]：`mblog.isLongText == true`（长文预览）
class WeiboMblogProfile {
  const WeiboMblogProfile({
    required this.index,
    required this.picNum,
    required this.hasPics,
    required this.hasRetweeted,
    required this.hasPageInfo,
    required this.isLongText,
    required this.textLength,
    required this.title,
  });

  /// 在 `data.cards` 里含 mblog 的卡片中的**序号**（从 0 开始）。
  final int index;

  /// `mblog.pic_num` 的原值；缺失按 0。
  final int picNum;

  final bool hasPics;
  final bool hasRetweeted;
  final bool hasPageInfo;
  final bool isLongText;

  /// `mblog.textLength`（正文长度）；缺失时退回 `mblog.text` 的字符串长度。
  final int textLength;

  /// `mblog.title.text`（如「置顶」）；没有则为空串。
  final String title;

  /// 摘要表里那一行。
  String toSummaryLine() {
    final StringBuffer buf = StringBuffer();
    buf.write('#$index ');
    buf.write('pic_num=$picNum  ');
    buf.write('retweeted=${hasRetweeted ? 'yes' : 'no'}  ');
    buf.write('page_info=${hasPageInfo ? 'yes' : 'no'}  ');
    buf.write('longText=${isLongText ? 'yes' : 'no'}  ');
    buf.write('textLen=$textLength');
    if (title.isNotEmpty) buf.write('  「$title」');
    return buf.toString();
  }

  @override
  String toString() => toSummaryLine();
}

/// 三类富媒体样本各自挑中的那条在列表里的序号。
///
/// 每项为 null 表示「这批里没有该类样本」——调用方必须如实写出来，
/// **不能**拿别的字段凑一个。
class WeiboSamplePicks {
  const WeiboSamplePicks({
    required this.picsIndex,
    required this.retweetedIndex,
    required this.pageInfoIndex,
  });

  /// 第一条 `pic_num > 0` 的序号。
  final int? picsIndex;

  /// 第一条 `retweeted_status != null` 的序号。
  final int? retweetedIndex;

  /// 第一条 `page_info != null` 的序号。
  final int? pageInfoIndex;

  /// 三类都没有样本。
  bool get isEmpty =>
      picsIndex == null && retweetedIndex == null && pageInfoIndex == null;

  @override
  String toString() => 'pics=$picsIndex retweeted=$retweetedIndex '
      'pageInfo=$pageInfoIndex';
}

/// 「字段结构 dump」的全量分类采样结果：只描述**结构**，不含 cookie。
///
/// 与单条版 [WeiboStructureDump] 的区别：先给**全部 mblog** 一张摘要表，
/// 再按「配图 / 转发 / 页面卡」三类各挑**第一条**做完整字段展开。
class WeiboRichStructureDump {
  const WeiboRichStructureDump({
    required this.httpStatus,
    required this.cardTotal,
    required this.cardTypeCounts,
    required this.emptyMblogCount,
    required this.cardlistInfoKeys,
    required this.sinceIdPresent,
    required this.profiles,
    required this.picks,
    required this.mblogs,
    required this.note,
  });

  final int? httpStatus;
  final int cardTotal;
  final Map<String, int> cardTypeCounts;
  final int emptyMblogCount;
  final List<String> cardlistInfoKeys;
  final bool sinceIdPresent;

  /// 全部含 `mblog` 的卡片，逐条的类型摘要（按出现顺序）。
  final List<WeiboMblogProfile> profiles;

  /// 三类样本的挑中结果。
  final WeiboSamplePicks picks;

  /// 与 [profiles] 同序的原始 mblog（只用于按需展开，不落盘）。
  final List<Map<String, Object?>> mblogs;

  /// 人话结论。
  final String note;

  /// 某一类在多少条里出现了几次样本。
  int get picSampleCount =>
      profiles.where((WeiboMblogProfile p) => p.hasPics).length;

  int get retweetedSampleCount =>
      profiles.where((WeiboMblogProfile p) => p.hasRetweeted).length;

  int get pageInfoSampleCount =>
      profiles.where((WeiboMblogProfile p) => p.hasPageInfo).length;

  /// 供对话框展示的完整文本（不含任何 cookie 内容）。
  ///
  /// 结构：头部摘要 → 全量分类表 → 三段分类型展开（配图 / 转发 / 页面卡）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('状态：${httpStatus == null ? '请求失败' : 'HTTP $httpStatus'}');
    buf.writeln('卡片总数：$cardTotal（无 mblog 的卡片 $emptyMblogCount 条）');
    buf.writeln('card_type 分布：${_diagCountsText(cardTypeCounts)}');
    buf.writeln('cardlistInfo keys：'
        '${cardlistInfoKeys.isEmpty ? '（无）' : cardlistInfoKeys.join(', ')}');
    buf.writeln('since_id：${sinceIdPresent ? '存在' : '缺失'}');
    buf.writeln('判定：$note');

    buf.writeln();
    buf.writeln('—— 全量分类摘要（共 ${profiles.length} 条）——');
    if (profiles.isEmpty) {
      buf.writeln('（没有可展示的 mblog）');
    } else {
      for (final WeiboMblogProfile p in profiles) {
        buf.writeln(p.toSummaryLine());
      }
      buf.writeln('样本统计：pics $picSampleCount 条 / '
          'retweeted_status $retweetedSampleCount 条 / '
          'page_info $pageInfoSampleCount 条');
    }

    final int total = profiles.length;
    _writeSection(
      buf,
      title: '配图 pics',
      pickIndex: picks.picsIndex,
      sampleCount: picSampleCount,
      total: total,
      missLabel: 'pics',
      focus: const <String>[
        'mblog.pics',
        'mblog.pic_ids',
      ],
    );
    _writeSection(
      buf,
      title: '转发 retweeted_status',
      pickIndex: picks.retweetedIndex,
      sampleCount: retweetedSampleCount,
      total: total,
      missLabel: 'retweeted_status',
      focus: const <String>[
        'mblog.retweeted_status',
      ],
    );
    _writeSection(
      buf,
      title: '页面卡 page_info（视频 / 文章）',
      pickIndex: picks.pageInfoIndex,
      sampleCount: pageInfoSampleCount,
      total: total,
      missLabel: 'page_info',
      focus: const <String>[
        'mblog.page_info',
      ],
    );

    return buf.toString();
  }

  void _writeSection(
    StringBuffer buf, {
    required String title,
    required int? pickIndex,
    required int sampleCount,
    required int total,
    required String missLabel,
    required List<String> focus,
  }) {
    buf.writeln();
    buf.writeln('════════════════════════════════════');
    if (pickIndex == null) {
      buf.writeln('■ $title：未找到含 $missLabel 的样本（$total 条中 0 条）');
      buf.writeln('════════════════════════════════════');
      return;
    }
    buf.writeln('■ $title：本类样本来自 #$pickIndex'
        '（$total 条中有 $sampleCount 条）');
    buf.writeln('════════════════════════════════════');
    final List<String> lines = _describeAt(pickIndex, focus);
    if (lines.isEmpty) {
      buf.writeln('（该条 mblog 展开为空）');
      return;
    }
    for (final String line in lines) {
      buf.writeln(line);
    }
  }

  /// 展开第 [index] 条 mblog；重点字段额外有一行 `★ 重点` 摘录。
  List<String> _describeAt(int index, List<String> focusPaths) {
    if (index < 0 || index >= mblogs.length) return const <String>[];
    final Map<String, Object?> mblog = mblogs[index];
    final List<String> out = <String>[
      '★ 样本 #$index 完整字段树（深度 3）',
      '',
      ...WeiboApiDiag.describeMblog(mblog),
    ];
    for (final String path in focusPaths) {
      final String? focusLine = _focusLine(mblog, path);
      if (focusLine != null) {
        out.add('');
        out.add('★ 重点 $path：$focusLine');
      }
    }
    return out;
  }


  /// 把 `mblog.xxx` 这类固定路径取出来，给一行简要的「在不在 / 什么类型 / 几项」。
  static String? _focusLine(Map<String, Object?> mblog, String path) {    if (!path.startsWith('mblog.')) return null;
    final Object? node = mblog[path.substring('mblog.'.length)];
    if (node == null) return null;
    if (node is List) {
      if (node.isEmpty) return 'List（空）';
      final Object? first = node.first;
      if (first is Map) {
        final List<String> keys = <String>[
          ...first.keys.map((Object? k) => k.toString()),
        ]..sort();
        return 'List（${node.length} 项，元素是 Map，'
            '元素字段 ${keys.length} 个：${keys.join(', ')}）';
      }
      return 'List（${node.length} 项，元素是 ${first.runtimeType}）';
    }
    if (node is Map) {
      final List<String> keys = <String>[
        ...node.keys.map((Object? k) => k.toString()),
      ]..sort();
      return 'Map（${keys.length} 个 key：${keys.join(', ')}）';
    }
    return '${node.runtimeType}';
  }
}

/// 深度采样里**一页**的原始产物：状态码 + 响应体。
///
/// 独立成类而不是用 record，是因为它要出现在公开 API（[WeiboApiDiag] 的
/// 纯函数 [WeiboApiDiag.judgeDeep]）签名里，命名比 `({int? a, String b})`
/// 好读得多。
class WeiboDeepPage {
  const WeiboDeepPage({required this.httpStatus, required this.body});

  /// HTTP 状态；null 表示这一页的请求本身失败（断网 / 超时 / DNS）。
  final int? httpStatus;

  /// 原始响应体。凭据不在里面（cookie 只在请求头）。
  final String body;
}

/// 深度采样里**单页**的统计行。只报计数，不含任何 cookie。
class WeiboDeepPageStat {
  const WeiboDeepPageStat({
    required this.pageNo,
    required this.httpStatus,
    required this.cardTotal,
    required this.mblogCount,
    required this.cardTypeCounts,
    required this.cursorPresent,
  });

  /// 页码（1 起）。
  final int pageNo;

  final int? httpStatus;

  /// `data.cards` 元素总数。
  final int cardTotal;

  /// 含 `mblog` 且 mblog 是 Map 的卡片数。
  final int mblogCount;

  /// 本页 `card_type` 分布。
  final Map<String, int> cardTypeCounts;

  /// 本页响应里有没有 `since_id`（只报有无，不报值）。
  final bool cursorPresent;

  String toLine() {
    final String status = httpStatus == null ? '请求失败' : 'HTTP $httpStatus';
    final List<String> keys = cardTypeCounts.keys.toList()..sort();
    final String types = keys.isEmpty
        ? '（无卡片）'
        : keys.map((String k) => '$k × ${cardTypeCounts[k]}').join(' / ');
    return '第$pageNo页：$status · 卡片 $cardTotal 条 · mblog $mblogCount 条'
        ' · card_type $types · since_id ${cursorPresent ? '有' : '无'}';
  }

  @override
  String toString() => toLine();
}

/// 深度采样里挑中的**一条样本**：字段树已经摊平好了。
class WeiboDeepSample {
  const WeiboDeepSample({
    required this.pageNo,
    required this.index,
    required this.header,
    required this.lines,
  });

  /// 样本来自第几页（1 起）。
  final int pageNo;

  /// 跨页序号（0 起，只数含 mblog 的卡片，与摘要行 `#N` 一致）。
  final int index;

  /// 一句话出处：`mblog.id=… mid=… 作者=…`。
  final String header;

  /// 已展开的字段树行（路径 → 类型 → 样例值）。
  final List<String> lines;
}

/// 「深度采样」结果：自动翻最多 3 页，汇总统计 + 转发/视频样本展开。
///
/// 为什么需要它：前两轮 dump 各只发 1 个请求，`retweeted_status` 连续两批
/// **零样本**，`page_info.media_info` 也一次都没出现过（见
/// `.env/weibo_mblog_structure2.md`）。字段名没有真实样本就不能写解析器，
/// 所以这里用 `since_id` 游标串起 3 页，把样本量抬到 30 条左右再统计。
///
/// 只描述**结构**，不含 cookie；样本展开深度 4，能看到
/// `mblog.retweeted_status.pics[0].url` 这一级。
class WeiboDeepSampleDump {
  const WeiboDeepSampleDump({
    required this.pageStats,
    required this.profiles,
    required this.mblogs,
    required this.mblogPageNos,
    required this.cardTypeCounts,
    required this.emptyMblogCount,
    required this.retweetedSample,
    required this.mediaInfoSample,
    required this.note,
  });

  /// 逐页统计（按请求顺序）。
  final List<WeiboDeepPageStat> pageStats;

  /// 跨页汇总的逐条类型摘要，序号是**跨页连续**的。
  final List<WeiboMblogProfile> profiles;

  /// 与 [profiles] 同序的原始 mblog（只用于展开，不落盘）。
  final List<Map<String, Object?>> mblogs;

  /// 与 [profiles] 同序：该条来自第几页（1 起）。
  final List<int> mblogPageNos;

  /// 跨页汇总的 `card_type` 分布。
  final Map<String, int> cardTypeCounts;

  /// 有卡片但 mblog 缺失/非 Map 的累计条数。
  final int emptyMblogCount;

  /// 第一条含 `retweeted_status` 的样本；没有就是 null（如实报「未找到」）。
  final WeiboDeepSample? retweetedSample;

  /// 第一条含 `page_info.media_info` 的样本；没有就是 null。
  final WeiboDeepSample? mediaInfoSample;

  final String note;

  /// 实际发出的请求数（= 页数）。
  int get pageCount => pageStats.length;

  /// 3 页合计的 mblog 条数。
  int get totalMblog => profiles.length;

  int get picsSampleCount =>
      profiles.where((WeiboMblogProfile p) => p.hasPics).length;

  int get retweetedSampleCount =>
      profiles.where((WeiboMblogProfile p) => p.hasRetweeted).length;

  /// 含 `page_info.media_info` 的条数（不能只看 `page_info`：
  /// 实测 `type="webpage"` 的外链卡**没有** `media_info`）。
  int get mediaInfoSampleCount {
    int n = 0;
    for (final Map<String, Object?> mblog in mblogs) {
      if (WeiboApiDiag._hasMediaInfo(mblog)) n += 1;
    }
    return n;
  }

  /// 供对话框展示的完整文本（不含任何 cookie 内容）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('════ 深度采样（最多 3 页 · 实际 $pageCount 页）════');
    for (final WeiboDeepPageStat s in pageStats) {
      buf.writeln(s.toLine());
    }
    buf.writeln();
    buf.writeln('合计：$pageCount 页共 $totalMblog 条 mblog'
        '（无 mblog 的卡片 $emptyMblogCount 条）');
    buf.writeln('card_type 分布：${_diagCountsText(cardTypeCounts)}');
    buf.writeln('样本统计：'
        'pics $picsSampleCount 条 / '
        'retweeted_status $retweetedSampleCount 条 / '
        'page_info.media_info $mediaInfoSampleCount 条');
    buf.writeln('判定：$note');

    buf.writeln();
    buf.writeln('—— 全量分类摘要（跨页共 ${profiles.length} 条）——');
    if (profiles.isEmpty) {
      buf.writeln('（没有可展示的 mblog）');
    } else {
      for (int i = 0; i < profiles.length; i++) {
        final int pageNo = i < mblogPageNos.length ? mblogPageNos[i] : 0;
        buf.writeln('P$pageNo ${profiles[i].toSummaryLine()}');
      }
    }

    _writeSampleSection(
      buf,
      title: '转发 retweeted_status',
      sample: retweetedSample,
      sampleCount: retweetedSampleCount,
      missingLabel: 'retweeted_status',
    );
    _writeSampleSection(
      buf,
      title: '视频 page_info.media_info',
      sample: mediaInfoSample,
      sampleCount: mediaInfoSampleCount,
      missingLabel: 'page_info.media_info',
    );

    return buf.toString();
  }

  void _writeSampleSection(
    StringBuffer buf, {
    required String title,
    required WeiboDeepSample? sample,
    required int sampleCount,
    required String missingLabel,
  }) {
    buf.writeln();
    buf.writeln('════════════════════════════════════');
    if (sample == null) {
      // 没有样本就直说页数和总条数，绝不拿别的字段硬凑。
      buf.writeln('■ $title：$pageCount 页共 $totalMblog 条中'
          '未找到含 $missingLabel 的样本');
      buf.writeln('════════════════════════════════════');
      return;
    }
    buf.writeln('■ $title：本类样本来自 P${sample.pageNo} #${sample.index}'
        '（$pageCount 页共 $totalMblog 条中有 $sampleCount 条）');
    buf.writeln('════════════════════════════════════');
    buf.writeln(sample.header);
    buf.writeln();
    if (sample.lines.isEmpty) {
      buf.writeln('（该节点展开为空）');
      return;
    }
    for (final String line in sample.lines) {
      buf.writeln(line);
    }
  }

}

/// 微博接口自检（**诊断工具，不是正式功能**）。
///
/// ## 它要回答的问题
///
/// 微博接口 `m.weibo.cn/api/container/getIndex` 在**游客态**恒返回 432。
/// 此前从未测过「带上一个**真实有效的 m 站登录 cookie**」的情况：游客票据的
/// `SUB` cookie 域是 `.weibo.com`，根本不会送达 `m.weibo.cn`。本类就是把
/// 内置 WebView 里已经登录的 cookie 放进这次请求的请求头里，看接口是否放行。
///
/// ## 凭据安全
///
/// cookie 只在本类内部作为请求头出现**一次**：不写日志、不落盘、不进异常
/// 文案、不参与 [WeiboApiDiagResult]。外部只允许拿到它的长度。
///
/// ## 只发一次
///
/// 本项目曾因密集请求被平台冷却，所以 [runOnce] 全程只发一次请求，且这里
/// **不挂任何重试拦截器**（`Dio()` 是裸实例，`DioFactory` 那套带重试的不能复用）。
class WeiboApiDiag {
  WeiboApiDiag({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  /// 被诊断的接口地址（固定：uid=1782488734 的微博列表）。
  static const String endpoint =
      '${WeiboWebUrls.mbBase}/api/container/getIndex'
      '?type=uid&value=1782488734&containerid=1076031782488734';

  /// 移动端 Chrome UA：桌面 UA 会被 `m.weibo.cn` 重定向。
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  static Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 12),
        responseType: ResponseType.plain,
        followRedirects: true,
        // 放宽到 <500：让 432 走正常返回路径，由 judge 显式判定。
        validateStatus: (int? status) => status != null && status < 500,
      ),
    );
  }

  /// 只发一次请求。cookie 只放进 header，绝不记录。
  Future<WeiboApiDiagResult> runOnce({required String cookie}) async {
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        endpoint,
        options: Options(
          headers: <String, String>{
            'User-Agent': _userAgent,
            'Referer': '${WeiboWebUrls.mbBase}/u/1782488734',
            'X-Requested-With': 'XMLHttpRequest',
            'MWeibo-Pwa': '1',
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            if (cookie.isNotEmpty) 'Cookie': cookie,
          },
        ),
      );
      final Object? data = res.data;
      final String body = data is String ? data : (data?.toString() ?? '');
      return judge(httpStatus: res.statusCode, body: body);
    } on DioException catch (e) {
      // 只取状态码，绝不把 requestOptions.headers 拼进任何文案。
      final int? status = e.response?.statusCode;
      final Object? data = e.response?.data;
      final String body = data is String ? data : (data?.toString() ?? '');
      return judge(httpStatus: status, body: body);
    } catch (_) {
      return judge(httpStatus: null, body: '');
    }
  }

  /// 分页测试：**最多两个请求**（第 1 页 + 第 2 页），都不重试、不轮询。
  ///
  /// 目的只有一个：验证 `getIndex` 的 `since_id` 游标能不能翻页。
  ///
  /// 流程：
  /// 1. 请求第 1 页，从响应体里定位游标（[extractSinceId]）；
  /// 2. 拿不到游标就**停止**，第 2 个请求一个字节都不发；
  /// 3. 拿到游标就把原字符串拼进 URL 请求第 2 页；
  /// 4. 用 [diffMblogIds] 算两页差异，[judgePaging] 给人话结论。
  ///
  /// 凭据安全：cookie 只出现在请求头里，不写日志、不落盘、不进结果对象。
  Future<WeiboPagingDiagResult> runPaging({required String cookie}) async {
    // —— 第 1 页 ——
    final _PagingFetch p1 = await _fetchPaging(endpoint, cookie);
    final String? sinceId1 = extractSinceId(p1.body);

    if (sinceId1 == null && p1.httpStatus == null) {
      return judgePaging(
        page1Status: null,
        page1Body: p1.body,
        sinceIdFromPage1: null,
        page2Status: null,
        page2Body: '',
      );
    }
    if (sinceId1 == null) {
      // 没有游标：不发明第 2 个请求。
      return judgePaging(
        page1Status: p1.httpStatus,
        page1Body: p1.body,
        sinceIdFromPage1: null,
        page2Status: null,
        page2Body: '',
      );
    }

    // —— 第 2 页（唯一允许的第二个请求）——
    // 游标原样拼接，绝不做数值转换：19 位 id 过 double 会丢精度。
    final String page2Url = '$endpoint&since_id=$sinceId1';
    final _PagingFetch p2 = await _fetchPaging(page2Url, cookie);

    return judgePaging(
      page1Status: p1.httpStatus,
      page1Body: p1.body,
      sinceIdFromPage1: sinceId1,
      page2Status: p2.httpStatus,
      page2Body: p2.body,
    );
  }

  /// 字段结构 dump：**只发 1 个请求**（第 1 页），不重试、不翻页。
  ///
  /// URL 与请求头与 [runOnce] 完全一致（含 `Cookie`）。
  /// 凭据安全：cookie 只出现在请求头里，不进结果对象、不写日志、不落盘。
  ///
  /// 返回的是**全量分类采样**：同一份响应里按类型各挑一条样本展开，
  /// 而不是只看第一条（第一条往往是置顶纯文字微博，三类富媒体都没有）。
  Future<WeiboRichStructureDump> dumpStructure({required String cookie}) async {
    final _PagingFetch fetch = await _fetchPaging(endpoint, cookie);
    return judgeRichStructure(
      httpStatus: fetch.httpStatus,
      body: fetch.body,
    );
  }

  /// 深度采样：**最多 3 个请求**（第 1/2/3 页，用 `since_id` 串联），不重试。
  ///
  /// 目的：前两轮 dump 各只发 1 个请求，`retweeted_status` 连续两批零样本，
  /// `page_info.media_info` 一次都没出现过。把样本量从 11 条抬到 30 条左右，
  /// 才有机会看到转发/视频的真实字段名。
  ///
  /// ## 翻页纪律
  ///
  /// - 游标**原样拼进 URL**（`_asCursor` 已保证是字符串）：19 位大整数一旦
  ///   过 `int`/`double` 就丢精度，会把第 2 页请求带偏。
  /// - 任一页拿不到游标、或请求失败（`httpStatus == null`）、或非 200，
  ///   **立刻停止**，不再发后续请求——宁可样本少，也不制造无谓的请求。
  /// - 最多 3 页，硬上限写在 [maxPages]，调用方无法调大。
  ///
  /// 凭据安全：cookie 只出现在请求头里，不写日志、不落盘、不进结果对象。
  Future<WeiboDeepSampleDump> runDeepSample({required String cookie}) async {
    final List<WeiboDeepPage> pages = <WeiboDeepPage>[];

    String url = endpoint;
    for (int pageNo = 1; pageNo <= maxPages; pageNo++) {
      final _PagingFetch fetch = await _fetchPaging(url, cookie);
      pages.add(WeiboDeepPage(httpStatus: fetch.httpStatus, body: fetch.body));

      // 请求失败 / 非 200 / 无游标 → 到此为止，不再发下一个请求。
      if (fetch.httpStatus != 200) break;
      final String? cursor = extractSinceId(fetch.body);
      if (cursor == null || cursor.isEmpty) break;
      // 游标原样拼接，不做任何数值转换。
      url = '$endpoint&since_id=$cursor';
    }

    return judgeDeep(pages);
  }

  /// 深度采样允许的最大页数（= 最大请求数）。硬上限，不给调用方改。
  static const int maxPages = 3;

  /// 纯函数：把多页响应体整理成深度采样结果，并展开转发/视频样本。必须可离线单测。
  ///
  /// 跨页汇总时，[WeiboMblogProfile.index] 是**跨页连续**的序号：这样摘要表里
  /// 的 `#N` 与样本出处能一一对应，不会出现「第 2 页又从 #0 开始」的混乱。
  static WeiboDeepSampleDump judgeDeep(List<WeiboDeepPage> pages) {
    final List<WeiboDeepPageStat> stats = <WeiboDeepPageStat>[];
    final List<WeiboMblogProfile> profiles = <WeiboMblogProfile>[];
    final List<Map<String, Object?>> mblogs = <Map<String, Object?>>[];
    final List<int> pageNos = <int>[];
    final Map<String, int> globalTypes = <String, int>{};
    int emptyMblog = 0;

    for (int i = 0; i < pages.length; i++) {
      final int pageNo = i + 1;
      final WeiboDeepPage page = pages[i];
      final List<Object?> cards = _cardsOf(page.body);
      final Map<String, int> typeCounts = <String, int>{};
      int pageMblog = 0;

      for (final Object? card in cards) {
        if (card is! Map) continue;
        final Object? type = card['card_type'];
        final String typeKey = type == null ? '（无 card_type）' : type.toString();
        typeCounts[typeKey] = (typeCounts[typeKey] ?? 0) + 1;
        globalTypes[typeKey] = (globalTypes[typeKey] ?? 0) + 1;

        final Object? mblog = card['mblog'];
        if (mblog is! Map || mblog.isEmpty) {
          emptyMblog += 1;
          continue;
        }
        final WeiboMblogProfile? profile = profileMblog(
          mblog,
          index: profiles.length,
        );
        if (profile == null) {
          emptyMblog += 1;
          continue;
        }
        profiles.add(profile);
        mblogs.add(mblog.cast<String, Object?>());
        pageNos.add(pageNo);
        pageMblog += 1;
      }

      stats.add(
        WeiboDeepPageStat(
          pageNo: pageNo,
          httpStatus: page.httpStatus,
          cardTotal: cards.length,
          mblogCount: pageMblog,
          cardTypeCounts: typeCounts,
          cursorPresent: extractSinceId(page.body) != null,
        ),
      );
    }

    final WeiboDeepSample? retweeted = _firstSample(
      mblogs,
      pageNos,
      (Map<String, Object?> m) {
        final Object? node = m['retweeted_status'];
        return node is Map && node.isNotEmpty ? node : null;
      },
      'mblog.retweeted_status',
    );
    final WeiboDeepSample? mediaInfo = _firstSample(
      mblogs,
      pageNos,
      (Map<String, Object?> m) {
        final Object? node = _mediaInfoOf(m);
        return node is Map && node.isNotEmpty ? node : null;
      },
      'mblog.page_info.media_info',
    );

    return WeiboDeepSampleDump(
      pageStats: stats,
      profiles: profiles,
      mblogs: mblogs,
      mblogPageNos: pageNos,
      cardTypeCounts: globalTypes,
      emptyMblogCount: emptyMblog,
      retweetedSample: retweeted,
      mediaInfoSample: mediaInfo,
      note: _deepNote(
        pageCount: pages.length,
        totalMblog: profiles.length,
        retweetedCount: profiles
            .where((WeiboMblogProfile p) => p.hasRetweeted)
            .length,
        mediaInfoCount: _countMediaInfo(mblogs),
      ),
    );
  }

  static String _deepNote({
    required int pageCount,
    required int totalMblog,
    required int retweetedCount,
    required int mediaInfoCount,
  }) {
    if (pageCount == 0) return '没有发出任何请求';
    if (totalMblog == 0) return '$pageCount 页里都没有 mblog';
    return '深度采样：$pageCount 页 $totalMblog 条，'
        'retweeted_status $retweetedCount 条 / '
        'media_info $mediaInfoCount 条';
  }

  /// `data.cards`；解析失败按空列表处理。
  static List<Object?> _cardsOf(String body) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final Object? data = json?['data'];
    final Object? cards = data is Map ? data['cards'] : null;
    return cards is List ? cards.cast<Object?>() : const <Object?>[];
  }

  /// `page_info.media_info` 节点；不存在返回 null。
  ///
  /// 单独抽出来是因为「有 `page_info`」≠「有 `media_info`」：实测第 1 页
  /// 两条 `page_info` 都是 `type="webpage"` 外链卡，7 个 key 里没有
  /// `media_info`。用 `page_info` 判视频会误判成两条视频。
  static Object? _mediaInfoOf(Map<String, Object?> mblog) {
    final Object? pageInfo = mblog['page_info'];
    if (pageInfo is! Map) return null;
    return pageInfo['media_info'];
  }

  static bool _hasMediaInfo(Map<String, Object?> mblog) {
    final Object? node = _mediaInfoOf(mblog);
    return node is Map && node.isNotEmpty;
  }

  static int _countMediaInfo(List<Map<String, Object?>> mblogs) {
    int n = 0;
    for (final Map<String, Object?> m in mblogs) {
      if (_hasMediaInfo(m)) n += 1;
    }
    return n;
  }

  /// 挑第一条满足 [pick] 的 mblog，把该节点单独展开成字段树。
  ///
  /// 展开用 [describeNode] 以**该节点为根**，而不是展开整条 mblog：
  /// 整条展开时 200 行上限会被 `user.badge.*` 之类的噪声吃掉，
  /// `media_info` 深处那几个视频地址字段反而看不见。
  static WeiboDeepSample? _firstSample(
    List<Map<String, Object?>> mblogs,
    List<int> pageNos,
    Object? Function(Map<String, Object?> mblog) pick,
    String rootPath,
  ) {
    for (int i = 0; i < mblogs.length; i++) {
      final Map<String, Object?> mblog = mblogs[i];
      final Object? node = pick(mblog);
      if (node == null) continue;
      return WeiboDeepSample(
        pageNo: i < pageNos.length ? pageNos[i] : 0,
        index: i,
        header: _sampleHeader(mblog, pageNo: i < pageNos.length ? pageNos[i] : 0),
        lines: describeNode(rootPath, node),
      );
    }
    return null;
  }

  /// 样本出处一行：id / mid / 作者昵称，不含任何凭据。
  static String _sampleHeader(Map<String, Object?> mblog, {required int pageNo}) {
    final String id = _asCursor(mblog['id']) ?? '（无 id）';
    final String mid = _asCursor(mblog['mid']) ?? '（无 mid）';
    String author = '（无昵称）';
    final Object? user = mblog['user'];
    if (user is Map) {
      final Object? name = user['screen_name'];
      if (name is String && name.isNotEmpty) author = name;
    }
    return '出处：P$pageNo mblog.id=$id mid=$mid 作者=$author';
  }

  /// 纯函数：给一条 `mblog` 打类型标记。输入非 Map 时返回 null。
  ///
  /// 判定只用接口原始字段，**不做任何推断**：`pic_num > 0` 才算有图，
  /// `retweeted_status`/`page_info` 只认「存在且非 null」。
  static WeiboMblogProfile? profileMblog(Object? mblog, {int index = 0}) {
    if (mblog is! Map) return null;
    final Object? picNumRaw = mblog['pic_num'];
    final int picNum = picNumRaw is num
        ? picNumRaw.toInt()
        : (picNumRaw is String ? (int.tryParse(picNumRaw) ?? 0) : 0);

    final Object? textRaw = mblog['text'];
    final String text = textRaw is String ? textRaw : '';
    final Object? textLengthRaw = mblog['textLength'];
    final int textLength = textLengthRaw is num
        ? textLengthRaw.toInt()
        : (textLengthRaw is String
              ? (int.tryParse(textLengthRaw) ?? text.length)
              : text.length);

    final Object? titleRaw = mblog['title'];
    String title = '';
    if (titleRaw is Map) {
      final Object? t = titleRaw['text'];
      if (t is String) title = t;
    }

    return WeiboMblogProfile(
      index: index,
      picNum: picNum,
      hasPics: picNum > 0,
      hasRetweeted: mblog['retweeted_status'] != null,
      hasPageInfo: mblog['page_info'] != null,
      isLongText: mblog['isLongText'] == true,
      textLength: textLength,
      title: title,
    );
  }

  /// 纯函数：三类富媒体样本各挑**第一条**，返回它们在本批里的序号。
  ///
  /// 参数是「含 mblog 的卡片」列表（也可以直接传 mblog 列表），顺序即展示顺序。
  /// 序号**只数含 mblog 的卡片**：header 卡（`card_type=11` 等）不占号，
  /// 与 [judgeRichStructure] 摘要表里的 `#N` 完全一致。
  /// 某类一个样本都没有时，对应字段为 null——调用方要如实报「无样本」。
  static WeiboSamplePicks pickSamples(List<Object?> cards) {
    int? picsIndex;
    int? retweetedIndex;
    int? pageInfoIndex;
    int i = 0;
    for (final Object? card in cards) {
      final Object? mblog = card is Map ? card['mblog'] : card;
      final WeiboMblogProfile? profile = profileMblog(mblog, index: i);
      if (profile == null) continue;
      i += 1;
      if (picsIndex == null && profile.hasPics) picsIndex = profile.index;
      if (retweetedIndex == null && profile.hasRetweeted) {
        retweetedIndex = profile.index;
      }
      if (pageInfoIndex == null && profile.hasPageInfo) {
        pageInfoIndex = profile.index;
      }
    }
    return WeiboSamplePicks(
      picsIndex: picsIndex,
      retweetedIndex: retweetedIndex,
      pageInfoIndex: pageInfoIndex,
    );
  }

  /// 纯函数：把一次 getIndex 响应体整理成**全量分类采样** dump。必须可离线单测。
  static WeiboRichStructureDump judgeRichStructure({
    required int? httpStatus,
    required String body,
  }) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final Object? data = json?['data'];
    final Map<String, dynamic>? dataMap =
        data is Map ? data.cast<String, dynamic>() : null;
    final Object? cardsRaw = dataMap?['cards'];
    final List<Object?> cards =
        cardsRaw is List ? cardsRaw.cast<Object?>() : const <Object?>[];

    final Map<String, int> typeCounts = <String, int>{};
    int emptyMblog = 0;
    final List<WeiboMblogProfile> profiles = <WeiboMblogProfile>[];
    final List<Map<String, Object?>> mblogs = <Map<String, Object?>>[];
    for (final Object? card in cards) {
      if (card is! Map) continue;
      final Object? type = card['card_type'];
      final String typeKey = type == null ? '（无 card_type）' : type.toString();
      typeCounts[typeKey] = (typeCounts[typeKey] ?? 0) + 1;

      final Object? mblog = card['mblog'];
      if (mblog == null) {
        emptyMblog += 1;
        continue;
      }
      final WeiboMblogProfile? profile = profileMblog(
        mblog,
        index: profiles.length,
      );
      if (profile == null) {
        emptyMblog += 1;
        continue;
      }
      profiles.add(profile);
      mblogs.add((mblog as Map).cast<String, Object?>());
    }

    final Object? cardlistInfo = dataMap?['cardlistInfo'];
    final Map<String, dynamic>? cardlistMap = cardlistInfo is Map
        ? cardlistInfo.cast<String, dynamic>()
        : null;
    final List<String> cardlistKeys = <String>[
      ...?cardlistMap?.keys,
    ]..sort();

    final WeiboSamplePicks picks = WeiboSamplePicks(
      picsIndex: profiles
          .where((WeiboMblogProfile p) => p.hasPics)
          .map((WeiboMblogProfile p) => p.index)
          .firstOrNull,
      retweetedIndex: profiles
          .where((WeiboMblogProfile p) => p.hasRetweeted)
          .map((WeiboMblogProfile p) => p.index)
          .firstOrNull,
      pageInfoIndex: profiles
          .where((WeiboMblogProfile p) => p.hasPageInfo)
          .map((WeiboMblogProfile p) => p.index)
          .firstOrNull,
    );

    return WeiboRichStructureDump(
      httpStatus: httpStatus,
      cardTotal: cards.length,
      cardTypeCounts: typeCounts,
      emptyMblogCount: emptyMblog,
      cardlistInfoKeys: cardlistKeys,
      sinceIdPresent: extractSinceId(body) != null,
      profiles: profiles,
      picks: picks,
      mblogs: mblogs,
      note: _richNote(
        httpStatus: httpStatus,
        cardTotal: cards.length,
        profileCount: profiles.length,
        picks: picks,
      ),
    );
  }

  static String _richNote({
    required int? httpStatus,
    required int cardTotal,
    required int profileCount,
    required WeiboSamplePicks picks,
  }) {
    if (httpStatus == null) return '请求失败（网络或超时）';
    if (httpStatus != 200) return '接口未放行（HTTP $httpStatus）';
    if (cardTotal == 0) return '响应里没有卡片';
    if (profileCount == 0) return '卡片里都没有 mblog';
    final List<String> parts = <String>[];
    parts.add('pics ${picks.picsIndex == null ? '无' : '#${picks.picsIndex}'}');
    parts.add('retweeted ${picks.retweetedIndex == null ? '无' : '#${picks.retweetedIndex}'}');
    parts.add('page_info ${picks.pageInfoIndex == null ? '无' : '#${picks.pageInfoIndex}'}');
    return '全量分类采样：$profileCount 条 mblog，样本 ${parts.join(' / ')}';
  }

  /// 纯函数：把一次 getIndex 响应体整理成单条结构 dump。必须可离线单测。
  ///
  /// ⚠️ 已不再是 UI 主路径：界面上「字段结构 dump」走 [judgeRichStructure]
  /// 做全量分类采样。这里保留是为了向后兼容（与已有单测）。
  static WeiboStructureDump judgeStructure({
    required int? httpStatus,
    required String body,
  }) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final Object? data = json?['data'];
    final Map<String, dynamic>? dataMap =
        data is Map ? data.cast<String, dynamic>() : null;
    final Object? cardsRaw = dataMap?['cards'];
    final List<Object?> cards =
        cardsRaw is List ? cardsRaw.cast<Object?>() : const <Object?>[];

    final Map<String, int> typeCounts = <String, int>{};
    int emptyMblog = 0;
    Object? firstMblog;
    final List<Map<String, Object?>> mblogs = <Map<String, Object?>>[];
    for (final Object? card in cards) {
      if (card is! Map) continue;
      final Object? type = card['card_type'];
      final String typeKey = type == null ? '（无 card_type）' : type.toString();
      typeCounts[typeKey] = (typeCounts[typeKey] ?? 0) + 1;

      final Object? mblog = card['mblog'];
      if (mblog == null) {
        emptyMblog += 1;
        continue;
      }
      firstMblog ??= mblog;
      if (mblog is Map) mblogs.add(mblog.cast<String, Object?>());
    }

    final Object? cardlistInfo = dataMap?['cardlistInfo'];
    final Map<String, dynamic>? cardlistMap = cardlistInfo is Map
        ? cardlistInfo.cast<String, dynamic>()
        : null;
    final List<String> cardlistKeys = <String>[
      ...?cardlistMap?.keys,
    ]..sort();

    final List<String> lines = describeMblog(firstMblog);

    final String note = _structureNote(
      httpStatus: httpStatus,
      cardTotal: cards.length,
      mblogCount: mblogs.length,
      lines: lines,
    );

    return WeiboStructureDump(
      httpStatus: httpStatus,
      cardTotal: cards.length,
      cardTypeCounts: typeCounts,
      mblogLines: lines,
      emptyMblogCount: emptyMblog,
      cardlistInfoKeys: cardlistKeys,
      sinceIdPresent: extractSinceId(body) != null,
      note: note,
    );
  }

  static String _structureNote({
    required int? httpStatus,
    required int cardTotal,
    required int mblogCount,
    required List<String> lines,
  }) {
    if (httpStatus == null) return '请求失败（网络或超时）';
    if (httpStatus != 200) return '接口未放行（HTTP $httpStatus）';
    if (cardTotal == 0) return '响应里没有卡片';
    if (mblogCount == 0) return '卡片里都没有 mblog';
    return '已展开 ${lines.length} 行字段（共 $mblogCount 条 mblog）';
  }

  /// 把一条 mblog 展开成「路径 → 类型 → 样例值」的文本行列表。
  ///
  /// 递归展开 Map/List，深度上限 4（`mblog` 自身算深度 0），单个值截断到
  /// 80 字符，最多产出 200 行。数组下标写成 `mblog.pics[0].url`。
  ///
  /// 深度 3 不够：`retweeted_status` 本身在深度 1，它的标量字段在深度 2，
  /// 但 `retweeted_status.pics[0].url` 要到深度 4——转发样本的配图字段
  /// 会整片看不见。所以这里放到 4，代价是行数变多（仍有 200 行硬上限）。
  ///
  /// 空容器**单独成行**（否则「有没有这个字段」就看不出来了）；
  /// 标量一律成行。null / 非 Map 输入返回空列表，绝不抛异常。
  static List<String> describeMblog(Object? mblog) {
    final List<String> out = <String>[];
    if (mblog is! Map || mblog.isEmpty) return out;
    _diagWalkTree(
      'mblog',
      mblog,
      0,
      out,
      maxLines: _maxMblogLines,
      maxDepth: _maxMblogDepth,
      maxListItems: 0,
    );
    return out;
  }

  /// 以任意节点为根做同样的展开，路径前缀由 [rootPath] 指定。
  ///
  /// 深度采样要用它把 `retweeted_status` / `page_info.media_info` **单独**
  /// 摊平：如果直接展开整条 mblog，200 行上限会被外层的 user / badge 字段
  /// 吃掉，真正的转发/视频字段反而看不见。这里把样本节点当根，深度预算
  /// 就全部花在它身上。
  ///
  /// 空 Map / 空 List 也单独成一行（和 [describeMblog] 的约定一致）；
  /// 标量根直接输出一行。绝不抛异常。
  static List<String> describeNode(String rootPath, Object? node) {
    final List<String> out = <String>[];
    if (rootPath.isEmpty || node == null) return out;
    if (node is Map && node.isEmpty) {
      out.add('$rootPath : Map : {}');
      return out;
    }
    if (node is List && node.isEmpty) {
      out.add('$rootPath : List : []');
      return out;
    }
    _diagWalkTree(
      rootPath,
      node,
      0,
      out,
      maxLines: _maxMblogLines,
      maxDepth: _maxMblogDepth,
      maxListItems: 0,
    );
    return out;
  }

  /// 深度上限：`mblog`(0) → `mblog.user`(1) → `mblog.user.x`(2) →
  /// `mblog.retweeted_status.pics[0]`(3) → `…[0].url`(4)。
  static const int _maxMblogDepth = 4;

  /// 行数上限。
  static const int _maxMblogLines = 200;

  /// 发一次 GET，带上与 [runOnce] 完全一致的请求头。返回状态码与原始响应体。
  ///
  /// 失败时返回 `httpStatus: null`，**不抛异常、不重试**。
  Future<_PagingFetch> _fetchPaging(String url, String cookie) async {
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: <String, String>{
            'User-Agent': _userAgent,
            'Referer': '${WeiboWebUrls.mbBase}/u/1782488734',
            'X-Requested-With': 'XMLHttpRequest',
            'MWeibo-Pwa': '1',
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            if (cookie.isNotEmpty) 'Cookie': cookie,
          },
        ),
      );
      final Object? data = res.data;
      return _PagingFetch(
        res.statusCode,
        data is String ? data : (data?.toString() ?? ''),
      );
    } on DioException catch (e) {
      // 只取状态码与 body，绝不把 requestOptions.headers 拼进任何文案。
      final Object? data = e.response?.data;
      return _PagingFetch(
        e.response?.statusCode,
        data is String ? data : (data?.toString() ?? ''),
      );
    } catch (_) {
      return const _PagingFetch(null, '');
    }
  }

  /// 纯函数：从 getIndex 响应体里找出分页游标。
  ///
  /// 依次尝试 `data.cardlistInfo.since_id` → `data.since_id` →
  /// `cardlistInfo.since_id` → 顶层 `since_id`，取第一个非空值。
  ///
  /// 返回值**原样是字符串**（数字会被转成字符串），不做数值转换：
  /// 这是 19 位大整数，过 `int`/`double` 会丢精度。
  /// 解析失败或全都取不到时返回 null，绝不抛异常。
  static String? extractSinceId(String body) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    if (json == null) return null;

    final Object? data = json['data'];
    final Map<String, dynamic>? dataMap = data is Map
        ? data.cast<String, dynamic>()
        : null;
    final Object? cardlistInfo = dataMap?['cardlistInfo'];
    final Map<String, dynamic>? cardlistMap = cardlistInfo is Map
        ? cardlistInfo.cast<String, dynamic>()
        : null;

    final List<String?> candidates = <String?>[
      _asCursor(cardlistMap?['since_id']),
      _asCursor(dataMap?['since_id']),
      _asCursor(json['cardlistInfo'] is Map
          ? (json['cardlistInfo'] as Map)['since_id']
          : null),
      _asCursor(json['since_id']),
    ];
    for (final String? candidate in candidates) {
      if (candidate != null && candidate.isNotEmpty) return candidate;
    }
    return null;
  }

  /// 纯函数：算两页 `mblog` id 的差异。
  ///
  /// `duplicate` = 交集大小，`novel` = 第 2 页里第 1 页没出现过的条数。
  /// 两页各自用 `mblog.id`，取不到就退回 `mblog.mid`；id 优先按字符串比较
  /// （19 位大整数过数值类型会丢精度）。非法 JSON 当作空页，不抛异常。
  static ({int duplicate, int novel}) diffMblogIds(
    String page1Body,
    String page2Body,
  ) {
    final Set<String> first = _mblogIds(page1Body);
    final Set<String> second = _mblogIds(page2Body);
    int duplicate = 0;
    for (final String id in second) {
      if (first.contains(id)) duplicate += 1;
    }
    return (duplicate: duplicate, novel: second.length - duplicate);
  }

  /// 纯函数：把两页结果翻译成人话结论。必须可离线单测。
  static WeiboPagingDiagResult judgePaging({
    required int? page1Status,
    required String page1Body,
    required String? sinceIdFromPage1,
    required int? page2Status,
    required String page2Body,
  }) {
    final int page1Cards = _countCards(page1Body);
    final int page2Cards = _countCards(page2Body);
    final String? sinceId2 = page2Status == null
        ? null
        : extractSinceId(page2Body);
    final ({int duplicate, int novel}) diff = page2Status == null
        ? (duplicate: 0, novel: 0)
        : diffMblogIds(page1Body, page2Body);
    final bool advanced =
        sinceIdFromPage1 != null && sinceId2 != null && sinceId2 != sinceIdFromPage1;

    final String note = _pagingNote(
      page1Status: page1Status,
      page1Cards: page1Cards,
      sinceIdFromPage1: sinceIdFromPage1,
      page2Status: page2Status,
      page2Cards: page2Cards,
      duplicate: diff.duplicate,
      novel: diff.novel,
      advanced: advanced,
    );

    return WeiboPagingDiagResult(
      page1Status: page1Status ?? 0,
      page1Cards: page1Cards,
      sinceIdFromPage1: sinceIdFromPage1,
      page2Status: page2Status ?? 0,
      page2Cards: page2Cards,
      duplicateCount: diff.duplicate,
      newCount: diff.novel,
      sinceIdFromPage2: sinceId2,
      cursorAdvanced: advanced,
      note: note,
    );
  }

  static String _pagingNote({
    required int? page1Status,
    required int page1Cards,
    required String? sinceIdFromPage1,
    required int? page2Status,
    required int page2Cards,
    required int duplicate,
    required int novel,
    required bool advanced,
  }) {
    if (page1Status == null) return '接口不可用（第 1 页请求失败）';
    if (page1Status == 432) return '接口不可用（WAF 拦截 432）';
    if (page1Status != 200) return '接口不可用（第 1 页 HTTP $page1Status）';
    if (page1Cards == 0) return '接口不可用（第 1 页没有卡片）';
    if (sinceIdFromPage1 == null) return '未找到 since_id 字段';
    if (page2Status == null) return '分页不可用（第 2 页请求失败）';
    if (page2Status != 200) return '分页不可用（第 2 页 HTTP $page2Status）';
    if (page2Cards == 0) return '分页异常：第 2 页没有卡片';
    if (novel == 0) {
      return duplicate > 0
          ? '分页异常：第 2 页 $duplicate 条全部与第 1 页重复'
          : '分页异常：第 2 页没有可用内容';
    }
    if (duplicate == 0) {
      return '分页可用：第 2 页 $novel 条全部为新内容';
    }
    return '分页可用：第 2 页新增 $novel 条，另有 $duplicate 条与第 1 页重复';
  }

  /// 只取 curl 候选值的字符串形态；数字也原样转字符串，不做数值转换。
  static String? _asCursor(Object? value) {
    if (value == null) return null;
    if (value is String) return value.trim();
    if (value is num) return value.toString();
    if (value is bool) return null;
    return null;
  }

  /// 抽出某页的 mblog id 集合（`mblog.id`，退回 `mblog.mid`）。
  static Set<String> _mblogIds(String body) {
    final Set<String> ids = <String>{};
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    if (json == null) return ids;
    final Object? data = json['data'];
    if (data is! Map) return ids;
    final Object? cards = data['cards'];
    if (cards is! List) return ids;
    for (final Object? card in cards) {
      if (card is! Map) continue;
      final Object? mblog = card['mblog'];
      if (mblog is! Map) continue;
      final String? id = _asCursor(mblog['id']) ?? _asCursor(mblog['mid']);
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  /// 纯函数：根据状态码与响应体判定。必须可离线单测。
  ///
  /// 判定优先级：432 → 200 且 ok==1 且有卡片 → 可用 → 200 且 ok==-100 →
  /// 要求登录 → 其它带上状态码。body 里的内容一律不出现在 note 里。
  static WeiboApiDiagResult judge({
    required int? httpStatus,
    required String body,
  }) {
    final int cardCount = _countCards(body);
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final Object? okValue = json?['ok'];
    final int? okFlag = okValue is num
        ? okValue.toInt()
        : (okValue is String ? int.tryParse(okValue) : null);

    if (httpStatus == 432) {
      return WeiboApiDiagResult(
        httpStatus: 432,
        cardCount: cardCount,
        ok: false,
        note: 'WAF 拦截（432）',
      );
    }
    if (httpStatus == 200 && okFlag == 1 && cardCount >= 1) {
      return WeiboApiDiagResult(
        httpStatus: 200,
        cardCount: cardCount,
        ok: true,
        note: '接口可用',
      );
    }
    if (httpStatus == 200 && okFlag == -100) {
      return WeiboApiDiagResult(
        httpStatus: 200,
        cardCount: cardCount,
        ok: false,
        note: '仍要求登录（-100）',
      );
    }
    if (httpStatus == null) {
      return WeiboApiDiagResult(
        httpStatus: null,
        cardCount: cardCount,
        ok: false,
        note: '请求失败（网络或超时）',
      );
    }
    if (httpStatus == 200 && json == null) {
      return WeiboApiDiagResult(
        httpStatus: 200,
        cardCount: cardCount,
        ok: false,
        note: '响应不是有效 JSON（HTTP 200）',
      );
    }
    return WeiboApiDiagResult(
      httpStatus: httpStatus,
      cardCount: cardCount,
      ok: false,
      note: '接口未放行（HTTP $httpStatus）',
    );
  }

  /// 数 `data.cards` 里含 `mblog` 字段的元素个数；解析失败按 0 处理。
  static int _countCards(String body) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    if (json == null) return 0;
    final Object? data = json['data'];
    if (data is! Map) return 0;
    final Object? cards = data['cards'];
    if (cards is! List) return 0;
    int count = 0;
    for (final Object? card in cards) {
      if (card is Map && card.containsKey('mblog') && card['mblog'] != null) {
        count += 1;
      }
    }
    return count;
  }

}

/// 分页测试里单次请求的原始产物：状态码 + 响应体。
///
/// `httpStatus == null` 表示请求本身失败（断网 / 超时 / DNS）。
class _PagingFetch {
  const _PagingFetch(this.httpStatus, this.body);

  final int? httpStatus;
  final String body;
}


/// 微博「我的关注列表」探针（**纯诊断工具，不是正式数据层**）。
///
/// ## 它要回答的问题
///
/// 微博订阅源在「订阅源」页显示成「微博 1782488734」而不是博主昵称（缺陷
/// N5）——根因是建订阅源时只有 UID，没有 uid → 昵称/头像 的映射。B 站侧靠
/// 「从关注列表导入」解决，微博侧一直没有对应的接口结论。本类只回答结构性
/// 问题，**不写任何正式功能**：
///
/// 1. `containerid=231093_-_selffollowed` 带真实 cookie 时能不能通；
/// 2. 博主列表的实际路径、每条里 uid / 昵称 / 头像的确切字段名与类型；
/// 3. 能不能分页、游标叫什么、第 2 页会不会和第 1 页重复；
/// 4. 一共能拿到多少个关注；
/// 5. cookie 为空（未登录）时返回什么——只测 1 次，确定判定依据。
///
/// P2（关注动态流）只是附带：试一个候选 + 一个对照，**失败不纠缠**。
///
/// ## 实战踩过的那条线：不要用「关注列表 × 逐个拉时间线」
///
/// 100 个关注 = 100 个 `getIndex` 请求，必然触发风控。本类**绝不**这么做：
/// 请求预算硬编码在 [maxRequests]，调用方调不动。
///
/// ## 凭据安全（硬约束）
///
/// cookie 只作为请求头出现：不进任何日志、不进结果对象、不进异常文案、
/// 不落盘。结果里连长度都不带；界面上由调用方单独显示长度。
///
/// ## 请求节制（硬上限，调用方改不动）
///
/// - 全流程最多 [maxRequests] 个请求，达到即停；
/// - 同一 URL 变体最多 [maxPerVariant] 次；
/// - 翻页最多 [maxPages] 页；
/// - 两次请求间隔 ≥ [minGap]；
/// - 连续 [maxConsecutive432] 次 432 立刻停；
/// - 单项超时 [itemTimeout]。
///
/// 刻意**不挂重试拦截器**（裸 `Dio`），也**不做任何风控绕过**：不伪造
/// `XSRF-TOKEN`、不换 UA、不重试轰炸。
class WeiboFollowingProbe {
  WeiboFollowingProbe({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  /// 全流程请求数硬上限。
  static const int maxRequests = 6;

  /// 同一 URL 变体最多发几次。
  static const int maxPerVariant = 2;

  /// 翻页硬上限（页数 = 请求数）。
  static const int maxPages = 2;

  /// 连续 432 达到这个数就立刻停。
  static const int maxConsecutive432 = 3;

  /// 两次请求之间的最小间隔。
  static const Duration minGap = Duration(milliseconds: 2500);

  /// 单项超时。
  static const Duration itemTimeout = Duration(seconds: 20);

  /// 「前 N 个博主的完整字段」里的 N。
  static const int maxBloggers = 3;

  /// 单个博主字段树的展开深度。
  static const int describeDepth = 2;

  /// 单个博主字段树的行数上限。
  static const int maxLinesPerUser = 22;

  /// 单值截断长度。
  static const int maxValueChars = 80;

  /// P1：我的关注列表（任务给定候选）。
  static const String followingEndpoint =
      '${WeiboWebUrls.mbBase}/api/container/getIndex'
      '?containerid=231093_-_selffollowed';

  /// P2-A：m 站「关注」tab 的混合时间流候选。
  static const String friendsFeedEndpoint = '${WeiboWebUrls.mbBase}/feed/friends';

  /// P2-B：`containerid=102803` 推荐流（**对照**，不是关注流）。
  static const String recommendControlEndpoint =
      '${WeiboWebUrls.mbBase}/api/container/getIndex?containerid=102803';

  /// 移动端 Chrome UA（与既有诊断保持一致：桌面 UA 会被重定向）。
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// 形似游标 / 页码的 key（只用于**如实报告**存在哪些字段）。
  static final RegExp _cursorKey = RegExp(
    r'^(since_id|max_id|page|page_num|pageNo|total_page|next_cursor|cursor)$',
  );

  /// 形似总数的 key。
  static final RegExp _totalKey = RegExp(
    r'^(total|total_number|count|total_count|following_count)$',
  );

  /// URL 里**必须脱敏**的参数名（凭据 / 一次性票据）。
  static final RegExp _sensitiveParam = RegExp(
    r'^(cookie|token|access_token|st|gsid|s|SUB|SUBP|sessionid|sig|sign)$',
    caseSensitive: false,
  );

  static Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: itemTimeout,
        receiveTimeout: itemTimeout,
        sendTimeout: itemTimeout,
        responseType: ResponseType.plain,
        followRedirects: true,
        // 放宽到 <600：432 / 5xx 都走正常返回路径，由本类显式判定，
        // 这样「状态码多少」这个结论不会变成一句缓存过的异常。
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
  final Map<String, int> _variantUsed = <String, int>{};

  /// 是否已达硬上限 / 已被连续 432 叫停。
  bool get aborted => _aborted;

  /// 已发出的请求数。
  int get requestCount => _requestCount;

  Future<void> _throttle() async {
    final DateTime? last = _lastRequestAt;
    if (last == null) return;
    final Duration elapsed = DateTime.now().difference(last);
    if (elapsed >= minGap) return;
    await Future<void>.delayed(minGap - elapsed);
  }

  /// 发一次 GET。cookie 只进 header；失败返回 `httpStatus: null`，不抛不重试。
  Future<_Fetch> _get(
    String url,
    String cookie, {
    required String referer,
    required String label,
    required String variant,
  }) async {
    if (_aborted) {
      _log.add('$label → 已叫停，未发出');
      return const _Fetch(httpStatus: null, body: '', skipped: true);
    }
    if (_requestCount >= maxRequests) {
      _aborted = true;
      _log.add('$label → 达到请求上限 $maxRequests，未发出');
      return const _Fetch(httpStatus: null, body: '', skipped: true);
    }
    final int used = _variantUsed[variant] ?? 0;
    if (used >= maxPerVariant) {
      _log.add('$label → 同一变体已发 $used 次（上限 $maxPerVariant），未发出');
      return const _Fetch(httpStatus: null, body: '', skipped: true);
    }

    await _throttle();
    _requestCount += 1;
    _variantUsed[variant] = used + 1;

    final String trimmed = cookie.trim();
    _Fetch fetch;
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: <String, String>{
            'User-Agent': _userAgent,
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
      fetch = _Fetch(
        httpStatus: res.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } on DioException catch (e) {
      // 只取状态码与 body，绝不把 requestOptions.headers 拼进任何文案。
      final Object? data = e.response?.data;
      fetch = _Fetch(
        httpStatus: e.response?.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } catch (_) {
      fetch = const _Fetch(httpStatus: null, body: '');
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
    } else {
      _consecutive432 = 0;
    }
    _log.add('$label → ${status == null ? '请求失败' : 'HTTP $status'}');
    return fetch;
  }

  // ------------------------------------------------------------ 主流程

  /// 跑一次关注列表探针：P1 第 1 页 → 第 2 页 → 未登录对照 → P2 关注流 1 个 + 对照 1 个。
  ///
  /// 请求预算：2（P1 翻页）+ 1（未登录）+ 2（P2）= 5，硬上限 [maxRequests]=6。
  ///
  /// 任一页**非 200 / ok≠1 / 被叫停**就立刻停止后续请求，不再制造无谓请求。
  /// 凭据安全：cookie 只进请求头，不进结果对象。
  Future<FollowingProbeResult> run({
    required String cookie,
    bool withGuestCheck = true,
    bool withFeedProbe = true,
  }) async {
    final List<FollowingPageStat> pages = <FollowingPageStat>[];
    final Set<String> seenUids = <String>{};
    final String referer = '${WeiboWebUrls.mbBase}/';

    // —— P1 第 1 页 ——
    FollowingPageStat? first = await _followingPage(
      pageNo: 1,
      pageParam: null,
      cookie: cookie,
      referer: referer,
      seenUids: seenUids,
      variant: 'p1',
    );
    if (first != null) pages.add(first);

    // —— P1 第 2 页：只有第 1 页真的给了数据才翻 ——
    String? page2Param;
    if (first != null &&
        first.httpStatus == 200 &&
        first.okRaw == '1' &&
        first.userCount > 0 &&
        !_aborted) {
      page2Param = 'page=2';
      final FollowingPageStat? second = await _followingPage(
        pageNo: 2,
        pageParam: page2Param,
        cookie: cookie,
        referer: referer,
        seenUids: seenUids,
        variant: 'p1',
      );
      if (second != null) pages.add(second);
    }

    // —— 未登录对照：只发 1 次 ——
    FollowingPageStat? guest;
    String guestBodyHead = '';
    if (withGuestCheck && !_aborted) {
      final _Fetch f = await _get(
        followingEndpoint,
        '',
        referer: referer,
        label: '未登录对照（cookie 为空）',
        variant: 'guest',
      );
      if (!f.skipped) {
        guest = parsePage(pageNo: 0, httpStatus: f.httpStatus, body: f.body);
        guestBodyHead = _diagHeadOf(f.body);
      }
    }

    // —— P2 关注动态流：1 个候选 + 1 个对照，失败不纠缠 ——
    final List<FeedProbeStat> feeds = <FeedProbeStat>[];
    if (withFeedProbe && !_aborted) {
      final _Fetch a = await _get(
        friendsFeedEndpoint,
        cookie,
        referer: '${WeiboWebUrls.mbBase}/',
        label: 'P2-A 关注 tab（feed/friends）',
        variant: 'p2a',
      );
      if (!a.skipped) {
        feeds.add(
          parseFeed(
            label: 'P2-A m 站「关注」tab',
            url: friendsFeedEndpoint,
            isFollowingFeedCandidate: true,
            httpStatus: a.httpStatus,
            body: a.body,
          ),
        );
      }
      final FeedProbeStat? last = feeds.isEmpty ? null : feeds.last;
      final bool needControl = last != null &&
          (last.httpStatus != 200 || last.okRaw != '1' || last.mblogCount == 0);
      if (needControl && !_aborted) {
        final _Fetch b = await _get(
          recommendControlEndpoint,
          cookie,
          referer: '${WeiboWebUrls.mbBase}/',
          label: 'P2-B 推荐流对照（containerid=102803）',
          variant: 'p2b',
        );
        if (!b.skipped) {
          feeds.add(
            parseFeed(
              label: 'P2-B containerid=102803（对照）',
              url: recommendControlEndpoint,
              isFollowingFeedCandidate: false,
              httpStatus: b.httpStatus,
              body: b.body,
            ),
          );
        }
      }
    }

    return FollowingProbeResult(
      pages: pages,
      page2Param: page2Param,
      guest: guest,
      guestBodyHead: guestBodyHead,
      feeds: feeds,
      requestLog: List<String>.unmodifiable(_log),
      requestCount: _requestCount,
      saw432: _saw432,
      max432Streak: _max432Streak,
      note: _overallNote(pages: pages, feeds: feeds, guest: guest),
    );
  }

  Future<FollowingPageStat?> _followingPage({
    required int pageNo,
    required String? pageParam,
    required String cookie,
    required String referer,
    required Set<String> seenUids,
    required String variant,
  }) async {
    final String url = followingUrl(pageParam: pageParam);
    final _Fetch f = await _get(
      url,
      cookie,
      referer: referer,
      label: 'P1 关注列表第$pageNo页',
      variant: variant,
    );
    if (f.skipped) return null;
    return parsePage(
      pageNo: pageNo,
      httpStatus: f.httpStatus,
      body: f.body,
      seenUids: seenUids,
    );
  }

  /// 关注列表 URL。**永远不发明参数**：`page` 要么不传，要么原样传 `page=2`。
  static String followingUrl({String? pageParam}) {
    final String p = (pageParam ?? '').trim();
    if (p.isEmpty) return followingEndpoint;
    return '$followingEndpoint&$p';
  }

  // ------------------------------------------------------------ 单页解析（纯函数）

  /// 纯函数：把一页关注列表响应整理成结构统计。必须可离线单测。
  ///
  /// 列表路径**不猜**：从响应里按「长得像用户对象」的特征扫描（含
  /// `screen_name` 且有 `id`/`idstr`/`uid`），把命中位置归一化成
  /// `data.cards[i].card_group[j].user` 这种模式一并报出来。
  ///
  /// [seenUids] 非空时，会把本页 uid 与它比对得出重复条数，并把本页 uid
  /// 合并进去（跨页去重用）。解析失败一律按「空页」处理，绝不抛异常。
  static FollowingPageStat parsePage({
    required int pageNo,
    required int? httpStatus,
    required String body,
    Set<String>? seenUids,
  }) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final Object? okValue = json?['ok'];
    final String okRaw = okValue == null ? '（无 ok）' : okValue.toString();
    final Map<String, dynamic>? data = _diagAsMap(json?['data']);

    // —— 用户对象扫描 ——
    final List<FollowingUser> users = <FollowingUser>[];
    final Map<String, FollowingUser> byUid = <String, FollowingUser>{};
    final List<String> rawPaths = <String>[];
    _collectUsers(data, 'data', 0, users, byUid, rawPaths);

    final List<String> patterns = <String>[];
    for (final String p in rawPaths) {
      final String normalized = normalizePath(p);
      if (!patterns.contains(normalized)) patterns.add(normalized);
    }
    patterns.sort();

    int duplicate = 0;
    if (seenUids != null) {
      for (final FollowingUser u in users) {
        final String? uid = u.uid;
        if (uid == null) continue;
        if (seenUids.contains(uid)) duplicate += 1;
      }
      for (final FollowingUser u in users) {
        final String? uid = u.uid;
        if (uid != null) seenUids.add(uid);
      }
    }

    // —— 总数：先找字段，再从卡片标题/描述里捞数字线索 ——
    int? totalValue;
    String? totalField;
    final List<String> totalCandidates = <String>[];
    void scanTotal(Map<String, dynamic>? map, String prefix) {
      if (map == null) return;
      for (final MapEntry<String, dynamic> e in map.entries) {
        if (!_totalKey.hasMatch(e.key)) continue;
        final Object? v = e.value;
        final String text = v is String ? v : (v?.toString() ?? '');
        totalCandidates.add('$prefix${e.key} = ${_diagMask(text)}（${_diagTypeName(v)}）');
      }
    }

    scanTotal(data, 'data.');
    scanTotal(json, '');
    for (final MapEntry<String, dynamic> e in _totalEntries(data, 'data.')) {
      totalValue = _diagAsInt(e.value);
      totalField = e.key;
      break;
    }
    if (totalField == null) {
      for (final MapEntry<String, dynamic> e in _totalEntries(json, '')) {
        totalValue = _diagAsInt(e.value);
        totalField = e.key;
        break;
      }
    }

    // 总数线索：cards[] 与 cards[].card_group[] 的标题/描述里都可能带
    // 「关注 128 人」这类文案（关注数本身常常**不在**任何字段里）。
    final List<String> totalHints = <String>[];
    final Object? cardsRaw = data?['cards'];
    final RegExp hasDigit = RegExp(r'\d');
    void collectHints(Map<String, dynamic>? card, String path) {
      if (card == null) return;
      for (final String key in const <String>['title', 'desc', 'name']) {
        final String? text = _diagAsText(card[key]);
        if (text == null || !hasDigit.hasMatch(text)) continue;
        if (totalHints.length >= 4) return;
        totalHints.add('$path.$key = "$text"');
      }
    }

    if (cardsRaw is List) {
      for (int i = 0; i < cardsRaw.length && totalHints.length < 4; i++) {
        final Map<String, dynamic>? card = _diagAsMap(cardsRaw[i]);
        if (card == null) continue;
        collectHints(card, 'data.cards[$i]');
        final Object? cg = card['card_group'];
        if (cg is! List) continue;
        for (int j = 0; j < cg.length && totalHints.length < 4; j++) {
          final Map<String, dynamic>? sub = _diagAsMap(cg[j]);
          if (sub == null) continue;
          collectHints(sub, 'data.cards[$i].card_group[$j]');
        }
      }
    }

    // —— 游标候选 ——
    final List<String> cursorCandidates = <String>[];
    void scanCursor(Map<String, dynamic>? map, String prefix) {
      if (map == null) return;
      for (final MapEntry<String, dynamic> e in map.entries) {
        if (!_cursorKey.hasMatch(e.key)) continue;
        final Object? v = e.value;
        final String text = v is String ? v : (v?.toString() ?? '');
        cursorCandidates.add('$prefix${e.key} = ${_diagMask(text)}（${_diagTypeName(v)}）');
      }
    }

    scanCursor(data, 'data.');
    scanCursor(json, '');

    // —— 卡片骨架（列表到底挂在哪里）——
    final List<String> cardShape = <String>[];
    if (cardsRaw is List) {
      cardShape.add('data.cards : List（${cardsRaw.length} 项）');
      for (int i = 0; i < cardsRaw.length && i < 6; i++) {
        final Map<String, dynamic>? card = _diagAsMap(cardsRaw[i]);
        if (card == null) {
          cardShape.add('  cards[$i] : ${_diagTypeName(cardsRaw[i])}');
          continue;
        }
        final List<String> parts = <String>[];
        if (card['card_type'] != null) parts.add('card_type=${card['card_type']}');
        final Object? cg = card['card_group'];
        if (cg is List) parts.add('card_group=${cg.length} 项');
        if (card['title'] != null) {
          parts.add('title=${_diagProbeSampleValue(card['title'])}');
        }
        cardShape.add(
          '  cards[$i] : ${parts.isEmpty ? '（无标志字段）' : parts.join(' · ')}'
          '  keys=[${_diagSortedKeys(card).join(',')}]',
        );
      }
    } else if (cardsRaw != null) {
      cardShape.add('data.cards 不是 List，而是 ${_diagTypeName(cardsRaw)}');
    } else {
      cardShape.add('data.cards 不存在；data keys=[${_diagSortedKeys(data).join(',')}]');
    }

    final List<String> fieldAnswers = users.isEmpty
        ? const <String>[]
        : answerUserFields(users.first.raw, path: users.first.path);

    final List<String> userTrees = <String>[];
    for (int i = 0; i < users.length && i < maxBloggers; i++) {
      final FollowingUser u = users[i];
      userTrees.add('—— 第 ${i + 1} 个（${u.path}）——');
      final List<String> lines = describeUser(u.raw, rootPath: u.path);
      if (lines.isEmpty) {
        userTrees.add('（空对象）');
      } else {
        userTrees.addAll(lines);
      }
    }

    return FollowingPageStat(
      pageNo: pageNo,
      httpStatus: httpStatus,
      okRaw: okRaw,
      topKeys: _diagSortedKeys(json),
      dataKeys: _diagSortedKeys(data),
      cardShape: cardShape,
      listPaths: patterns,
      userCount: users.length,
      duplicateWithPrev: duplicate,
      totalValue: totalValue,
      totalField: totalField,
      totalCandidates: totalCandidates,
      totalHints: totalHints,
      cursorCandidates: cursorCandidates,
      fieldAnswers: fieldAnswers,
      userTrees: userTrees,
      sampleUsers: List<FollowingUser>.unmodifiable(
        users.take(maxBloggers).toList(),
      ),
      bodyHead: _diagHeadOf(body),
    );
  }

  /// 纯函数：把一页「动态流」响应整理成统计。必须可离线单测。
  ///
  /// ## 必须同时认两种形态（实测踩过）
  ///
  /// - **包装态**：`data.cards[i].mblog = {...}`（`containerid=102803` 推荐流）；
  /// - **裸列表态**：`data.statuses[i] = {...}`（`/feed/friends` 关注流，
  ///   微博对象**没有** `mblog` 外壳，直接就是 mblog 的形状）。
  ///
  /// 只认包装态会得到「200 + ok=1 + 0 条」的假阴性——这正是第一轮探测把
  /// 关注流误判成 NO 的原因。所以判定用 [looksLikeStatus] 看**形状**，
  /// 不依赖某个固定 key。
  ///
  /// 只统计能自己核实的量：状态码、`ok`、微博条数、作者 uid 去重数。
  /// 作者去重数是判断「是不是混合关注流」的唯一硬证据。
  static FeedProbeStat parseFeed({
    required String label,
    required String url,
    required bool isFollowingFeedCandidate,
    required int? httpStatus,
    required String body,
  }) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final String okRaw =
        json?['ok'] == null ? '（无 ok）' : json!['ok'].toString();
    final Map<String, dynamic>? data = _diagAsMap(json?['data']);

    int mblogCount = 0;
    int wrappedCount = 0;
    int bareCount = 0;
    final Set<String> authors = <String>{};
    final Map<String, int> types = <String, int>{};
    final List<String> rawPaths = <String>[];

    /// 一条微博对象的作者 uid（`user.idstr` 优先，退回 `user.id`）。
    String? authorOf(Map<String, dynamic> status) {
      final Map<String, dynamic>? user = _diagAsMap(status['user']);
      return _diagAsText(user?['idstr']) ?? _diagAsText(user?['id']);
    }

    void walk(Object? node, String path, int depth) {
      if (depth > 4) return;
      if (node is List) {
        for (int i = 0; i < node.length; i++) {
          walk(node[i], '$path[$i]', depth + 1);
        }
        return;
      }
      if (node is! Map) return;
      final Map<String, dynamic> map = node.cast<String, dynamic>();

      // 形态 1：cards[i].mblog 包装
      final Object? mblog = map['mblog'];
      if (mblog is Map && mblog.isNotEmpty) {
        final Map<String, dynamic> inner = mblog.cast<String, dynamic>();
        mblogCount += 1;
        wrappedCount += 1;
        rawPaths.add('$path.mblog');
        final Object? t = map['card_type'] ?? inner['card_type'];
        final String key = t == null ? '（无 card_type）' : t.toString();
        types[key] = (types[key] ?? 0) + 1;
        final String? uid = authorOf(inner);
        if (uid != null) authors.add(uid);
        // mblog 内部不再下钻：转发原帖也带 user，会虚高作者数。
        return;
      }

      // 形态 2：裸微博对象（data.statuses[i]）
      if (looksLikeStatus(map)) {
        mblogCount += 1;
        bareCount += 1;
        rawPaths.add(path);
        final Object? t = map['card_type'];
        final String key = t == null ? '（无 card_type）' : t.toString();
        types[key] = (types[key] ?? 0) + 1;
        final String? uid = authorOf(map);
        if (uid != null) authors.add(uid);
        return;
      }

      for (final MapEntry<String, dynamic> e in map.entries) {
        walk(e.value, '$path.${e.key}', depth + 1);
      }
    }

    walk(data ?? json, 'data', 0);

    final List<String> listPaths = <String>[];
    for (final String p in rawPaths) {
      final String n = normalizePath(p);
      if (!listPaths.contains(n)) listPaths.add(n);
    }

    // 游标候选：关注流要不要翻页、怎么翻，全看这里有没有 since_id / page。
    final List<String> cursors = <String>[];
    void scanCursor(Map<String, dynamic>? map, String prefix) {
      if (map == null) return;
      for (final MapEntry<String, dynamic> e in map.entries) {
        if (!_cursorKey.hasMatch(e.key)) continue;
        final Object? v = e.value;
        final String text = v is String ? v : (v?.toString() ?? '');
        cursors.add('$prefix${e.key} = ${_diagMask(text)}（${_diagTypeName(v)}）');
      }
    }

    scanCursor(data, 'data.');
    scanCursor(json, '');

    return FeedProbeStat(
      label: label,
      url: maskUrl(url),
      rawUrl: url,
      isFollowingFeedCandidate: isFollowingFeedCandidate,
      httpStatus: httpStatus,
      okRaw: okRaw,
      mblogCount: mblogCount,
      wrappedCount: wrappedCount,
      bareCount: bareCount,
      distinctAuthors: authors.length,
      listPaths: listPaths,
      cursorCandidates: cursors,
      cardTypes: types.entries
          .map((MapEntry<String, int> e) => 'card_type=${e.key}×${e.value}')
          .toList(),
      topKeys: _diagSortedKeys(json),
      dataKeys: _diagSortedKeys(data),
      bodyHead: _diagHeadOf(body),
    );
  }

  /// 是否「长得像一条微博对象」（**不看外层包装 key**）。
  ///
  /// 判据：有 `user` Map，且有 `mid` / `idstr` / `id` 之一，且有 `text`。
  /// 这三条同时缺一不可——只看 `user` 会把「用户卡片」也算成微博。
  static bool looksLikeStatus(Map<String, dynamic> map) {
    if (map['user'] is! Map) return false;
    if (!map.containsKey('text')) return false;
    return map.containsKey('mid') ||
        map.containsKey('idstr') ||
        map.containsKey('id');
  }

  // ------------------------------------------------------------ 用户对象扫描（纯函数）

  /// 递归扫描：把「长得像用户对象」的 Map 收集起来，附带它的原始路径。
  ///
  /// 判定特征：有 `screen_name`（String）且有 `id` / `idstr` / `uid`。
  /// 这样不管列表挂在 `data.cards[].card_group[].user` 还是别的位置，
  /// 结论都是**实测出来的**，不是照文档猜的。
  static void _collectUsers(
    Object? node,
    String path,
    int depth,
    List<FollowingUser> out,
    Map<String, FollowingUser> byUid,
    List<String> rawPaths,
  ) {
    if (depth > 5) return;
    if (node is List) {
      for (int i = 0; i < node.length && out.length < 200; i++) {
        _collectUsers(node[i], '$path[$i]', depth + 1, out, byUid, rawPaths);
      }
      return;
    }
    if (node is! Map) return;
    final Map<String, dynamic> map = node.cast<String, dynamic>();
    final Object? nameValue = map['screen_name'];
    final bool looksLikeUser = nameValue is String &&
        (map.containsKey('id') || map.containsKey('idstr') || map.containsKey('uid'));
    if (looksLikeUser) {
      final FollowingUser user = FollowingUser.of(map, path);
      final String? uid = user.uid;
      rawPaths.add(path);
      if (uid != null && byUid.containsKey(uid)) {
        // 同一 uid 出现在多个位置：只保留第一次，避免「总数」虚高。
        return;
      }
      if (uid != null) byUid[uid] = user;
      out.add(user);
      return;
    }
    for (final MapEntry<String, dynamic> e in map.entries) {
      _collectUsers(e.value, '$path.${e.key}', depth + 1, out, byUid, rawPaths);
    }
  }

  /// 路径归一化：`data.cards[0].card_group[1].user` → `data.cards[i].card_group[j].user`。
  static String normalizePath(String path) =>
      path.replaceAll(RegExp(r'\[\d+\]'), '[i]');

  // ------------------------------------------------------------ 字段定位（纯函数）

  /// 重点字段定位：uid / 昵称 / 头像。
  ///
  /// 只**如实报告**实际存在的字段名与类型；一个都找不到时明确写「未找到」，
  /// 绝不拿别的字段顶上。
  static List<String> answerUserFields(
    Map<String, dynamic>? user, {
    required String path,
  }) {
    final List<String> out = <String>[];
    if (user == null) return out;
    for (final ({String label, List<String> keys}) wanted in _wanted) {
      final List<String> hits = <String>[];
      for (final String key in wanted.keys) {
        if (!user.containsKey(key)) continue;
        final Object? v = user[key];
        hits.add('$key（${_diagTypeName(v)}）样例 ${_diagProbeSampleValue(v)}');
      }
      if (hits.isEmpty) {
        out.add('${wanted.label} → 未找到（${wanted.keys.join(' / ')} 均不存在）');
      } else {
        out.add('${wanted.label} → ${hits.join('  ／  ')}');
      }
    }
    out.add('（位置：$path）');
    return out;
  }

  /// 三个重点字段的候选 key（按真实接口字段名逐一比对，不做猜测）。
  static const List<({String label, List<String> keys})> _wanted =
      <({String label, List<String> keys})>[
        (label: 'uid', keys: <String>['id', 'idstr', 'uid', 'user_id']),
        (label: '昵称', keys: <String>['screen_name', 'name', 'nick_name']),
        (
          label: '头像',
          keys: <String>[
            'avatar_hd',
            'avatar_large',
            'profile_image_url',
            'avatar',
          ],
        ),
      ];

  /// 把一个用户对象摊平成「路径 → 类型 → 样例值」文本行。深度 [describeDepth]。
  static List<String> describeUser(
    Map<String, dynamic>? user, {
    String rootPath = 'user',
  }) {
    final List<String> out = <String>[];
    if (user == null) return out;
    _diagWalkTree(
      rootPath,
      user,
      0,
      out,
      maxLines: maxLinesPerUser,
      maxDepth: describeDepth,
      maxListItems: 2,
      // 历史实现：关注列表探针的 List 分支不判断深度上限，保持一致。
      capListDepth: false,
      sampleNullText: '',
    );
    return out;
  }

  // ------------------------------------------------------------ URL 脱敏（纯函数）

  /// 脱敏：把凭据 / 一次性票据类参数的值换成 `***`，其余参数**原样保留**
  /// （保留是为了让读报告的人能自己复现同一个请求；`containerid` 这类参数
  /// 只是接口名，不是凭据，截断反而让报告不可用）。
  static String maskUrl(String url) {
    final int q = url.indexOf('?');
    if (q < 0) return url;
    final String base = url.substring(0, q);
    final List<String> pairs = url.substring(q + 1).split('&');
    final List<String> masked = <String>[];
    for (final String pair in pairs) {
      final int eq = pair.indexOf('=');
      if (eq < 0) {
        masked.add(pair);
        continue;
      }
      final String key = pair.substring(0, eq);
      if (_sensitiveParam.hasMatch(key)) {
        masked.add('$key=***');
      } else {
        masked.add(pair);
      }
    }
    return '$base?${masked.join('&')}';
  }

  // ------------------------------------------------------------ 结论（纯函数）

  /// 分页结论（**纯函数**，只根据实测页数据判断，不猜）。
  ///
  /// 关键坑（第一轮真机就踩到了）：第 2 页返回 `200 + ok=1` 但 **0 个用户**
  /// 时，绝不能写成「不重复（分页有效）」——0 与 0 当然不重复。
  /// 只有「第 2 页确实返回了用户」才算翻页可用。
  static String pagingVerdict(List<FollowingPageStat> pages) {
    if (pages.length <= 1) return '未翻页';
    final FollowingPageStat p2 = pages[1];
    if (p2.httpStatus != 200) return '第 2 页未放行（${p2.statusText}）';
    if (p2.okRaw != '1') return '第 2 页 ok=${p2.okRaw}';
    if (p2.userCount == 0) {
      return '第 2 页 200 + ok=1 但 0 个用户（该接口不吃 page 参数，翻页无效）';
    }
    if (p2.duplicateWithPrev == 0) return '第 2 页 ${p2.userCount} 个且无重复（翻页有效）';
    return '第 2 页重复 ${p2.duplicateWithPrev} 个（翻页参数可能无效）';
  }

  static String _overallNote({
    required List<FollowingPageStat> pages,
    required List<FeedProbeStat> feeds,
    required FollowingPageStat? guest,
  }) {
    final StringBuffer buf = StringBuffer();
    if (pages.isEmpty) {
      buf.write('未发出任何关注列表请求（被叫停）');
    } else {
      final FollowingPageStat f = pages.first;
      final int? status = f.httpStatus;
      if (status == null) {
        buf.write('P1 请求失败（网络 / 超时）');
      } else if (status == 432) {
        buf.write('P1 被 WAF 拦截（HTTP 432）');
      } else if (status != 200) {
        buf.write('P1 未放行（HTTP $status）');
      } else if (f.okRaw != '1') {
        buf.write('P1 返回 ok=${f.okRaw}（非 1）');
      } else if (f.userCount == 0) {
        buf.write('P1 200 + ok=1，但没扫到用户对象（可能列表在别的路径）');
      } else {
        final int total = pages.fold<int>(
          0,
          (int a, FollowingPageStat b) => a + b.userCount,
        );
        final int dups = pages
            .skip(1)
            .fold<int>(0, (int a, FollowingPageStat b) => a + b.duplicateWithPrev);
        buf.write('P1 可用：首页 ${f.userCount} 个关注，'
            '${pages.length} 页共 $total 个；${WeiboFollowingProbe.pagingVerdict(pages)}');
        if (dups > 0) buf.write('（重复 $dups 个）');
      }
    }
    buf.write('；');
    if (feeds.isEmpty) {
      buf.write('P2 未探测');
    } else {
      final FeedProbeStat a =
          feeds.firstWhere((FeedProbeStat f) => f.isFollowingFeedCandidate,
              orElse: () => feeds.first);
      buf.write('P2 ${a.verdict}');
    }
    if (guest != null) buf.write('；未登录 ok=${guest.okRaw}');
    return buf.toString();
  }

  // ------------------------------------------------------------ 小工具

  static List<MapEntry<String, dynamic>> _totalEntries(
    Map<String, dynamic>? map,
    String prefix,
  ) {
    if (map == null) return const <MapEntry<String, dynamic>>[];
    final List<MapEntry<String, dynamic>> out = <MapEntry<String, dynamic>>[];
    for (final MapEntry<String, dynamic> e in map.entries) {
      if (_totalKey.hasMatch(e.key)) out.add(e);
    }
    return out;
  }
}

/// 关注列表里的一个用户对象（**不含任何凭据**）。
class FollowingUser {
  const FollowingUser({
    required this.path,
    required this.uid,
    required this.uidField,
    required this.uidType,
    required this.screenName,
    required this.nameField,
    required this.avatar,
    required this.avatarField,
    required this.raw,
  });

  /// 首次出现的位置（原始带下标的路径）。
  final String path;

  /// 解析出来的 uid（优先 `idstr`：19 位大整数走数值类型会丢精度）。
  final String? uid;

  /// uid 命中的字段名。
  final String? uidField;

  /// uid 的类型名（int / String …）。
  final String? uidType;

  final String? screenName;
  final String? nameField;

  final String? avatar;
  final String? avatarField;

  /// 原始对象（只在内存里流转，展示前按需摊平）。
  final Map<String, dynamic> raw;

  /// 从原始 Map 里按**实测存在的字段**取值，不做任何猜测性回退。
  factory FollowingUser.of(Map<String, dynamic> map, String path) {
    String? uid;
    String? uidField;
    String? uidType;
    for (final String key in const <String>['idstr', 'uid', 'id', 'user_id']) {
      if (!map.containsKey(key)) continue;
      final Object? v = map[key];
      final String? text = _diagAsText(v);
      if (text == null) continue;
      uid = text;
      uidField = key;
      uidType = _diagTypeName(v);
      break;
    }

    String? screenName;
    String? nameField;
    for (final String key in const <String>['screen_name', 'name', 'nick_name']) {
      final String? text = _diagAsText(map[key]);
      if (text == null) continue;
      screenName = text;
      nameField = key;
      break;
    }

    String? avatar;
    String? avatarField;
    for (final String key in const <String>[
      'avatar_hd',
      'avatar_large',
      'profile_image_url',
      'avatar',
    ]) {
      final String? text = _diagAsText(map[key]);
      if (text == null) continue;
      avatar = text;
      avatarField = key;
      break;
    }

    return FollowingUser(
      path: path,
      uid: uid,
      uidField: uidField,
      uidType: uidType,
      screenName: screenName,
      nameField: nameField,
      avatar: avatar,
      avatarField: avatarField,
      raw: map,
    );
  }

  String toLine() {
    final String a = uid == null ? 'uid=?' : 'uid=$uid（$uidField/$uidType）';
    final String n = screenName == null ? '昵称=?' : '昵称=$screenName（$nameField）';
    final String av = avatarField == null ? '头像=?' : '头像=$avatarField';
    return '$a · $n · $av · 位置 $path';
  }
}

/// 关注列表一页的结构统计（**不含任何凭据**）。
class FollowingPageStat {
  const FollowingPageStat({
    required this.pageNo,
    required this.httpStatus,
    required this.okRaw,
    required this.topKeys,
    required this.dataKeys,
    required this.cardShape,
    required this.listPaths,
    required this.userCount,
    required this.duplicateWithPrev,
    required this.totalValue,
    required this.totalField,
    required this.totalCandidates,
    required this.totalHints,
    required this.cursorCandidates,
    required this.fieldAnswers,
    required this.userTrees,
    required this.sampleUsers,
    required this.bodyHead,
  });

  /// 1..N；0 表示未登录对照页。
  final int pageNo;
  final int? httpStatus;

  /// 顶层 `ok` 的原值文本；缺失时是「（无 ok）」。
  final String okRaw;

  final List<String> topKeys;
  final List<String> dataKeys;

  /// 卡片骨架（`data.cards` 到底长什么样）。
  final List<String> cardShape;

  /// 归一化后的用户对象出现位置（列表路径）。
  final List<String> listPaths;

  /// 扫到的用户对象数。
  final int userCount;

  /// 与**之前各页**重复的 uid 数。
  final int duplicateWithPrev;

  final int? totalValue;
  final String? totalField;

  /// 所有形似总数的 key 与其值摘要。
  final List<String> totalCandidates;

  /// 卡片标题/描述里的数字线索（如「共 128 人」）。
  final List<String> totalHints;

  /// 所有形似游标 / 页码的 key 与其值摘要。
  final List<String> cursorCandidates;

  /// uid / 昵称 / 头像 的定位结论（针对第一个用户）。
  final List<String> fieldAnswers;

  /// 前 [WeiboFollowingProbe.maxBloggers] 个博主的字段树。
  final List<String> userTrees;

  /// 前几个博主的解析结果。
  final List<FollowingUser> sampleUsers;

  /// 响应体摘要（压平、截断）。
  final String bodyHead;

  String get statusText => httpStatus == null ? '请求失败' : 'HTTP $httpStatus';

  String toLine() {
    final String label = pageNo == 0 ? '未登录' : '第$pageNo页';
    final String total =
        totalField == null ? '总数未找到' : '$totalField=$totalValue';
    return '$label：$statusText · ok=$okRaw · 用户 $userCount 个 · $total'
        '${pageNo == 0 ? '' : ' · 与前页重复 $duplicateWithPrev 个'}';
  }
}

/// 一页「动态流」探测结果（**不含任何凭据**）。
class FeedProbeStat {
  const FeedProbeStat({
    required this.label,
    required this.url,
    required this.rawUrl,
    required this.isFollowingFeedCandidate,
    required this.httpStatus,
    required this.okRaw,
    required this.mblogCount,
    required this.wrappedCount,
    required this.bareCount,
    required this.distinctAuthors,
    required this.listPaths,
    required this.cursorCandidates,
    required this.cardTypes,
    required this.topKeys,
    required this.dataKeys,
    required this.bodyHead,
  });

  final String label;

  /// 脱敏后的 URL（展示用）。
  final String url;

  /// 原始 URL（只用于拼请求 / 拼接说明，展示时用 [url]）。
  final String rawUrl;

  /// 是否是「关注流」候选（false = 只是对照）。
  final bool isFollowingFeedCandidate;

  final int? httpStatus;
  final String okRaw;

  /// 本页微博条数（包装态 + 裸列表态）。
  final int mblogCount;

  /// `cards[].mblog` 包装态的条数。
  final int wrappedCount;

  /// 裸微博对象（如 `data.statuses[]`）的条数。
  final int bareCount;

  /// 作者 uid 去重数——判断「是不是混合关注流」的唯一硬证据。
  final int distinctAuthors;

  /// 微博对象出现的位置（归一化，如 `data.statuses[i]`）。
  final List<String> listPaths;

  /// 游标 / 页码候选（`since_id` / `page` …）。
  final List<String> cursorCandidates;

  final List<String> cardTypes;
  final List<String> topKeys;
  final List<String> dataKeys;
  final String bodyHead;

  String get statusText => httpStatus == null ? '请求失败' : 'HTTP $httpStatus';

  /// `YES` / `NO` / `UNKNOWN` 三态，供最终报告直接取用。
  String get verdict {
    if (httpStatus == null) return 'UNKNOWN（请求失败）';
    if (httpStatus == 432) return 'NO（HTTP 432 风控拦截）';
    if (httpStatus != 200) return 'NO（HTTP $httpStatus）';
    if (okRaw != '1') return 'NO（ok=$okRaw）';
    if (mblogCount == 0) return 'NO（200 但 0 条微博）';
    if (!isFollowingFeedCandidate) {
      return 'NO（这是推荐流对照，作者数 $distinctAuthors，不能算关注流）';
    }
    if (distinctAuthors >= 2) {
      return 'YES（一次请求 $mblogCount 条、$distinctAuthors 个不同作者）';
    }
    return 'UNKNOWN（只有 $mblogCount 条、$distinctAuthors 个作者，样本不足）';
  }

  String toLine() {
    final String shape = bareCount > 0 && wrappedCount == 0
        ? '裸列表'
        : (wrappedCount > 0 && bareCount == 0 ? 'mblog 包装' : '混合');
    return '$label：$statusText · ok=$okRaw · 微博 $mblogCount 条（$shape）· '
        '作者去重 $distinctAuthors 个 · 位置 '
        '${listPaths.isEmpty ? '未定位' : listPaths.join(' / ')}';
  }
}

/// 一次关注列表探针的完整结果（**不含任何凭据**）。
class FollowingProbeResult {
  const FollowingProbeResult({
    required this.pages,
    required this.page2Param,
    required this.guest,
    required this.guestBodyHead,
    required this.feeds,
    required this.requestLog,
    required this.requestCount,
    required this.saw432,
    required this.max432Streak,
    required this.note,
  });

  final List<FollowingPageStat> pages;

  /// 第 2 页实际用的参数（如 `page=2`）；null = 没翻页。
  final String? page2Param;

  /// 未登录对照（cookie 为空）；null = 没跑。
  final FollowingPageStat? guest;

  /// 未登录响应的正文摘要（已压平、截断；cookie 为空所以不含凭据）。
  final String guestBodyHead;

  /// P2 关注流探测结果（按请求顺序）。
  final List<FeedProbeStat> feeds;

  /// 逐条请求记录（只有标签与状态码）。
  final List<String> requestLog;

  final int requestCount;
  final bool saw432;
  final int max432Streak;
  final String note;

  FollowingPageStat? get firstPage => pages.isEmpty ? null : pages.first;

  /// 供对话框展示的紧凑文本（不含任何 cookie 内容）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('════ 微博关注列表探针 ════');
    buf.writeln();
    buf.writeln('—— 请求记录（${requestLog.length} 条 / 上限 '
        '${WeiboFollowingProbe.maxRequests}）——');
    if (requestLog.isEmpty) {
      buf.writeln('（没有发出请求）');
    } else {
      for (int i = 0; i < requestLog.length; i++) {
        buf.writeln('#${i + 1} ${requestLog[i]}');
      }
    }
    buf.writeln();
    buf.writeln('—— P1 各页 ——');
    if (pages.isEmpty) {
      buf.writeln('（没有可展示的页）');
    } else {
      for (final FollowingPageStat p in pages) {
        buf.writeln(p.toLine());
      }
      final FollowingPageStat f = pages.first;
      buf.writeln('顶层 keys：${f.topKeys.join(', ')}');
      buf.writeln('data keys：${f.dataKeys.join(', ')}');
      buf.writeln('列表路径：${f.listPaths.isEmpty ? '未定位' : f.listPaths.join(' / ')}');
      buf.writeln('游标候选：'
          '${f.cursorCandidates.isEmpty ? '（无）' : f.cursorCandidates.join(' / ')}');
    }
    buf.writeln('第2页参数：${page2Param ?? '（未翻页）'}');
    buf.writeln();
    buf.writeln('—— 重点字段 ——');
    final FollowingPageStat? f0 = firstPage;
    if (f0 == null || f0.fieldAnswers.isEmpty) {
      buf.writeln('（无用户对象可判定）');
    } else {
      for (final String l in f0.fieldAnswers) {
        buf.writeln(l);
      }
    }
    buf.writeln();
    buf.writeln('—— 前 ${WeiboFollowingProbe.maxBloggers} 个博主字段树 ——');
    if (f0 == null || f0.userTrees.isEmpty) {
      buf.writeln('（无用户对象可展开）');
    } else {
      for (final String l in f0.userTrees) {
        buf.writeln(l);
      }
    }
    buf.writeln();
    buf.writeln('—— P2 关注动态流 ——');
    if (feeds.isEmpty) {
      buf.writeln('（未探测）');
    } else {
      for (final FeedProbeStat f in feeds) {
        buf.writeln(f.toLine());
        buf.writeln('  判定：${f.verdict}');
      }
    }
    buf.writeln();
    buf.writeln('—— 未登录对照（cookie 为空，只测 1 次）——');
    final FollowingPageStat? g = guest;
    if (g == null) {
      buf.writeln('（未发出）');
    } else {
      buf.writeln('${g.statusText} · ok=${g.okRaw} · 用户 ${g.userCount} 个');
      if (guestBodyHead.isNotEmpty) buf.writeln('响应摘要：$guestBodyHead');
    }
    buf.writeln();
    buf.writeln('—— 判定 ——');
    buf.writeln(note);
    return buf.toString();
  }

  /// 供落盘用的 Markdown（结构固定，便于直接 `adb pull` 到 `.env/`）。
  ///
  /// [cookieLength] 只写长度，**永远不写内容**。
  String toMarkdown({required int cookieLength, String? date}) {
    final String day = date ?? _today();
    final FollowingPageStat? f0 = firstPage;
    final StringBuffer buf = StringBuffer();

    buf.writeln('# 微博关注列表探针（$day）');
    buf.writeln();
    buf.writeln('## 一、P1 关注列表');
    buf.writeln();
    buf.writeln('- 请求 URL（脱敏）：`${WeiboFollowingProbe.maskUrl(WeiboFollowingProbe.followingEndpoint)}`');
    if (page2Param != null) {
      buf.writeln('- 第 2 页追加参数：`$page2Param`');
    }
    buf.writeln('- 请求记录（${requestLog.length} 条 / 上限 '
        '${WeiboFollowingProbe.maxRequests}）：');
    for (final String l in requestLog) {
      buf.writeln('  - $l');
    }
    if (f0 == null) {
      buf.writeln('- 状态：未发出任何 P1 请求');
      buf.writeln('- 判定：$note');
    } else {
      buf.writeln('- HTTP 状态 / ok 字段：${f0.statusText} / ok=${f0.okRaw}');
      buf.writeln('- 列表路径：'
          '${f0.listPaths.isEmpty ? '未定位（见下方卡片骨架）' : f0.listPaths.join(' ／ ')}');
      buf.writeln('- 关注总数：'
          '${f0.totalField == null ? '字段里没有（见下方线索）' : '${f0.totalField}=${f0.totalValue}'}');
      if (f0.totalHints.isNotEmpty) {
        buf.writeln('- 总数线索（卡片标题里）：「${f0.totalHints.join('」「')}」');
      }
      buf.writeln('- 本页扫到用户对象：${f0.userCount} 个');
      buf.writeln();
      buf.writeln('### 卡片骨架');
      for (final String l in f0.cardShape) {
        buf.writeln('- `$l`');
      }
      buf.writeln();
      buf.writeln('### 前 ${WeiboFollowingProbe.maxBloggers} 个博主（完整字段）');
      for (final FollowingUser u in f0.sampleUsers) {
        buf.writeln('- ${u.toLine()}');
      }
      buf.writeln();
      buf.writeln('### 字段树');
      buf.write('```');
      for (final String l in f0.userTrees) {
        buf.writeln(l);
      }
      buf.writeln('```');
      buf.writeln();
      buf.writeln('### 游标');
      buf.writeln('- 游标候选：'
          '${f0.cursorCandidates.isEmpty ? '响应里没有任何形似游标/页码的字段' : f0.cursorCandidates.join(' ／ ')}');
      if (pages.length > 1) {
        final FollowingPageStat p2 = pages[1];
        buf.writeln('- 第 2 页：${p2.statusText} · 用户 ${p2.userCount} 个 · '
            '与第 1 页重复 ${p2.duplicateWithPrev} 个');
        buf.writeln('- 第 2 页是否与第 1 页重复 / 分页是否可用：**${WeiboFollowingProbe.pagingVerdict(pages)}**');
      } else {
        buf.writeln('- 第 2 页是否与第 1 页重复：未翻页（第 1 页没给出可用数据）');
      }
      buf.writeln();
      buf.writeln('### 两页汇总');
      int total = 0;
      for (final FollowingPageStat p in pages) {
        total += p.userCount;
      }
      buf.writeln('- 累计扫到 $total 个关注（${pages.length} 页以内的观测值）');
    }

    buf.writeln();
    buf.writeln('## 二、重点关注（逐项回答）');
    buf.writeln();
    if (f0 == null || f0.fieldAnswers.isEmpty) {
      buf.writeln('- uid / 昵称 / 头像：无用户对象，无法判定');
    } else {
      for (final String l in f0.fieldAnswers) {
        buf.writeln('- $l');
      }
      buf.writeln('- 分页：第 2 页参数 `${page2Param ?? '未翻页'}`；'
          '${WeiboFollowingProbe.pagingVerdict(pages)}');
    }

    buf.writeln();
    buf.writeln('## 三、P2 关注动态流');
    buf.writeln();
    if (feeds.isEmpty) {
      buf.writeln('- （未探测）');
    } else {
      for (final FeedProbeStat f in feeds) {
        buf.writeln('- 候选：`${f.url}`（${f.label}）');
        buf.writeln('  - ${f.toLine()}');
        buf.writeln('  - 判定：${f.verdict}');
        if (f.bodyHead.isNotEmpty) {
          buf.writeln('  - 响应摘要：`${_escapeInline(f.bodyHead)}`');
        }
      }
      final FeedProbeStat cand = feeds.firstWhere(
        (FeedProbeStat f) => f.isFollowingFeedCandidate,
        orElse: () => feeds.first,
      );
      final bool yes = cand.httpStatus == 200 &&
          cand.okRaw == '1' &&
          cand.mblogCount > 0 &&
          cand.distinctAuthors >= 2;
      buf.writeln('- **明确结论：能否一次请求拿到「我关注的人的混合时间流」→ '
          '${yes ? '能' : '不能（本次探测未找到可用入口）'}**');
      if (yes) {
        buf.writeln('- 依据：`${cand.url}` 一次返回 '
            '**${cand.mblogCount} 条微博 / ${cand.distinctAuthors} 个不同作者**'
            '（HTTP 200 + ok=1），列表形态是'
            '「${cand.bareCount > 0 ? '裸微博对象（无 mblog 外壳）' : 'cards[].mblog 包装'}」，'
            '位置 `${cand.listPaths.join(' / ')}`。');
        buf.writeln('- 游标：'
            '${cand.cursorCandidates.isEmpty ? '响应里没有形似游标/页码的字段（翻页参数需另行实测）' : cand.cursorCandidates.join(' ／ ')}');
      } else {
        buf.writeln('- 依据：关注流候选 `${cand.url}` 的实际结果是 '
            '「${cand.verdict}」；'
            '未达到「200 + ok=1 + 多条微博 + ≥2 个不同作者」的判据。');
      }
    }

    buf.writeln();
    buf.writeln('## 四、未登录态');
    buf.writeln();
    final FollowingPageStat? g = guest;
    if (g == null) {
      buf.writeln('- （未发出未登录对照请求）');
    } else {
      buf.writeln('- cookie 为空时：${g.statusText} · ok=${g.okRaw} · '
          '扫到用户 ${g.userCount} 个');
      if (guestBodyHead.isNotEmpty) {
        buf.writeln('- 响应摘要：`${_escapeInline(guestBodyHead)}`');
      }
      buf.writeln('- 判定依据：'
          '${g.httpStatus == 432 ? '432 = 未登录被拦，可作为「登录态失效」的判据' : '状态码 ${g.httpStatus} 不能单独当登录判据，需结合 ok=${g.okRaw}'}');
    }

    buf.writeln();
    buf.writeln('## 五、给实现者的硬结论');
    buf.writeln();
    final FollowingUser? u0 =
        (f0 == null || f0.sampleUsers.isEmpty) ? null : f0.sampleUsers.first;
    buf.writeln('- uid 字段：'
        '${u0?.uidField == null ? '未定位' : '`${u0!.uidField}`（${u0.uidType}），样例 ${u0.uid}。'
            '关注列表的 user 对象里**只有 id（int），没有 idstr**——读法与时间线不同，'
            '取值时按 `${u0.uidType == 'int' ? 'int → toString()' : 'String 直接用'}` 处理；'
            '微博 uid 目前是 10 位，仍在 double 精确范围内，但**不要**中途过 num 再转回'}');
    buf.writeln('- 昵称字段：'
        '${u0?.nameField == null ? '未定位' : '`${u0!.nameField}`（String），样例「${u0.screenName}」'}');
    buf.writeln('- 头像字段：'
        '${u0?.avatarField == null ? '未定位' : '`${u0!.avatarField}`（String），样例 ${_escapeInline(u0.avatar ?? '')}；'
            '另有 `profile_image_url`（正方形裁剪）、`cover_image_phone`'}');
    buf.writeln('- 分页：${page2Param == null ? '未验证（第 1 页就没给出可用数据）' : '`&$page2Param` 追加在 containerid 之后'}；'
        '${WeiboFollowingProbe.pagingVerdict(pages)}。');
    buf.writeln('- 风控注意：同一变体最多 2 次、间隔 ≥2.5 s、连续 3 次 432 立即停；'
        '**绝不要**「关注列表 × 逐个拉时间线」，那是 N 倍请求，必然被风控。');
    buf.writeln('- 与 N5 的关系：关注列表天然给出 uid → 昵称/头像 的映射，'
        '比「等时间线返回 user.screen_name」可靠得多；导入后即可把'
        '「微博 1782488734」改成真实昵称。');
    buf.writeln('- 列表边界：第 1 页只返回 '
        '${f0?.userCount ?? 0} 个用户（`data.cards[2].card_group` 里），'
        '**不是全部关注**；这个 containerid 不吃 `page` 参数（见分页结论），'
        '所以「导入全部关注」不能靠它翻页拿到。');
    buf.writeln();
    buf.writeln('## 六、cookie 长度');
    buf.writeln();
    buf.writeln('- $cookieLength（内容绝不记录、绝不落盘）');
    return buf.toString();
  }

  static String _today() {
    final DateTime now = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  static String _escapeInline(String s) =>
      s.replaceAll('`', "'").replaceAll('|', '/');
}

/// 单次请求的原始产物（`skipped` = 因限额 / 叫停而没发）。
class _Fetch {
  const _Fetch({
    required this.httpStatus,
    required this.body,
    this.skipped = false,
  });

  final int? httpStatus;
  final String body;
  final bool skipped;
}


/// 微博评论接口探针（**诊断工具，不是正式评论数据层**）。
///
/// ## 它要回答的问题
///
/// 时间线（`api/container/getIndex`）已经能用真实登录 cookie 打通，但**评论
/// 接口从未验证过**。本类把「候选接口 + 真实 cookie」跑一遍，只回答结构性
/// 问题：状态码、顶层 `ok`、评论列表在哪、每条评论的字段名与类型、二级评论
/// 在哪、游标叫什么、连续 3 页是否触发风控、未登录时返回什么。
///
/// 顶部候选接口：
/// - C1（首选）`https://m.weibo.cn/comments/hotflow` —— 用 m 站 cookie，App
///   已有全局通道，可直接复用；
/// - C2（备选）`https://weibo.com/ajax/statuses/buildComments` —— 需要
///   `weibo.com` 域 cookie + `XSRF-TOKEN`，当前 App 没有这条通道，**只在 C1
///   失败时才试一次**。
///
/// ## 凭据安全（硬约束）
///
/// cookie 只作为请求头出现：不进任何日志、不进结果对象、不进异常文案、
/// 不落盘。结果里连长度都不带；界面上由调用方单独显示长度。
///
/// ## 请求节制（硬上限，调用方改不动）
///
/// - 全流程最多 [maxRequests] 个请求，达到即停；
/// - 翻页最多 [maxPages] 页；
/// - 两次请求间隔 ≥ [minGap]；
/// - 连续 [maxConsecutive432] 次 432 立刻停；
/// - 单项超时 [itemTimeout]。
///
/// 刻意**不挂重试拦截器**（裸 `Dio`），也**不做任何风控绕过**：不伪造
/// `XSRF-TOKEN`、不换 UA、不重试轰炸。
class WeiboCommentProbe {
  WeiboCommentProbe({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  /// 全流程请求数硬上限。
  static const int maxRequests = 12;

  /// 翻页硬上限（页数 = 请求数）。
  static const int maxPages = 3;

  /// 连续 432 达到这个数就立刻停。
  static const int maxConsecutive432 = 3;

  /// 两次请求之间的最小间隔。
  static const Duration minGap = Duration(milliseconds: 2500);

  /// 单项超时。
  static const Duration itemTimeout = Duration(seconds: 20);

  /// 字段树展开深度（任务要求 3）。
  static const int describeDepth = 3;

  /// 单值截断长度。
  static const int maxValueChars = 80;

  /// 字段树行数上限。
  static const int maxLines = 200;

  /// 拿种子微博用的时间线接口（与 `weibo_api_diag.dart` 的 uid 一致）。
  static const String timelineEndpoint =
      '${WeiboWebUrls.mbBase}/api/container/getIndex'
      '?type=uid&value=1782488734&containerid=1076031782488734';

  /// C1：m 站评论接口。
  static const String hotflowEndpoint = '${WeiboWebUrls.mbBase}/comments/hotflow';

  /// C2：weibo.com 域评论接口（只在 C1 失败时试一次）。
  static const String buildCommentsEndpoint =
      'https://weibo.com/ajax/statuses/buildComments';

  /// 移动端 Chrome UA（与既有诊断保持一致：桌面 UA 会被重定向）。
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// 形似游标的 key（只用于**如实报告**存在哪些游标字段）。
  static final RegExp _cursorKey = RegExp(
    r'max_id$|cursor$|since_id$|page_num$|total_page$',
  );

  static Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: itemTimeout,
        receiveTimeout: itemTimeout,
        sendTimeout: itemTimeout,
        responseType: ResponseType.plain,
        followRedirects: true,
        // 放宽到 <600：432 / 5xx 都走正常返回路径，由本类显式判定，
        // 这样「状态码多少」这个结论不会变成一句缓存过的异常。
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

  /// 是否已达硬上限 / 已被连续 432 叫停。
  bool get aborted => _aborted;

  /// 已发出的请求数。
  int get requestCount => _requestCount;

  Future<void> _throttle() async {
    final DateTime? last = _lastRequestAt;
    if (last == null) return;
    final Duration elapsed = DateTime.now().difference(last);
    if (elapsed >= minGap) return;
    await Future<void>.delayed(minGap - elapsed);
  }

  /// 发一次 GET。cookie 只进 header；失败返回 `httpStatus: null`，不抛不重试。
  Future<_Fetch> _get(
    String url,
    String cookie, {
    required String referer,
    required String label,
  }) async {
    if (_aborted) {
      _log.add('$label → 已叫停，未发出');
      return const _Fetch(httpStatus: null, body: '', skipped: true);
    }
    if (_requestCount >= maxRequests) {
      _aborted = true;
      _log.add('$label → 达到请求上限 $maxRequests，未发出');
      return const _Fetch(httpStatus: null, body: '', skipped: true);
    }

    await _throttle();
    _requestCount += 1;

    final String trimmed = cookie.trim();
    _Fetch fetch;
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: <String, String>{
            'User-Agent': _userAgent,
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
      fetch = _Fetch(
        httpStatus: res.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } on DioException catch (e) {
      // 只取状态码与 body，绝不把 requestOptions.headers 拼进任何文案。
      final Object? data = e.response?.data;
      fetch = _Fetch(
        httpStatus: e.response?.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } catch (_) {
      fetch = const _Fetch(httpStatus: null, body: '');
    }

    _lastRequestAt = DateTime.now();
    final int? status = fetch.httpStatus;
    if (status == null || fetch.skipped) {
      _consecutive432 = 0;
    } else if (status == 432) {
      _saw432 = true;
      _consecutive432 += 1;
      if (_consecutive432 > _max432Streak) _max432Streak = _consecutive432;
      if (_consecutive432 >= maxConsecutive432) {
        _aborted = true;
        _log.add('$label → HTTP 432（连续 $_consecutive432 次，已停）');
        return fetch;
      }
    } else {
      _consecutive432 = 0;
    }
    _log.add('$label → ${status == null ? '请求失败' : 'HTTP $status'}');
    return fetch;
  }

  // ------------------------------------------------------------ 种子微博

  /// 先从时间线取一条**真实微博**当评论目标：**1 个请求**。
  ///
  /// 同一次响应里直接挑 `comments_count` 最大的那条（没有就退回第一条），
  /// 避免「随机挑到一条零评论微博 → 探针得到假阴性」。
  Future<ProbeSeed> fetchSeed({required String cookie}) async {
    final _Fetch f = await _get(
      timelineEndpoint,
      cookie,
      referer: '${WeiboWebUrls.mbBase}/u/1782488734',
      label: '种子时间线（getIndex）',
    );
    return judgeSeed(httpStatus: f.httpStatus, body: f.body);
  }

  /// 纯函数：从 getIndex 响应体里挑种子微博。必须可离线单测。
  static ProbeSeed judgeSeed({required int? httpStatus, required String body}) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final Map<String, dynamic>? data = _diagAsMap(json?['data']);
    final Object? cardsRaw = data?['cards'];
    final List<Object?> cards = cardsRaw is List
        ? cardsRaw.cast<Object?>()
        : const <Object?>[];

    ProbeSeed? best;
    int bestComments = -1;
    int mblogCount = 0;
    for (final Object? card in cards) {
      final Map<String, dynamic>? cardMap = _diagAsMap(card);
      final Map<String, dynamic>? mblog = _diagAsMap(cardMap?['mblog']);
      if (mblog == null || mblog.isEmpty) continue;
      mblogCount += 1;
      final String? id = _diagAsText(mblog['id']);
      final String? mid = _diagAsText(mblog['mid']);
      if (id == null && mid == null) continue;
      final int comments = _diagAsInt(mblog['comments_count']) ?? 0;
      if (best == null || comments > bestComments) {
        bestComments = comments;
        best = ProbeSeed(
          httpStatus: httpStatus,
          id: id,
          mid: mid,
          commentsCount: comments,
          cardCount: mblogCount,
          author: _diagAsText(_diagAsMap(mblog['user'])?['screen_name']) ?? '',
          text: _diagAsText(mblog['text']) ?? '',
        );
      }
    }

    if (best != null) return best;
    return ProbeSeed(
      httpStatus: httpStatus,
      id: null,
      mid: null,
      commentsCount: 0,
      cardCount: mblogCount,
      author: '',
      text: '',
    );
  }

  // ------------------------------------------------------------ 主流程

  /// 跑一次评论探针：C1 首页 → 最多再翻 2 页 → 一次未登录对照。
  ///
  /// 请求预算：种子 1 + 翻页 ≤3 + 未登录 1 = 5，远在 [maxRequests] 之内。
  ///
  /// 任一页**非 200 / ok≠1 / 没游标 / 被叫停**就立刻停止翻页，不再制造
  /// 无谓请求。凭据安全：cookie 只进请求头，不进结果对象。
  Future<CommentProbeResult> run({
    required String cookie,
    required String mid,
    String? id,
    ProbeSeed? seed,
    bool withPaging = true,
    bool withGuestCheck = true,
  }) async {
    final String postMid = mid.trim();
    final String postId = ((id ?? mid)).trim();
    final String referer = '${WeiboWebUrls.mbBase}/status/$postMid';
    final List<CommentPageStat> pages = <CommentPageStat>[];
    final Set<String> seen = <String>{};

    String url = _hotflowUrl(
      postId: postId,
      mid: postMid,
      maxId: null,
      maxIdType: '0',
    );
    final int pageLimit = withPaging ? maxPages : 1;

    for (int pageNo = 1; pageNo <= pageLimit; pageNo++) {
      final _Fetch f = await _get(
        url,
        cookie,
        referer: referer,
        label: 'C1 hotflow 第$pageNo页',
      );
      if (f.skipped) break;
      final CommentPageStat stat = parsePage(
        pageNo: pageNo,
        httpStatus: f.httpStatus,
        body: f.body,
        seenIds: seen,
      );
      pages.add(stat);
      if (f.httpStatus != 200) break;
      if (stat.okRaw != '1') break;
      final String? cursor = stat.cursorValue;
      if (cursor == null || cursor.isEmpty) break;
      if (_aborted) break;
      url = _hotflowUrl(
        postId: postId,
        mid: postMid,
        maxId: cursor,
        maxIdType: stat.maxIdType ?? '0',
      );
    }

    // —— 未登录对照：只发 1 次 ——
    CommentPageStat? guest;
    String guestBodyHead = '';
    if (withGuestCheck && !_aborted) {
      final _Fetch f = await _get(
        _hotflowUrl(postId: postId, mid: postMid, maxId: null, maxIdType: '0'),
        '',
        referer: referer,
        label: '未登录对照（cookie 为空）',
      );
      if (!f.skipped) {
        guest = parsePage(pageNo: 0, httpStatus: f.httpStatus, body: f.body);
        guestBodyHead = _diagHeadOf(f.body);
      }
    }

    return CommentProbeResult(
      seed: seed,
      mid: postMid,
      id: postId,
      pages: pages,
      guest: guest,
      guestBodyHead: guestBodyHead,
      requestLog: List<String>.unmodifiable(_log),
      requestCount: _requestCount,
      saw432: _saw432,
      max432Streak: _max432Streak,
      note: _overallNote(pages: pages, guest: guest),
    );
  }

  static String _hotflowUrl({
    required String postId,
    required String mid,
    required String? maxId,
    required String maxIdType,
  }) {
    final StringBuffer buf = StringBuffer(hotflowEndpoint);
    buf.write('?id=$postId&mid=$mid&max_id_type=$maxIdType');
    final String? cursor = maxId;
    if (cursor != null && cursor.isNotEmpty) buf.write('&max_id=$cursor');
    return buf.toString();
  }

  static String _overallNote({
    required List<CommentPageStat> pages,
    required CommentPageStat? guest,
  }) {
    if (pages.isEmpty) return '未发出任何评论请求（被叫停或没有种子微博）';
    final CommentPageStat first = pages.first;
    final int? status = first.httpStatus;
    if (status == null) return 'C1 请求失败（网络 / 超时）';
    if (status == 432) return 'C1 被 WAF 拦截（HTTP 432）';
    if (status != 200) return 'C1 未放行（HTTP $status）';
    if (first.okRaw != '1') return 'C1 返回 ok=${first.okRaw}（非 1）';
    if (first.commentCount == 0) return 'C1 200 + ok=1，但评论 0 条（该微博可能无评论）';
    final int paged = pages.length;
    final int dups = pages
        .skip(1)
        .fold<int>(0, (int sum, CommentPageStat s) => sum + s.duplicateWithPrev);
    final int total = pages.fold<int>(
      0,
      (int sum, CommentPageStat s) => sum + s.commentCount,
    );
    final String paging = paged <= 1
        ? '未翻页'
        : (dups == 0 ? '$paged 页无重复' : '$paged 页中 $dups 条重复');
    final String guestText = guest == null
        ? '未登录对照未发出'
        : '未登录 ok=${guest.okRaw}';
    return 'C1 可用：首页 ${first.commentCount} 条，$paged 页共 $total 条（$paging）；'
        '游标 ${first.cursorField ?? '无'}；$guestText';
  }

  // ------------------------------------------------------------ 单页解析（纯函数）

  /// 纯函数：把一页 hotflow 响应整理成结构统计。必须可离线单测。
  ///
  /// [seenIds] 非空时，会把本页评论 id 与它比对得出重复条数，并把本页 id
  /// 合并进去（跨页去重用）。解析失败一律按「空页」处理，绝不抛异常。
  static CommentPageStat parsePage({
    required int pageNo,
    required int? httpStatus,
    required String body,
    Set<String>? seenIds,
  }) {
    final Map<String, dynamic>? json = _diagTryParseObject(body);
    final Object? okValue = json?['ok'];
    final String okRaw = okValue == null ? '（无 ok）' : okValue.toString();

    final Map<String, dynamic>? data = _diagAsMap(json?['data']);
    final Object? listRaw = data?['data'];
    final List<Object?> comments = listRaw is List
        ? listRaw.cast<Object?>()
        : const <Object?>[];

    final List<String> ids = <String>[];
    for (final Object? c in comments) {
      final Map<String, dynamic>? m = _diagAsMap(c);
      final String? id = _diagAsText(m?['id']) ?? _diagAsText(m?['idstr']);
      if (id != null) ids.add(id);
    }
    int duplicate = 0;
    if (seenIds != null) {
      for (final String id in ids) {
        if (seenIds.contains(id)) duplicate += 1;
      }
      seenIds.addAll(ids);
    }

    // —— 评论总数 ——
    int? totalValue;
    String? totalField;
    for (final String name in const <String>[
      'total_number',
      'total',
      'count',
    ]) {
      final Object? fromData = data?[name];
      final Object? fromTop = json?[name];
      final Object? value = fromData ?? fromTop;
      if (value == null) continue;
      final int? parsed = _diagAsInt(value);
      if (parsed == null) continue;
      totalValue = parsed;
      totalField = fromData != null ? 'data.$name' : name;
      break;
    }

    // —— 游标字段：如实列出所有形似游标的 key ——
    final List<String> cursorCandidates = <String>[];
    void scan(Map<String, dynamic>? map, String prefix) {
      if (map == null) return;
      for (final MapEntry<String, dynamic> e in map.entries) {
        if (!_cursorKey.hasMatch(e.key)) continue;
        final Object? v = e.value;
        final String text = v is String ? v : (v?.toString() ?? '');
        cursorCandidates.add('$prefix${e.key} = ${_diagMask(text)}（${_diagTypeName(v)}）');
      }
    }

    scan(data, 'data.');
    scan(json, '');

    String? cursorField;
    String? cursorValue;
    String? cursorTypeName;
    for (final MapEntry<String, dynamic> e in _cursorEntries(data, '')) {
      cursorField = e.key;
      final Object? v = e.value;
      cursorValue = v is String ? v.trim() : (v?.toString() ?? '');
      cursorTypeName = _diagTypeName(v);
      break;
    }
    if (cursorField == null) {
      for (final MapEntry<String, dynamic> e in _cursorEntries(json, '')) {
        cursorField = e.key;
        final Object? v = e.value;
        cursorValue = v is String ? v.trim() : (v?.toString() ?? '');
        cursorTypeName = _diagTypeName(v);
        break;
      }
    }

    final String? maxIdType = _diagAsText(data?['max_id_type']) ??
        _diagAsText(json?['max_id_type']);

    final Map<String, dynamic>? first = comments.isEmpty
        ? null
        : _diagAsMap(comments.first);

    return CommentPageStat(
      pageNo: pageNo,
      httpStatus: httpStatus,
      okRaw: okRaw,
      commentCount: comments.length,
      totalValue: totalValue,
      totalField: totalField,
      topKeys: _diagSortedKeys(json),
      dataKeys: _diagSortedKeys(data),
      cursorField: cursorField,
      cursorValue: cursorValue,
      cursorTypeName: cursorTypeName,
      cursorHint: cursorValue == null ? null : _diagMask(cursorValue),
      maxIdType: maxIdType,
      cursorCandidates: cursorCandidates,
      duplicateWithPrev: duplicate,
      firstCommentTree: first == null
          ? const <String>[]
          : describeComment(first, rootPath: 'data.data[0]'),
      fieldAnswers: first == null
          ? const <String>[]
          : answerFields(first, rootPath: 'data.data[0]'),
      nestedLines: first == null
          ? const <String>[]
          : describeNested(first, rootPath: 'data.data[0]'),
      nestedPath: first == null ? null : _nestedPath(first, 'data.data[0]'),
    );
  }

  // ------------------------------------------------------------ 字段树（纯函数）

  /// 把一条评论展开成「路径 → 类型 → 样例值」文本行。深度 [describeDepth]。
  static List<String> describeComment(
    Object? node, {
    String rootPath = 'data.data[0]',
  }) {
    final List<String> out = <String>[];
    if (node == null) return out;
    _diagWalkTree(
      rootPath,
      node,
      0,
      out,
      maxLines: maxLines,
      maxDepth: describeDepth,
      maxListItems: 2,
      sampleNullText: '',
    );
    return out;
  }

  /// 重点字段定位：正文 / 用户名 / 头像 / 点赞数 / 时间 / 评论 id / 二级评论。
  ///
  /// 只**如实报告**实际存在的字段名与类型；一个都找不到时明确写「未找到」，
  /// 绝不拿别的字段顶上。
  static List<String> answerFields(
    Object? comment, {
    String rootPath = 'data.data[0]',
  }) {
    final List<String> out = <String>[];
    final List<_FieldRef> refs = <_FieldRef>[];
    if (comment is Map) _scan(comment, rootPath, 0, refs);

    for (final ({String label, List<String> keys}) wanted in _wanted) {
      final List<_FieldRef> hits = refs
          .where((_FieldRef r) => wanted.keys.contains(r.key))
          .toList()
        ..sort((_FieldRef a, _FieldRef b) => a.depth.compareTo(b.depth));
      if (hits.isEmpty) {
        out.add('${wanted.label} → 未找到（${wanted.keys.join(' / ')} 均不存在）');
        continue;
      }
      final List<String> parts = hits
          .take(2)
          .map(
            (_FieldRef r) =>
                '${r.path}（${r.typeName}）${r.sample.isEmpty ? '' : ' 样例 ${r.sample}'}',
          )
          .toList();
      out.add('${wanted.label} → ${parts.join('  ／  ')}');
    }
    return out;
  }

  /// 二级评论（楼中楼）结构：找到承载它的字段，把它单独当根展开。
  static List<String> describeNested(
    Object? comment, {
    String rootPath = 'data.data[0]',
  }) {
    if (comment is! Map) return const <String>[];
    final List<MapEntry<String, Object?>> found = <MapEntry<String, Object?>>[];
    void scan(Map<Object?, Object?> map, String path, int depth) {
      if (depth > 2) return;
      for (final MapEntry<Object?, Object?> e in map.entries) {
        final String key = e.key?.toString() ?? '';
        if (key.isEmpty) continue;
        if (_nestedKeys.contains(key)) {
          found.add(MapEntry<String, Object?>('$path.$key', e.value));
          continue;
        }
        final Object? v = e.value;
        if (v is Map && v.isNotEmpty) scan(v, '$path.$key', depth + 1);
      }
    }

    scan(comment, rootPath, 0);
    final List<String> out = <String>[];
    for (final MapEntry<String, Object?> e in found) {
      final Object? v = e.value;
      if (v is List) {
        out.add('${e.key} : List（${v.length} 项）');
        if (v.isEmpty) {
          out.add('  （空列表：本条评论没有二级评论）');
          continue;
        }
        final Map<String, dynamic>? firstNested = _diagAsMap(v.first);
        final List<String> keys = _diagSortedKeys(firstNested);
        out.add(
          '  元素是 Map，字段 ${keys.length} 个：${keys.join(', ')}',
        );
        out.add('  —— 二级评论 [0] 展开（深度 $describeDepth）——');
        for (final String line in describeComment(
          v.first,
          rootPath: '${e.key}[0]',
        )) {
          out.add('  $line');
        }
      } else if (v is Map) {
        out.add('${e.key} : Map（字段 ${_diagSortedKeys(_diagAsMap(v)).join(', ')}）');
      } else {
        out.add('${e.key} : ${_diagTypeName(v)} : ${_diagProbeSampleValue(v)}');
      }
    }
    return out;
  }

  /// 二级评论字段的路径（只报位置，供汇总行显示）。
  static String? _nestedPath(Object? comment, String rootPath) {
    if (comment is! Map) return null;
    for (final Object? key in comment.keys) {
      final String k = key?.toString() ?? '';
      if (_nestedKeys.contains(k)) return '$rootPath.$k';
    }
    return null;
  }

  static const Set<String> _nestedKeys = <String>{
    'comments',
    'comments_list',
    'replies',
    'reply_comment',
  };

  /// 七个重点字段的候选 key（按真实接口字段名逐一比对，不做猜测）。
  static const List<({String label, List<String> keys})> _wanted =
      <({String label, List<String> keys})>[
        (label: '正文', keys: <String>['text', 'text_raw']),
        (label: '用户名', keys: <String>['screen_name']),
        (
          label: '头像',
          keys: <String>['profile_image_url', 'avatar_hd', 'avatar_large'],
        ),
        (
          label: '点赞数',
          keys: <String>[
            'like_counts',
            'like_count',
            'likes_count',
            'attitudes_count',
          ],
        ),
        (label: '时间', keys: <String>['created_at', 'created_at_raw', 'time']),
        (label: '评论 id', keys: <String>['id', 'idstr']),
        (
          label: '二级评论',
          keys: <String>['comments', 'comments_list', 'replies', 'reply_comment'],
        ),
      ];

  static void _scan(
    Object? node,
    String path,
    int depth,
    List<_FieldRef> out,
  ) {
    if (node is! Map || depth > 2) return;
    for (final MapEntry<Object?, Object?> e in node.entries) {
      final String key = e.key?.toString() ?? '';
      if (key.isEmpty) continue;
      final String p = '$path.$key';
      final Object? v = e.value;
      if (v is Map) {
        _scan(v, p, depth + 1, out);
      } else if (v is List) {
        out.add(
          _FieldRef(
            path: p,
            key: key,
            typeName: 'List',
            sample: v.isEmpty ? '[]' : '（${v.length} 项）',
            depth: depth + 1,
          ),
        );
      } else {
        out.add(
          _FieldRef(
            path: p,
            key: key,
            typeName: _diagTypeName(v),
            sample: _diagProbeSampleValue(v),
            depth: depth + 1,
          ),
        );
      }
    }
  }

  // ------------------------------------------------------------ 小工具

  static List<MapEntry<String, dynamic>> _cursorEntries(
    Map<String, dynamic>? map,
    String prefix,
  ) {
    if (map == null) return const <MapEntry<String, dynamic>>[];
    final List<MapEntry<String, dynamic>> preferred = <MapEntry<String, dynamic>>[];
    for (final MapEntry<String, dynamic> e in map.entries) {
      if (e.key == 'max_id') preferred.add(e);
    }
    if (preferred.isNotEmpty) return preferred;
    final List<MapEntry<String, dynamic>> fallback = <MapEntry<String, dynamic>>[];
    for (final MapEntry<String, dynamic> e in map.entries) {
      if (_cursorKey.hasMatch(e.key)) fallback.add(e);
    }
    return fallback;
  }
}

/// 种子微博：探评论用的那条真实微博。
class ProbeSeed {
  const ProbeSeed({
    required this.httpStatus,
    required this.id,
    required this.mid,
    required this.commentsCount,
    required this.cardCount,
    required this.author,
    required this.text,
  });

  /// 种子时间线请求的 HTTP 状态；null = 请求失败。
  final int? httpStatus;

  /// `mblog.id`（hotflow 的 `id` 参数）。
  final String? id;

  /// `mblog.mid`（hotflow 的 `mid` 参数）。
  final String? mid;

  /// `mblog.comments_count`——评论数（用于和 hotflow 的总数交叉验证）。
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
    return '$status · mblog $cardCount 条 · 选中 id=${maskId(id)} '
        'mid=${maskId(mid)} · comments_count=$commentsCount'
        '${author.isEmpty ? '' : ' · 作者 $author'}';
  }
}

/// 一页 hotflow 的结构统计（**不含任何凭据**）。
class CommentPageStat {
  const CommentPageStat({
    required this.pageNo,
    required this.httpStatus,
    required this.okRaw,
    required this.commentCount,
    required this.totalValue,
    required this.totalField,
    required this.topKeys,
    required this.dataKeys,
    required this.cursorField,
    required this.cursorValue,
    required this.cursorTypeName,
    required this.cursorHint,
    required this.maxIdType,
    required this.cursorCandidates,
    required this.duplicateWithPrev,
    required this.firstCommentTree,
    required this.fieldAnswers,
    required this.nestedLines,
    required this.nestedPath,
  });

  final int pageNo;
  final int? httpStatus;

  /// 顶层 `ok` 的原值文本；缺失时是「（无 ok）」。
  final String okRaw;

  /// `data.data` 的元素数（= 本页评论条数）。
  final int commentCount;

  /// 评论总数；null = 没找到。
  final int? totalValue;

  /// 总数所在字段路径（如 `data.total_number`）。
  final String? totalField;

  final List<String> topKeys;
  final List<String> dataKeys;

  /// 游标字段名（如 `max_id`）。
  final String? cursorField;

  /// 游标原值（**只在本对象内部流转，展示用 [cursorHint]**）。
  final String? cursorValue;

  /// 游标类型（String / int / ...）。
  final String? cursorTypeName;

  /// 游标脱敏摘要。
  final String? cursorHint;

  /// `max_id_type` 原值。
  final String? maxIdType;

  /// 所有形似游标的 key 与其值摘要。
  final List<String> cursorCandidates;

  /// 本页与**之前各页**重复的评论数。
  final int duplicateWithPrev;

  /// 第一条评论的字段树（只有第 1 页有）。
  final List<String> firstCommentTree;

  /// 重点字段定位（只有第 1 页有）。
  final List<String> fieldAnswers;

  /// 二级评论展开（只有第 1 页有）。
  final List<String> nestedLines;

  /// 二级评论字段路径。
  final String? nestedPath;

  String get statusText => httpStatus == null ? '请求失败' : 'HTTP $httpStatus';

  String toLine() {
    final String total = totalField == null
        ? '总数未找到'
        : '$totalField=$totalValue';
    final String cursor = cursorField == null
        ? '游标未找到'
        : '$cursorField（${cursorTypeName ?? '?'}）$cursorHint';
    final String label = pageNo == 0 ? '未登录' : '第$pageNo页';
    return '$label：$statusText · ok=$okRaw · 评论 $commentCount 条 · '
        '$total · $cursor'
        '${pageNo == 0 ? '' : ' · 与前页重复 $duplicateWithPrev 条'}';
  }
}

/// 一次评论探针的完整结果（**不含任何凭据**）。
class CommentProbeResult {
  const CommentProbeResult({
    required this.seed,
    required this.mid,
    required this.id,
    required this.pages,
    required this.guest,
    required this.guestBodyHead,
    required this.requestLog,
    required this.requestCount,
    required this.saw432,
    required this.max432Streak,
    required this.note,
  });

  final ProbeSeed? seed;
  final String mid;
  final String id;

  /// C1 各页统计（按请求顺序）。
  final List<CommentPageStat> pages;

  /// 未登录对照（cookie 为空）；null = 没跑。
  final CommentPageStat? guest;

  /// 未登录响应的正文摘要（已压平、截断；cookie 为空所以不含凭据）。
  final String guestBodyHead;

  /// 逐条请求记录（只有标签与状态码）。
  final List<String> requestLog;

  final int requestCount;

  /// 是否出现过 432。
  final bool saw432;

  /// 连续 432 的峰値。
  final int max432Streak;

  final String note;

  CommentPageStat? get firstPage => pages.isEmpty ? null : pages.first;

  /// 供对话框展示的完整文本（不含任何 cookie 内容）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('════ 微博评论接口探针（C1 hotflow）════');
    final ProbeSeed? s = seed;
    buf.writeln(s == null ? '种子微博：（未取到）' : '种子：${s.toLine()}');
    if (s != null && s.text.isNotEmpty) {
      final String flat = s.text.replaceAll(RegExp(r'\s+'), ' ');
      buf.writeln(
        '种子正文：${flat.length > 40 ? '${flat.substring(0, 40)}…' : flat}',
      );
    }
    buf.writeln('评论目标：id=${ProbeSeed.maskId(id)} mid=${ProbeSeed.maskId(mid)}');

    buf.writeln();
    buf.writeln('—— 请求记录（${requestLog.length} 个 / 上限 '
        '${WeiboCommentProbe.maxRequests}）——');
    if (requestLog.isEmpty) {
      buf.writeln('（没有发出请求）');
    } else {
      for (int i = 0; i < requestLog.length; i++) {
        buf.writeln('#${i + 1} ${requestLog[i]}');
      }
    }

    buf.writeln();
    buf.writeln('—— C1 各页 ——');
    if (pages.isEmpty) {
      buf.writeln('（没有可展示的页）');
    } else {
      for (final CommentPageStat p in pages) {
        buf.writeln(p.toLine());
      }
      final CommentPageStat f = pages.first;
      buf.writeln('第1页顶层 keys：'
          '${f.topKeys.isEmpty ? '（空）' : f.topKeys.join(', ')}');
      buf.writeln('第1页 data keys：'
          '${f.dataKeys.isEmpty ? '（空）' : f.dataKeys.join(', ')}');
      buf.writeln('游标候选：'
          '${f.cursorCandidates.isEmpty ? '（无）' : f.cursorCandidates.join(' / ')}');
    }

    final CommentPageStat? f0 = firstPage;
    if (f0 != null) {
      buf.writeln();
      buf.writeln('—— 第一条评论字段树（深度 ${WeiboCommentProbe.describeDepth}）——');
      if (f0.firstCommentTree.isEmpty) {
        buf.writeln('（没有评论可展开）');
      } else {
        for (final String l in f0.firstCommentTree) {
          buf.writeln(l);
        }
      }

      buf.writeln();
      buf.writeln('—— 重点字段 ——');
      if (f0.fieldAnswers.isEmpty) {
        buf.writeln('（没有评论可判定）');
      } else {
        for (final String l in f0.fieldAnswers) {
          buf.writeln(l);
        }
      }

      buf.writeln();
      buf.writeln('—— 二级评论（楼中楼）——');
      if (f0.nestedLines.isEmpty) {
        buf.writeln('（第一条评论里没有 comments / replies / reply_comment 字段）');
      } else {
        for (final String l in f0.nestedLines) {
          buf.writeln(l);
        }
      }
    }

    buf.writeln();
    buf.writeln('—— 翻页与风控 ——');
    if (pages.length <= 1) {
      buf.writeln('只跑了第 1 页（后续页未发出）');
    } else {
      for (final CommentPageStat p in pages) {
        buf.writeln('第${p.pageNo}页：${p.statusText} · ${p.commentCount} 条');
      }
      final int dups = pages
          .skip(1)
          .fold<int>(0, (int a, CommentPageStat b) => a + b.duplicateWithPrev);
      buf.writeln(dups == 0
          ? '重复：0 条（游标推进有效）'
          : '重复：$dups 条（游标可能无效）');
    }
    buf.writeln('432：${saw432 ? '出现过（连续峰值 $max432Streak）' : '未出现'}');
    buf.writeln('请求数：$requestCount / ${WeiboCommentProbe.maxRequests}');

    buf.writeln();
    buf.writeln('—— 未登录对照（cookie 为空，只测 1 次）——');
    final CommentPageStat? g = guest;
    if (g == null) {
      buf.writeln('（未发出）');
    } else {
      buf.writeln('${g.statusText} · ok=${g.okRaw} · 评论 ${g.commentCount} 条');
      if (guestBodyHead.isNotEmpty) buf.writeln('响应摘要：$guestBodyHead');
    }

    buf.writeln();
    buf.writeln('—— 判定 ——');
    buf.writeln(note);
    return buf.toString();
  }
}

/// 一条评论里某个标量的位置。
class _FieldRef {
  const _FieldRef({
    required this.path,
    required this.key,
    required this.typeName,
    required this.sample,
    required this.depth,
  });

  final String path;
  final String key;
  final String typeName;
  final String sample;
  final int depth;
}

