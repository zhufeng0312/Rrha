"""Rrha 接口实测脚本（走 OpenSSL + 代理，绕开 Schannel 问题）。

目的：把 docs/LIVE_CHECK.md 里的「待实测」项全部跑一遍，用真实响应校准
lib/ 下的代码假设。特别是用**独立实现**复刻一遍 WBI 签名，验证
lib/data/bili/wbi.dart 的算法（混淆表 + 参数排序 + !'()* 过滤）是否正确。

用法：
    python tools/live_probe.py
    python tools/live_probe.py --proxy=http://127.0.0.1:7897 --uid=2267573
"""

import argparse
import hashlib
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
REFERER = {"Referer": "https://www.bilibili.com/"}

# 与 lib/data/bili/wbi.dart 中完全一致的混淆表
MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
]

FILTER_CHARS = "!'()*"

CONFIG = {"proxy": "http://127.0.0.1:7897", "rsshub": "https://rsshub.app", "uid": "2267573"}


# --------------------------------------------------------------------- HTTP

def _opener(proxy):
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def http(url, headers=None, proxy=None, timeout=25):
    """返回 (status, bytes, ms)；异常时返回 (None, 错误文本, ms)。"""
    h = {"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"}
    if headers:
        h.update(headers)
    started = time.time()
    try:
        req = urllib.request.Request(url, headers=h)
        with _opener(proxy if proxy is not None else CONFIG["proxy"]).open(req, timeout=timeout) as r:
            data = r.read()
            return r.status, data, int((time.time() - started) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:2000], int((time.time() - started) * 1000)
    except Exception as e:  # noqa: BLE001
        return None, "{}: {}".format(type(e).__name__, str(e)[:160]).encode("utf-8", "replace"), int((time.time() - started) * 1000)


def show(label, status, body, ms, limit=260):
    text = body.decode("utf-8", "replace") if isinstance(body, bytes) else str(body)
    one = " ".join(text.split())
    print("  [{}] HTTP {}  {}ms  {}B".format(label, status, ms, len(body) if isinstance(body, bytes) else len(text)))
    if one:
        print("      {}".format(one[:limit]))


# --------------------------------------------------------------------- WBI

def key_from_url(url):
    seg = url.rsplit("/", 1)[-1]
    return seg.split(".", 1)[0]


def mixin_key(img_key, sub_key):
    orig = img_key + sub_key
    if len(orig) != 64:
        raise ValueError("密钥长度异常: {}".format(len(orig)))
    return "".join(orig[i] for i in MIXIN_KEY_ENC_TAB)[:32]


def enc_wbi(params, img_key, sub_key):
    """与 Dart 版签名字节级一致：值先剔除 !'()* 再 encodeURIComponent。"""
    mixin = mixin_key(img_key, sub_key)
    merged = dict(params)
    merged["wts"] = int(time.time())
    # safe="~" 让 ~ 不被编码，与 JS 的 encodeURIComponent / Dart 的 Uri.encodeComponent 对齐
    pairs = []
    for k in sorted(merged.keys()):
        v = merged[k]
        if v is None:
            continue
        cleaned = "".join(ch for ch in str(v) if ch not in FILTER_CHARS)
        pairs.append("{}={}".format(urllib.parse.quote(str(k), safe="~"),
                                    urllib.parse.quote(cleaned, safe="~")))
    query = "&".join(pairs)
    w_rid = hashlib.md5((query + mixin).encode("utf-8")).hexdigest()
    return "{}&w_rid={}".format(query, w_rid)


def api_get(path, params, keys, cookie=None, timeout=25):
    query = enc_wbi(params, keys["img"], keys["sub"])
    headers = dict(REFERER)
    if cookie:
        headers["Cookie"] = cookie
    return http("https://api.bilibili.com{}?{}".format(path, query), headers=headers, timeout=timeout)


# --------------------------------------------------------------------- 各段实测

def section(title):
    print("\n" + "=" * 78)
    print(title)
    print("=" * 78)


def probe_rsshub():
    section("1. RSSHub 路由实测（base = {}）".format(CONFIG["rsshub"]))
    uid = CONFIG["uid"]
    results = {}
    for label, path in [
        ("B站视频", "/bilibili/user/video/{}?limit=3".format(uid)),
        ("B站动态", "/bilibili/user/dynamic/{}?limit=3".format(uid)),
        ("微博", "/weibo/user/1234567890?limit=3"),
    ]:
        status, body, ms = http(CONFIG["rsshub"] + path)
        show(label, status, body, ms)
        results[label] = (status, body)
        text = body.decode("utf-8", "replace") if isinstance(body, bytes) else str(body)
        if status == 200:
            items = re.findall(r"<item>(.*?)</item>", text, re.S)
            print("      item 数 = {}".format(len(items)))
            if items:
                first = items[0]
                has_img = bool(re.search(r"<img[^>]+src=", first))
                has_media = bool(re.search(r"<media:thumbnail", first))
                pub = re.search(r"<pubDate>(.*?)</pubDate>", first, re.S)
                author = re.search(r"<(?:author|dc:creator)>(.*?)</", first, re.S)
                bv = re.search(r"(BV[0-9A-Za-z]{10})", first)
                print("      description 含 <img> = {} | media:thumbnail = {}".format(has_img, has_media))
                print("      pubDate = {!r}".format(pub.group(1).strip() if pub else None))
                print("      author  = {!r}".format(author.group(1).strip() if author else None))
                print("      首个 BV = {}".format(bv.group(1) if bv else None))
    return results


