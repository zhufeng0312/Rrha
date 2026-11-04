import '../../core/config/app_config.dart';
import '../bili/bili_client.dart';
import '../bili/bili_models.dart';
import '../models/danmaku_item.dart';

/// 视频数据仓库。
///
/// 比 [BiliClient] 多的只有一层「页面级缓存」：
/// 播放页里弹幕、清晰度切换、回到前台都可能重复请求，缓存能省下
/// 对 B 站接口的重复调用（也更不容易触发风控）。
class VideoRepository {
  VideoRepository({required BiliClient client}) : _client = client;

  final BiliClient _client;

  final Map<int, List<DanmakuItem>> _danmakuCache = <int, List<DanmakuItem>>{};

  /// playurl 缓存：键是 **cid@qn**。
  ///
  /// ⚠️ 早先的键只有 cid。真机上「切清晰度」就是这么坏掉的：720P 播过之后
  /// 用户点 360P，`playUrl(qn: 360)` 直接命中那份 720P 缓存并原样返回，
  /// 于是重建播放器用的还是 720P 的流、菜单里的勾也停在 720P ——
  /// 症状是「点了清晰度没反应」。清晰度是请求参数的一部分，必须进键。
  final Map<String, PlayUrlResult> _playUrlCache = <String, PlayUrlResult>{};

  static String _playUrlKey(int cid, int qn) => '$cid@$qn';

  BiliClient get client => _client;

  Future<BiliVideoInfo> videoInfo({String? bvid, int? aid}) =>
      _client.videoInfo(bvid: bvid, aid: aid);

  Future<PlayUrlResult> playUrl({
    required String bvid,
    required int cid,
    int qn = AppConfig.preferredQuality,
    bool useCache = true,
    bool preferDash = false,
  }) async {
    // DASH 兜底结果不进 MP4 缓存：两者是不同形态，混用会让下次正常播放
    // 直接拿到「为兜底而取的 DASH」，反而多走通道 B。
    final key = _playUrlKey(cid, qn);
    if (useCache && !preferDash) {
      final cached = _playUrlCache[key];
      if (cached != null) return cached;
    }
    final result = await _client.playUrl(
      bvid: bvid,
      cid: cid,
      qn: qn,
      preferDash: preferDash,
    );
    if (!preferDash) _playUrlCache[key] = result;
    return result;
  }

  /// 弹幕按 cid 缓存：同一分 P 反复进播放页不重复拉取。
  Future<List<DanmakuItem>> danmaku(int cid, {bool useCache = true}) async {
    if (useCache) {
      final cached = _danmakuCache[cid];
      if (cached != null) return cached;
    }
    final items = await _client.danmaku(cid: cid);
    _danmakuCache[cid] = items;
    return items;
  }

  void clearCaches() {
    _danmakuCache.clear();
    _playUrlCache.clear();
  }

  /// 已缓存的弹幕条数（设置页诊断用）。
  int get cachedDanmakuCount =>
      _danmakuCache.values.fold<int>(0, (sum, list) => sum + list.length);
}
