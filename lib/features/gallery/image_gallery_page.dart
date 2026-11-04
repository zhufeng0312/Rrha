import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/config/app_config.dart';
import '../../providers.dart';
import '../../widgets/cached_image.dart';

/// 全屏图片预览页。
///
/// 需求：点动态里的图片 → 全屏看大图、双指缩放、左右滑动切换同一组图、
/// 保存到相册、关掉回到列表。
///
/// **手势协调是本页最容易做错的地方**（也是「放大后想拖图却翻页」的根因）：
/// [PageView] 与 [InteractiveViewer] 都要吃水平拖动事件。做法是监听
/// [TransformationController] 的缩放值 —— scale > 1.01 时把 PageView 的
/// physics 换成 [NeverScrollableScrollPhysics]（此时水平手势全部交给
/// InteractiveViewer 去拖图），缩回 1x 时恢复可翻页。阈值 1.01 而不是 1.0
/// 是为了躲开捏合回弹时浮点数的 0.9999。
///
/// 为什么 `initialIndex` 不能简单塞给 PageView 的 `initialPage`：
/// 那样必须等 PageController 建好才能跳页；这里用 PageController(initialPage:)
/// 一次性建好，避免「先显示第 1 张再跳」的闪烁。
class ImageGalleryPage extends ConsumerStatefulWidget {
  const ImageGalleryPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.heroTagPrefix,
    this.title,
  });

  /// 同一组图片（已归一化为 https）。
  final List<String> images;

  /// 初始显示第几张（0 起）。越界会被夹到合法范围。
  final int initialIndex;

  /// Hero 动画标签前缀（可选）。同组图必须共用前缀 + 各自的 index。
  final String? heroTagPrefix;

  /// 顶部标题（可选）。
  final String? title;

  /// 缩放判定阈值。
  static const double zoomThreshold = 1.01;

  /// 双击放大的目标倍数。
  static const double doubleTapScale = 2.5;

  @override
  ConsumerState<ImageGalleryPage> createState() => _ImageGalleryPageState();
}

