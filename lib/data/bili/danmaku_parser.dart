import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../core/utils/logger.dart';
import '../models/danmaku_item.dart';

/// 弹幕双通道解析器。
///
/// B 站近两年持续收紧弹幕接口，两套接口的可用性都可能变化，因此
/// **两条通道都实现**，任何一条成功即可：
/// - 通道 1：`/x/v1/dm/list.so?oid={cid}` → deflate 压缩的 protobuf；
/// - 通道 2：`https://comment.bilibili.com/{cid}.xml` → 传统 XML。
///
/// 解析器本身是纯函数（不联网），可以直接用固定字节做单元测试。
class DanmakuParser {
  DanmakuParser._();

  // ------------------------------------------------------------ 解压

  /// 尽力解压：zlib / gzip / **raw deflate** / 原样。
  ///
  /// 实测（2026-10）：`/x/v1/dm/list.so` 返回 `Content-Encoding: deflate`，
  /// 但流里**没有 zlib 头**（首字节是 `0xcc` 而非 `0x78`）—— 是裸 deflate。
  /// 同时 dart:io 的 HttpClient 只自动解压 gzip、不处理 deflate，
  /// 所以这一层必须自己兜住：否则拿到的是压缩垃圾，弹幕一条都解析不出来。
  static Uint8List maybeInflate(Uint8List data) {
    if (data.isEmpty) return data;

    // 0) 已经是明文文本（XML/JSON），直接返回。
    //
    // 【实机修复 · 2026-10-14】这一步不能省。
    // 旧实现无条件把输入丢给裸 deflate 解压器，于是**未压缩的 XML 文本**
    // 会被 deflate 头几个字节解析成荒谬的长度字段。实测在单元测试里
    // 触发 `Shell: Exhausted heap space, trying to allocate 25769738272 bytes`
    // （试图分配约 25 GB），整个进程被拖垮、该用例跑了近 3 分钟才失败。
    //
    // 触发条件在真实网络下是存在的：CDN/中间层漏发 `Content-Encoding`
    // 时会直接返回明文 XML，而需求明确要求「解析失败不得崩溃」。
    // 明文一定以可打印字符开头，压缩流则不会，据此先行短路即可。
    if (_looksLikeText(data)) return data;

    // 1) zlib
    if (data.length > 1 && data[0] == 0x78) {
      final out = _tryDecode(() => ZLibDecoder().decodeBytes(data), 'zlib');
      if (out != null) return out;
    }

    // 2) gzip（dart:io 通常已经解过，这里兜住未解压的情况）
    if (data.length > 1 && data[0] == 0x1F && data[1] == 0x8B) {
      final out = _tryDecode(() => GZipDecoder().decodeBytes(data), 'gzip');
      if (out != null) return out;
    }

    // 3) 裸 deflate（B 站 dm/list.so 的真实形态）。
    //
    // 不能用「手工补 zlib 头」的办法：zlib 尾部的 Adler-32 是对**解压后**的
    // 数据计算的，而我们解压前无法预知它 —— 实测那一步必然报
    // `incorrect data check`。正确做法是用 archive 的 Inflate，
    // 它只解裸 deflate 负载、不做尾部校验。
    final out = _tryDecode(() => Inflate(data).getBytes(), 'raw-deflate');
    if (out != null) return out;

    // 4) 未压缩（CDN 已解压或本来就没压缩）
    return data;
  }

  /// 判断载荷是否看起来已经是文本（而非压缩流）。
  ///
  /// 只看开头一小段：明文 XML/JSON 的起始字节全部可打印，
  /// 而 zlib/gzip/deflate 流的首字节几乎不可能连续落在这个范围内。
  /// 这个判定只用于「跳过解压」，判断错了也只是走回原来的解压路径，
  /// 不会引入新的失败面。
  static bool _looksLikeText(Uint8List data) {
    final n = data.length < 16 ? data.length : 16;
    var printable = 0;
    for (var i = 0; i < n; i++) {
      final b = data[i];
      // 可见 ASCII + 常见空白（\t \n \r 空格）；允许 UTF-8 BOM 与高位字节
      // 出现在后续位置，但首字节必须是可打印字符才算文本。
      if ((b >= 0x20 && b < 0x7F) || b == 0x09 || b == 0x0A || b == 0x0D) {
        printable++;
      }
    }
    if (printable == n) return true;
    // `<` 开头（含 BOM 后紧跟 `<`）是 XML 的强特征。
    if (data[0] == 0x3C) return true;
    if (n >= 4 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF &&
        data[3] == 0x3C) {
      return true;
    }
    return false;
  }