def fetch_keys():
    section("2. B 站 WBI 密钥（nav 接口）")
    status, body, ms = http("https://api.bilibili.com/x/web-interface/nav", headers=REFERER)
    show("nav", status, body, ms)
    try:
        data = json.loads(body)
    except Exception as e:  # noqa: BLE001
        print("  !! 响应不是 JSON: {}".format(e))
        return None
    print("  code = {}  message = {!r}  isLogin = {}".format(
        data.get("code"), data.get("message"), (data.get("data") or {}).get("isLogin")))
    wbi_img = (data.get("data") or {}).get("wbi_img") or {}
    if not wbi_img.get("img_url"):
        print("  !! 没有 wbi_img —— 与代码假设不符，需要改 BiliClient._refreshKeys")
        return None
    img_key = key_from_url(wbi_img["img_url"])
    sub_key = key_from_url(wbi_img["sub_url"])
    print("  img_key = {} (len={})".format(img_key, len(img_key)))
    print("  sub_key = {} (len={})".format(sub_key, len(sub_key)))
    if len(img_key) + len(sub_key) == 64:
        mk = mixin_key(img_key, sub_key)
        print("  mixinKey = {}".format(mk))
        print("  ^ 与 Dart 端 test/bili/wbi_test.dart 的黄金值为同算法（表一致则结果一致）")
    else:
        print("  !! 密钥长度不是 32+32，混淆表实现需要复核")
    return {"img": img_key, "sub": sub_key}


def fetch_buvid():
    status, body, ms = http("https://api.bilibili.com/x/frontend/finger/spi", headers=REFERER)
    try:
        b3 = (json.loads(body).get("data") or {}).get("b_3")
    except Exception:  # noqa: BLE001
        b3 = None
    print("  [finger/spi] HTTP {}  {}ms  buvid3 = {}".format(status, ms, (b3 or "")[:16] + ("..." if b3 else "")))
    return b3


def pick_bvid(rsshub_results):
    """优先从 RSSHub 取真实 BV，兜底用热门接口。"""
    body = rsshub_results.get("B站视频", (None, b""))[1]
    text = body.decode("utf-8", "replace") if isinstance(body, bytes) else str(body)
    m = re.search(r"(BV[0-9A-Za-z]{10})", text)
    if m:
        return m.group(1), "RSSHub"
    status, body, ms = http("https://api.bilibili.com/x/web-interface/popular?ps=1&pn=1", headers=REFERER)
    try:
        d = json.loads(body).get("data") or {}
        lst = d.get("list") or []
        if lst:
            return lst[0]["bvid"], "popular 接口"
    except Exception:  # noqa: BLE001
        pass
    return None, None


