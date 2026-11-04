import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/data/bili/bili_client.dart';

/// 用假的 Dio adapter 精确控制弹幕两条通道的响应，
/// 以便把「接口成功但确实没有弹幕」和「接口失败」两种情况分开验证。
///
/// 背景（2026-10-14 实机）：视频没有弹幕时，`/x/v1/dm/list.so` 与
/// `comment.bilibili.com/{cid}.xml` 都会返回 HTTP 200 + 141 字节的
/// 空 XML 骨架。旧实现把「解析出 0 条」也当成失败，最终抛出
/// 「弹幕加载失败」，在播放页显示成红色报错 + 重试按钮 —— 而实际上
/// 一切正常。这些用例锁定修复后的契约。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  /// 返回 (statusCode, bodyBytes)。抛异常表示连接层失败。
  final (int, List<int>) Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, bytes) = handler(options);
    return ResponseBody.fromBytes(
      bytes,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 空弹幕稿件的真实响应：HTTP 200 + 141B 合法 XML，`<d>` 条数为 0。
final Uint8List _emptyXml = Uint8List.fromList(
  '<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com'
          '</chatserver><chatid>34866269840</chatid><mission>0</mission>'
          '<maxlimit>3000</maxlimit><state>0</state><real_name>0</real_name>'
          '<source>k-v</source></i>'
      .codeUnits,
);

/// 一条正常弹幕的 XML（zlib 压缩，覆盖解压路径）。
Uint8List _zlibXml(String xml) {
  final enc = ZLibEncoder().encode(utf8.encode(xml));
  return Uint8List.fromList(enc);
}

BiliClient _client(
  (int, List<int>) Function(RequestOptions options) handler,
) {
  final dio = Dio(BaseOptions(
    // 与生产实现保持一致：4xx 不抛异常，交给调用方显式映射。
    validateStatus: (int? s) => s != null && s < 500,
  ));
  dio.httpClientAdapter = _FakeAdapter(handler);
  return BiliClient(dio: dio);
}

void main() {
  group('弹幕：空结果不是错误', () {
    test('两个通道都返回合法空 XML 时，返回空列表而不抛错', () async {
      final client = _client((RequestOptions o) => (200, _emptyXml));

      final items = await client.danmaku(cid: 34866269840);

      expect(items, isEmpty, reason: '0 条弹幕是完全正常的结果，不该报错');
    });

    test('空 XML 经压缩后同样返回空列表', () async {
      final client = _client(
        (RequestOptions o) => (200, _zlibXml(
              '<?xml version="1.0" encoding="UTF-8"?><i><chatid>1</chatid></i>',
            )),
      );

      expect(await client.danmaku(cid: 1), isEmpty);
    });

    test('通道 1 失败、通道 2 返回空 XML：仍返回空列表（不误报故障）', () async {
      final client = _client((RequestOptions o) {
        // list.so 返回 500，comment.bilibili.com 返回空 XML
        if (o.uri.path.contains('list.so')) return (500, <int>[]);
        return (200, _emptyXml);
      });

      expect(await client.danmaku(cid: 1), isEmpty);
    });

    test('有弹幕时正常解析（回归保护）', () async {
      final xml = '<?xml version="1.0" encoding="UTF-8"?><i>'
          '<d p="4.39000,1,25,16777215,1700000000,0,abcd,123,10">前方高能</d>'
          '</i>';
      final client = _client((RequestOptions o) => (200, _zlibXml(xml)));

      final items = await client.danmaku(cid: 1);

      expect(items.length, 1);
      expect(items.single.text, '前方高能');
      expect(items.single.progressMs, closeTo(4390, 1));
    });

    test('两个通道都真的失败时，才抛「弹幕加载失败」', () async {
      final client = _client((RequestOptions o) {
        throw DioException.connectionError(
          requestOptions: o,
          reason: 'network down',
        );
      });

      await expectLater(
        client.danmaku(cid: 1),
        throwsA(
          isA<AppError>().having(
            (AppError e) => e.kind,
            'kind',
            AppErrorKind.empty,
          ),
        ),
      );
    });

    test('两个通道都返回空响应体时，也视为故障', () async {
      final client = _client((RequestOptions o) => (200, <int>[]));

      await expectLater(
        client.danmaku(cid: 1),
        throwsA(isA<AppError>()),
      );
    });
  });
}
