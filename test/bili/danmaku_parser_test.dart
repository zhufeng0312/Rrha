import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/danmaku_parser.dart';
import 'package:rrha/data/models/danmaku_item.dart';

// ---------------------------------------------------------------- protobuf 构造

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  while (true) {
    if (v < 0x80) {
      out.add(v);
      return out;
    }
    out.add((v & 0x7F) | 0x80);
    v >>= 7;
  }
}

/// 按 DanmakuElem 的真实字段号构造一条弹幕：
/// 2=progress, 3=mode, 4=fontsize, 5=color, 7=content
List<int> _elem({
  required int progress,
  required int mode,
  required int fontSize,
  required int color,
  required String text,
}) {
  final textBytes = utf8.encode(text);
  return <int>[
    ..._varint(2 << 3), ..._varint(progress),
    ..._varint(3 << 3), ..._varint(mode),
    ..._varint(4 << 3), ..._varint(fontSize),
    ..._varint(5 << 3), ..._varint(color),
    ..._varint((7 << 3) | 2), ..._varint(textBytes.length), ...textBytes,
  ];
}

/// 构造 DmSegMobileReply（repeated DanmakuElem elems = 1）。
Uint8List _reply(List<List<int>> elems) {
  final out = <int>[];
  for (final e in elems) {
    out.addAll(_varint((1 << 3) | 2));
    out.addAll(_varint(e.length));
    out.addAll(e);
  }
  return Uint8List.fromList(out);
}

/// 真实形态（2026-10 实测自 comment.bilibili.com/{cid}.xml）：
/// p = `出现秒数(浮点),模式,字号,颜色,时间戳,池,用户hash,弹幕id,权重`
const String _xmlSample = '''
<i>
  <chatserver>chat.bilibili.com</chatserver>
  <chatid>42625207701</chatid>
  <maxlimit>500</maxlimit>
  <d p="1.00000,1,25,16777215,1700000000,0,abcd1234,2219118517716981760,10">第一条弹幕</d>
  <d p="2.50000,5,25,16711680,1700000001,0,abcd1235,2219118517716981761,10">顶部弹幕</d>
  <d p="3.00000,4,18,255,1700000002,0,abcd1236,2219118517716981762,10">底部弹幕</d>
</i>
''';

/// 裸 deflate（无 zlib 头）压缩的同一段 XML。
///
/// 由 Python 的 `zlib.compressobj(9, zlib.DEFLATED, -15)` 生成，与 B 站
/// `Content-Encoding: deflate` 却发裸 deflate 流的真实行为一致。
/// 首字节是 0x6d 而不是 0x78 —— 这正是老实现会静默失败的地方。
const String _rawDeflateFixture =
    'bc4xDoJAFATQqxjqH9j5sPuXBPcuKg2dRzDxDJQWdBbURozHcTXcQtxsghqmmmZepmpcVa/26wSp+oRArAlGRBhTERVDijbbXQ3OC2JGCVgNEZjSQsy0U4l79f3jenieOn8f/NBWWR1xTnUwdMQBY9WMY8b1Ao6Aj91lPJ7/5TzeLgh2wr8e84yaBZQD6m/tL5o17g0=';

