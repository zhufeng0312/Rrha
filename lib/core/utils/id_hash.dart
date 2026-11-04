import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 内容条目的稳定 id 生成。
///
/// **抽成公共工具的理由**：同一个视频/微博，无论走 RSSHub 的 RSS
/// 还是走平台官方 API 的 JSON 拿到，都必须得到**同一个 id**。
/// 否则「新内容」标记（靠 id 与已读集合比对）会在数据源切换的那一刻
/// 把整条时间线错标成「新」—— 而且只在切换时错一次，最难排查。
class IdHash {
  IdHash._();

  /// SHA1 取前 16 位十六进制。
  ///
  /// 输入取内容自身的稳定标识（RSS 的 guid / 条目链接 / 标题），
  /// 不用时间戳之类会变的东西。
  static String of(String input) =>
      sha1.convert(utf8.encode(input)).toString().substring(0, 16);

  /// 内容条目 id 的完整形态：`{platform}:{hash}`。
  static String itemId(String platformKey, String stableKey) =>
      '$platformKey:${of(stableKey)}';
}
