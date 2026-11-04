import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/bili_client.dart';
import 'package:rrha/data/repo/video_repo.dart';

/// playurl 缓存键必须包含 **qn**。
///
/// ## 这条测试来自一次真机事故
///
/// 2026-10-21 在荣耀 Magic8 Pro 上验收「清晰度切换」：
/// 菜单里点了 360P，播放器重建了、位置也对，但「播放信息」里的
/// `qn` 仍然是 **64**，菜单里的勾也还停在 720P —— 看起来就是「点了没反应」。
///
/// 根因不在播放页，而在仓库层：`_playUrlCache` 的键只有 `cid`。
/// 720P 那次请求先把结果存了进去，之后 `playUrl(qn: 360)` 直接命中缓存
/// 原样返回，`_client.playUrl` 根本没被调用，界面拿到的 `quality` 自然是 64。
///
/// 所以这里用假 adapter **数请求次数**来钉死它：切清晰度必须真的发一次请求。
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.handler);

  final (int, Object) Function(RequestOptions options) handler;
  final List<Uri> requests = <Uri>[];

  /// 只数**真正取流**的请求：nav（WBI 密钥）是前置准备，
  /// 把它算进来会让「命中缓存因此少一次请求」这类断言失真。
  Iterable<Uri> get playurlRequests =>
      requests.where((u) => u.path.contains('playurl'));

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final (status, body) = handler(options);
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 一个最小的 playurl 响应：`durl` 形态，`quality` 回显请求里的 qn。
Map<String, Object> _playurlBody(int qn) => <String, Object>{
      'code': 0,
      'message': '0',
      'data': <String, Object>{
        'quality': qn,
        'format': 'mp4',
        'timelength': 60000,
        'accept_quality': <int>[112, 80, 64, 32, 16],
        'support_formats': <Map<String, Object>>[
          <String, Object>{'quality': 112, 'new_description': '1080P 高码率'},
          <String, Object>{'quality': 64, 'new_description': '720P 准高清'},
          <String, Object>{'quality': 16, 'new_description': '360P 流畅'},
        ],
        'durl': <Map<String, Object>>[
          <String, Object>{
            'url': 'https://upos-sz-mirror08.bilivideo.com/v/$qn.m4s',
            'size': 100,
          },
        ],
      },
    };

void main() {
  late _CountingAdapter adapter;
  late VideoRepository repo;

  setUp(() {
    adapter = _CountingAdapter((RequestOptions o) {
      // WBI 签名需要先拿 nav 的 wbi_img（缺失时客户端会抛
      // 「无法从 nav 接口解析 WBI 密钥」，playurl 根本发不出去）。
      if (o.uri.path.contains('/x/web-interface/nav')) {
        return (200, <String, Object>{
          'code': 0,
          'data': <String, Object>{
            'wbi_img': <String, Object>{
              'img_url':
                  'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
              'sub_url':
                  'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
            },
          },
        });
      }
      final qn = int.tryParse(o.uri.queryParameters['qn'] ?? '') ?? 0;
      return (200, _playurlBody(qn));
    });
    final dio = Dio(BaseOptions(validateStatus: (int? s) => s != null && s < 500));
    dio.httpClientAdapter = adapter;
    repo = VideoRepository(client: BiliClient(dio: dio));
  });

  group('playurl 缓存', () {
    test('同一 cid + 同一 qn 命中缓存（只发一次请求）', () async {
      final a = await repo.playUrl(bvid: 'BV1xx', cid: 100, qn: 64);
      final b = await repo.playUrl(bvid: 'BV1xx', cid: 100, qn: 64);

      expect(a.quality, 64);
      expect(b.quality, 64);
      expect(adapter.playurlRequests, hasLength(1), reason: '第二次必须命中缓存');
    });

    test('⚠️ 同一 cid + 不同 qn **不能**命中缓存（真机事故的回归测试）', () async {
      final hd = await repo.playUrl(bvid: 'BV1xx', cid: 200, qn: 64);
      final sd = await repo.playUrl(bvid: 'BV1xx', cid: 200, qn: 16);

      expect(hd.quality, 64);
      expect(
        sd.quality,
        16,
        reason: '缓存键里漏掉 qn 时，这里会拿到 64 —— 就是「点了清晰度没反应」',
      );
      expect(
        adapter.playurlRequests,
        hasLength(2),
        reason: '切清晰度必须真的向服务端再要一次流',
      );
    });

    test('不同 cid 之间互不影响', () async {
      await repo.playUrl(bvid: 'BV1xx', cid: 301, qn: 64);
      await repo.playUrl(bvid: 'BV1xx', cid: 302, qn: 64);
      expect(adapter.playurlRequests, hasLength(2));
    });

    test('clearCaches 之后会重新请求', () async {
      await repo.playUrl(bvid: 'BV1xx', cid: 400, qn: 64);
      expect(adapter.playurlRequests, hasLength(1));

      repo.clearCaches();
      await repo.playUrl(bvid: 'BV1xx', cid: 400, qn: 64);
      expect(adapter.playurlRequests, hasLength(2));
    });

    test('useCache: false 强制重新请求（改 qn 即可绕开，但仍要支持）', () async {
      await repo.playUrl(bvid: 'BV1xx', cid: 500, qn: 64);
      await repo.playUrl(bvid: 'BV1xx', cid: 500, qn: 64, useCache: false);
      expect(adapter.playurlRequests, hasLength(2));
    });

    test('preferDash 结果不进 MP4 缓存（既有契约不被破坏）', () async {
      // 第一次走 DASH（preferDash），第二次正常请求必须重新发，
      // 而不是把 DASH 结果当 MP4 缓存返回。
      await repo.playUrl(bvid: 'BV1xx', cid: 600, qn: 64, preferDash: true);
      expect(adapter.playurlRequests, hasLength(1));

      await repo.playUrl(bvid: 'BV1xx', cid: 600, qn: 64);
      expect(
        adapter.playurlRequests,
        hasLength(2),
        reason: 'DASH 兜底结果不能被当成 MP4 缓存',
      );
    });
  });
}
