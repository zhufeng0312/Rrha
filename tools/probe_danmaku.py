"""深挖弹幕接口的真实形态。

实测发现两个疑点，这个脚本负责定性：
  1. /x/v1/dm/list.so 响应首字节是 cc bd 5b 6f，既不是 zlib(0x78) 也不是 gzip(0x1f8b)
     —— 高度怀疑是 **raw deflate**（Dart 端 DanmakuParser.maybeInflate 目前没覆盖这条）
  2. comment.bilibili.com/{cid}.xml 返回 200/21KB 但抓不到 <d p= 标签
     —— 怀疑是 gzip 响应体没被 urllib 解压，或者内容根本不是弹幕 XML

同时顺便用独立实现解析 protobuf，核对字段号假设：
  2=progress 3=mode 4=fontsize 5=color 7=content
"""

import gzip
import sys
import urllib.request
import zlib

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
REFERER = {"Referer": "https://www.bilibili.com/", "User-Agent": UA}
PROXY = "http://127.0.0.1:7897"


def raw_get(url, headers=None):
    h = dict(REFERER)
    if headers:
        h.update(headers)
    op = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
    )
    req = urllib.request.Request(url, headers=h)
    with op.open(req, timeout=30) as r:
        return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()


# ------------------------------------------------------------------ protobuf

def read_varint(data, pos):
    result = 0
    shift = 0
    while True:
        b = data[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
        if shift > 63:
            raise ValueError("varint 过长")
    return result, pos


def split_reply(data):
    """把 DmSegMobileReply 拆成若干 DanmakuElem 字节串。"""
    pos = 0
    elems = []
    while pos < len(data):
        tag, pos = read_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if field == 1 and wire == 2:
            ln, pos = read_varint(data, pos)
            elems.append(data[pos:pos + ln])
            pos += ln
        elif wire == 0:
            _, pos = read_varint(data, pos)
        elif wire == 2:
            ln, pos = read_varint(data, pos)
            pos += ln
        elif wire == 5:
            pos += 4
        elif wire == 1:
            pos += 8
        else:
            raise ValueError("非法 wire type {}".format(wire))
    return elems


def parse_elem(elem):
    """按社区公开的字段号解析一条弹幕。"""
    out = {}
    pos = 0
    while pos < len(elem):
        tag, pos = read_varint(elem, pos)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            val, pos = read_varint(elem, pos)
            out[field] = val
        elif wire == 2:
            ln, pos = read_varint(elem, pos)
            raw = elem[pos:pos + ln]
            pos += ln
            out[field] = raw.decode("utf-8", "replace")
        elif wire == 5:
            pos += 4
        elif wire == 1:
            pos += 8
        else:
            raise ValueError("非法 wire type {}".format(wire))
    return out


def try_decompress(body):
    """依次尝试各种解压方式，返回 (方式, 解压后字节)。"""
    attempts = [
        ("zlib(wbits=15)", lambda d: zlib.decompress(d)),
        ("raw-deflate(wbits=-15)", lambda d: zlib.decompress(d, -15)),
        ("gzip", lambda d: gzip.decompress(d)),
    ]
    results = []
    for name, fn in attempts:
        try:
            out = fn(body)
            results.append((name, out))
        except Exception as e:  # noqa: BLE001
            results.append((name, "{}: {}".format(type(e).__name__, str(e)[:60])))
    return results


def main():
    cid = sys.argv[1] if len(sys.argv) > 1 else None
    if not cid:
        print("用法: python tools/probe_danmaku.py <cid>")
        return

    print("=" * 78)
    print("A. /x/v1/dm/list.so?oid={}  （客户端当前首选通道）".format(cid))
    print("=" * 78)
    status, hdrs, body = raw_get("https://api.bilibili.com/x/v1/dm/list.so?oid={}".format(cid))
    print("HTTP {}".format(status))
    for k in ("content-type", "content-encoding", "content-length", "vary", "server"):
        if k in hdrs:
            print("  {}: {}".format(k, hdrs[k]))
    print("  原始长度 = {}B".format(len(body)))
    print("  前 16 字节 = {}".format(body[:16].hex(" ")))

    print("\n  -- 解压尝试 --")
    decompressed = None
    for name, result in try_decompress(body):
        if isinstance(result, bytes):
            print("  [OK]   {:<24} -> {}B  前 8 字节 = {}".format(name, len(result), result[:8].hex(" ")))
            if decompressed is None:
                decompressed = result
        else:
            print("  [FAIL] {:<24} {}".format(name, result))

    if decompressed is None:
        print("\n  没能解压，按未压缩处理（可能是 CDN 已解压）")
        decompressed = body

    print("\n  -- 按 DmSegMobileReply 解析 --")
    try:
        elems = split_reply(decompressed)
        print("  DanmakuElem 条数 = {}".format(len(elems)))
        for i, e in enumerate(elems[:3]):
            parsed = parse_elem(e)
            print("  第 {} 条:".format(i + 1))
            print("      field2(progress) = {!r}".format(parsed.get(2)))
            print("      field3(mode)     = {!r}".format(parsed.get(3)))
            print("      field4(fontsize) = {!r}".format(parsed.get(4)))
            print("      field5(color)    = {!r}".format(parsed.get(5)))
            print("      field6(midHash)  = {!r}".format(str(parsed.get(6))[:20]))
            print("      field7(content)  = {!r}".format(str(parsed.get(7))[:40]))
            print("      其它字段号        = {}".format(sorted(k for k in parsed if k not in (2, 3, 4, 5, 6, 7))))
        print("\n  >>> 字段号与 Dart 端 DanmakuParser._parseElem 的假设一致与否，看上面 progress/mode/color/content 是否合理")
    except Exception as e:  # noqa: BLE001
        print("  解析失败: {}: {}".format(type(e).__name__, e))
        print("  头 64 字节: {}".format(decompressed[:64].hex(" ")))

    print("\n" + "=" * 78)
    print("B. https://comment.bilibili.com/{}.xml  （客户端当前兜底通道）".format(cid))
    print("=" * 78)
    status, hdrs, body2 = raw_get("https://comment.bilibili.com/{}.xml".format(cid))
    print("HTTP {}".format(status))
    for k in ("content-type", "content-encoding", "content-length", "server"):
        if k in hdrs:
            print("  {}: {}".format(k, hdrs[k]))
    print("  原始长度 = {}B".format(len(body2)))
    print("  前 16 字节 = {}".format(body2[:16].hex(" ")))

    text = None
    for name, result in try_decompress(body2):
        if isinstance(result, bytes):
            print("  [OK]   {:<24} -> {}B".format(name, len(result)))
            if text is None:
                text = result.decode("utf-8", "replace")
            break
    if text is None:
        text = body2.decode("utf-8", "replace")

    print("  解压后前 400 字符：")
    print("      {}".format(" ".join(text.split())[:400]))
    print("  含 '<d p=' 次数 = {}".format(text.count("<d p=")))
    if "<d p=" not in text:
        print("  >>> 这条通道返回的不是弹幕 XML —— Dart 端的 XML 兜底通道需要改或删")


if __name__ == "__main__":
    main()
