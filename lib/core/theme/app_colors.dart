import 'package:flutter/material.dart';

/// 全局配色（对标 B 站动态页的亮色规范，见 `docs/UI_HANDOFF.md` §1.1）。
///
/// 为什么要把这些值集中在一处：
/// - 亮色化是**一次性全局改动**，散落的 `const Color(0xFFxxxxxx)` 已经证明
///   会漏（深色下看不出问题，转亮后就是「白底白字」）；
/// - 卡片、媒体区、时间线外壳三处都要用同一组灰阶，各自写死迟早不一致。
///
/// 刻意**不**放进 `Theme.of(context).colorScheme`：本项目的卡片样式一律自绘
/// （`CardTheme` 在不同 Flutter 版本间类型不兼容，见 `main.dart` 的注释），
/// 组件直接读这里的常量即可，不需要 BuildContext。
class AppColors {
  AppColors._();

  /// 页面底色（原型 `.mobile-container` 的 `#F4F5F7`）。
  static const Color page = Color(0xFFF4F5F7);

  /// 卡片底色。
  static const Color card = Colors.white;

  /// 卡片内「嵌套区块」的底色（转发动态里的原动态块，原型 `#F6F7F8`）。
  ///
  /// 比 [card] 暗一档、比 [page] 亮一档：**三个灰阶必须能区分开**。
  /// 早先原动态块直接复用 [page]，在白色卡片里彻底看不出来是个独立区域。
  static const Color nested = Color(0xFFF6F7F8);

  /// 主标题 / 正文。
  static const Color textPrimary = Color(0xFF18191C);

  /// 次要信息（时间、操作栏、占位图标）。
  static const Color textSecondary = Color(0xFF9499A0);

  /// 链接色（「全文」）。
  static const Color link = Color(0xFF00AEEC);

  /// 分割线。
  static const Color divider = Color(0xFFE3E5E7);

  /// 头像 / 图片占位底色（原型 `.avatar` 的背景色）。
  static const Color placeholder = Color(0xFFE3E5E7);

  /// 微博昵称色（原型 `#FB7299`）。
  static const Color weiboName = Color(0xFFFB7299);

  /// B 站昵称色（与正文同色）。
  static const Color biliName = textPrimary;

  /// 微博「@某人」提及色（原型 `.text-weibo` 的 `#507DAF`）。
  ///
  /// 与 [weiboName]（`#FB7299` 粉）**是两个色**：粉色是「正文作者昵称」，
  /// 这个偏蓝的灰蓝是「被提及的人 / 被转发的原作者」。混用会让转发卡片里
  /// 转发者与原博主看起来是同一层级。
  static const Color weiboMention = Color(0xFF507DAF);

  /// B 站蓝（seed / 品牌强调）。
  static const Color biliBlue = Color(0xFF00A1D6);

  /// 微博红（品牌强调）。
  static const Color weiboRed = Color(0xFFE6162D);

  /// 「新内容」标记色。
  static const Color newBadge = Color(0xFFFF6699);

  /// 警告块底色（微博「视频解析失败」那种浅橙底）。
  ///
  /// 深色时代这里是 `0xFF2A1F1F`（深棕）。亮色下必须换成浅橙，
  /// 否则深棕块在白色页面里像个窟窿。
  static const Color warningTint = Color(0xFFFFF4EC);

  /// 警告色（与 [warningTint] 配套的正文/图标色）。
  static const Color warning = Color(0xFFD97706);

  /// 成功 / 在线的绿（亮色下用深一档，`greenAccent` 在白底上几乎看不见）。
  static const Color success = Color(0xFF16A34A);
}
