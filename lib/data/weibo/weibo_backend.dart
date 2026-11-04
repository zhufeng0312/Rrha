/// 微博后端形态。
/// api = 直连官方接口（当前不可用：游客态恒 432，能穿透的接口要求登录）
/// webView = 内置浏览器打开（当前采用）
enum WeiboBackend { api, webView }

/// 当前采用的微博后端。
const WeiboBackend weiboBackend = WeiboBackend.webView;

/// 微博降级相关的用户可读文案。
///
/// 全部集中在这里的原因：同一件事（「微博为什么没有卡片」）会在两个地方
/// 出现 —— 数据源状态面板的说明、时间线占位卡上的说明。分散写死很容易
/// 改了一处忘另一处，让用户看到自相矛盾的两段话。
class WeiboCopy {
  WeiboCopy._();

  /// 时间线「数据源状态」面板里给微博源用的原因说明。
  ///
  /// 注意：微博源在数据层是「空结果且不报错」，所以这段文案只会出现在
  /// 空结果的解释位置，不会被当成错误横幅的一部分。
  static const String statusPanelReason =
      '微博接口当前要求登录态，App 内改用内置浏览器打开博主主页';

  /// 占位卡上的说明文字。
  ///
  /// ⚠️ 这条是**默认**副标题（「没有可用内容」时的通用引导）。未登录/登录失效
  /// 时换用 [facadeSubtitleAuth]，因为那种情况下「打开主页」并不能解决问题 ——
  /// 用户真正要做的是在内置浏览器里登录一次。
  static const String facadeSubtitle =
      '微博接口当前要求登录态，App 内改用内置浏览器打开该博主主页';

  /// 占位卡副标题：该源报的是**登录类**错误（未登录 / 登录失效）。
  static const String facadeSubtitleAuth =
      '微博未登录：点此打开微博页面登录一次，之后这里会自动出现内容';

  /// 占位卡副标题：该源没有内容、也没有登录问题（只是最近没发 / 没拉到）。
  static const String facadeSubtitleOpen = '点此用内置浏览器打开该博主主页';

  /// 占位卡标题（带博主名）。
  static String facadeTitle(String displayName) => '在浏览器里打开 $displayName';
}
