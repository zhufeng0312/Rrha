/// 微博诊断面板（7 个对话框）——**诊断工具，不是正式功能**。
///
/// 这些面板从 `weibo_webview_page.dart` 里整体搬出来，页面本身只保留「打开哪个
/// 面板」的分发逻辑，由 [WeiboDiagnosticsActions] 提供。
///
/// 是否显示入口由编译期常量 `kWeiboDiagnosticsEnabled`
/// （`lib/core/config/diagnostics_config.dart`，可用
/// `--dart-define=RRHA_WEIBO_DIAG=true` 覆盖）控制：正式包默认不渲染 `⋮` 菜单，
/// 用户看不到这些探针。
///
/// ## 凭据安全（所有面板一致）
///
/// cookie 从 WebView 取出后**只**交给对应的诊断类放进请求头，界面上只显示
/// 它的长度；不打印、不落盘、不进 State 之外的任何地方。唯一会落盘的是关注
/// 列表探针的 Markdown 报告，其内容已经脱敏（URL 参数打码、不含 cookie）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/net/app_error.dart';
// `content_item.dart` 里定义了同名枚举 `Platform`，会与 `dart:io` 的
// `Platform` 撞车（本文件用 `Platform.pathSeparator` 落盘）。这里**隐藏**
// 那个枚举，只取 `ContentItem`；真正需要平台枚举的地方用完整类型标注。
import '../../data/models/content_item.dart' hide Platform;
import '../../data/weibo/weibo_comment_multi_pic_probe.dart';
import '../../data/weibo/weibo_comment_pic_probe.dart';
import '../../data/weibo/weibo_subcomment_probe.dart';
import '../../data/weibo/weibo_video_probe.dart';
import '../../data/weibo/weibo_diagnostics.dart';
import '../../widgets/native_webview.dart';
import '../timeline/content_detail_page.dart';

/// 「分发」入口：微博 WebView 页的 `⋮` 菜单每一项对应这里的一个方法。
///
/// 每个方法都是 `showDialog` + 一个面板，`barrierDismissible: false`：
/// 诊断要跑网络请求，误触外部关掉会让请求结果无处展示。
///
/// **没有重试按钮**是有意的：本项目曾因密集请求被平台冷却，要再测就关掉重开。
class WeiboDiagnosticsActions {
  WeiboDiagnosticsActions._();

  /// 打开「接口自检」：**打开即跑一次**，只发 1 个请求。
  static Future<void> openDiag(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboDiagDialog(controller: controller);
      },
    );
  }

  /// 打开「分页测试」：最多两个请求，验证 `since_id` 游标能不能翻页。
  static Future<void> openPaging(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboPagingDialog(controller: controller);
      },
    );
  }

  /// 打开「字段结构 dump」：只发 1 个请求，做全量分类采样。
  static Future<void> openStructure(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboStructureDialog(controller: controller);
      },
    );
  }

  /// 打开「深度采样」：最多 3 个请求（`since_id` 串 3 页），补转发/视频字段。
  static Future<void> openDeepSample(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboDeepSampleDialog(controller: controller);
      },
    );
  }

  /// 打开「评论探针」：最多 5 个请求（种子 1 + 翻页 ≤3 + 未登录 1）。
  static Future<void> openCommentProbe(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboCommentProbeDialog(controller: controller);
      },
    );
  }

  /// 打开「关注列表探针」：最多 6 个请求；结果另存一份脱敏 Markdown。
  static Future<void> openFollowingProbe(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboFollowingProbeDialog(controller: controller);
      },
    );
  }

  /// 打开「评论图片探针」：翻页找带图评论，命中后 dump 结构并落盘脱敏 Markdown。
  static Future<void> openCommentPicProbe(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboCommentPicProbeDialog(controller: controller);
      },
    );
  }

  /// 打开「多图探针」：跟随 `mix_media_ids` 里的 `t.cn` 短链，看能否拿到全部图。
  ///
  /// **最多 4 个请求**（1 次评论列表 + ≤3 次短链跟随）。
  static Future<void> openCommentMultiPicProbe(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboCommentMultiPicProbeDialog(controller: controller);
      },
    );
  }

  /// 打开「子评论探针」：验证二级回复（楼中楼）能否拿全、N 从哪来。
  ///
  /// **最多 16 个请求**（≤3 页一级评论 + ≤2 页 hotflowChild + ≤3 个 T3 兜底）。
  /// 打开即跑，无重试按钮。
  static Future<void> openSubCommentProbe(
    BuildContext context,
    NativeWebViewController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboSubCommentProbeDialog(controller: controller);
      },
    );
  }

  /// 视频直链探针：**最多 6 个请求**，打开即跑。
  ///
  /// 目的只有一个：把 `page_info.media_info` 的真实字段名钉下来。
  static Future<void> openVideoProbe(
    BuildContext context,
    NativeWebViewController controller, {
    String? uid,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WeiboVideoProbeDialog(controller: controller, uid: uid);
      },
    );
  }
}