  static Uint8List? _tryDecode(List<int> Function() decode, String label) {
    try {
      final out = decode();
      if (out.isEmpty) return null;
      return Uint8List.fromList(out);
    } catch (e) {
      Log.d('DanmakuParser', '$label 解压失败（继续尝试其它方式）：$e');
      return null;
    }
  }

  // ------------------------------------------------------------ 自动识别

  /// 自动识别弹幕载荷：解压后判断是 XML 文本还是 protobuf 二进制。
  ///
  /// 实测（2026-10）：`/x/v1/dm/list.so` 现在返回的是 **deflate 压缩的 XML**
  /// （`<?xml version="1.0"?><i><d p="...">`），不再是历史文档里写的 protobuf；
  /// 而且 `comment.bilibili.com/{cid}.xml` 与它返回的字节完全一致（同源）。
  ///
  /// 所以客户端不该硬编码「通道 1 是 proto、通道 2 是 XML」，而应看内容本身。
  static List<DanmakuItem> parseAuto(Uint8List raw) {
    final data = maybeInflate(raw);

    if (_looksLikeXml(data)) {
      final items = parseXml(utf8.decode(data, allowMalformed: true));
      if (items.isNotEmpty) return items;
    }

    final proto = _parseProtoBytes(data);
    if (proto.isNotEmpty) return proto;

    // 最后按文本再试一次，覆盖「不是以 < 开头但确实是 XML」的极端情况
    return parseXml(utf8.decode(data, allowMalformed: true));
  }

  /// 解压后的数据是否像 XML：跳过 BOM 与空白后，第一个可见字符是 `<`。
  static bool _looksLikeXml(Uint8List data) {
    final limit = data.length < 8 ? data.length : 8;
    for (var i = 0; i < limit; i++) {
      final b = data[i];
      if (b == 0xEF || b == 0xBB || b == 0xBF) continue; // UTF-8 BOM
      if (b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09) continue;
      return b == 0x3C; // '<'
    }
    return false;
  }

  // ------------------------------------------------------------ protobuf

  /// 解析 `DmSegMobileReply`（`repeated DanmakuElem elems = 1`）。
  ///
  /// 主接口目前已不返回这个格式，但分段接口（如 `/x/v2/dm/web/seg.so`）
  /// 仍然是 protobuf，因此保留实现与单测覆盖。
  static List<DanmakuItem> parseProto(Uint8List raw) =>
      _parseProtoBytes(maybeInflate(raw));

  static List<DanmakuItem> _parseProtoBytes(Uint8List data) {
    final items = <DanmakuItem>[];
    if (data.isEmpty) return items;

    try {
      final reader = _PbReader(data);
      while (!reader.atEnd) {
        final tag = reader.readVarint();
        final field = tag >> 3;
        final wire = tag & 7;
        if (field == 1 && wire == 2) {
          final item = _parseElem(reader.readBytes());
          if (item != null) items.add(item);
        } else {
          reader.skip(wire);
        }
      }
    } catch (e) {
      Log.d('DanmakuParser', 'protobuf 解析中断（已保留 ${items.length} 条）：$e');
    }
    return items;
  }

  /// `DanmakuElem` 字段号（社区公开定义）：
  /// 1=id, 2=progress, 3=mode, 4=fontsize, 5=color, 6=midHash, 7=content
  static DanmakuItem? _parseElem(Uint8List bytes) {
    var progressMs = -1;
    var mode = 1;
    var fontSize = 25;
    var color = 0xFFFFFF;
    String? text;
    String? uidHash;

    try {
      final reader = _PbReader(bytes);
      while (!reader.atEnd) {
        final tag = reader.readVarint();
        final field = tag >> 3;
        final wire = tag & 7;
        switch (field) {
          case 2:
            if (wire == 0) {
              progressMs = reader.readVarint();
            } else {
              reader.skip(wire);
            }
            break;
          case 3:
            if (wire == 0) {
              mode = reader.readVarint();
            } else {
              reader.skip(wire);
            }
            break;
          case 4:
            if (wire == 0) {
              fontSize = reader.readVarint();
            } else {
              reader.skip(wire);
            }
            break;
          case 5:
            if (wire == 0) {
              color = reader.readVarint();
            } else {
              reader.skip(wire);
            }
            break;
          case 6:
            if (wire == 2) {
              uidHash = utf8.decode(reader.readBytes(), allowMalformed: true);
            } else {
              reader.skip(wire);
            }
            break;
          case 7:
            if (wire == 2) {
              text = utf8.decode(reader.readBytes(), allowMalformed: true);
            } else {
              reader.skip(wire);
            }
            break;
          default:
            reader.skip(wire);
        }
      }
    } catch (e) {
      return null;
    }

    if (text == null || text.isEmpty || progressMs < 0) return null;
    return DanmakuItem(
      progressMs: progressMs,
      mode: DanmakuMode.fromCode(mode),
      fontSize: fontSize <= 0 ? 25 : fontSize,
      color: color,
      text: text,
      uidHash: uidHash,
    );
  }