void main() {
  group('XML 通道', () {
    test('解析 p 属性与文本', () {
      final items = DanmakuParser.parseXml(_xmlSample);
      expect(items.length, 3);

      expect(items[0].progressMs, 1000);
      expect(items[0].mode, DanmakuMode.scroll);
      expect(items[0].fontSize, 25);
      expect(items[0].color, 16777215);
      expect(items[0].text, '第一条弹幕');

      expect(items[1].mode, DanmakuMode.top);
      expect(items[2].mode, DanmakuMode.bottom);
      expect(items[2].fontSize, 18);
    });

    test('损坏的 XML 不抛异常，只返回空列表', () {
      expect(DanmakuParser.parseXml('<i><d p="bad'), isEmpty);
      expect(DanmakuParser.parseXml(''), isEmpty);
    });

    test('p 字段不足的条目被跳过', () {
      final items = DanmakuParser.parseXml(
        '<i><d p="1,2">缺字段</d><d p="100,1,25,16777215,0,0,x,0,0">正常</d></i>',
      );
      expect(items.length, 1);
      expect(items.single.text, '正常');
    });

    test('时间字段是浮点秒（真实抓包形态），不是整数毫秒', () {
      // 这是联网实测抓出来的坑：int.tryParse("4.39000") 返回 null，
      // 结果是每一条弹幕都被静默跳过、弹幕永远不显示。
      final items = DanmakuParser.parseXml(
        '<i><d p="4.39000,1,25,16777215,1791630741,0,7baffcf4,2219118517716981760,10">滑动弹幕</d></i>',
      );
      expect(items.length, 1);
      expect(items.single.progressMs, 4390);
    });

    test('时间字段的数量级兜底', () {
      // 小整数 → 按秒
      expect(
        DanmakuParser.parseXml('<i><d p="23,1,25,0,0,0,x,0,0">a</d></i>')
            .single
            .progressMs,
        23000,
      );
      // 数量级 >= 100000 → 认为已经是毫秒
      expect(
        DanmakuParser.parseXml('<i><d p="120000,1,25,0,0,0,x,0,0">a</d></i>')
            .single
            .progressMs,
        120000,
      );
      // 非法值 → 跳过而不是崩
      expect(
        DanmakuParser.parseXml('<i><d p="abc,1,25,0,0,0,x,0,0">a</d></i>'),
        isEmpty,
      );
    });

    test('模式 / 颜色 / 用户 hash 按真实字段号解析', () {
      final item = DanmakuParser.parseXml(
        '<i><d p="1.5,5,25,16707842,1791630741,0,7baffcf4,123,10">顶部</d></i>',
      ).single;
      expect(item.mode, DanmakuMode.top);
      expect(item.color, 16707842);
      expect(item.argbColor, 0xFF000000 | 16707842);
      expect(item.uidHash, '7baffcf4');
    });
  });

  group('自动识别 parseAuto', () {
    test('识别明文 XML', () {
      final items = DanmakuParser.parseAuto(
        Uint8List.fromList(utf8.encode(_xmlSample)),
      );
      expect(items.length, 3);
      expect(items.first.text, '第一条弹幕');
    });

    test('识别 protobuf 二进制', () {
      final items = DanmakuParser.parseAuto(
        _reply(<List<int>>[
          _elem(progress: 1200, mode: 1, fontSize: 25, color: 0xFFFFFF, text: 'hello'),
        ]),
      );
      expect(items.length, 1);
      expect(items.single.text, 'hello');
    });

    test('识别 zlib 流（其它 CDN 可能这么发）', () {
      final zlibbed = ZLibEncoder().encode(utf8.encode(_xmlSample));
      expect(Uint8List.fromList(zlibbed).first, 0x78);
      final items = DanmakuParser.parseAuto(Uint8List.fromList(zlibbed));
      expect(items.length, 3);
    });

    test('识别裸 deflate（dm/list.so 的真实形态）', () {
      // fixture 由 Python 的 zlib.compressobj(wbits=-15) 生成，
      // 与 B 站 Content-Encoding: deflate 但无 zlib 头的实际行为一致。
      final bytes = base64Decode(_rawDeflateFixture);
      expect(bytes.first, isNot(0x78), reason: '确认不是 zlib 流，这个测试才有意义');

      final items = DanmakuParser.parseAuto(bytes);
      expect(items.length, 3);
      expect(items[0].text, '第一条弹幕');
      expect(items[0].progressMs, 1000);
      expect(items[1].mode, DanmakuMode.top);
      expect(items[2].progressMs, 3000);
    });

    test('空数据与垃圾数据不抛异常', () {
      expect(DanmakuParser.parseAuto(Uint8List(0)), isEmpty);
      expect(
        () => DanmakuParser.parseAuto(
          Uint8List.fromList(List<int>.generate(200, (i) => (i * 31) % 256)),
        ),
        returnsNormally,
      );
    });
  });

  group('protobuf 通道', () {
    test('解析未压缩的 DmSegMobileReply', () {
      final bytes = _reply(<List<int>>[
        _elem(progress: 1200, mode: 1, fontSize: 25, color: 0xFFFFFF, text: 'hello'),
        _elem(progress: 3400, mode: 5, fontSize: 18, color: 0xFF0000, text: '顶部'),
      ]);

      final items = DanmakuParser.parseProto(bytes);
      expect(items.length, 2);
      expect(items[0].progressMs, 1200);
      expect(items[0].text, 'hello');
      expect(items[0].mode, DanmakuMode.scroll);
      expect(items[1].progressMs, 3400);
      expect(items[1].mode, DanmakuMode.top);
      expect(items[1].color, 0xFF0000);
    });

    test('解析 zlib 压缩的响应体（dm/list.so 的真实形态）', () {
      final raw = _reply(<List<int>>[
        _elem(progress: 500, mode: 1, fontSize: 25, color: 0xFFFFFF, text: '压缩弹幕'),
      ]);
      final compressed = Uint8List.fromList(ZLibEncoder().encode(raw));
      // 确认确实是 zlib 流（0x78 头），否则这个测试就没有验证到解压路径。
      expect(compressed.first, 0x78);

      final items = DanmakuParser.parseProto(compressed);
      expect(items.length, 1);
      expect(items.single.text, '压缩弹幕');
    });

    test('乱码字节不抛异常', () {
      final garbage = Uint8List.fromList(List<int>.generate(64, (i) => (i * 7) % 256));
      expect(() => DanmakuParser.parseProto(garbage), returnsNormally);
    });

    test('缺 progress 或文本的条目被丢弃', () {
      // 只有 content，没有 progress
      final onlyText = <int>[
        ..._varint((7 << 3) | 2), ..._varint(2), 0x61, 0x62,
      ];
      final items = DanmakuParser.parseProto(_reply(<List<int>>[onlyText]));
      expect(items, isEmpty);
    });
  });

  group('排序', () {
    test('sorted 按时间升序', () {
      final bytes = _reply(<List<int>>[
        _elem(progress: 5000, mode: 1, fontSize: 25, color: 0, text: 'c'),
        _elem(progress: 1000, mode: 1, fontSize: 25, color: 0, text: 'a'),
        _elem(progress: 3000, mode: 1, fontSize: 25, color: 0, text: 'b'),
      ]);
      final items = DanmakuParser.sorted(DanmakuParser.parseProto(bytes));
      expect(items.map((e) => e.text).toList(), <String>['a', 'b', 'c']);
    });
  });

  group('DanmakuSettings', () {
    test('关键词屏蔽不区分大小写', () {
      const settings = DanmakuSettings(blockKeywords: <String>['前方高能']);
      expect(settings.blocks('前方高能预警'), isTrue);
      expect(settings.blocks('普通弹幕'), isFalse);
    });

    test('空关键词列表不屏蔽任何内容', () {
      const settings = DanmakuSettings();
      expect(settings.blocks('随便什么'), isFalse);
      expect(settings.normalizedKeywords, isEmpty);
    });

    test('序列化往返', () {
      const settings = DanmakuSettings(
        enabled: false,
        opacity: 0.5,
        blockKeywords: <String>['abc'],
        maxOnScreen: 300,
      );
      final restored = DanmakuSettings.fromJson(settings.toJson());
      expect(restored.enabled, isFalse);
      expect(restored.opacity, 0.5);
      expect(restored.blockKeywords, <String>['abc']);
      expect(restored.maxOnScreen, 300);
    });
  });
}