/// 诊断对话框：打开即跑一次自检，跑完只展示结论。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboApiDiag.runOnce] 放进
/// 请求头，界面上只显示它的长度；不打印、不落盘、不进 State 之外的任何地方。
class WeiboDiagDialog extends StatefulWidget {
  const WeiboDiagDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboDiagDialog> createState() => _WeiboDiagDialogState();
}

class _WeiboDiagDialogState extends State<WeiboDiagDialog> {
  bool _running = true;

  /// 结果只存判定结论（不含 cookie）。
  WeiboApiDiagResult? _result;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  @override
  void initState() {
    super.initState();
    _runOnce();
  }

  Future<void> _runOnce() async {
    final String cookie = await widget.controller.getCookies();
    final WeiboApiDiagResult result = await WeiboApiDiag().runOnce(
      cookie: cookie,
    );
    if (!mounted) return;
    setState(() {
      _cookieLength = cookie.length;
      _result = result;
      _running = false;
    });
  }

  String get _statusText {
    final int? status = _result!.httpStatus;
    return status == null ? '请求失败' : 'HTTP $status';
  }

  @override
  Widget build(BuildContext context) {
    final WeiboApiDiagResult? result = _result;
    return AlertDialog(
      title: const Text('微博接口自检'),
      content: _running
          ? const SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('方式A（Dio + WebView Cookie）'),
                const SizedBox(height: 8),
                Text('$_statusText · 卡片 ${result!.cardCount} 条'),
                const SizedBox(height: 4),
                Text('判定：${result.note}'),
                const SizedBox(height: 4),
                Text('cookie 长度：$_cookieLength（内容不显示）'),
              ],
            ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「分页测试」对话框：打开即跑一次两页对比，跑完只展示结论。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboApiDiag.runPaging]
/// 放进请求头，界面上只显示它的长度；不打印、不落盘、不进 State 之外的任何地方。
///
/// 没有重试按钮：再测一次就关掉重开——本项目曾因密集请求被平台冷却。
class WeiboPagingDialog extends StatefulWidget {
  const WeiboPagingDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboPagingDialog> createState() => _WeiboPagingDialogState();
}

class _WeiboPagingDialogState extends State<WeiboPagingDialog> {
  bool _running = true;

