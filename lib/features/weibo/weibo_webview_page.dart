import 'package:flutter/material.dart';

import '../../core/config/diagnostics_config.dart';
import '../../core/net/app_error.dart';
import '../../widgets/error_view.dart';
import '../../widgets/native_webview.dart';
import 'weibo_diagnostics_ui.dart';

/// 内置浏览器页面：用系统 WebView 打开微博 Web 端。
///
/// 为什么需要它：微博的 HTTP 接口在游客态被风控恒定拦截（432），客户端拿不到
/// 数据也绕不过去，所以改走「WebView 打开 `m.weibo.cn`」——用户看到的是微博
/// 自己的网页，登录态与 Cookie 都由系统 WebView 维护，App 不碰。
///
/// 本页只负责「浏览器外壳」：进度条、刷新、错误层、系统返回键回退一页。
///
/// AppBar 里的 `⋮` 菜单是**诊断入口**（接口自检 / 分页测试 / 字段结构 dump /
/// 深度采样 / 评论探针 / 关注列表探针 / 子评论探针），全部面板实现在
/// `weibo_diagnostics_ui.dart`。它们不是正式功能：借用 WebView 里已有的登录
/// cookie 发请求看接口放不放行，只显示结论（状态码 / 卡片数 / cookie 长度），
/// cookie 内容绝不展示、不记录。
///
/// 该入口由编译期常量 [kWeiboDiagnosticsEnabled] 控制：开关为 false 时
/// **连 `PopupMenuButton` 都不渲染**（正式包里用户看不到这些探针）。
class WeiboWebViewPage extends StatefulWidget {
  const WeiboWebViewPage({super.key, required this.url, this.title});

  /// 首次加载的地址（一般由 `WeiboWebUrls.profile/status` 生成）。
  final String url;

  /// AppBar 标题，默认「微博」。
  final String? title;

  @override
  State<WeiboWebViewPage> createState() => _WeiboWebViewPageState();
}

class _WeiboWebViewPageState extends State<WeiboWebViewPage> {
  final NativeWebViewController _controller = NativeWebViewController();

  /// 0..1 的加载进度。
  double _progress = 0;

  /// 页面内是否还有历史可回退（决定系统返回键是「回退一页」还是「退出本页」）。
  bool _canGoBack = false;

  /// 非 null 时覆盖错误层——不允许静默白屏。
  AppError? _error;

