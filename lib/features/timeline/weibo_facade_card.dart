import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/weibo/weibo_backend.dart';

/// 时间线里的「微博占位卡」。
///
/// 出现在什么位置：只有**该微博订阅本轮没有拉到任何内容**时，才作为
/// 「去登录 / 换内置浏览器看」的入口插在列表顶部（判定见 `timeline_page.dart`
/// 的 `facadeSubsFor`）。有真实微博卡片时它不出现 —— 免得一屏内容被一张
/// 「去浏览器看」的卡片压在下面。
///
/// 为什么仍然保留这张卡：微博接口要求登录 cookie，游客态恒 432；未登录时
/// 数据层只会给一条 auth 错误，用户需要一条明确的入口去内置浏览器里登录一次。
/// 这里**不伪造任何微博条目**。
///
/// 视觉与 [ContentCard] 保持一致（同一个白色底、同样的 12 圆角与
/// 12 内边距），左侧用微博品牌色 `0xFFE6162D` 做强调，右下角给出可点提示。
///
/// 底色必须由 [Material] 提供，否则不透明 `Container` 会遮住 [InkWell] 的
/// 水波纹（splash 画在 Material 层，被不透明子节点盖住就完全看不见）。这张卡
/// 唯一的交互就是「点我打开浏览器」，没有反馈等于让用户以为点空了。
///
/// 单独成文件是为了将来能独立做 widget 测试：它不依赖 Riverpod、不加载网络
/// 图片、不读 Prefs，只靠几个入参就能渲染出来。
class WeiboFacadeCard extends StatelessWidget {
  const WeiboFacadeCard({
    super.key,
    required this.displayName,
    required this.uid,
    required this.onOpen,
    this.subtitle,
  });

  /// 博主展示名（订阅别名或「微博 UID」）。
  final String displayName;

  /// 微博 UID，用于生成要打开的地址。
  final String uid;

  /// 点击整张卡时执行（一般是打开内置浏览器）。
  final VoidCallback onOpen;

  /// 副标题：调用方按该源的错误类型传入
  /// （登录类 → `WeiboCopy.facadeSubtitleAuth`，其它 → `WeiboCopy.facadeSubtitleOpen`）。
  /// 默认取 [WeiboCopy.facadeSubtitle]，保持既有调用点的行为不变。
  final String? subtitle;

  /// 微博品牌色。
  static const Color brandColor = Color(0xFFE6162D);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Material(
      // 底色必须由 Material 提供，否则不透明 Container 会遮住 InkWell
      // 的水波纹（splash 画在 Material 层，被不透明子节点盖住就看不见了）。
      color: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: brandColor.withValues(alpha: 0.45)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 品牌色方块代替左边框：Flutter 里「只左边一条线」配圆角需要
                // 一整圈同色边框，做不出来，所以用色块强调来源。
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: brandColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.public_rounded,
                    size: 22,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        WeiboCopy.facadeTitle(displayName),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle ?? WeiboCopy.facadeSubtitle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(
                              Icons.open_in_browser_rounded,
                              size: 14,
                              color: brandColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '打开',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: brandColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