  /// 结果只存统计结论（不含 cookie）。
  WeiboPagingDiagResult? _result;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final WeiboPagingDiagResult result = await WeiboApiDiag().runPaging(
        cookie: cookie,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _result = result;
        _running = false;
      });
    } catch (e) {
      // 读 cookie 就失败（WebView 还没就绪等）：也要给出能看懂的原因，不卡转圈。
      if (!mounted) return;
      setState(() {
        _error = _describeFailure(e);
        _running = false;
      });
    }
  }

  String _describeFailure(Object e) {
    if (e is AppError) return e.message;
    return '分页测试未能开始（无法读取 WebView 登录态）';
  }

  String _statusText(int status) => status == 0 ? '请求失败' : 'HTTP $status';

  @override
  Widget build(BuildContext context) {
    final WeiboPagingDiagResult? result = _result;
    final String? error = _error;

    final Widget content;
    if (_running) {
      content = const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      content = Text(error);
    } else {
      final WeiboPagingDiagResult r = result!;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '第1页：${_statusText(r.page1Status)} · 卡片 ${r.page1Cards} 条'
            ' · since_id=${r.page1CursorHint}',
          ),
          const SizedBox(height: 4),
          Text(
            '第2页：${_statusText(r.page2Status)} · 卡片 ${r.page2Cards} 条'
            ' · 重复 ${r.duplicateCount} 条 · 新增 ${r.newCount} 条',
          ),
          const SizedBox(height: 4),
          Text('游标推进：${r.cursorAdvanced ? '是' : '否'}'),
          const SizedBox(height: 4),
          Text('判定：${r.note}'),
          const SizedBox(height: 4),
          Text('cookie 长度：$_cookieLength（内容不显示）'),
        ],
      );
    }

    return AlertDialog(
      title: const Text('微博分页测试'),
      content: content,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「字段结构 dump」对话框：打开即跑一次，把 `mblog` 的字段树摊平显示。
///
/// 现在做的是**全量分类采样**：同一份响应里先给全部 mblog 一张摘要表，
/// 再按「配图 / 转发 / 页面卡」三类各挑第一条做完整字段展开。这样即使
/// 第一条是置顶纯文字微博，也不会出现三类富媒体全无样本的情况。
///
/// 结果很长（可达上千行），所以内容区是 [SingleChildScrollView] +
/// [SelectableText]：可滚动、可长按复制（方便取到 .env 里存档）。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboApiDiag.dumpStructure]
/// 放进请求头，界面只显示它的长度；不打印、不落盘、不进 State 之外的任何地方。
///
/// 没有重试按钮：再 dump 一次就关掉重开——本项目曾因密集请求被平台冷却。
class WeiboStructureDialog extends StatefulWidget {
  const WeiboStructureDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboStructureDialog> createState() => _WeiboStructureDialogState();
}

class _WeiboStructureDialogState extends State<WeiboStructureDialog> {
  bool _running = true;

  /// 结果只存结构描述（不含 cookie）。
  WeiboRichStructureDump? _dump;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final WeiboRichStructureDump dump = await WeiboApiDiag().dumpStructure(
        cookie: cookie,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _dump = dump;
        _running = false;
      });
    } catch (e) {
      // 读 cookie 就失败（WebView 还没就绪等）：给出能看懂的原因，不卡转圈。
      if (!mounted) return;
      setState(() {
        _error = e is AppError ? e.message : '结构 dump 未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final WeiboRichStructureDump? dump = _dump;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      // 头部单独放（不进滚动区），下面整块是可滚动、可选择的字段树。
      body = SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  dump!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('mblog 字段结构 dump'),
      content: body,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「深度采样」对话框：自动翻**最多 3 页**，汇总统计并展开转发/视频样本。
///
/// 为什么单独做一个入口：普通「字段结构 dump」只发 1 个请求（11 条），
/// `retweeted_status` 连续两轮零样本、「media_info」一次都没出现，字段名
/// 拿不到就不能写解析器。这里用 `since_id` 串 3 页把样本量抬高。
///
/// 请求纪律：最多 3 个请求、不重试、没有重试按钮；任一页失败或没游标就停。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboApiDiag.runDeepSample]
/// 放进请求头，界面只显示它的长度；不打印、不落盘、不进 State 之外的任何地方。
class WeiboDeepSampleDialog extends StatefulWidget {
  const WeiboDeepSampleDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboDeepSampleDialog> createState() => _WeiboDeepSampleDialogState();
}

class _WeiboDeepSampleDialogState extends State<WeiboDeepSampleDialog> {
  bool _running = true;

  /// 结果只存结构描述（不含 cookie）。
  WeiboDeepSampleDump? _dump;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final WeiboDeepSampleDump dump = await WeiboApiDiag().runDeepSample(
        cookie: cookie,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _dump = dump;
        _running = false;
      });
    } catch (e) {
      // 读 cookie 就失败（WebView 还没就绪等）：给出能看懂的原因，不卡转圈。
      if (!mounted) return;
      setState(() {
        _error =
            e is AppError ? e.message : '深度采样未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final WeiboDeepSampleDump? dump = _dump;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      body = SizedBox(
        width: double.maxFinite,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  dump!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('mblog 深度采样（3 页）'),
      content: body,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「评论探针」对话框：打开即跑，**最多 5 个请求**（种子 1 + 翻页 ≤3 + 未登录 1）。
///
/// 为什么需要它：内容已经能在 App 内看，但**评论列表没有数据源**，而评论接口
/// （`comments/hotflow`）从未验证过——字段名、游标形态、风控边界都是空白。
/// 这个对话框只回答这些结构性问题，**不写任何正式评论数据层**。
///
/// 请求纪律：间隔 ≥2.5 秒、翻页 ≤3 页、连续 3 次 432 立刻停、单项超时 20 秒；
/// 没有重试按钮——再测就关掉重开。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboCommentProbe] 放进
/// 请求头，界面只显示它的长度；不打印、不落盘、不进 State 之外的任何地方。
class WeiboCommentProbeDialog extends StatefulWidget {
  const WeiboCommentProbeDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboCommentProbeDialog> createState() =>
      _WeiboCommentProbeDialogState();
}

class _WeiboCommentProbeDialogState extends State<WeiboCommentProbeDialog> {
  bool _running = true;

  /// 结果只存结构描述（不含 cookie）。
  CommentProbeResult? _result;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final WeiboCommentProbe probe = WeiboCommentProbe();
      final ProbeSeed seed = await probe.fetchSeed(cookie: cookie);
      final String? mid = seed.mid ?? seed.id;
      if (mid == null || mid.isEmpty) {
        if (!mounted) return;
        setState(() {
          _cookieLength = cookie.length;
          _error = '未能从时间线取到可用的微博（${seed.toLine()}）';
          _running = false;
        });
        return;
      }
      final CommentProbeResult result = await probe.run(
        cookie: cookie,
        mid: mid,
        id: seed.id ?? mid,
        seed: seed,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _result = result;
        _running = false;
      });
    } catch (e) {
      // 读 cookie 就失败（WebView 还没就绪等）：给出能看懂的原因，不卡转圈。
      if (!mounted) return;
      setState(() {
        _error =
            e is AppError ? e.message : '评论探针未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final CommentProbeResult? result = _result;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      body = SizedBox(
        width: double.maxFinite,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  result!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('微博评论探针'),
      content: body,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「关注列表探针」对话框：打开即跑，**最多 6 个请求**
/// （P1 第 1/2 页 + 未登录对照 1 + P2 候选/对照 ≤2）。
///
/// 为什么需要它：微博订阅源在「订阅源」页只能显示成「微博 1782488734」
/// （缺陷 N5），因为建源时只有 UID，没有 uid → 昵称/头像 的映射。B 站侧靠
/// 「从关注列表导入」拿到这份映射，微博侧一直缺接口结论。这个对话框只回答
/// 结构性问题（状态码 / ok / 列表路径 / 字段名与类型 / 游标 / 未登录），
/// **不写任何正式功能**。
///
/// 请求纪律：间隔 ≥2.5 秒、翻页 ≤2 页、同一变体 ≤2 次、连续 3 次 432 立刻停、
/// 单项超时 20 秒；没有重试按钮——再测就关掉重开。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboFollowingProbe] 放进
/// 请求头，界面只显示它的长度；不打印、不落盘（落盘的是脱敏后的 Markdown）、
/// 不进 State 之外的任何地方。
class WeiboFollowingProbeDialog extends StatefulWidget {
  const WeiboFollowingProbeDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboFollowingProbeDialog> createState() =>
      _WeiboFollowingProbeDialogState();
}

class _WeiboFollowingProbeDialogState extends State<WeiboFollowingProbeDialog> {
  bool _running = true;

  /// 结果只存结构描述（不含 cookie）。
  FollowingProbeResult? _result;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// Markdown 落盘路径（写失败时保留 null，不影响结论展示）。
  String? _dumpPath;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final FollowingProbeResult result = await WeiboFollowingProbe().run(
        cookie: cookie,
      );
      // 落盘只在有结果时做，且内容已脱敏（无 cookie、URL 参数已打码）。
      final String? path = await _dumpMarkdown(
        result: result,
        cookieLength: cookie.length,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _result = result;
        _dumpPath = path;
        _running = false;
      });
    } catch (e) {
      // 读 cookie 就失败（WebView 还没就绪等）：给出能看懂的原因，不卡转圈。
      if (!mounted) return;
      setState(() {
        _error = e is AppError
            ? e.message
            : '关注列表探针未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  /// 写一份 Markdown 到 App 外部目录（`adb pull` 可直接取走）。
  ///
  /// 只在 debug/profile 诊断用；任何异常都吞掉并返回 null——诊断报告的落盘
  /// 失败不该让屏幕上的结论一起消失。
  Future<String?> _dumpMarkdown({
    required FollowingProbeResult result,
    required int cookieLength,
  }) async {
    try {
      Directory? dir;
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      dir ??= await getApplicationDocumentsDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}weibo_following_probe.md',
      );
      await file.writeAsString(
        result.toMarkdown(cookieLength: cookieLength),
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final FollowingProbeResult? result = _result;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      body = SizedBox(
        width: double.maxFinite,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            if (_dumpPath != null)
              Text(
                '报告：$_dumpPath',
                style: const TextStyle(fontSize: 11),
              ),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  result!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('微博关注列表探针'),
      content: body,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「评论图片探针」对话框：翻页扫到带图评论，dump 字段树并落盘 Markdown。
///
/// 为什么需要它：评论接口通了、字段也摸清了，但历史采样里**所有评论
/// `pic_num` 都是 0**，带图评论的字段结构从未取证，于是评论区一直不显示图片。
/// 这个对话框只回答结构问题（图片挂在哪个字段 / 元素是 List 还是 Map /
/// URL 在哪一层 / 尺寸变体叫什么 / 最多几张 / 二级是否同构），
/// **不写任何正式评论解析器**。
///
/// 请求纪律：间隔 ≥2.5 秒、总请求 ≤12、页数 ≤6、微博数 ≤3、
/// 连续 3 次 432 立刻停、单项超时 20 秒；没有重试按钮——再测就关掉重开。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboCommentPicProbe] 放进
/// 请求头，界面只显示它的长度；不打印、落盘的 Markdown 已脱敏。
class WeiboCommentPicProbeDialog extends StatefulWidget {
  const WeiboCommentPicProbeDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboCommentPicProbeDialog> createState() =>
      _WeiboCommentPicProbeDialogState();
}

class _WeiboCommentPicProbeDialogState extends State<WeiboCommentPicProbeDialog> {
  bool _running = true;

  /// 结果只存结构描述（不含 cookie）。
  CommentPicProbeResult? _result;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// Markdown 落盘路径（写失败时保留 null，不影响结论展示）。
  String? _dumpPath;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final CommentPicProbeResult result = await WeiboCommentPicProbe().run(
        cookie: cookie,
      );
      // 落盘只在有结果时做，且内容已脱敏（无 cookie、id 已打码）。
      final String? path = await _dumpMarkdown(
        result: result,
        cookieLength: cookie.length,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _result = result;
        _dumpPath = path;
        _running = false;
      });
    } catch (e) {
      // 读 cookie 就失败（WebView 还没就绪等）：给出能看懂的原因，不卡转圈。
      if (!mounted) return;
      setState(() {
        _error = e is AppError
            ? e.message
            : '评论图片探针未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  /// 写一份 Markdown 到 App 外部目录（`adb pull` 可直接取走）。
  ///
  /// 任何异常都吞掉并返回 null——诊断报告的落盘失败不该让屏幕上的结论一起消失。
  Future<String?> _dumpMarkdown({
    required CommentPicProbeResult result,
    required int cookieLength,
  }) async {
    try {
      Directory? dir;
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      dir ??= await getApplicationDocumentsDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}weibo_comment_pics_probe.md',
      );
      await file.writeAsString(
        result.toMarkdown(cookieLength: cookieLength),
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final CommentPicProbeResult? result = _result;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      body = SizedBox(
        width: double.maxFinite,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            if (_dumpPath != null)
              Text(
                '报告：$_dumpPath',
                style: const TextStyle(fontSize: 11),
              ),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  result!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('微博评论图片探针'),
      content: body,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「评论多图探针」对话框：跟随 `mix_media_ids` 里的 `t.cn` 短链。
///
/// 为什么需要它：上一轮已证明 `comments/hotflow` 对多图评论**只回 1 张代表图**，
/// 张数只体现在 `pic_num` 与 `mix_media_ids`（N 个 `http://t.cn/…` 短链）上。
/// 短链背后到底是什么——图片直链、网页、还是死链——决定了评论区能不能显示多图。
/// 这个对话框只回答这一件事，**不写任何正式解析器**。
///
/// 请求纪律：间隔 ≥2 秒、总请求 ≤4（1 次评论列表 + ≤3 次短链跟随）、
/// 连续 3 次 432 立刻停、单项超时 20 秒；没有重试按钮——再测就关掉重开。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboCommentMultiPicProbe]
/// 放进请求头，界面只显示它的长度；落盘的 Markdown 已脱敏。
class WeiboCommentMultiPicProbeDialog extends StatefulWidget {
  const WeiboCommentMultiPicProbeDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboCommentMultiPicProbeDialog> createState() =>
      _WeiboCommentMultiPicProbeDialogState();
}

class _WeiboCommentMultiPicProbeDialogState
    extends State<WeiboCommentMultiPicProbeDialog> {
  bool _running = true;

  /// 结果只存结构描述（不含 cookie）。
  CommentMultiPicProbeResult? _result;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// Markdown 落盘路径（写失败时保留 null，不影响结论展示）。
  String? _dumpPath;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final CommentMultiPicProbeResult result =
          await WeiboCommentMultiPicProbe().run(cookie: cookie);
      final String? path = await _dumpMarkdown(
        result: result,
        cookieLength: cookie.length,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _result = result;
        _dumpPath = path;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AppError
            ? e.message
            : '多图探针未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  /// 写一份 Markdown 到 App 外部目录（`adb pull` 可直接取走）。
  Future<String?> _dumpMarkdown({
    required CommentMultiPicProbeResult result,
    required int cookieLength,
  }) async {
    try {
      Directory? dir;
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      dir ??= await getApplicationDocumentsDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}'
        'weibo_comment_multi_pic_probe.md',
      );
      await file.writeAsString(
        result.toMarkdown(cookieLength: cookieLength),
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final CommentMultiPicProbeResult? result = _result;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      body = SizedBox(
        width: double.maxFinite,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            if (_dumpPath != null)
              Text(
                '报告：$_dumpPath',
                style: const TextStyle(fontSize: 11),
              ),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  result!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('微博评论多图探针'),
      content: body,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 「子评论探针」对话框：验证微博楼中楼（二级回复）的完整数据来源。
///
/// 为什么需要它：用户反馈「子评论最多只显示 2 条」。一级评论接口
/// `comments/hotflow` 把楼中楼**内嵌**在 `data.data[i].comments[]` 里，
/// 但实测这个数组**恒为 2 条**，而微博里同一楼层能展开十几条 —— 说明
/// 内嵌的只是前几条，完整回复要靠单独接口。这个对话框只回答三件事：
///
/// 1. `comments/hotflowChild?cid=<一级评论 id>` 能不能拿到完整回复、返回几条；
/// 2. 分页游标字段叫什么、第 2 页能否续拉；
/// 3. UI 上「共 N 条回复」的 N 该从哪个字段取。
///
/// 请求纪律：间隔 ≥2.5 秒、总请求 ≤16、连续 3 次 432 立刻停、单项超时 20 秒；
/// 没有重试按钮——再测就关掉重开。
///
/// 凭据安全：cookie 从 WebView 取出后**只**交给 [WeiboSubCommentProbe]
/// 放进请求头，界面只显示它的长度；落盘的 Markdown 已脱敏。
class WeiboSubCommentProbeDialog extends StatefulWidget {
  const WeiboSubCommentProbeDialog({super.key, required this.controller});

  final NativeWebViewController controller;

  @override
  State<WeiboSubCommentProbeDialog> createState() =>
      _WeiboSubCommentProbeDialogState();
}

class _WeiboSubCommentProbeDialogState
    extends State<WeiboSubCommentProbeDialog> {
  bool _running = true;

  /// 结果只存结构描述（不含 cookie）。
  SubCommentProbeResult? _result;

  /// 只用于展示，不是凭据本身。
  int _cookieLength = 0;

  /// Markdown 落盘路径（写失败时保留 null，不影响结论展示）。
  String? _dumpPath;

  /// 异常文案：只说明失败类型，**绝不拼入任何响应体或 cookie**。
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final SubCommentProbeResult result =
          await WeiboSubCommentProbe().run(cookie: cookie);
      final String? path = await _dumpMarkdown(
        result: result,
        cookieLength: cookie.length,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _result = result;
        _dumpPath = path;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AppError
            ? e.message
            : '子评论探针未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  /// 写一份 Markdown 到 App 外部目录（`adb pull` 可直接取走）。
  Future<String?> _dumpMarkdown({
    required SubCommentProbeResult result,
    required int cookieLength,
  }) async {
    try {
      Directory? dir;
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      dir ??= await getApplicationDocumentsDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}'
        'weibo_subcomment_probe.md',
      );
      await file.writeAsString(
        result.toMarkdown(cookieLength: cookieLength),
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final SubCommentProbeResult? result = _result;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      body = SizedBox(
        width: double.maxFinite,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            if (_dumpPath != null)
              Text(
                '报告：$_dumpPath',
                style: const TextStyle(fontSize: 11),
              ),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  result!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('微博子评论探针'),
      content: body,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 视频直链探针面板：借 WebView 登录 cookie 打真实视频，钉死
/// `page_info.media_info` 的字段名（历史上该分支 0 样本，全靠猜）。
class WeiboVideoProbeDialog extends StatefulWidget {
  const WeiboVideoProbeDialog({
    super.key,
    required this.controller,
    this.uid,
  });

  final NativeWebViewController controller;

  /// 要翻的博主 uid（从打开本页的订阅带过来）。为空则只走兜底路径。
  final String? uid;

  @override
  State<WeiboVideoProbeDialog> createState() => _WeiboVideoProbeDialogState();
}

class _WeiboVideoProbeDialogState extends State<WeiboVideoProbeDialog> {
  bool _running = true;
  WeiboVideoProbeResult? _result;
  int _cookieLength = 0;
  String? _dumpPath;
  String? _error;

  /// 探针命中的那条视频的**真实解析结果**（诊断用：可一键打开详情页做真机验证）。
  ContentItem? _hitItem;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final String cookie = await widget.controller.getCookies();
      final WeiboVideoProbeResult result = await WeiboVideoProbe().run(
        cookie: cookie,
        uid: widget.uid,
        onHitItem: (ContentItem item) => _hitItem = item,
      );
      final String? path = await _dumpMarkdown(
        result: result,
        cookieLength: cookie.length,
      );
      if (!mounted) return;
      setState(() {
        _cookieLength = cookie.length;
        _result = result;
        _dumpPath = path;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AppError
            ? e.message
            : '视频直链探针未能开始（无法读取 WebView 登录态）';
        _running = false;
      });
    }
  }

  /// 写一份 Markdown 到 App 外部目录（`adb pull` 可直接取走）。
  Future<String?> _dumpMarkdown({
    required WeiboVideoProbeResult result,
    required int cookieLength,
  }) async {
    try {
      Directory? dir;
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      dir ??= await getApplicationDocumentsDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}weibo_video_probe.md',
      );
      await file.writeAsString(
        result.toMarkdown(cookieLength: cookieLength),
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final WeiboVideoProbeResult? result = _result;
    final String? error = _error;

    final Widget body;
    if (_running) {
      body = const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (error != null) {
      body = Text(error);
    } else {
      body = SizedBox(
        width: double.maxFinite,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('cookie 长度：$_cookieLength（内容不显示）'),
            if (_dumpPath != null)
              Text('报告：$_dumpPath', style: const TextStyle(fontSize: 11)),
            const Divider(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  result!.toText(),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text('微博视频直链探针'),
      content: body,
      actions: <Widget>[
        // 诊断用：探针命中的那条视频，一键打开**产品自己的详情页**。
        // 这是「探针结论 → 真实界面」的最后一段验证：视频能不能自动播、
        // 评论能不能加载，只有真机点一次才知道。
        if (_hitItem != null)
          TextButton(
            onPressed: () {
              final ContentItem item = _hitItem!;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ContentDetailPage(item: item),
                ),
              );
            },
            child: const Text('打开这条视频详情页'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
