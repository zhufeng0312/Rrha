"""B 站评论接口 -403 悬案：根因定位 + 分页可行性验证（HANDOVER §7.4）。

第一轮复测（本文件上一版）已证伪「出口 IP 被风控」这个推断：
  - 直连与代理**结果完全一致**（都 -403 / 都 code=0）；
  - 真正的分界是 `pagination_str` 的取值形态。

由此产生的假设：
  - Python `json.dumps({"offset": ""})` 产出 **带空格** 的 `{"offset": ""}` → B 站返回 -403；
  - Dart `jsonEncode({'offset': ''})` 产出 **紧凑** 的 `{"offset":""}` → 应用内实测可用。
  也就是说：-403 不是风控，而是 pagination_str 的**字节形态**不被接受。

本脚本负责：
  1. 用严格的变体矩阵确认「带空格 → -403 / 紧凑 → code=0」；
  2. 验证**分页**真的能走通（用响应里的 next_offset 取第二页），
     否则「能拿首页」对 App 没有实际意义；
  3. 确认 Dart 现有实现（紧凑形态）与之一致。

安全：凭据只从 C:\\gradle-home\\tmp\\bili_login\\session.json 读取（项目外），
日志只打印键名与长度，绝不打印值。

用法：
  python -X utf8 tools/probe_comment_retest.py
  python -X utf8 tools/probe_comment_retest.py --export-dir 代理 --aid 115751935613951
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

SESSION = r"C:\gradle-home\tmp\bili_login\session.json"

MIXIN_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
]

PC_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

PROXY = os.environ.get("PROXY") or "http://127.0.0.1:7897"


def load_cookie() -> str:
    with open(SESSION, "r", encoding="utf-8") as fh:
        sess = json.load(fh)
    return "; ".join("%s=%s" % (k, v) for k, v in sess["cookies"].items())


def make_getter(use_proxy: bool, cookie: str, ua: str = PC_UA):
    handler = (
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
        if use_proxy
        else urllib.request.ProxyHandler({})
    )
    opener = urllib.request.build_opener(handler)
    opener.addheaders = [
        ("User-Agent", ua),
        ("Referer", "https://www.bilibili.com/"),
        ("Origin", "https://www.bilibili.com"),
        ("Cookie", cookie),
        ("Accept", "application/json, text/plain, */*"),
        ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8"),
    ]

    def get(url: str, timeout: int = 20):
        try:
            r = opener.open(url, timeout=timeout)
            return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception as e:
            return None, "%s: %s" % (type(e).__name__, str(e)[:110])

    return get


def wbi_mixin(get) -> str:
    _, body = get("https://api.bilibili.com/x/web-interface/nav")
    j = json.loads(body)
    wbi = (j.get("data") or {}).get("wbi_img") or {}
    img = (wbi.get("img_url") or "").rsplit("/", 1)[-1].split(".")[0]
    sub = (wbi.get("sub_url") or "").rsplit("/", 1)[-1].split(".")[0]
    orig = img + sub
    return "".join(orig[i] for i in MIXIN_TAB)[:32] if len(orig) == 64 else ""


def signed_url(path: str, params: dict, mk: str) -> str:
    p = dict(params)
    p["wts"] = int(time.time())
    pairs = [
        (k, "".join(c for c in str(v) if c not in "!'()*")) for k, v in sorted(p.items())
    ]
    query = urllib.parse.urlencode(pairs)
    w_rid = hashlib.md5((query + mk).encode("utf-8")).hexdigest()
    return "https://api.bilibili.com%s?%s&w_rid=%s" % (path, query, w_rid)


def call_main(
    get,
    mk: str,
    aid: int,
    pagination: str | None,
    tag: str,
    extra: dict | None = None,
    mode: int = 3,
):
    """调用 /x/v2/reply/wbi/main。pagination=None 表示完全不传该参数。"""
    params = {"oid": aid, "type": 1, "mode": mode, "plat": 1, "web_location": 1315875}
    if pagination is not None:
        params["pagination_str"] = pagination
    if extra:
        params.update(extra)

    status, body = get(signed_url("/x/v2/reply/wbi/main", params, mk))
    try:
        j = json.loads(body)
    except Exception:
        print("  %-40s HTTP %-5s 非 JSON：%s" % (tag, status, body[:70].replace("\n", " ")))
        return None

    code = j.get("code")
    data = j.get("data") or {}
    replies = data.get("replies") or []
    cursor = data.get("cursor") or {}
    next_offset = ((cursor.get("pagination_reply") or {}).get("next_offset"))
    print(
        "  %-40s code=%-7s 主评论=%-3d is_end=%-5s next_offset=%s"
        % (tag, code, len(replies), cursor.get("is_end"), (next_offset or "-")[:28])
    )
    return j


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--aid", type=int, default=115751935613951)
    ap.add_argument("--proxy", action="store_true", help="用代理出口（默认直连）")
    ap.add_argument(
        "--popular",
        action="store_true",
        help="自动挑一个评论最多的热门视频来验证分页（默认用 --aid）",
    )
    args = ap.parse_args()

    spaced = json.dumps({"offset": ""})                                  # {"offset": ""}
    compact = json.dumps({"offset": ""}, separators=(",", ":"))         # {"offset":""}

    print("=" * 104)
    print("B 站评论接口 -403 根因定位（HANDOVER §7.4）")
    print("=" * 104)
    print("出口：%s" % ("代理 " + PROXY if args.proxy else "直连（本机出口）"))
    print("对照的两种 pagination_str（注意空格差异，肉眼几乎看不出来）：")
    print("   Python json.dumps 默认 : %r" % spaced)
    print("   Dart   jsonEncode     : %r" % compact)

    ck = load_cookie()
    get = make_getter(args.proxy, ck)
    mk = wbi_mixin(get)
    if not mk:
        print("WBI 密钥获取失败")
        return 2

    target_aid = args.aid
    if args.popular:
        status, body = get("https://api.bilibili.com/x/web-interface/popular?ps=20&pn=1")
        try:
            lst = (json.loads(body).get("data") or {}).get("list") or []
            cand = sorted(
                lst, key=lambda v: (v.get("stat") or {}).get("reply", 0), reverse=True
            )
            if cand:
                best = cand[0]
                target_aid = best.get("aid")
                print(
                    "\n自动选取热门视频：%s（aid=%s，评论数=%s）"
                    % (
                        (best.get("title") or "")[:38],
                        target_aid,
                        (best.get("stat") or {}).get("reply"),
                    )
                )
        except Exception as e:
            print("\n热门视频选取失败：%s（改用 --aid）" % e)

    print("\n[1] pagination_str 变体矩阵（同一出口、同一 aid、同一登录态）")
    call_main(get, mk, args.aid, spaced, "带空格 %s" % spaced)
    call_main(get, mk, args.aid, compact, "紧凑 %s  ← Dart jsonEncode 形态" % compact)
    call_main(get, mk, args.aid, "", "空字符串 pagination_str=")
    call_main(get, mk, args.aid, None, "完全不传 pagination_str")
    call_main(get, mk, args.aid, '{"offset":""}', "字面量紧凑（不用 json 库）")

    print("\n[2] 分页验证：mode=3(热度) 与 mode=2(时间) 各连续翻 3 页")
    for mode in (3, 2):
        print("   —— mode=%d%s ——" % (mode, " 热度" if mode == 3 else " 时间"))
        seen: set = set()
        prev_offset = None
        pagination = compact
        for page in range(1, 4):
            j = call_main(get, mk, target_aid, pagination, "第 %d 页" % page, mode=mode)
            if not j:
                break
            data = j.get("data") or {}
            ids = [r.get("rpid") for r in (data.get("replies") or [])]
            dup = seen & set(ids)
            new = len(set(ids) - seen)
            seen |= set(ids)
            cursor = data.get("cursor") or {}
            nxt = (cursor.get("pagination_reply") or {}).get("next_offset")
            print(
                "     本页 %-3d 条 / 新增 %-3d 条 / 与已见重复 %-3d 条 / is_end=%s"
                % (len(ids), new, len(dup), cursor.get("is_end"))
            )
            if cursor.get("is_end"):
                print("     停止：is_end=True（评论区到底）")
                break
            if not nxt or nxt == prev_offset:
                print("     停止：游标未推进（next_offset 与上一页相同）")
                break
            prev_offset = nxt
            pagination = json.dumps({"offset": nxt}, separators=(",", ":"))

    print("\n[3] Dart 侧现有实现对照（lib/data/bili/bili_client.dart:comments()）")
    dart_form = "jsonEncode(<String, String>{'offset': ''})"
    print("     代码：pagination = %s" % dart_form)
    print("     产物：%s  → 与上面「紧凑」变体一致" % compact)
    print("=" * 104)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
