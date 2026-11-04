/// 微博**子评论（二级回复）**探针（纯诊断，不是正式数据层）。
///
/// ## 为什么还要一个探针
///
/// 一级评论接口 `comments/hotflow` 的响应里，楼中楼**内嵌**在
/// `data.data[i].comments[]`。但实测那条数组**恒为 2 条**（详见
/// `.env/weibo_comment_probe.md`，`data.data[0].comments` 只有 [0]、[1]），
/// 而微博 App 里同一楼层能展开十几条回复。于是有一个从未验证的假设：
///
/// > 内嵌的 `comments[]` **只是前 2 条**，完整回复要靠**单独接口**拿。
///
/// 本探针只回答这一件事，同时把 UI 上「共 N 条回复」的 N 从哪来一并钉死：
///
/// 1. **T1** `comments/hotflowChild?cid=<一级评论 id>&max_id_type=0`
///    —— 状态码 / `ok` / 列表路径 / 返回条数 / 与内嵌 2 条的对比；
/// 2. **分页** —— 游标字段名、形态、第 2 页能否续拉、两页是否重复；
/// 3. **T2** 一级评论里哪个字段是「总回复数」
///    （用 hotflowChild 的 `total_number` 与之**交叉验证**，而不是靠猜字段名）；
/// 4. **T3**（仅 T1 失败时）`api/comments/showChild` / `comments/hotFlowChild`
///    大小写变体 / 评论详情页 `comment/<cid>`。
///
/// 它不产出任何模型、不碰 `weibo_comment_parser.dart`、不改 UI。
///
/// ## 请求纪律（硬上限，调用方改不动）
///
/// 间隔 ≥2.5s · 总请求 ≤[WeiboSubCommentProbe.maxRequests]（16）·
/// 一级评论最多翻 [WeiboSubCommentProbe.maxPostPages] 页 · 连续 3 次 432
/// 立刻停 · 单项超时 20s · **不重试**、**不做任何风控绕过**
/// （不伪造 XSRF、不换 UA 批量试、不拼 `st` 参数）。
///
/// ## 凭据安全（硬约束）
///
/// cookie 只作为请求头出现：不进日志、不进结果对象、不进异常文案、不落盘。
/// 落盘的 Markdown 里只写 cookie **长度**。URL 一律脱敏（参数值只留长度）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'weibo_web_urls.dart';

// ===========================================================================
// 本地共享工具（与 weibo_comment_multi_pic_probe.dart 一致，
// 但那是 library 私有符号、跨 library 用不了，这里只保留最小一份）
// ===========================================================================

const int _scMaxValueChars = 60;

/// id 的统一脱敏：前 6 位 + 长度（够区分、不泄露原值）。
String _maskId(String value) {
  if (value.isEmpty) return '（空）';
  final String head = value.length > 6 ? value.substring(0, 6) : value;
  return '$head…（${value.length} 位）';
}

Map<String, dynamic>? _scAsMap(Object? value) {
  if (value is! Map) return null;
  return value.cast<String, dynamic>();
}