class _ImageGalleryPageState extends ConsumerState<ImageGalleryPage>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late final List<TransformationController> _controllers;
  late final AnimationController _doubleTapAnim;
  late int _index;

  /// 当前页是否处于放大状态（决定 PageView 是否可翻页）。
  bool _zoomed = false;

  /// 正在保存的图片下标（用于按钮转圈）。
  int? _savingIndex;

  int get _count => widget.images.length;

  @override
  void initState() {
    super.initState();
    _index = _count == 0 ? 0 : widget.initialIndex.clamp(0, _count - 1);
    _pageController = PageController(initialPage: _index);
    _controllers = List<TransformationController>.generate(
      _count,
      (_) => TransformationController()..addListener(_onTransformChanged),
    );
    _doubleTapAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.removeListener(_onTransformChanged);
      c.dispose();
    }
    _doubleTapAnim.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    if (!mounted) return;
    final zoomed = _controllerAt(_index).value.getMaxScaleOnAxis() >
        ImageGalleryPage.zoomThreshold;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  TransformationController _controllerAt(int index) =>
      _controllers[index.clamp(0, _count - 1)];

  @override
  Widget build(BuildContext context) {
    // 黑底、白字：图片预览页不该被 App 主题色干扰。
    const bg = Color(0xFF000000);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _topBar(),
            Expanded(
              child: _count == 0
                  ? const Center(
                      child: Text(
                        '没有可预览的图片',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : PageView.builder(
                      controller: _pageController,
                      // 关键：放大后禁止翻页，否则「拖图」会变成「翻页」。
                      physics: _zoomed
                          ? const NeverScrollableScrollPhysics()
                          : const PageScrollPhysics(),
                      itemCount: _count,
                      onPageChanged: (i) => setState(() {
                        _index = i;
                        _zoomed = _controllerAt(i).value.getMaxScaleOnAxis() >
                            ImageGalleryPage.zoomThreshold;
                      }),
                      itemBuilder: (context, i) => _page(i),
                    ),
            ),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              widget.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          // 页码从 1 开始，形如 `5 / 9`。
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              _count == 0 ? '0 / 0' : '${_index + 1} / $_count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(int index) {
    final controller = _controllers[index];

    // 走 [CachedImage]：磁盘上已有这张图时**首帧就是真图**，
    // 翻页/重进不闪灰；没有时仍然先联网显示，同时后台落盘。
    Widget image = CachedImage(
      url: widget.images[index],
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.contain,
      placeholder: const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      ),
      // 加载失败必须给明确的失败占位：白屏或崩溃都会让用户以为 App 挂了。
      errorWidget: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image_outlined, size: 40, color: Colors.white30),
            SizedBox(height: 10),
            Text(
              '这张图片加载失败',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
    );

    final prefix = widget.heroTagPrefix;
    if (prefix != null) {
      image = Hero(tag: '$prefix$index', child: image);
    }

    // 双击手势必须挂在 InteractiveViewer **外面**：InteractiveViewer 自己
    // 不暴露 onDoubleTap（它只处理缩放/平移），挂里面收不到事件。
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onDoubleTapDown: (details) => _handleDoubleTap(controller, details),
      child: InteractiveViewer(
        transformationController: controller,
        minScale: 1.0,
        maxScale: 5.0,
        child: image,
      ),
    );
  }

  /// 双击：1x ↔ [ImageGalleryPage.doubleTapScale]，以点中的位置为中心。
  void _handleDoubleTap(TransformationController controller, TapDownDetails d) {
    final current = controller.value.getMaxScaleOnAxis();
    final focal = d.localPosition;

    final Matrix4 end;
    if (current > ImageGalleryPage.zoomThreshold) {
      end = Matrix4.identity();
    } else {
      const s = ImageGalleryPage.doubleTapScale;
      // 平移量要按 **缩放后的** 坐标算：v' = M·v，其中
      // M = T(-p·(s-1)) · S(s)，于是 p 这一点在变换后仍落在 p（以 p 为中心放大）。
      end = Matrix4.identity()
        ..translateByDouble(-focal.dx * (s - 1), -focal.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }

    final animation = Matrix4Tween(begin: controller.value, end: end).animate(
      CurvedAnimation(parent: _doubleTapAnim, curve: Curves.easeOutCubic),
    );
    void apply() => controller.value = animation.value;
    animation.addListener(apply);
    _doubleTapAnim.forward(from: 0).whenCompleteOrCancel(
      () => animation.removeListener(apply),
    );
  }

  Widget _bottomBar() {
    final saving = _savingIndex;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (saving != null)
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              ),
            ),
          FilledButton.icon(
            onPressed: saving == null && _count > 0 ? _saveCurrent : null,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('保存到相册'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 保存到相册

  /// 下载 → 落到临时目录 → `Gal.putImage`。
  ///
  /// 刻意**不用** `Gal.putImageBytes`：9 图动态的大图单张就能到几 MB，
  /// 整块读进内存再往方法通道里塞，低端机上很容易 OOM 或超时。
  /// 走文件路径则内存占用是常数级。
  Future<void> _saveCurrent() async {
    final index = _index;
    if (index < 0 || index >= _count) return;
    setState(() => _savingIndex = index);

    final messenger = ScaffoldMessenger.of(context);
    final imageCache = ref.read(imageCacheStoreProvider);
    final url = widget.images[index];
    String? tempPath;
    try {
      // 1) 权限：Android 10+ 走 MediaStore 不需要任何权限；
      //    旧版本先问一次（被拒时给出可读原因，绝不假装成功）。
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          throw const _SaveFailure('相册权限被拒绝，请在系统设置里允许本应用访问相册');
        }
      }

      // 2) 先看磁盘缓存里有没有**够大**的同一张图，有就直接用，别重复下载。
      //
      // 为什么要卡尺寸：网格缩略图的 cacheWidth 只有 360px 左右，
      // 用那张去保存等于给用户存了一张缩略图。宁可重下一次原图。
      File? source;
      final cached = imageCache.lookup(url);
      if (cached != null && await cached.exists()) {
        final decoded = await decodeImageFromList(await cached.readAsBytes());
        if (decoded.width >= _minSavableWidth) source = cached;
      }

      if (source == null) {
        // 必须带 Referer，否则 B 站图床会 403。
        final ext = _extensionOf(url);
        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}/rrha_${DateTime.now().millisecondsSinceEpoch}$ext',
        );
        tempPath = file.path;

        final dio = ref.read(biliDioProvider);
        final resp = await dio.download(
          url,
          file.path,
          options: Options(
            responseType: ResponseType.bytes,
            headers: const <String, String>{
              'Referer': 'https://www.bilibili.com/',
              'User-Agent': AppConfig.browserUserAgent,
            },
          ),
        );
        final status = resp.statusCode ?? 0;
        if (status < 200 || status >= 300) {
          throw _SaveFailure('图片下载失败（HTTP $status）');
        }
        final length = await file.length();
        if (length <= 0) {
          throw const _SaveFailure('图片下载失败（服务端返回空内容）');
        }
        // 顺手落进图片缓存：用户刚存过的图，回到列表不会再走网络。
        unawaited(imageCache.put(url, await file.readAsBytes()));
        source = file;
      }

      // 3) 写入系统相册。失败原因必须原样区分出来。
      await Gal.putImage(source.path, album: _album);
      _toast(messenger, '已保存到相册（相册 → $_album）');
    } on _SaveFailure catch (e) {
      _toast(messenger, e.message);
    } on GalException catch (e) {
      _toast(messenger, _describeGalError(e));
    } on DioException catch (e) {
      _toast(messenger, '图片下载失败：${_describeDioError(e)}');
    } on FileSystemException catch (e) {
      _toast(messenger, '写入临时文件失败：${e.message}');
    } catch (e) {
      _toast(messenger, '保存失败：$e');
    } finally {
      // 临时文件用完即删，别在用户手机上攒垃圾（缓存里的那份不删）。
      final p = tempPath;
      if (p != null) {
        unawaited(File(p).delete().catchError((_) => File(p)));
      }
      if (mounted) setState(() => _savingIndex = null);
    }
  }

  static const String _album = 'Rrha';

  /// 读磁盘缓存去保存时，图片宽度低于这个值就认为「只是缩略图」，
  /// 宁可重下一次原图也不给用户存低清版本。
  static const int _minSavableWidth = 640;

  void _toast(ScaffoldMessengerState messenger, String text) {
    messenger.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  /// 从 URL 猜一个扩展名。`Gal.putImage` 要求路径**带扩展名**，
  /// 而 B 站图床给的是 `.../xxx.jpg` 或 `.../xxx.webp@1100w_1100h`。
  static String _extensionOf(String url) {
    final withoutQuery = url.split('?').first.split('@').first;
    final dot = withoutQuery.lastIndexOf('.');
    if (dot < 0) return '.jpg';
    final ext = withoutQuery.substring(dot).toLowerCase();
    if (ext.length > 6) return '.jpg';
    const known = <String>['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];
    return known.contains(ext) ? ext : '.jpg';
  }

  static String _describeGalError(GalException e) => switch (e.type) {
        GalExceptionType.accessDenied => '相册权限被拒绝，请在系统设置里允许本应用访问相册',
        GalExceptionType.notEnoughSpace => '设备存储空间不足，无法保存',
        GalExceptionType.notSupportedFormat => '系统相册不支持这种图片格式',
        GalExceptionType.unexpected =>
          '系统相册写入失败：${e.platformException.message ?? e.type.message}',
      };

  static String _describeDioError(DioException e) => switch (e.type) {
        DioExceptionType.connectionTimeout => '连接超时',
        DioExceptionType.receiveTimeout => '接收超时',
        DioExceptionType.sendTimeout => '发送超时',
        DioExceptionType.connectionError => '网络不可用',
        DioExceptionType.badResponse => 'HTTP ${e.response?.statusCode}',
        DioExceptionType.cancel => '请求已取消',
        _ => e.message ?? '未知网络错误',
      };
}

class _SaveFailure implements Exception {
  const _SaveFailure(this.message);
  final String message;
}
