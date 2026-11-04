import 'package:flutter/material.dart';

import '../../core/net/app_error.dart';
import '../../widgets/error_view.dart';
import 'player_adapter.dart';

/// 微博视频的简易播放页。
///
/// 用 libmpv（[MpvPlayerAdapter]）而不是 ExoPlayer，因为微博直链的封装格式
/// 不可预期。
///
/// ## `referer` 是**必需**参数，不是可选优化
///
/// 真机实测（2026-10-27，`.env/weibo_video_probe.md`）：
/// 同一条 `f.video.weibocdn.com/....mp4` 直链，
/// **不带 Referer → `HTTP 403 · text/html · 238 字节`**；
/// **带 `Referer: https://weibo.com/` → `HTTP 200 · video/mp4 · 2.7MB`**。
///
/// 所以「视频看不了」的根因有两个，缺一不可：解析层没找到直链（封面字段也
/// 找错了位置），以及播放时不带 Referer 必然被 CDN 拒绝。
class SimpleVideoPage extends StatefulWidget {
  const SimpleVideoPage({
    super.key,
    required this.url,
    required this.title,
    this.referer,
  });

  final String url;
  final String title;
  final String? referer;

  @override
  State<SimpleVideoPage> createState() => _SimpleVideoPageState();
}

class _SimpleVideoPageState extends State<SimpleVideoPage> {
  RrhaPlayer? _player;
  AppError? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final player = MpvPlayerAdapter(
        videoUrls: <String>[widget.url],
        headers: widget.referer == null
            ? null
            : <String, String>{'Referer': widget.referer!},
      );
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      _player = player;
      await player.play();
      if (mounted) setState(() => _loading = false);
    } on AppError catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppError(AppErrorKind.unknown, '播放失败：$e', detail: widget.url);
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          ErrorView(error: _error!, onRetry: _init),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              // 不再写「不承诺可播」：那条结论来自「不知道直链要不要 Referer」的
              // 时代。现在直链带 Referer 实测可下（200 + video/mp4），
              // 真正的失败原因只剩两种：签名过期、或该条没有直链。
              '微博视频直链带时效签名，过期后会失效。\n'
              '若一直失败，可回到该条微博的详情页，用「在应用内查看」打开。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.white54, height: 1.5),
            ),
          ),
        ],
      );
    }

    final player = _player;
    if (player == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SizedBox.expand(child: player.buildView(context));
  }
}