def probe_bili(keys, cookie):
    section("3. B 站接口实测")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default=CONFIG["proxy"])
    ap.add_argument("--rsshub", default=CONFIG["rsshub"])
    ap.add_argument("--uid", default=CONFIG["uid"])
    args = ap.parse_args()
    CONFIG.update(proxy=args.proxy, rsshub=args.rsshub.rstrip("/"), uid=args.uid)

    print("proxy   = {}".format(CONFIG["proxy"]))
    print("rsshub  = {}".format(CONFIG["rsshub"]))
    print("uid     = {}".format(CONFIG["uid"]))

    rsshub_results = probe_rsshub()

    keys = fetch_keys()
    if not keys:
        print("\n无法取得 WBI 密钥，后续 B 站接口实测跳过。")
        return
    buvid3 = fetch_buvid()
    cookie = "buvid3={}".format(buvid3) if buvid3 else None

    section("3. 取一个真实视频用于后续实测")
    bvid, source = pick_bvid(rsshub_results)
    print("  bvid = {}  （来源：{}）".format(bvid, source))
    if not bvid:
        print("  !! 取不到 bvid，停止")
        return

    section("4. view：验证签名是否被接受（这是 WBI 正确性的第一道门）")
    status, body, ms = api_get("/x/web-interface/view", {"bvid": bvid}, keys, cookie)
    try:
        d = json.loads(body)
    except Exception as e:  # noqa: BLE001
        show("view", status, body, ms)
        print("  !! 非 JSON: {}".format(e))
        return
    print("  [view] HTTP {}  {}ms  code = {}  message = {!r}".format(status, ms, d.get("code"), d.get("message")))
    if d.get("code") != 0:
        print("  !! 签名被拒绝 —— 混淆表或签名流程需要修正")
        print("      完整响应: {}".format(json.dumps(d, ensure_ascii=False)[:400]))
        return
    info = d["data"]
    aid, cid = info["aid"], info["cid"]
    print("  OK  aid={} cid={} title={!r}".format(aid, cid, info.get("title", "")[:40]))
    print("  >>> WBI 签名实现正确（独立实现的签名被 B 站接受）")

    section("5. playurl：fnval=1 到底给不给单文件 MP4")
    for fnval in (1, 4048):
        status, body, ms = api_get(
            "/x/player/wbi/playurl",
            {"bvid": bvid, "cid": cid, "qn": 64, "fnver": 0, "fnval": fnval, "fourk": 1},
            keys, cookie,
        )
        try:
            d = json.loads(body)
        except Exception:  # noqa: BLE001
            show("playurl fnval={}".format(fnval), status, body, ms)
            continue
        data = d.get("data") or {}
        durl = data.get("durl") or []
        dash = data.get("dash") or {}
        videos = dash.get("video") or []
        audios = dash.get("audio") or []
        print("  [fnval={}] HTTP {}  {}ms  code={}  durl={}  dash.video={}  dash.audio={}".format(
            fnval, status, ms, d.get("code"), len(durl), len(videos), len(audios)))
        if durl:
            print("        durl[0].url = {}".format(durl[0].get("url", "")[:90]))
            print("        >>> 通道 A（video_player + MP4）可用")
        if videos:
            codecs = sorted({v.get("codecid") for v in videos})
            qns = sorted({v.get("id") for v in videos})
            print("        dash codecid={} qn={}".format(codecs, qns))
            print("        >>> 需要通道 B（media_kit）")
        fmts = data.get("support_formats") or []
        if fmts:
            print("        support_formats = {}".format(
                [(f.get("quality"), f.get("new_description")) for f in fmts][:6]))

    section("6. 弹幕两条通道")
    status, body, ms = http(
        "https://api.bilibili.com/x/v1/dm/list.so?oid={}".format(cid),
        headers=dict(REFERER, Cookie=cookie) if cookie else REFERER,
    )
    if isinstance(body, bytes) and body:
        head = " ".join("{:02x}".format(b) for b in body[:8])
        print("  [proto 通道] HTTP {}  {}ms  {}B  前 8 字节 = {}".format(status, ms, len(body), head))
        if body[0] == 0x78:
            print("        >>> 是 zlib 流，与 DanmakuParser.maybeInflate 的 zlib 分支一致")
        else:
            print("        >>> 不是 zlib（可能已被 CDN 解压），解析器的兜底分支会接住")
    else:
        print("  [proto 通道] HTTP {}  {}ms  响应为空".format(status, ms))

    status, body, ms = http("https://comment.bilibili.com/{}.xml".format(cid), headers=REFERER)
    text = body.decode("utf-8", "replace") if isinstance(body, bytes) else str(body)
    dcount = len(re.findall(r"<d p=", text))
    print("  [xml 通道]   HTTP {}  {}ms  {}B  <d> 条数 = {}".format(status, ms, len(text), dcount))
    if dcount:
        sample = re.search(r'<d p="([^"]*)">([^<]*)</d>', text)
        if sample:
            print("        p = {!r}  text = {!r}".format(sample.group(1)[:60], sample.group(2)[:30]))
            print("        >>> XML 通道可用（这是代码里的兜底通道）")

    section("7. 评论接口（无登录态的风控程度）")
    status, body, ms = api_get(
        "/x/v2/reply/wbi/main",
        {
            "oid": aid, "type": 1, "mode": 3, "plat": 1, "ps": 20,
            "pagination_str": json.dumps({"offset": ""}, separators=(",", ":")),
            "web_location": 1315875, "seek_rpid": "",
        },
        keys, cookie,
    )
    try:
        d = json.loads(body)
    except Exception:  # noqa: BLE001
        show("reply/wbi/main", status, body, ms)
        return
    data = d.get("data") or {}
    replies = data.get("replies") or []
    top = data.get("top_replies") or []
    cursor = (data.get("cursor") or {}).get("pagination_reply") or {}
    print("  HTTP {}  {}ms  code = {}  message = {!r}".format(status, ms, d.get("code"), d.get("message")))
    print("  replies = {}  top_replies = {}  is_end = {}  next_offset {}存在".format(
        len(replies), len(top), (data.get("cursor") or {}).get("is_end"),
        "有" if cursor.get("next_offset") else "无"))
    if d.get("code") == 0 and replies:
        r0 = replies[0]
        print("  首条: uname={!r} like={} rcount={} 有 replies 字段={}".format(
            (r0.get("member") or {}).get("uname"), r0.get("like"), r0.get("rcount"), "replies" in r0))
        print("  >>> 无登录态即可取到评论，代码路径可用")
    elif d.get("code") == 0:
        print("  >>> code=0 但 replies 为空 —— 接口在无登录态下只给部分数据，UI 需如实展示")
    else:
        print("  >>> 需要登录态或风控拦截，与代码里的降级路径（错误卡片 + 重试）一致")

    section("实测结束")


if __name__ == "__main__":
    main()