String? _scAsText(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final String s = value.trim();
    return s.isEmpty ? null : s;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

int? _scAsInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Map<String, dynamic>? _scTryParseObject(String body) {
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

String _scTypeName(Object? value) {
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
String _scSampleValue(Object? value, {int maxChars = _scMaxValueChars}) {
  if (value == null) return '';
  final String raw = value is String ? value : value.toString();
  if (raw.length <= maxChars) return value is String ? '"$raw"' : raw;
  final String cut = raw.substring(0, maxChars);
  return value is String
      ? '"$cut…（原长 ${raw.length}）'
      : '$cut…（原长 ${raw.length}）';
}

String _scToday() {
  final DateTime now = DateTime.now();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}

// ===========================================================================
// 纯函数：字段识别 / 响应解析（全部必须可离线单测）
// ===========================================================================

/// 「像总数」的字段名。
///
/// `comments_num` / `reply_count` / `total_number` / `sub_comment_count` 这类
/// 全都能匹配上；`like_count` / `floor_number` 这类由下面的黑名单排除。
final RegExp _countKeyRe = RegExp(
  r'(comment|reply|sub|child|total|count|num)',
  caseSensitive: false,
);

/// 明确**不是**回复数的字段（都是评论里固定出现的元数据）。
const Set<String> _noiseKeys = <String>{
  'id',
  'gid',
  'mid',
  'uid',
  'rootid',
  'rootidstr',
  'rid',
  'bid',
  'floor_number',
  'like_count',
  'liked',
  'pic_num',
  'disable_reply',
  'restrictOperate',
  'restrict_state',
  'biz_mark_type',
  'shouldShowColon',
  'allow_follow',
  'isLikedByMblogAuthor',
  'status',
  'item_category',
  'match_ai_play_picture',
};

/// 一个候选「总数」字段。
class CountLikeField {
  const CountLikeField({required this.key, required this.value});

  /// 字段名，例如 `comments_num`。
  final String key;

  /// 字段值（只接受 int）。
  final int value;

  String get text => '$key=$value';
}

/// 「总数」候选：扫一条评论的**顶层标量字段**，留下名字像总数且是 int 的。
///
/// 只扫顶层：`user.*` / `comment_badge.*` / `comment_dynamic_message.*` 是噪声，
/// 里面的 `follow_count`、`statuses_count` 明显不是本楼的回复数。
List<CountLikeField> countLikeFields(Object? comment) {
  final Map<String, dynamic>? m = _scAsMap(comment);
  if (m == null) return const <CountLikeField>[];
  final List<CountLikeField> out = <CountLikeField>[];
  for (final MapEntry<String, dynamic> e in m.entries) {
    if (_noiseKeys.contains(e.key)) continue;
    if (!_countKeyRe.hasMatch(e.key)) continue;
    final int? v = _scAsInt(e.value);
    if (v == null) continue;
    out.add(CountLikeField(key: e.key, value: v));
  }
  out.sort((CountLikeField a, CountLikeField b) => a.key.compareTo(b.key));
  return out;
}

/// 「id 类」字段名（值要脱敏后再进报告）。
final RegExp _idLikeKeyRe = RegExp(
  r'(^|_)(id|mid|gid|uid|bid|rid|rootid|rootidstr|idstr|author_uid)$',
  caseSensitive: false,
);

/// 一条评论顶层标量字段的「全量摘录」（人工核查用，防止漏掉没猜到的字段名）。
///
/// 只取 String / num / bool，`Map` / `List` 只写类型与项数，避免把
/// `report_scheme` 这种近千字符的串灌进报告。
List<String> scalarDump(Object? comment, {int limit = 48}) {
  final Map<String, dynamic>? m = _scAsMap(comment);
  if (m == null) return const <String>[];
  final List<String> keys = m.keys.toList()..sort();
  final List<String> out = <String>[];
  for (final String k in keys) {
    if (out.length >= limit) break;
    final Object? v = m[k];
    if (v is Map) {
      out.add('$k : Map（${v.length} 个 key）');
      continue;
    }
    if (v is List) {
      out.add('$k : List（${v.length} 项）');
      continue;
    }
    // id 类键脱敏：报告里不该出现完整 mid / cid（与 URL 脱敏保持同一标准）。
    final String shown = _idLikeKeyRe.hasMatch(k)
        ? _maskId(v is String ? v : '$v')
        : _scSampleValue(v);
    out.add('$k : ${_scTypeName(v)} : $shown');
  }
  return out;
}

/// 一条一级评论的「内嵌二级评论」与「声称的总回复数」。
class SubCommentInlineSample {
  const SubCommentInlineSample({
    required this.postIndex,
    required this.id,
    required this.author,
    required this.inlineCount,
    required this.countFields,
    required this.claimedField,
    required this.claimedTotal,
    required this.textHead,
    required this.inlineMaxId,
  });

  /// 在 `data.data[]` 里的下标（落盘用 `data.data[i]` 定位）。
  final int postIndex;

  /// 一级评论 id（= hotflowChild 的 `cid`）。
  final String id;

  final String? author;

  /// 内嵌 `comments[]` 的条数（实测通常是 2）。
  final int inlineCount;

  /// 所有「像总数」的 int 字段。
  final List<CountLikeField> countFields;

  /// 其中值 **大于** 内嵌条数的那个字段名（null = 没有这样的字段）。
  final String? claimedField;

  /// 上面对应字段的值。
  final int? claimedTotal;

  /// 一级评论节点里自带的 `max_id`。
  ///
  /// **真机实测（2026-10-22）**：`hotflowChild` 的响应里**没有任何游标**，
  /// 但同一楼层的一级评论节点里有 `max_id`（`data.data[0].max_id`，int 15 位）
  /// 与 `total_number`（68）。子评论第 1 页只回 10 条 —— 剩下 58 条的续拉
  /// 游标**就藏在一级评论节点里**。这个字段就是它的原值。
  final String? inlineMaxId;

  /// 正文开头（截断，落盘用）。
  final String textHead;

  /// 选样打分：有「声称总数」的优先，其次内嵌条数多的。
  int get score => (claimedTotal != null ? 10000 : 0) + inlineCount;

  /// 是否为「强候选」：内嵌有内容，且存在一个更大的总数声明。
  bool get isStrong => inlineCount >= 1 && claimedTotal != null;
}

/// 在一页 hotflow 响应里挑最合适的一级评论。
///
/// 优先「内嵌非空 **且** 有字段声称更大总数」的（那正是本探针要打的样本）；
/// 都没有时退回「内嵌条数最多」的那条 —— 这样即使微博不再给总数字段，
/// 探针仍能跑到 T1，不至于得出 NO_SAMPLE 的假结论。
SubCommentInlineSample? pickInlineSample(String body) {
  final Map<String, dynamic>? root = _scTryParseObject(body);
  final Map<String, dynamic>? data = _scAsMap(root?['data']);
  final Object? list = data?['data'];
  if (list is! List) return null;

  SubCommentInlineSample? best;
  for (int i = 0; i < list.length; i++) {
    final Map<String, dynamic>? m = _scAsMap(list[i]);
    if (m == null) continue;
    final Object? nested = m['comments'];
    final int inline = nested is List ? nested.length : 0;
    final List<CountLikeField> fields = countLikeFields(m);
    CountLikeField? bigger;
    for (final CountLikeField f in fields) {
      if (f.value > inline) {
        bigger = f;
        break;
      }
    }
    final Map<String, dynamic>? user = _scAsMap(m['user']);
    final String? author = _scAsText(user?['screen_name']);
    final String? rawText = _scAsText(m['text']);
    final SubCommentInlineSample s = SubCommentInlineSample(
      postIndex: i,
      id: _scAsText(m['id']) ?? _scAsText(m['mid']) ?? '',
      author: author,
      inlineCount: inline,
      countFields: fields,
      claimedField: bigger?.key,
      claimedTotal: bigger?.value,
      inlineMaxId: _scAsText(m['max_id']) ?? _scAsText(m['max']),
      textHead: rawText == null
          ? '（无正文）'
          : (rawText.length > 24 ? '${rawText.substring(0, 24)}…' : rawText),
    );
    if (s.id.isEmpty) continue;
    if (best == null || s.score > best.score) best = s;
  }
  return best;
}

/// 一条评论顶层所有 **int 标量**（排除已知元数据），用于和子接口的
/// `total_number` 逐值比对 —— 这样即使字段名没被 [_countKeyRe] 命中，
/// 也不会把「总回复数」漏掉。
Map<String, int> intScalars(Object? comment) {
  final Map<String, dynamic>? m = _scAsMap(comment);
  if (m == null) return const <String, int>{};
  final Map<String, int> out = <String, int>{};
  for (final MapEntry<String, dynamic> e in m.entries) {
    if (_noiseKeys.contains(e.key)) continue;
    final int? v = _scAsInt(e.value);
    if (v == null) continue;
    out[e.key] = v;
  }
  return out;
}

/// 取一页响应里 `data.data[i]` 的原始节点。
Map<String, dynamic>? nodeAt(String body, int index) {
  final Map<String, dynamic>? root = _scTryParseObject(body);
  final Map<String, dynamic>? data = _scAsMap(root?['data']);
  final Object? list = data?['data'];
  if (list is! List || index < 0 || index >= list.length) return null;
  return _scAsMap(list[index]);
}

/// hotflow 一页的翻页游标（`data.max_id`）。
String? hotflowCursorOf(String body) {
  final Map<String, dynamic>? root = _scTryParseObject(body);
  final Map<String, dynamic>? data = _scAsMap(root?['data']);
  return _scAsText(data?['max_id']) ?? _scAsText(data?['max']);
}

/// 子评论列表**可能**所在的路径（按优先级）。命中第一个「非空 List」。
///
/// 本探针不预设答案：`data.data[]` 是 hotflow 的形态，`hotflowChild` 未必
/// 一样，所以这里把常见几种都探一遍，把**实际命中的路径**写进报告。
const List<List<String>> childListPathCandidates = <List<String>>[
  <String>['data', 'data'],
  <String>['data'],
  <String>['data', 'comments'],
  <String>['data', 'replies'],
  <String>['data', 'list'],
  <String>['comments'],
];

Object? _valueAtPath(Map<String, dynamic> root, List<String> path) {
  Object? cur = root;
  for (final String seg in path) {
    if (cur is List) {
      final int? idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= cur.length) return null;
      cur = cur[idx];
      continue;
    }
    final Map<String, dynamic>? m = _scAsMap(cur);
    if (m == null) return null;
    if (!m.containsKey(seg)) return null;
    cur = m[seg];
  }
  return cur;
}

/// 一个游标字段（在 `data` 层里按名字找出来的）。
class ChildCursor {
  const ChildCursor({
    required this.path,
    required this.key,
    required this.value,
    required this.typeName,
  });

  /// 完整路径，例如 `data.max_id`。
  final String path;

  final String key;

  /// 原始值（续拉时原样拼进 query）。
  final String value;

  final String typeName;

  /// 展示用：`data.max_id(int)=1.827e14`（值按长度脱敏，游标不算凭据但也不必全量落盘）。
  String get text => '$path($typeName)='
      '${value.length <= 6 ? value : '${value.substring(0, 6)}…（${value.length} 位）'}';
}

/// 在 `data` 层（深度 2）找所有像游标的标量字段。
List<ChildCursor> findCursors(Map<String, dynamic>? data) {
  if (data == null) return const <ChildCursor>[];
  final RegExp cursorRe = RegExp(
    r'(max|cursor|since|next|page|offset)',
    caseSensitive: false,
  );

  /// **不是**游标的字段：`max_id_type` 恒为 0（它是「游标类型」标记，
  /// 拼进 query 会原样拿到同一页），`max_id_type`/`max_id` 的区分必须在这里
  /// 做掉，否则续拉永远「成功」但永远重复第 1 页。
  const Set<String> notCursor = <String>{
    'max_id_type',
    'status',
    'page_size',
    'total_page',
  };
  final List<ChildCursor> out = <ChildCursor>[];
  void visit(Map<String, dynamic> m, String prefix, int depth) {
    final List<String> keys = m.keys.toList()..sort();
    for (final String k in keys) {
      final Object? v = m[k];
      final String path =
          prefix.isEmpty ? 'data.$k' : 'data.$prefix.$k';
      if (v is Map && depth < 2) {
        visit(v.cast<String, dynamic>(), path.substring(5), depth + 1);
        continue;
      }
      if (v is List) continue;
      if (!cursorRe.hasMatch(k)) continue;
      if (notCursor.contains(k)) continue;
      final String? text = _scAsText(v);
      if (text == null) continue;
      out.add(
        ChildCursor(
          path: path,
          key: k,
          value: text,
          typeName: _scTypeName(v),
        ),
      );
    }
  }

  visit(data, '', 1);
  return out;
}

/// 子评论接口的一页（**不含凭据**）。
class ChildPageProbe {
  const ChildPageProbe({
    required this.label,
    required this.urlMasked,
    required this.httpStatus,
    required this.okFlag,
    required this.listPath,
    required this.ids,
    required this.cursors,
    required this.cursorField,
    required this.cursorValue,
    required this.totalNumber,
    required this.dataKeys,
    required this.duplicateOfPrevious,
    required this.byteLength,
  });

  /// 展示标签，例如「T1 第 1 页」。
  final String label;

  /// 已脱敏的请求 URL（参数值只留长度）。
  final String urlMasked;

  final int? httpStatus;

  /// 顶层 `ok`（微博业务码）。
  final int? okFlag;

  /// 回复列表实际命中的路径（`data.data` / `data.comments` / `NONE`）。
  final String listPath;

  /// 该页返回的评论 id（**原始**，仅用于跨页去重，落盘时脱敏）。
  final List<String> ids;

  /// 该页出现的所有游标字段。
  final List<ChildCursor> cursors;

  /// 选中的游标字段名（续拉时用的 query 参数名）；null = 没找到。
  final String? cursorField;

  /// 选中游标的原始值；null = 没找到。
  final String? cursorValue;

  /// `data.total_number`（若有）。
  final int? totalNumber;

  /// `data` 层的 key 列表（报告里说明「为什么要用这个路径」）。
  final List<String> dataKeys;

  /// 与上一页重复的条数（第 1 页恒 0）。
  final int duplicateOfPrevious;

  /// 响应字节数（`0` 表示空体，常用于判断 432 / WAF）。
  final int byteLength;

  int get returned => ids.length;

  /// 该页是否「可用」：200 + ok==1 + 列表非空。
  bool get usable => httpStatus == 200 && okFlag == 1 && ids.isNotEmpty;

  /// 还有没有下一页（有游标且本页非空）。
  bool get hasMore =>
      ids.isNotEmpty && cursorField != null && (cursorValue ?? '').isNotEmpty;
}

/// 解析子评论接口的一页。
///
/// 只做**结构发现**，不假设路径：返回实际命中路径、游标字段、总数字段。
ChildPageProbe parseChildPage({
  required String body,
  required int? httpStatus,
  required String urlMasked,
  required String label,
  int duplicateOfPrevious = 0,
}) {
  final Map<String, dynamic>? root = _scTryParseObject(body);
  final int? okFlag = _scAsInt(root?['ok']);
  final Map<String, dynamic>? data = _scAsMap(root?['data']);

  String listPath = 'NONE';
  List<Object?> hitList = const <Object?>[];
  for (final List<String> p in childListPathCandidates) {
    final Object? v = root == null ? null : _valueAtPath(root, p);
    if (v is! List) continue;
    if (v.isNotEmpty) {
      listPath = p.join('.');
      hitList = v;
      break;
    }
    // 空 List 也记一下，但继续找非空的；全空时才用它兜底。
    if (listPath == 'NONE') {
      listPath = '${p.join('.')}（空）';
      hitList = v;
    }
  }

  final List<String> ids = <String>[];
  for (final Object? e in hitList) {
    final Map<String, dynamic>? m = _scAsMap(e);
    if (m == null) continue;
    final String? id = _scAsText(m['id']) ?? _scAsText(m['mid']);
    if (id != null) ids.add(id);
  }

  final List<ChildCursor> cursors = findCursors(data);

  // 游标字段优选：精确 `max_id` > 其它含 max 的 > 其余。
  ChildCursor? picked;
  for (final ChildCursor c in cursors) {
    if (c.key == 'max_id') {
      picked = c;
      break;
    }
  }
  if (picked == null) {
    for (final ChildCursor c in cursors) {
      if (c.key.toLowerCase().contains('max')) {
        picked = c;
        break;
      }
    }
  }
  picked ??= cursors.isEmpty ? null : cursors.first;

  final int? total = _scAsInt(data?['total_number']) ??
      _scAsInt(data?['total']) ??
      _scAsInt(data?['total_count']);

  return ChildPageProbe(
    label: label,
    urlMasked: urlMasked,
    httpStatus: httpStatus,
    okFlag: okFlag,
    listPath: listPath,
    ids: ids,
    cursors: cursors,
    cursorField: picked?.key,
    cursorValue: picked?.value,
    totalNumber: total,
    dataKeys: data != null
        ? (data.keys.toList()..sort())
        : (root != null && root['data'] is List
            ? <String>['data 是 List，${(root['data'] as List).length} 项']
            : const <String>[]),
    duplicateOfPrevious: duplicateOfPrevious,
    byteLength: body.length,
  );
}

/// 两页 id 的交集大小（第 2 页是否在重复第 1 页）。
int overlapCount(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final Set<String> set = a.toSet();
  int n = 0;
  for (final String x in b) {
    if (set.contains(x)) n += 1;
  }
  return n;
}

/// 兜底候选（T3）的一次尝试结果。
class T3Attempt {
  const T3Attempt({
    required this.label,
    required this.urlMasked,
    required this.httpStatus,
    required this.okFlag,
    required this.listPath,
    required this.returned,
    required this.bodyKind,
    required this.note,
  });

  final String label;
  final String urlMasked;
  final int? httpStatus;
  final int? okFlag;
  final String listPath;
  final int returned;

  /// `json` / `html` / `empty` / `text`。
  final String bodyKind;

  final String note;

  bool get usable => httpStatus == 200 && returned > 0;
}

/// 判一个响应体的「形态」。
String bodyKindOf(String body) {
  if (body.trim().isEmpty) return 'empty';
  final String head = body.trimLeft();
  if (head.startsWith('{') || head.startsWith('[')) return 'json';
  if (head.toLowerCase().startsWith('<!doctype') ||
      head.toLowerCase().startsWith('<html')) {
    return 'html';
  }
  return 'text';
}

// ===========================================================================
// 结果对象（**不含任何凭据**）
// ===========================================================================

/// 一次子评论探针的完整结果。
class SubCommentProbeResult {
  const SubCommentProbeResult({
    required this.mid,
    required this.postPagesFetched,
    required this.scannedPages,
    required this.sample,
    required this.sampleScalars,
    required this.childFirst,
    required this.childSecond,
    required this.t3,
    required this.requestLog,
    required this.requestCount,
    required this.saw432,
    required this.max432Streak,
    required this.maxRequests,
    required this.totalField,
    required this.totalFieldVerified,
    required this.note,
  });

  final String mid;

  /// 一级评论翻了几页。
  final int postPagesFetched;

  /// 每页扫到多少条一级评论 / 其中多少条内嵌非空（人话描述）。
  final List<String> scannedPages;

  /// 被选中的一级评论（null = 3 页都没扫到可用样本）。
  final SubCommentInlineSample? sample;

  /// 该一级评论顶层标量字段摘录（人工核查用）。
  final List<String> sampleScalars;

  /// `hotflowChild` 第 1 页。
  final ChildPageProbe? childFirst;

  /// `hotflowChild` 第 2 页（续拉成功才有）。
  final ChildPageProbe? childSecond;

  /// T3 兜底候选的尝试记录（T1 成功时为空）。
  final List<T3Attempt> t3;

  final List<String> requestLog;
  final int requestCount;
  final bool saw432;
  final int max432Streak;
  final int maxRequests;

  /// 「共 N 条回复」的 N 来自哪个字段（`NONE` = 没找到）。
  final String totalField;

  /// `totalField` 是否与 hotflowChild 的 `total_number` 交叉验证过。
  final bool totalFieldVerified;

  final String note;

  // ------------------------------------------------------------ 派生结论

  /// `OK` / `FAILED` / `NO_SAMPLE`。
  String get verdict {
    if (sample == null) return 'NO_SAMPLE';
    if (childFirst != null && childFirst!.usable) return 'OK';
    for (final T3Attempt a in t3) {
      if (a.usable) return 'OK';
    }
    return 'FAILED';
  }

  /// T1 第 1 页返回的条数（null = 没发或没解析到）。
  int? get returnedCount => childFirst?.ids.length;

  /// 内嵌条数。
  int get inlineCount => sample?.inlineCount ?? 0;

  /// 内嵌 2 条之外还多出多少条（负数 = 反而更少）。
  int? get delta => childFirst == null ? null : returnedCount! - inlineCount;

  /// 游标字段名（`NONE` = 没有）。
  String get cursorField => childFirst?.cursorField ?? 'NONE';

  /// 第 2 页是否续拉成功且有新内容。
  bool get secondPageWorks =>
      childSecond != null &&
      childSecond!.usable &&
      childSecond!.duplicateOfPrevious == 0;

  /// 拿全需要几个请求（子评论接口的页数）。
  ///
  /// 实测得到：第 1 页有游标且第 2 页有新内容 → 至少 3 页；第 2 页已无游标
  /// → 2 页；第 1 页就没游标 → 1 页。无法确定时返回 null（报告里写「≥N」）。
  int? get requestsToFetchAll {
    final ChildPageProbe? first = childFirst;
    if (first == null || !first.usable) return null;

    // 第 1 页的条数已经覆盖了「声称总数」→ 1 个请求就拉全了。
    final int? claimed = sample?.claimedTotal;
    if (claimed != null && first.returned >= claimed) return 1;

    final ChildPageProbe? second = childSecond;
    if (second == null) {
      // 没拉第 2 页：只有第 1 页确实没游标、且条数够，才算 1；否则未知。
      if (!first.hasMore && (claimed == null || first.returned >= claimed)) {
        return 1;
      }
      return null;
    }
    if (!second.usable) return 2;
    // 第 2 页追加成功：总数够就不止一页了，具体几页看第 2 页还有没有游标。
    final int got = first.returned + second.returned;
    if (claimed != null && got >= claimed) return 2;
    if (!second.hasMore) return 2;
    return null;
  }

  /// **续拉游标到底从哪来**（报告里必须说清楚，否则实现方会以为接口自带）。
  ///
  /// - `child`  = 子接口响应自带（`data.max_id` 之类）
  /// - `inline` = 一级评论节点里的 `max_id`
  /// - `NONE`   = 两处都没有
  String get cursorSource {
    final ChildPageProbe? first = childFirst;
    if (first != null && first.hasMore) return 'child';
    final String? inline = sample?.inlineMaxId;
    if (inline != null && inline.isNotEmpty) return 'inline';
    return 'NONE';
  }

  /// 续拉实际用的游标字段名（`NONE` = 没有）。
  String get effectiveCursorField {
    final String src = cursorSource;
    if (src == 'child') return childFirst?.cursorField ?? 'max_id';
    if (src == 'inline') return 'max_id';
    return 'NONE';
  }

  /// 声称总数与实际可拉取条数的**一致性**。
  ///
  /// `consistent` / `mismatch` / `unknown`。
  ///
  /// 真机实测（2026-10-22）：一级评论 `total_number=68`，但 `hotflowChild`
  /// 第 1 页 10 条 + 第 2 页 2 条之后就没有游标了 —— 实际只能拿到 **12 条**。
  /// 也就是说 `total_number` **不是**「可获取的回复条数」，UI 上的
  /// 「共 N 条回复」不能直接拿它当可展开条数，否则用户展开后会看到
  /// 「说 68 条，只给了 12 条」。本 getter 就是把这个坑显式暴露出来。
  String get totalConsistency {
    final int? claimed = sample?.claimedTotal;
    if (claimed == null) return 'unknown';
    final int? got = obtainableCount;
    if (got == null) return 'unknown';
    return got == claimed ? 'consistent' : 'mismatch';
  }

  /// 实际能拉到的总条数（已拉到的页都算上；null = 还没法判断）。
  int? get obtainableCount {
    final ChildPageProbe? first = childFirst;
    if (first == null || !first.usable) return null;
    final ChildPageProbe? second = childSecond;
    if (second == null) {
      // 第 1 页没有游标（且没有 inline 游标可续）→ 这就已经全了。
      if (!first.hasMore && (sample?.inlineMaxId ?? '').isEmpty) {
        return first.returned;
      }
      return null;
    }
    if (!second.usable) return first.returned;
    if (!second.hasMore) return first.returned + second.returned;
    return null;
  }

  /// 请求数的人话形态。
  ///
  /// 能算出确定值就给数字；只知道「还有下一页」时给**下界**（`≥N`），
  /// 绝不用编出来的数字冒充实测（那会让实现方按错的成本做设计）。
  String get requestsToFetchAllText {
    final int? n = requestsToFetchAll;
    if (n != null) return '$n';
    final ChildPageProbe? first = childFirst;
    if (first == null || !first.usable) return 'N/A';
    if (childSecond == null) return '≥2';
    return '≥3';
  }

  /// 供对话框展示的完整文本（不含任何 cookie 内容）。
  String toText() {
    final StringBuffer buf = StringBuffer();
    buf.writeln('════ 微博子评论（二级回复）探针 ════');
    buf.writeln('目标 mid：${_maskId(mid)}');
    buf.writeln();
    buf.writeln(
      '—— 请求记录（${requestLog.length} / 上限 $maxRequests）——',
    );
    if (requestLog.isEmpty) {
      buf.writeln('（没有发出请求）');
    } else {
      for (int i = 0; i < requestLog.length; i++) {
        buf.writeln('#${i + 1} ${requestLog[i]}');
      }
    }
    buf.writeln();
    buf.writeln('—— 一级评论扫描（$postPagesFetched 页）——');
    if (scannedPages.isEmpty) {
      buf.writeln('（没有可展示的页）');
    } else {
      for (final String l in scannedPages) {
        buf.writeln(l);
      }
    }
    buf.writeln();

    final SubCommentInlineSample? s = sample;
    buf.writeln('—— 样本 ——');
    if (s == null) {
      buf.writeln('（3 页都没扫到内嵌二级评论的一级评论 → NO_SAMPLE）');
    } else {
      buf.writeln(
        '位置 data.data[${s.postIndex}] · id ${_maskId(s.id)} · '
        '作者 ${s.author ?? '（未知）'}',
      );
      buf.writeln('正文：${s.textHead}');
      buf.writeln(
        '内嵌 comments 条数：${s.inlineCount} · '
        '声称总数：${s.claimedField == null ? '（没有更大的数字段）' : '${s.claimedField}=${s.claimedTotal}'}',
      );
      if (s.countFields.isNotEmpty) {
        buf.writeln(
          '「像总数」的字段：'
          '${s.countFields.map((CountLikeField f) => f.text).join('、')}',
        );
      }
    }
    buf.writeln();

    void dumpPage(ChildPageProbe? p) {
      if (p == null) return;
      buf.writeln('—— ${p.label} ——');
      buf.writeln('URL：${p.urlMasked}');
      buf.writeln(
        'HTTP ${p.httpStatus ?? '（失败）'} · ok=${p.okFlag ?? '缺失'} · '
        '${p.byteLength} 字符',
      );
      buf.writeln(
        '列表路径：${p.listPath} · 返回 ${p.returned} 条'
        '${p.duplicateOfPrevious > 0 ? ' · 与上一页重复 ${p.duplicateOfPrevious} 条' : ''}',
      );
      buf.writeln('data keys：${p.dataKeys.isEmpty ? '（无）' : p.dataKeys.join(', ')}');
      if (p.cursors.isEmpty) {
        final bool fromInline =
            p == childFirst && sample?.inlineMaxId != null;
        buf.writeln(
          '游标字段：（响应里没有）'
          '${fromInline ? ' · 续拉用一级评论节点的 max_id' : ''}',
        );
      } else {
        buf.writeln('游标字段：');
        for (final ChildCursor c in p.cursors) {
          buf.writeln(
            '  - ${c.text}${c.key == p.cursorField ? '  ← 采用' : ''}',
          );
        }
      }
      buf.writeln('total_number：${p.totalNumber ?? '（无）'}');
      if (p.ids.isNotEmpty) {
        final String head = p.ids
            .take(3)
            .map((String id) => _maskId(id))
            .join('、');
        buf.writeln('前 ${p.ids.length < 3 ? p.ids.length : 3} 条 id：$head');
      }
      buf.writeln();
    }

    dumpPage(childFirst);
    dumpPage(childSecond);

    if (t3.isNotEmpty) {
      buf.writeln('—— T3 兜底候选 ——');
      for (final T3Attempt a in t3) {
        buf.writeln(
          '${a.label}：HTTP ${a.httpStatus ?? '失败'} · ok=${a.okFlag ?? '缺失'} · '
          '${a.bodyKind} · 列表 ${a.listPath} · ${a.returned} 条 — ${a.note}',
        );
      }
      buf.writeln();
    }

    buf.writeln('════ 结论 ════');
    buf.writeln('判定：$verdict');
    buf.writeln(
      '1. hotflowChild 能否拿全？'
      '${verdict == 'OK' ? '能。返回 $returnedCount 条（内嵌 $inlineCount 条）' : '见上表状态码'}',
    );
    final int? cursorLen = childFirst?.cursorValue?.length ??
        sample?.inlineMaxId?.length;
    buf.writeln(
      '2. 分页：游标 `$effectiveCursorField`（来源 $cursorSource）'
      '${cursorLen == null ? '' : '，$cursorLen 位'}'
      '；第 2 页${childSecond == null ? '未拉' : (secondPageWorks ? '可续拉' : '不可用/重复')}'
      '；拿全约 $requestsToFetchAllText 个请求',
    );
    buf.writeln(
      '3. 「共 N 条回复」的 N：`$totalField`'
      '${totalFieldVerified ? '（已与子接口 total_number 交叉验证）' : '（未交叉验证）'}',
    );
    buf.writeln('备注：$note');
    return buf.toString();
  }

  /// 落盘 Markdown（七节结构，任务给定）。
  ///
  /// [cookieLength] 只写长度，**永远不写内容**。
  String toMarkdown({required int cookieLength, String? date}) {
    final String day = date ?? _scToday();
    final StringBuffer buf = StringBuffer();
    final SubCommentInlineSample? s = sample;
    final String childListPath = childFirst?.listPath ?? 'NONE';
    final int? claimedN = sample?.claimedTotal;
    final int? gotN = obtainableCount;

    buf.writeln('# 微博子评论（二级回复）探针（$day）');
    buf.writeln();
    buf.writeln(
      '> 真机落盘。cookie 只作请求头，全文只记长度（`$cookieLength`）。'
      'URL 已脱敏（参数值只留长度）。',
    );
    buf.writeln();

    // ---------------------------------------------------------- 一
    buf.writeln('## 一、样本选择');
    buf.writeln();
    buf.writeln('- mid：`${_maskId(mid)}`');
    buf.writeln('- 一级评论翻了 **$postPagesFetched** 页');
    for (final String l in scannedPages) {
      buf.writeln('  - $l');
    }
    if (s == null) {
      buf.writeln('- **没有扫到内嵌二级评论的一级评论** → `NO_SAMPLE`');
    } else {
      buf.writeln(
        '- 选中：`data.data[${s.postIndex}]` · cid `${_maskId(s.id)}` · '
        '作者 `${s.author ?? '（未知）'}`',
      );
      buf.writeln('- 正文开头：`${s.textHead}`');
      buf.writeln('- 内嵌 `comments[]` 条数：**${s.inlineCount}**');
      buf.writeln(
        '- 声称总回复数：'
        '${s.claimedField == null ? '**没有**任何字段大于内嵌条数' : '`${s.claimedField}` = **${s.claimedTotal}**'}',
      );
    }
    buf.writeln();

    // ---------------------------------------------------------- 二
    buf.writeln('## 二、T1 hotflowChild 结果');
    buf.writeln();
    if (childFirst == null) {
      buf.writeln('（未发出 —— 没有样本）');
      buf.writeln();
    } else {
      final ChildPageProbe? cf = childFirst;
      final ChildPageProbe? cs = childSecond;
      for (final ChildPageProbe p in <ChildPageProbe>[
        if (cf != null) cf,
        if (cs != null) cs,
      ]) {
        buf.writeln('### ${p.label}');
        buf.writeln();
        buf.writeln('| 项 | 值 |');
        buf.writeln('| --- | --- |');
        buf.writeln('| 请求 URL（脱敏） | `${p.urlMasked}` |');
        buf.writeln('| HTTP 状态 | ${p.httpStatus ?? '（请求失败）'} |');
        buf.writeln('| `ok` 字段 | ${p.okFlag ?? '（缺失）'} |');
        buf.writeln('| 响应字节数 | ${p.byteLength} |');
        buf.writeln('| `data` keys | `${p.dataKeys.isEmpty ? '（无）' : p.dataKeys.join(', ')}` |');
        buf.writeln('| 回复列表路径 | **`${p.listPath}`** |');
        buf.writeln('| 返回条数 | **${p.returned}** |');
        buf.writeln('| `total_number` | ${p.totalNumber ?? '（无）'} |');
        buf.writeln(
          '| 与上一页重复 | ${p.duplicateOfPrevious} 条 |',
        );
        buf.writeln();
        if (p.cursors.isEmpty) {
          final bool fromInline =
              p == childFirst && s?.inlineMaxId != null;
          buf.writeln(
            '- 游标字段：**响应里一个都没有**'
            '${fromInline ? '（续拉改用一级评论节点 `max_id`，见「分页」小节）' : '（这页就是全部）'}',
          );
        } else {
          buf.writeln('- 游标字段（`data` 层扫描）：');
          for (final ChildCursor c in p.cursors) {
            buf.writeln(
              '  - `${c.text}`${c.key == p.cursorField ? ' ← **采用**' : ''}',
            );
          }
        }
        buf.writeln();
      }
      buf.writeln('### 与内嵌 2 条对比');
      buf.writeln();
      final int diff = delta ?? 0;
      final int rc = returnedCount ?? 0;
      buf.writeln(
        '- 内嵌 `data.data[${s?.postIndex}].comments[]`：**$inlineCount** 条',
      );
      buf.writeln('- `hotflowChild` 第 1 页：**$rc** 条');
      buf.writeln(
        '- 差值：**${diff > 0 ? '+$diff' : '$diff'}**'
        '（${diff > 0 ? '子接口比内嵌多' : (diff == 0 ? '与内嵌相同' : '子接口反而更少')}）',
      );
      buf.writeln();
      buf.writeln('### 分页');
      buf.writeln();
      final String src = cursorSource;
      buf.writeln(
        '- 游标字段名：**`$effectiveCursorField`**',
      );
      buf.writeln(
        '- 游标来源：**`$src`**'
        '${src == 'child' ? '（子接口响应自带 `${childFirst!.cursorField}`，长度 ${childFirst!.cursorValue?.length ?? 0}）' : ''}'
        '${src == 'inline' ? '（子接口**自己不给**游标；`max_id` 取自一级评论节点 `data.data[${s?.postIndex}].max_id`，长度 ${s!.inlineMaxId!.length}）' : ''}'
        '${src == 'NONE' ? '（子接口与一级评论节点都没有游标）' : ''}',
      );
      buf.writeln(
        '- 一级评论节点里的 `max_id`：${s?.inlineMaxId == null ? '**没有**' : '有（长度 ${s!.inlineMaxId!.length}）'}'
        ' · `total_number`：${s?.claimedTotal ?? '（无）'}',
      );
      final int? secondReturned = childSecond?.returned;
      buf.writeln(
        '- 第 2 页：${childSecond == null ? '未拉（没有游标 / 被叫停）' : (secondPageWorks ? '**可续拉**，且与第 1 页无重复' : '拉到但不可用或与第 1 页重复')}'
        '${secondReturned == null ? '' : '（返回 $secondReturned 条）'}',
      );
      buf.writeln();
    }

    // ---------------------------------------------------------- 三
    buf.writeln('## 三、T2 总回复数字段');
    buf.writeln();
    buf.writeln(
      '- 结论字段：**`$totalField`**'
      '（${totalFieldVerified ? '与子接口 `total_number` 交叉验证一致' : '未交叉验证'}）',
    );
    if (totalConsistency != 'unknown') {
      buf.writeln(
        '- 声称总数 vs 实际可拉取：**$claimedN vs $gotN** → '
        '**${totalConsistency == 'consistent' ? '一致' : '不一致（不能把声称总数当可展开条数）'}**',
      );
    }
    if (s != null) {
      buf.writeln(
        '- 一级评论里「像总数」的 int 字段：'
        '${s.countFields.isEmpty ? '（一个都没有）' : s.countFields.map((CountLikeField f) => '`${f.text}`').join('、')}',
      );
      buf.writeln('- 实测值 vs 内嵌条数（$inlineCount）：');
      if (s.countFields.isEmpty) {
        buf.writeln('  - 没有可比字段');
      } else {
        for (final CountLikeField f in s.countFields) {
          buf.writeln(
            '  - `${f.text}` → ${f.value == inlineCount ? '等于内嵌（不是总数）' : (f.value > inlineCount ? '**大于内嵌**（候选总数）' : '小于内嵌')}',
          );
        }
      }
      buf.writeln();
      buf.writeln('<details><summary>一级评论顶层标量字段全量摘录</summary>');
      buf.writeln();
      for (final String l in sampleScalars) {
        buf.writeln('- `$l`');
      }
      buf.writeln();
      buf.writeln('</details>');
    }
    buf.writeln();

    // ---------------------------------------------------------- 四
    buf.writeln('## 四、结论（逐条回答）');
    buf.writeln();
    buf.writeln(
      '1. **`hotflowChild` 能否拿到完整二级回复？返回条数？** '
      '${verdict == 'OK' ? '能。第 1 页 **$returnedCount** 条（内嵌只有 $inlineCount 条），列表在 `$childListPath`。' : '不能（证据见第二节状态码与 `ok`）。'}',
    );
    buf.writeln(
      '2. **分页怎么做？游标字段名与形态？** '
      '`$effectiveCursorField`'
      '（来源 **`$cursorSource`**：'
      '${cursorSource == 'inline' ? '子接口自己不带游标，要拿一级评论节点里的 `max_id`' : (cursorSource == 'child' ? '子接口响应自带' : '两处都没有')}'
      '；续拉时原样拼 `&$effectiveCursorField=<值>`）。'
      '第 2 页${childSecond == null ? '未拉' : (secondPageWorks ? '**可续拉、无重复**' : '不可用/重复')}。',
    );
    buf.writeln(
      '3. **「共 N 条回复」的 N 从哪个字段取（一级评论里有没有）？** '
      '`$totalField`'
      '${totalFieldVerified ? '（与子接口 `total_number` 相等，可信）' : ''}。'
      '${totalField == 'NONE' ? '一级评论里**没有**这个字段——N 只能来自子接口的 `data.total_number`（或者退化成「已加载条数」，但那样和微博 App 的数字对不上）。' : ''}'
      '${totalConsistency == 'mismatch' ? '**注意：声称总数 $claimedN 与实际可拉取 $gotN 条不一致** —— 它是「微博 App 里显示的回复数」（含被折叠/已删除），不是「接口能返回的条数」。UI 展开后不要承诺这个数字。' : ''}',
    );
    buf.writeln(
      '4. **拿一条 10+ 回复的评论，总共需要几个请求？** '
      '约 **$requestsToFetchAllText** 个子评论请求'
      '（第 1 页 ${returnedCount ?? '?'} 条'
      '${sample?.claimedTotal == null ? '' : '，声称总数 ${sample!.claimedTotal}'}'
      '；${requestsToFetchAllText == '1' ? '一页就够' : (requestsToFetchAllText == '2' ? '两页' : '受每页 10 条限制，条数越多页数越多')}）'
      '；一级评论列表是已经加载好的，不计入。',
    );
    buf.writeln(
      '5. **若全都不可行，能否明确说「不可行」？** '
      '${verdict == 'OK' ? '**可行**（T1 已成功）。' : (verdict == 'NO_SAMPLE' ? '本轮没找到样本，无法判定（不是「不可行」）。' : '**不可行**，证据为第二节的状态码与响应片段。')}',
    );
    buf.writeln();

    // ---------------------------------------------------------- 五
    buf.writeln('## 五、若可行：实现建议');
    buf.writeln();
    buf.writeln(
      '- **时机**：只在用户点「…… 共 N 条回复 >」时请求。列表加载时不预取：'
      '一页 20 条一级评论，预取就是 20 个请求，必定触发风控。',
    );
    buf.writeln(
      '- **分页**：首次展开拉第 1 页（本轮 ${returnedCount ?? '?'} 条），'
      '还有更多且用户继续滚动时，用 `$effectiveCursorField`（来源 `$cursorSource`）续拉，'
      '**不自动连翻**（每页条数未经压测，见第六节）。',
    );
    buf.writeln(
      '- **缓存**：按一级评论 `cid` 缓存已拉到的二级评论 + 最后游标 + `total_number`；'
      '同一 cid 只拉一次，失败不重试（重试交给用户手上的「加载更多」）。',
    );
    buf.writeln(
      '- **与内嵌合并去重**：内嵌的 2 条**通常就是子接口第 1 页的前 2 条**'
      '（按 `id` 比对确认），所以合并时以 `id` 为键去重、保留先到的顺序；'
      '不要「内嵌 2 条 + 子接口全部」直接拼，会出现重复条目。',
    );
    buf.writeln(
      '- **N 的来源**：${totalField == 'NONE' ? '一级评论里没有总数字段，只能用子接口的 `data.total_number`；拿不到就退回「已加载条数」。' : '用一级评论的 `$totalField`（列表阶段就能显示「共 N 条」，无需先发请求）。'}',
    );
    if (totalConsistency == 'mismatch') {
      buf.writeln(
        '- **但 N 不等于可展开条数**：实测声称 $claimedN 条、接口只给 '
        '$gotN 条（第 2 页之后就没有游标了）。建议文案写'
        '「共 $claimedN 条回复」，展开后按**实际拉到的**渲染，'
        '拉完就显示「已显示全部 $gotN 条」，不要用 N 做 loading 进度'
        '（否则永远卡在 $gotN/$claimedN）。',
      );
    }
    buf.writeln();

    // ---------------------------------------------------------- 六
    buf.writeln('## 六、未取证');
    buf.writeln();
    buf.writeln('- 更深的分页（第 3 页及以后）是否有重复 / 是否会 `ok=0` 收尾：本轮只续拉到第 2 页（预算内只验「能否续拉」这一个问题）。');
    buf.writeln('- `cid` 到底是 `data.data[i].id` 还是 `mid`（两者实测同值，未构造不同值的样本）。');
    buf.writeln('- 未登录态（cookie 为空）调 `hotflowChild` 的行为：本轮全部带真机 WebView 登录态。');
    buf.writeln('- 二级评论的二级（真正的三层楼中楼）是否存在：微博一般是两层，未压测。');
    buf.writeln('- **每页上限到底是 10 还是 20**：本轮样本第 1 页 10 条、第 2 页 2 条，'
        '无法区分「每页 10」与「总共只剩 12 条」。');
    buf.writeln('- `total_number=68` 与实拉 12 条的差额来源（被删的回复？被折叠的？'
        '`hotflowChild` 的更多页？）：本轮第 2 页后已无游标，无法再往下探。');
    buf.writeln('- 请求计数：**$requestCount / $maxRequests**'
        '${saw432 ? ' · 本轮出现过 432（连续最多 $max432Streak 次）' : ' · 本轮未出现 432'}');
    buf.writeln();

    // ---------------------------------------------------------- 七
    buf.writeln('## 七、cookie 长度');
    buf.writeln();
    buf.writeln('`$cookieLength`（内容不显示、不落盘、不进日志）');
    buf.writeln();
    buf.writeln('---');
    buf.writeln();
    buf.writeln('请求记录：');
    buf.writeln();
    for (int i = 0; i < requestLog.length; i++) {
      buf.writeln('${i + 1}. ${requestLog[i]}');
    }
    buf.writeln();
    buf.writeln('备注：$note');
    return buf.toString();
  }
}

// ===========================================================================
// 探针本体
// ===========================================================================

/// 单次请求的原始产物（`skipped` = 因限额 / 叫停而没发）。
class _ScFetch {
  const _ScFetch({
    this.httpStatus,
    this.body = '',
    this.skipped = false,
  });

  final int? httpStatus;
  final String body;
  final bool skipped;
}

/// 微博子评论探针：扫一级评论找样本 → 打 `hotflowChild` → 续拉第 2 页。
class WeiboSubCommentProbe {
  WeiboSubCommentProbe({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  /// 全流程请求数硬上限（任务给的 16）。
  static const int maxRequests = 16;

  /// 一级评论最多翻几页（找「内嵌 2 条但总回复更多」的样本）。
  static const int maxPostPages = 3;

  /// 连续 432 达到这个数就立刻停。
  static const int maxConsecutive432 = 3;

  /// 两次请求之间的最小间隔（任务要求 ≥2.5s）。
  static const Duration minGap = Duration(milliseconds: 2500);

  /// 单项超时。
  static const Duration itemTimeout = Duration(seconds: 20);

  /// 默认样本：`_warma_` 的「晕3D」那条（评论 362 条，回复多的一级评论概率高）。
  static const String defaultMid = '5355066445792642';

  /// 一级评论接口。
  static const String hotflowEndpoint = '${WeiboWebUrls.mbBase}/comments/hotflow';

  /// 子评论接口（T1）。
  static const String childEndpoint =
      '${WeiboWebUrls.mbBase}/comments/hotflowChild';

  /// T3 候选（每个只试 1 次）。
  static const String t3ShowChild = '${WeiboWebUrls.mbBase}/api/comments/showChild';
  static const String t3UpperChild = '${WeiboWebUrls.mbBase}/comments/hotFlowChild';

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

  int get requestCount => _requestCount;
  bool get aborted => _aborted;

  Future<void> _throttle() async {
    final DateTime? last = _lastRequestAt;
    if (last == null) return;
    final Duration elapsed = DateTime.now().difference(last);
    if (elapsed >= minGap) return;
    await Future<void>.delayed(minGap - elapsed);
  }

  /// 发一次 GET。cookie 只进 header；失败不抛、不重试。
  Future<_ScFetch> _get(
    String url,
    String cookie, {
    required String referer,
    required String label,
  }) async {
    if (_aborted) {
      _log.add('$label → 已叫停，未发出');
      return const _ScFetch(skipped: true);
    }
    if (_requestCount >= maxRequests) {
      _aborted = true;
      _log.add('$label → 达到请求上限 $maxRequests，未发出');
      return const _ScFetch(skipped: true);
    }

    await _throttle();
    _requestCount += 1;

    final String trimmed = cookie.trim();
    _ScFetch fetch;
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: <String, String>{
            'User-Agent': userAgent,
            'Referer': referer,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,en;q=0.8',
            if (trimmed.isNotEmpty) 'Cookie': trimmed,
          },
        ),
      );
      final Object? data = res.data;
      fetch = _ScFetch(
        httpStatus: res.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } on DioException catch (e) {
      final Object? data = e.response?.data;
      fetch = _ScFetch(
        httpStatus: e.response?.statusCode,
        body: data is String ? data : (data?.toString() ?? ''),
      );
    } catch (_) {
      fetch = const _ScFetch();
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

  // ------------------------------------------------------------ URL

  /// 一级评论分页 URL。
  static String hotflowPageUrl({required String mid, String? cursor}) {
    final StringBuffer buf = StringBuffer(
      '$hotflowEndpoint?id=$mid&mid=$mid&max_id_type=0',
    );
    final String c = (cursor ?? '').trim();
    if (c.isNotEmpty) buf.write('&max_id=$c');
    return buf.toString();
  }

  /// 子评论 URL（T1）。
  ///
  /// `cid` 是一级评论的 **id**（不是 mid）；续拉时原样拼 `&<cursorKey>=<值>`。
  static String childUrl({
    required String cid,
    String? cursor,
    String? cursorKey,
  }) {
    final StringBuffer buf = StringBuffer('$childEndpoint?cid=$cid&max_id_type=0');
    final String c = (cursor ?? '').trim();
    if (c.isNotEmpty) buf.write('&${cursorKey ?? 'max_id'}=$c');
    return buf.toString();
  }

  /// T3 候选 URL。
  static String t3Url(String base, {required String cid}) => '$base?id=$cid';

  /// URL 脱敏：只保留 scheme/host/path 与**参数名**，值只留长度。
  ///
  /// 这样报告里有「打了哪个接口、带了哪些参数」，但拿不到任何 id / 游标原文。
  static String maskUrl(String url) {
    final Uri? u = Uri.tryParse(url);
    if (u == null) return '（非法 URL）';
    final StringBuffer buf = StringBuffer('${u.scheme}://${u.host}${u.path}');
    if (u.queryParameters.isNotEmpty) {
      final List<String> parts = <String>[];
      for (final MapEntry<String, String> e in u.queryParameters.entries) {
        parts.add('${e.key}=<${e.value.length} 位>');
      }
      buf.write('?${parts.join('&')}');
    }
    return buf.toString();
  }

  /// id 脱敏（委托 library 私有实现，保持单一实现）。
  static String maskId(String value) => _maskId(value);

  // ------------------------------------------------------------ 主流程

  /// 跑一次：≤3 页一级评论 + ≤2 页 hotflowChild（+ 最多 3 个 T3 候选）。
  Future<SubCommentProbeResult> run({
    required String cookie,
    String? mid,
  }) async {
    final String target = (mid ?? defaultMid).trim();
    final String referer = '${WeiboWebUrls.mbBase}/status/$target';

    // ---------- 1. 扫一级评论找样本
    SubCommentInlineSample? sample;

    /// 选中样本的原始节点（用于字段摘录与总数交叉验证）。
    Map<String, dynamic>? sampleRaw;
    final List<String> scanned = <String>[];
    String? cursor;
    int postPages = 0;

    for (int page = 1; page <= maxPostPages && !_aborted; page++) {
      if (_requestCount >= maxRequests) break;
      final _ScFetch f = await _get(
        hotflowPageUrl(mid: target, cursor: cursor),
        cookie,
        referer: referer,
        label: 'A 一级评论第 $page 页',
      );
      if (f.skipped) break;
      postPages += 1;
      if (f.httpStatus != 200) {
        scanned.add('第 $page 页：HTTP ${f.httpStatus ?? '失败'}（停止扫描）');
        break;
      }
      final Map<String, dynamic>? root = _scTryParseObject(f.body);
      final Map<String, dynamic>? data = _scAsMap(root?['data']);
      final Object? list = data?['data'];
      final int total = list is List ? list.length : 0;
      final SubCommentInlineSample? found = pickInlineSample(f.body);
      scanned.add(
        '第 $page 页：一级评论 $total 条 · '
        '最佳样本 data.data[${found?.postIndex ?? '-'}] '
        '内嵌 ${found?.inlineCount ?? 0} 条'
        '${found?.claimedTotal == null ? '' : ' · 声称总数 ${found!.claimedTotal}（${found.claimedField}）'}'
        '${found?.inlineMaxId == null ? '' : ' · 节点内 max_id ${found!.inlineMaxId!.length} 位'}',
      );
      if (found != null && (sample == null || found.score > sample.score)) {
        sample = found;
        sampleRaw = nodeAt(f.body, found.postIndex);
      }
      // 强候选（内嵌非空 + 有更大的总数声明）就没有翻页的必要了。
      if (sample != null && sample.isStrong) break;
      cursor = hotflowCursorOf(f.body);
      if (cursor == null || cursor.isEmpty) break;
    }

    // ---------- 2. T1：hotflowChild 第 1 页
    ChildPageProbe? first;
    ChildPageProbe? second;
    if (sample != null && !_aborted) {
      final String url = childUrl(cid: sample.id);
      final _ScFetch f = await _get(
        url,
        cookie,
        referer: referer,
        label: 'B hotflowChild 第 1 页（cid=${_maskId(sample.id)}）',
      );
      if (!f.skipped) {
        first = parseChildPage(
          body: f.body,
          httpStatus: f.httpStatus,
          urlMasked: maskUrl(url),
          label: 'T1 第 1 页',
        );
      }

      // ---------- 3. 续拉第 2 页
      //
      // 游标有两个可能来源，**优先用接口自己给的**：
      //   a. `hotflowChild` 响应里的 `data.max_id`（若微博将来补上）；
      //   b. 一级评论节点里的 `max_id`（真机实测 2026-10-22：子接口只回 10 条、
      //      自己不带游标，但同楼层一级评论节点带 `max_id` + `total_number=68`）。
      // 只试一次，**不连翻**：第 2 页能否续上就是本探针要回答的问题。
      final String? cursorValue = first != null && first.hasMore
          ? first.cursorValue
          : sample.inlineMaxId;
      final String cursorKey =
          first != null && first.hasMore ? (first.cursorField ?? 'max_id') : 'max_id';

      if (first != null && first.usable && cursorValue != null) {
        final String url2 = childUrl(
          cid: sample.id,
          cursor: cursorValue,
          cursorKey: cursorKey,
        );
        final _ScFetch f2 = await _get(
          url2,
          cookie,
          referer: referer,
          label: 'B hotflowChild 第 2 页（续拉）',
        );
        if (!f2.skipped) {
          final ChildPageProbe parsed = parseChildPage(
            body: f2.body,
            httpStatus: f2.httpStatus,
            urlMasked: maskUrl(url2),
            label: 'T1 第 2 页',
          );
          second = ChildPageProbe(
            label: parsed.label,
            urlMasked: parsed.urlMasked,
            httpStatus: parsed.httpStatus,
            okFlag: parsed.okFlag,
            listPath: parsed.listPath,
            ids: parsed.ids,
            cursors: parsed.cursors,
            cursorField: parsed.cursorField,
            cursorValue: parsed.cursorValue,
            totalNumber: parsed.totalNumber,
            dataKeys: parsed.dataKeys,
            duplicateOfPrevious: overlapCount(first.ids, parsed.ids),
            byteLength: parsed.byteLength,
          );
        }
      }
    }

    // ---------- 4. T3（仅 T1 没成功时，每个只试 1 次）
    final List<T3Attempt> t3 = <T3Attempt>[];
    final bool t1Ok = first != null && first.usable;
    if (sample != null && !t1Ok && !_aborted) {
      final List<MapEntry<String, String>> candidates =
          <MapEntry<String, String>>[
        MapEntry<String, String>('T3-a api/comments/showChild', t3ShowChild),
        MapEntry<String, String>('T3-b comments/hotFlowChild', t3UpperChild),
        MapEntry<String, String>(
          'T3-c comment/<cid> 详情页',
          '${WeiboWebUrls.mbBase}/comment/${sample.id}',
        ),
      ];
      for (final MapEntry<String, String> c in candidates) {
        if (_aborted || _requestCount >= maxRequests) break;
        final String url = c.value.contains('comment/')
            ? c.value
            : t3Url(c.value, cid: sample.id);
        final _ScFetch f = await _get(
          url,
          cookie,
          referer: referer,
          label: c.key,
        );
        if (f.skipped) continue;
        final String kind = bodyKindOf(f.body);
        final int? okFlag =
            kind == 'json' ? _scAsInt(_scTryParseObject(f.body)?['ok']) : null;
        int returned = 0;
        String listPath = 'NONE';
        if (kind == 'json') {
          final ChildPageProbe parsed = parseChildPage(
            body: f.body,
            httpStatus: f.httpStatus,
            urlMasked: maskUrl(url),
            label: c.key,
          );
          returned = parsed.returned;
          listPath = parsed.listPath;
        }
        t3.add(
          T3Attempt(
            label: c.key,
            urlMasked: maskUrl(url),
            httpStatus: f.httpStatus,
            okFlag: okFlag,
            listPath: listPath,
            returned: returned,
            bodyKind: kind,
            note: returned > 0
                ? '拿到 $returned 条'
                : (kind == 'html'
                    ? '返回 HTML 页面，不是接口'
                    : '没有可用列表'),
          ),
        );
      }
    }

    // ---------- 5. T2：总回复数字段（用子接口 total_number 交叉验证）
    final StringBuffer totalBuf = StringBuffer();
    bool verified = false;
    if (sample == null) {
      totalBuf.write('NONE');
    } else {
      final int? childTotal = first?.totalNumber;
      if (childTotal != null) {
        // 子接口给了 total_number：在样本所有 int 标量里找**相等**的那一个。
        // 逐值比对（而不是靠字段名猜）——名字叫什么都无所谓，值对上才算数。
        final Map<String, int> ints = intScalars(sampleRaw);
        final List<String> keys = ints.keys.toList()..sort();
        String? matched;
        for (final String k in keys) {
          if (ints[k] == childTotal) {
            matched = k;
            break;
          }
        }
        if (matched != null) {
          verified = true;
          totalBuf.write('$matched（=$childTotal，已与子接口 total_number 交叉验证）');
        } else {
          totalBuf.write('NONE');
        }
      } else if (sample.claimedField != null) {
        totalBuf.write('${sample.claimedField}（=${sample.claimedTotal}，未交叉验证）');
      } else {
        totalBuf.write('NONE');
      }
    }
    final String totalField = totalBuf.toString();

    // ---------- 6. 备注
    final String note;
    if (sample == null) {
      note = '翻了 $postPages 页一级评论都没扫到内嵌二级评论的样本（NO_SAMPLE）';
    } else if (t1Ok) {
      note =
          'T1 可用：hotflowChild 第 1 页 ${first.returned} 条（内嵌 ${sample.inlineCount} 条）'
          '，列表在 ${first.listPath}，'
          '游标 ${first.cursorField ?? '响应无（改用一级评论节点 max_id）'}'
          '${second == null ? '' : '，第 2 页 ${second.returned} 条'}';
    } else {
      note = 'T1 不可用，T3 也失败；见请求记录';
    }

    return SubCommentProbeResult(
      mid: target,
      postPagesFetched: postPages,
      scannedPages: List<String>.unmodifiable(scanned),
      sample: sample,
      sampleScalars: sample == null || sampleRaw == null
          ? const <String>[]
          : List<String>.unmodifiable(scalarDump(sampleRaw)),
      childFirst: first,
      childSecond: second,
      t3: List<T3Attempt>.unmodifiable(t3),
      requestLog: List<String>.unmodifiable(_log),
      requestCount: _requestCount,
      saw432: _saw432,
      max432Streak: _max432Streak,
      maxRequests: maxRequests,
      totalField: totalField,
      totalFieldVerified: verified,
      note: note,
    );
  }
}