  /// 每次「需要真正重新加载」时递增，用作 PlatformView 的 key，
  /// 保证重建后一定重新走一次 `initialUrl` 加载。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    // PlatformView 要等这一帧布局后才会创建，所以首帧之后再查一次后退状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncCanGoBack();
    });
  }

  Future<void> _syncCanGoBack() async {
    final bool canGoBack = await _controller.canGoBack();
    if (!mounted) return;
    if (canGoBack != _canGoBack) {
      setState(() => _canGoBack = canGoBack);
    }
  }

  /// 从 `widget.url` 里取博主 uid（只服务诊断入口）。
  ///
  /// 支持两种形态：`https://m.weibo.cn/u/<uid>` 与
  /// `...?type=uid&value=<uid>`。取不到就返回 null（探针退化成兜底路径）。
  String? _uidFromUrl() {
    final Uri? uri = Uri.tryParse(widget.url);
    if (uri == null) return null;
    final String? q = uri.queryParameters['value'];
    if (q != null && RegExp(r'^\d+$').hasMatch(q)) return q;
    final List<String> segs = uri.pathSegments;
    for (int i = 0; i < segs.length - 1; i++) {
      if (segs[i] == 'u' && RegExp(r'^\d+$').hasMatch(segs[i + 1])) {
        return segs[i + 1];
      }
    }
    return null;
  }

  /// 刷新（同时清掉错误层）。PlatformView 已不存在时改为重建一个。
  Future<void> _reload() async {
    setState(() {
      _error = null;
      _progress = 0;
      if (!_controller.isReady) _generation += 1;
    });
    await _controller.reload();
    await _syncCanGoBack();
  }

  void _onProgress(double value) {
    if (!mounted) return;
    setState(() => _progress = value.clamp(0.0, 1.0));
  }

  void _onPageStarted() {
    if (!mounted) return;
    setState(() {
      _error = null;
      _progress = 0;
    });
  }

  void _onPageFinished() {
    if (!mounted) return;
    setState(() => _progress = 1);
    _syncCanGoBack();
  }

  /// 原生侧在历史栈变化（含 SPA 页内跳转）时主动上报，不必等 `onPageFinished`。
  void _onCanGoBackChanged(bool canGoBack) {
    if (!mounted) return;
    if (canGoBack != _canGoBack) setState(() => _canGoBack = canGoBack);
  }

  void _onError(String code, String description) {
    if (!mounted) return;
    setState(() {
      _progress = 1;
      _error = AppError(
        AppErrorKind.network,
        '页面加载失败，请检查网络后重试',
        detail: 'code=$code $description',
        retryable: true,
      );
    });
  }

  /// `⋮` 菜单分发。只在 [kWeiboDiagnosticsEnabled] 为 true 时才有菜单项，
  /// 但分发本身仍按值匹配：开关关闭时这个函数不会被触达。
  Future<void> _onDiagnosticSelected(String value) async {
    if (value == 'diag') {
      await WeiboDiagnosticsActions.openDiag(context, _controller);
    } else if (value == 'paging') {
      await WeiboDiagnosticsActions.openPaging(context, _controller);
    } else if (value == 'structure') {
      await WeiboDiagnosticsActions.openStructure(context, _controller);
    } else if (value == 'deep') {
      await WeiboDiagnosticsActions.openDeepSample(context, _controller);
    } else if (value == 'comment') {
      await WeiboDiagnosticsActions.openCommentProbe(context, _controller);
    } else if (value == 'following') {
      await WeiboDiagnosticsActions.openFollowingProbe(context, _controller);
    } else if (value == 'commentPics') {
      await WeiboDiagnosticsActions.openCommentPicProbe(context, _controller);
    } else if (value == 'commentMultiPics') {
      await WeiboDiagnosticsActions.openCommentMultiPicProbe(
        context,
        _controller,
      );
    } else if (value == 'subComment') {
      await WeiboDiagnosticsActions.openSubCommentProbe(context, _controller);
    } else if (value == 'videoProbe') {
      // 从当前页面 URL 里取 uid（`.../u/<uid>` 或 `?type=uid&value=<uid>`），
      // 让探针能翻真实博主时间线找视频样本。
      await WeiboDiagnosticsActions.openVideoProbe(
        context,
        _controller,
        uid: _uidFromUrl(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _canGoBack) {
          _controller.goBack();
          _syncCanGoBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title ?? '微博'),
          actions: <Widget>[
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _reload,
            ),
            // 编译期开关：false 时整个 PopupMenuButton 不进组件树，
            // 连 `⋮` 图标都不会出现（正式包默认如此）。
            if (kWeiboDiagnosticsEnabled)
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: _onDiagnosticSelected,
                itemBuilder: (BuildContext context) =>
                    const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'diag',
                        child: Text('接口自检'),
                      ),
                      PopupMenuItem<String>(
                        value: 'paging',
                        child: Text('分页测试'),
                      ),
                      PopupMenuItem<String>(
                        value: 'structure',
                        child: Text('字段结构 dump'),
                      ),
                      PopupMenuItem<String>(
                        value: 'deep',
                        child: Text('深度采样（3 页）'),
                      ),
                      PopupMenuItem<String>(
                        value: 'comment',
                        child: Text('评论探针'),
                      ),
                      PopupMenuItem<String>(
                        value: 'following',
                        child: Text('关注列表探针'),
                      ),
                      PopupMenuItem<String>(
                        value: 'commentPics',
                        child: Text('评论图片探针'),
                      ),
                      PopupMenuItem<String>(
                        value: 'commentMultiPics',
                        child: Text('多图探针'),
                      ),
                      PopupMenuItem<String>(
                        value: 'subComment',
                        child: Text('子评论探针'),
                      ),
                      PopupMenuItem<String>(
                        value: 'videoProbe',
                        child: Text('视频直链探针'),
                      ),
                    ],
              ),
          ],
        ),
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: NativeWebView(
                key: ValueKey<int>(_generation),
                initialUrl: widget.url,
                controller: _controller,
                onProgress: _onProgress,
                onPageStarted: _onPageStarted,
                onPageFinished: _onPageFinished,
                onCanGoBackChanged: _onCanGoBackChanged,
                onError: _onError,
              ),
            ),
            if (_progress < 1)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(value: _progress),
              ),
            if (_error != null)
              Positioned.fill(
                child: ColoredBox(
                  color: theme.colorScheme.surface,
                  child: ErrorView(error: _error!, onRetry: _reload),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