  // ------------------------------------------------------------ XML

  /// 解析传统 XML 弹幕。
  ///
  /// 真实格式（2026-10 实测）：
  /// `<d p="4.39000,5,25,16707842,1791630741,0,7baffcf4,2219118517716981760,10">文本</d>`
  /// 即 `出现秒数,模式,字号,颜色,时间戳,池,用户hash,弹幕id,权重`。
  ///
  /// **注意 p[0] 是浮点秒而不是整数毫秒** —— 用 `int.tryParse` 会全部返回 null，
  /// 结果是一条弹幕都解析不出来。这个坑是联网实测才抓出来的。
  static List<DanmakuItem> parseXml(String xmlText) {
    final items = <DanmakuItem>[];
    if (xmlText.trim().isEmpty) return items;

    try {
      final doc = XmlDocument.parse(xmlText);
      for (final d in doc.findAllElements('d')) {
        final p = d.getAttribute('p');
        if (p == null) continue;
        final parts = p.split(',');
        if (parts.length < 4) continue;

        final progress = _parseXmlProgressMs(parts[0]);
        if (progress == null) continue;
        final mode = int.tryParse(parts[1]) ?? 1;
        final fontSize = int.tryParse(parts[2]) ?? 25;
        final color = int.tryParse(parts[3]) ?? 0xFFFFFF;
        final text = d.innerText.trim();
        if (text.isEmpty) continue;

        items.add(
          DanmakuItem(
            progressMs: progress,
            mode: DanmakuMode.fromCode(mode),
            fontSize: fontSize <= 0 ? 25 : fontSize,
            color: color,
            text: text,
            uidHash: parts.length > 6 ? parts[6] : null,
          ),
        );
      }
    } catch (e) {
      Log.w('DanmakuParser', 'XML 弹幕解析失败：$e');
    }
    return items;
  }

  /// 解析 XML 弹幕的时间字段（秒 → 毫秒）。
  ///
  /// B 站的 `p[0]` 一直是**秒**（`"4.39000"` 这种浮点）。为兼容极少数返回毫秒的
  /// 镜像，用数量级做一次兜底：任何真实视频都远小于 100000 秒，
  /// 因此 `>= 100000` 的数值只可能是毫秒。
  static int? _parseXmlProgressMs(String raw) {
    final value = double.tryParse(raw.trim());
    if (value == null || value < 0) return null;
    if (value >= 100000) return value.round();
    return (value * 1000).round();
  }

  /// 按时间排序（两套接口返回顺序都不保证）。
  static List<DanmakuItem> sorted(List<DanmakuItem> items) {
    final copy = List<DanmakuItem>.from(items);
    copy.sort((a, b) => a.progressMs.compareTo(b.progressMs));
    return copy;
  }
}

/// 极简 protobuf wire format 读取器。
///
/// 只实现本项目需要的三种 wire type：varint(0)、64bit(1)、
/// length-delimited(2)、32bit(5)。引入完整 protobuf 代码生成对这种
/// 「只读几个字段」的场景过重。
class _PbReader {
  _PbReader(this.data);

  final Uint8List data;
  int pos = 0;

  bool get atEnd => pos >= data.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= data.length) throw const FormatException('varint 越界');
      final b = data[pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) throw const FormatException('varint 过长');
    }
    return result;
  }

  Uint8List readBytes() {
    final len = readVarint();
    if (len < 0 || pos + len > data.length) {
      throw const FormatException('length-delimited 越界');
    }
    final out = Uint8List.sublistView(data, pos, pos + len);
    pos += len;
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
        break;
      case 1:
        pos += 8;
        break;
      case 2:
        readBytes();
        break;
      case 5:
        pos += 4;
        break;
      default:
        throw FormatException('不支持的 wire type $wireType');
    }
    if (pos > data.length) throw const FormatException('跳过字段时越界');
  }
}
