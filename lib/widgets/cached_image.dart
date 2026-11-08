import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/cache/image_cache_store.dart';
import '../core/config/app_config.dart';
import '../core/theme/app_colors.dart';
import '../core/utils/logger.dart';

/// 带**磁盘**缓存的网络图片。
///
/// 与裸 `Image.network` 的区别只有一件事，但正是用户看到的那件事：
/// 裸的 `Image.network` 只走 Flutter 的 [ImageCache]（默认 1000 张 / 100MB），
/// 一条 9 图动态加上前后几条卡片就能把它挤爆，逐出之后**只能重新联网** ——
/// 表现就是「滚走再滚回，封面重新加载、闪一下灰」。
///
/// 这里补上磁盘那一层：
/// - **命中磁盘**（[ImageCacheStore.lookup] 是同步的）→ 直接 `Image.file`，
///   **首帧就是真图**，不闪灰、不联网；
/// - **未命中** → 仍然先用 `Image.network` 立即显示（不为了缓存牺牲首屏），
///   同时在后台下载落盘；下次就是磁盘命中了。
///
/// 磁盘缓存**只有下界没有上界**的过期策略：不设 TTL。
/// 封面/头像这类资源的 URL 本身带内容指纹，内容变了 URL 就变；
/// 真需要清理时走设置页的「清除图片缓存」或 LRU 淘汰。
class CachedImage extends StatefulWidget {
  const CachedImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.borderRadius = 0,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.placeholder,
    this.errorWidget,
    this.cache,
  });

  /// 图片地址（已归一化为 https）。
  final String? url;

  final double width;
  final double height;

  /// 圆角。为 0 时不额外包 `ClipRRect`。
  final double borderRadius;

  final BoxFit fit;

  /// 图片在框内的对齐方式。默认居中。
  ///
  /// 用途：被裁的**超长竖图**要从顶部露（长截图的标题/页头在顶部），
  /// 居中会把最有信息的那一段裁掉。见 `PhotoGrid._single`。
  final AlignmentGeometry alignment;

  /// 解码宽度上限（按显示宽度 ×3 传，避免原图全尺寸解码吃内存）。
  final int? cacheWidth;

  /// 加载中 / 地址为空时显示的占位。为 null 时用内置灰底图标。
  final Widget? placeholder;

  /// 加载失败时显示的占位。为 null 时用内置灰底图标。
  final Widget? errorWidget;

  /// 注入缓存实例（单测用临时目录的实例）。默认从 [ImageCacheScope] 取。
  final ImageCacheStore? cache;

  /// 把「磁盘文件」变成 [ImageProvider] 的工厂。
  ///
  /// 生产代码永远用默认的 [FileImage]。存在的唯一理由是 widget 测试：
  /// 图片解码（无论 `FileImage` 还是 `MemoryImage`）在 `flutter_test` 里
  /// **永远不会完成** —— 测试进程会永久挂起、连超时都触发不了，
  /// 必须手动 kill 进程。所以单测用「探针模式」绕开真实解码，
  /// 只验证「走了磁盘还是走了网络」这条决策逻辑。
  @visibleForTesting
  static ImageProvider Function(File file)? fileProviderFactory;

  /// 只做决策、不建真实 `Image` 的测试探针。
  ///
  /// 收到文本 = 走磁盘（内容是文件路径）；收到 `null` = 走网络。
  /// 为 null 时（生产）完全不生效。
  @visibleForTesting
  static ValueChanged<String?>? decisionProbe;

  @override
  State<CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> {
  /// 命中磁盘时的文件；null 表示需要联网。
  File? _file;

  /// 缓存的入口在 `initState` 里就要用到，而那时不能用
  /// `dependOnInheritedWidgetOfExactType`（会注册依赖，且规范上不推荐）。
  /// 用 `getElementForInheritedWidgetOfExactType` 只读一次、不建立依赖 ——
  /// 缓存实例本身在整个 App 生命周期里不会变，本来也不需要重建依赖。
  late ImageCacheStore? _inheritedCache;

  @override
  void initState() {
    super.initState();
    _inheritedCache = widget.cache ??
        (context
            .getElementForInheritedWidgetOfExactType<ImageCacheScope>()
            ?.widget as ImageCacheScope?)
            ?.cache;
    _resolveFromDisk();
    // 未命中时首帧之后再触发后台下载：不能在 initState 里直接发起，
    // 那会让首帧多等一个微任务，列表快速滚动时会积累 jank。
    if (_file == null && _url.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _downloadInBackground());
    }
  }

  @override
  void didUpdateWidget(CachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _file = null;
      _resolveFromDisk();
      if (_file == null && _url.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _downloadInBackground());
      }
    }
  }

  String get _url => widget.url ?? '';

  ImageCacheStore? get _cache => widget.cache ?? _inheritedCache;

  /// 同步查磁盘。这就是「滚回不闪灰」的全部秘密：不 await、不查文件是否存在。
  ///
  /// ⚠️ **刻意不做 `existsSync()` 二次校验**：索引是权威（`ImageCacheStore`
  /// 在 `ensureReady` 时已经校验过文件存在性、在 `removeFileFor` 里会清掉坏条目），
  /// 而每张图都同步 stat 一次文件会在快速滚动时累积成可观的阻塞。
  /// 文件在两次校验之间被系统清掉的极端情况由 `errorBuilder` 兜住：
  /// 那一次会走错误占位，同时把坏条目删掉，下一帧就是网络图 —— 自愈。
  ///
  /// 另一个理由同样重要：不碰文件系统，这个 widget 才能在单测里用假 store
  /// 完整验证决策逻辑（真实文件 I/O 在 `flutter_test` 里会挂起，见测试文件注释）。
  void _resolveFromDisk() {
    if (_url.isEmpty) return;
    _file = _cache?.lookup(_url);
  }

  Future<void> _downloadInBackground() async {
    if (!mounted) return;
    final cache = _cache;
    if (cache == null) {
      // ⚠️ 这里曾经静默 return：`ImageCacheScope` 没挂上时，所有图片都只能
      // 走网络、永远不落盘，而界面上看不出任何异常（只是「每次都要重新加载」）。
      // 2026-11-08 查「B 站头像不显示」时就是靠这条日志才排除了这条路径。
      Log.w('CachedImage', '没有可用的 ImageCacheStore，跳过磁盘缓存：'
          '${widget.url ?? ''}');
      return;
    }
    final file = await cache.fetchAndStore(_url);
    if (!mounted || file == null) return;
    // 落盘完成 → 换成 Image.file（顺带让这一张图不再依赖网络）。
    setState(() => _file = file);
  }

  @override
  Widget build(BuildContext context) {
    final cache = _cache;
    final content = widget.url == null || _url.isEmpty
        ? _fallback(widget.placeholder)
        : _content(cache);

    // 测试探针：只报告决策结果，不参与真实渲染（见 decisionProbe 的注释）。
    final probe = CachedImage.decisionProbe;
    if (probe != null) {
      probe(_file?.path);
      return _fallback(widget.placeholder);
    }

    if (widget.borderRadius <= 0) return content;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: content,
    );
  }

  Widget _content(ImageCacheStore? cache) {
    final file = _file;
    if (file != null) {
      final factory = CachedImage.fileProviderFactory;
      final provider = factory != null ? factory(file) : FileImage(file);
      return Image(
        // 用 ResizeImage 而不是 `Image.file(cacheWidth:)`：这样「按显示宽度解码」
        // 在有测试注入的 provider 时也照样生效，两条路径的解码行为一致。
        image: _resize(provider),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        alignment: widget.alignment,
        errorBuilder: (context, error, stack) {
          // 磁盘文件坏掉（被截断/不是图片）→ 删掉索引里的这条并退回联网，
          // 而不是把「一张永远显示不出来的图」留在那里。
          if (cache != null) unawaited(cache.removeFileFor(_url));
          return _network();
        },
      );
    }
    return _network();
  }

  ImageProvider _resize(ImageProvider provider) {
    final width = widget.cacheWidth;
    if (width == null || width <= 0) return provider;
    return ResizeImage(provider, width: width);
  }

  Widget _network() {
    return Image.network(
      _url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      cacheWidth: widget.cacheWidth,
      // 图床对 Referer 敏感时返回 403，必须显式带上**对应站点**的那个：
      // - B 站图床（`*.hdslb.com` 等）认 `www.bilibili.com`；
      // - 微博图床（`*.sinaimg.cn`）对 B 站 Referer 直接 403，认 `weibo.com`。
      // 早先这里写死 B 站 Referer，接入微博真实数据后表现为「微博卡片封面
      // 一片灰、正文正常」——只在真机上看得见，单测完全发现不了。
      headers: <String, String>{
        'Referer': _refererFor(_url),
        'User-Agent': AppConfig.browserUserAgent,
      },
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _fallback(widget.placeholder);
      },
      errorBuilder: (context, error, stack) => _fallback(widget.errorWidget),
    );
  }

  /// 按图床域名挑 Referer。
  ///
  /// 默认仍是 B 站：绝大多数图片来自 B 站，且这条默认值已经过真机验证。
  /// 只对**确认认微博 Referer**的域名改用 `weibo.com`，避免波及别的图床。
  static String _refererFor(String url) {
    final String lower = url.toLowerCase();
    const List<String> weiboHosts = <String>[
      'sinaimg.cn',
      'sinaimg.com',
      'weibo.cn',
      'weibo.com',
    ];
    for (final String host in weiboHosts) {
      if (lower.contains(host)) return 'https://weibo.com/';
    }
    return 'https://www.bilibili.com/';
  }

  Widget _fallback(Widget? custom) {
    if (custom != null) return custom;
    return Container(
      width: widget.width,
      height: widget.height,
      color: AppColors.placeholder,
      child: const Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 18,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// 把 [ImageCacheStore] 交给子树里的 [CachedImage]。
///
/// 为什么不直接用 Riverpod 的 Provider：`CachedImage` 是**纯 widget**，
/// 会被放进时间线、详情页、预览页三处互不相干的树里，
/// 用 InheritedWidget 才能让它在 `initState` 里（同步地）拿到缓存实例 ——
/// 这正是「首帧就出真图」的前提。Riverpod 的 `ref.read` 需要 `ConsumerWidget`，
/// 会把这一层耦合带进所有调用方。
class ImageCacheScope extends InheritedWidget {
  const ImageCacheScope({
    super.key,
    required this.cache,
    required super.child,
  });

  final ImageCacheStore cache;

  static ImageCacheStore? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ImageCacheScope>()
      ?.cache;

  @override
  bool updateShouldNotify(ImageCacheScope oldWidget) => cache != oldWidget.cache;
}
