import 'dart:convert';

import 'package:crypto/crypto.dart';

/// WBI 签名实现。
///
/// B 站的 `playurl` / 评论等接口在缺少有效 `w_rid` + `wts` 时会返回
/// `code: -352`（风控校验失败），所以必须做签名。
///
/// 算法（公开逆向结果）：
/// 1. 取 `nav` 接口返回的 `wbi_img.img_url` / `sub_url`，各取文件名去掉扩展名，
///    拼成 64 字符的 `orig`；
/// 2. 按固定索引表重排 `orig`，取前 32 字符作为 `mixinKey`；
/// 3. 参数按 key 升序，值先剔除 `!'()*` 再 URL 编码，拼成 query；
/// 4. 加上 `wts`（Unix 秒）后 `w_rid = md5(query + mixinKey)`。
///
/// 本类是**纯函数**，没有 IO，因此可以对固定向量做单元测试。
/// 若 B 站调整混淆表，单测会第一时间失败（见 test/bili/wbi_test.dart）。
class WbiSigner {
  WbiSigner._();

  /// 混淆索引表（社区公开版本）。
  ///
  /// 单元测试会校验它确实是 0..63 的一个排列，防止手抄错误。
  static const List<int> mixinKeyEncTab = <int>[
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
  ];

  static final RegExp _filtered = RegExp(r"[!'()*]");

  /// 从 `nav` 响应的图片地址里取 32 字符密钥片段。
  static String? keyFromImageUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final seg = url.split('/').last;
    final dot = seg.indexOf('.');
    final name = dot > 0 ? seg.substring(0, dot) : seg;
    return name.isEmpty ? null : name;
  }

  /// 由 imgKey + subKey 计算 mixinKey（32 字符）。
  ///
  /// 密钥长度异常时抛 [ArgumentError]，由调用方走「强刷密钥」流程，
  /// 绝不静默产出一个错误的签名。
  static String mixinKey(String imgKey, String subKey) {
    final orig = '$imgKey$subKey';
    if (orig.length != 64) {
      throw ArgumentError('WBI 密钥长度异常：期望 64，实际 ${orig.length}');
    }
    final buf = StringBuffer();
    for (final i in mixinKeyEncTab) {
      buf.write(orig[i]);
    }
    return buf.toString().substring(0, 32);
  }

  /// 生成带签名的完整 query string（含 `wts` 与 `w_rid`）。
  ///
  /// [timestampSeconds] 只用于测试固定向量，生产路径应留空。
  static String sign({
    required Map<String, dynamic> params,
    required String imgKey,
    required String subKey,
    int? timestampSeconds,
  }) {
    final mixin = mixinKey(imgKey, subKey);
    final wts = timestampSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final all = <String, dynamic>{...params, 'wts': wts};
    final sortedKeys = all.keys.toList()..sort();

    final parts = <String>[];
    for (final k in sortedKeys) {
      final v = all[k];
      if (v == null) continue;
      final filtered = v.toString().replaceAll(_filtered, '');
      parts.add('${Uri.encodeComponent(k)}=${Uri.encodeComponent(filtered)}');
    }
    final query = parts.join('&');
    final wRid = md5.convert(utf8.encode('$query$mixin')).toString();
    return '$query&w_rid=$wRid';
  }
}

/// WBI 密钥对（带获取时间，用于 12 小时过期判断）。
class WbiKeys {
  const WbiKeys({
    required this.imgKey,
    required this.subKey,
    required this.fetchedAt,
  });

  final String imgKey;
  final String subKey;
  final DateTime fetchedAt;

  bool isExpired(Duration ttl) => DateTime.now().difference(fetchedAt) > ttl;

  /// 从 `nav` 接口的 `data` 里提取。
  static WbiKeys? fromNavData(Object? data) {
    if (data is! Map) return null;
    final wbiImg = data['wbi_img'];
    if (wbiImg is! Map) return null;
    final imgKey = WbiSigner.keyFromImageUrl(wbiImg['img_url']?.toString());
    final subKey = WbiSigner.keyFromImageUrl(wbiImg['sub_url']?.toString());
    if (imgKey == null || subKey == null) return null;
    return WbiKeys(
      imgKey: imgKey,
      subKey: subKey,
      fetchedAt: DateTime.now(),
    );
  }
}
