import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/app_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/logger.dart';
import '../../data/bili/bili_content_parser.dart';
import '../../data/bili/bili_timeline_source.dart';
import '../../data/models/content_item.dart';
import '../../providers.dart';
import '../../widgets/error_view.dart';
import '../comments/comment_section.dart';
import 'bili_dynamic_body.dart';

/// 「按动态链接打开」的结果页：一条 B 站动态的详情 + 评论。
///
/// ## 视觉参照
///
/// 按用户给的参考稿（`桌面/动态内部.html`）重排。参考稿里有**两屏**，
/// 对应两种形态，骨架与字号差异集中写在 [BiliDynamicBody] 的文档里：
///
/// ```
/// ←                                       ↗  ⋮      ← 顶部导航
/// ◯ 48px  作者昵称                                  ← 作者行
///          2026-11-02 18:08
///
/// 正文（纯文字 16px / 带图 15px，行高 1.6）
///
/// [图片区 —— 按微博板块的规则渲染]
///
/// 评论 50    赞和转发 331                          ← 数据栏（粉色评论数）
/// ─────────────────────────────
/// 热门评论                          三 按热度     ← 评论头部
/// ```
///
/// 刻意**不做**的：IP 属地（参考稿明确去掉了）、点赞/投屏等写操作
/// （本 App 没有这些能力，画出来只会点了没反应）。
///
/// ## 正文渲染为什么在校验过 `summary`
///
/// 早先本页把 `item.title` 当标题、`item.summary` 当正文各画一次。
/// 可是 B 站动态经常没有标题，解析层会把 `title` 兜底成「正文首行截 60 字」
/// （`BiliContentParser._fromDynamic` 的 `effectiveTitle`）。于是纯文字动态
/// 在真机上**整段内容出现两次** —— 用户截图报的正是这个。
/// 现在 `title` 只在 [BiliDynamicStyle.hasOwnTitle] 为真时才渲染。
///
/// ## 关键点：opus id **不是**评论 oid
///
/// 用户从浏览器复制来的是 `https://www.bilibili.com/opus/<id>`。这段 id
/// 拿去打评论接口会得到 `-404 啥都木有`（探针
/// `.env/probe_bili_opus_comment_entry.py` 实证：type=11 与 type=17 都失败）。
/// 正确入口在动态详情的 `item.basic.comment_id_str` / `comment_type`。
class OpusDetailPage extends ConsumerStatefulWidget {
  const OpusDetailPage({super.key, required this.opusId});

  /// opus 链接里那段数字（= 动态的 `id_str`）。
  final String opusId;

  @override
  ConsumerState<OpusDetailPage> createState() => _OpusDetailPageState();
}

class _OpusDetailPageState extends ConsumerState<OpusDetailPage> {
  bool _loading = true;
  Object? _error;

  /// 解析后的内容。
  ContentItem? _item;

  /// 评论入口（oid + type）。
  ({String oid, int type})? _entry;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final client = ref.read(biliClientProvider);
      final raw = await client.dynamicDetail(widget.opusId);
      if (!mounted) return;
      if (raw == null) {
        throw StateError('detail 接口没有返回 item');
      }

      final fetchedAt = DateTime.now().toUtc();
      final item = BiliContentParser.fromDynamicDetail(
        raw,
        sub: BiliTimelineSource.followingSubscription,
        fetchedAt: fetchedAt,
      );
      final entry = BiliContentParser.commentEntryOf(raw);

      // 这两条日志是刻意留的：真机上「看不到评论」时，一眼能分辨
      // 到底是「接口没给评论入口」还是「给了但渲染失败」。
      Log.d(
        'OpusDetailPage',
        'opus=${widget.opusId} 解析${item == null ? '失败' : '成功'} '
            '评论入口=${entry == null ? '（无）' : 'oid=${entry.oid} type=${entry.type}'}',
      );

      setState(() {
        _item = item;
        _entry = entry;
        _loading = false;
      });
    } catch (e, st) {
      Log.e('OpusDetailPage', '打开动态失败 opus=${widget.opusId}', e, st);
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;

    return Scaffold(
      backgroundColor: AppColors.card,
      appBar: AppBar(
        backgroundColor: AppColors.card,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        title: const Text('动态详情', style: TextStyle(fontSize: 15)),
        actions: <Widget>[
          IconButton(
            tooltip: '复制链接',
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
            onPressed: item == null ? null : () => _copyLink(item),
          ),
          IconButton(
            tooltip: '重新加载',
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(item),
    );
  }

  Widget _body(ContentItem? item) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ErrorView(
            error: error is AppError
                ? error
                : AppError(AppErrorKind.unknown, '打开动态失败：$error'),
            onRetry: _load,
          ),
        ),
      );
    }
    if (item == null) {
      return const Center(
        child: Text('这条动态没有可展示的内容', style: TextStyle(fontSize: 13)),
      );
    }

    return BiliDynamicBody(
      item: item,
      commentSection: _commentSection(),
    );
  }

  /// 评论区：用 detail 接口给的**真实入口**。
  ///
  /// 没有入口时给一句可读的说明，而不是留白 ——
  /// 「接口没给评论入口」和「加载失败」是两回事，不能让用户去猜。
  Widget _commentSection() {
    final entry = _entry;
    if (entry == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '这条动态的接口没有给出评论入口（comment_id_str 缺失），'
          '暂时看不到评论。',
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
        ),
      );
    }
    return CommentSection(
      oid: entry.oid,
      type: entry.type,
      embedded: true,
    );
  }

  Future<void> _copyLink(ContentItem item) async {
    final link = item.link;
    if (link.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('链接已复制')),
    );
  }
}
