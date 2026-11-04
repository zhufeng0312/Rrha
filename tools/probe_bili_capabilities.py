"""阶段 0 验证：登录态到底能解锁哪些能力。

用上一步扫码拿到的凭据，逐条验证「App 内直连官方 API」路线所需的接口：
  1. nav                 —— 确认登录态有效
  2. relation/followings —— 「我关注的 UP 主」列表（阶段 2 的地基）
  3. space/wbi/arc/search—— UP 主视频列表（需 WBI 签名，此前未登录是 -403）
  4. space/wbi/acc/info  —— 用户信息（需 WBI，此前未登录是 -352 风控）
  5. history/cursor      —— 观看历史（登录专属）
  6. reply/wbi/main      —— 评论（此前无登录是 -403）

安全：Cookie 从 session.json 读取，日志只打印接口返回，绝不打印凭据值。
"""

import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

SESSION = r"C:\gradle-home\tmp\bili_login\session.json"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

# WBI 重排表（与项目 lib/data/bili/wbi.dart 中一致）
MIXIN_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
]


def load_cookie() -> str:
    with open(SESSION, "r", encoding="utf-8") as fh:
        sess = json.load(fh)
    return "; ".join("%s=%s" % (k, v) for k, v in sess["cookies"].items())


COOKIE = load_cookie()


def get(url: str, cookie: str = COOKIE):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    opener.addheaders = [
        ("User-Agent", UA),
        ("Referer", "https://www.bilibili.com/"),
        ("Cookie", cookie),
    ]
    try:
        r = opener.open(url, timeout=25)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, str(e)[:80])


def wbi_keys():
    _, body = get("https://api.bilibili.com/x/web-interface/nav")
    j = json.loads(body)
    wbi = (j.get("data") or {}).get("wbi_img") or {}
    img = (wbi.get("img_url") or "").rsplit("/", 1)[-1].split(".")[0]
    sub = (wbi.get("sub_url") or "").rsplit("/", 1)[-1].split(".")[0]
    return img, sub


def mixin(img: str, sub: str) -> str:
    orig = img + sub
    return "".join(orig[i] for i in MIXIN_TAB)[:32]


def signed(path: str, params: dict, mk: str) -> str:
    p = dict(params)
    p["wts"] = int(time.time())
    items = sorted(p.items())
    # 过滤 !'()* 后再编码，这是 WBI 的关键细节
    pairs = [
        (k, "".join(c for c in str(v) if c not in "!'()*")) for k, v in items
    ]
    query = urllib.parse.urlencode(pairs)
    w_rid = hashlib.md5((query + mk).encode("utf-8")).hexdigest()
    return "https://api.bilibili.com%s?%s&w_rid=%s" % (path, query, w_rid)


def show(tag: str, status, body: str, extra=None):
    try:
        j = json.loads(body)
        code = j.get("code")
        msg = (j.get("message") or "")[:34]
        print("  %-22s HTTP %-4s code=%-7s msg=%s" % (tag, status, code, msg))
        if extra:
            extra(j)
        return j
    except Exception:
        print("  %-22s HTTP %-4s (非 JSON) %s" % (tag, status, body[:70].replace("\n", " ")))
        return None


def main() -> int:
    print("=" * 72)
    print("阶段 0 验证：登录态解锁能力（凭据来源：扫码登录）")
    print("=" * 72)

    # ---- 1) nav：确认登录态 ----
    print("\n[1] 登录态确认")
    _, body = get("https://api.bilibili.com/x/web-interface/nav")
    mid_holder = {}

    def grab_nav(j):
        d = j.get("data") or {}
        mid_holder["mid"] = d.get("mid")
        print("      isLogin=%s  uname=%s  mid=%s  vip=%s" % (
            d.get("isLogin"), d.get("uname"), d.get("mid"),
            ((d.get("vipStatus") == 1) if d.get("vipStatus") is not None else "?")))

    show("nav", 200, body, grab_nav)
    mid = mid_holder.get("mid")
    if not mid:
        print("  !! 未取到 mid，后续依赖 mid 的验证会跳过")
        mid = 2 

    # ---- 2) 关注列表（阶段 2 的地基）----
    print("\n[2] 「我关注的 UP 主」列表")
    _, body = get(
        "https://api.bilibili.com/x/relation/followings?vmid=%s&pn=1&ps=20&order=desc" % mid
    )

    def grab_follow(j):
        d = j.get("data") or {}
        lst = d.get("list") or []
        print("      关注总数=%s  本页返回=%d 条" % (d.get("total"), len(lst)))
        for u in lst[:5]:
            print("        - %-18s mid=%-12s 粉丝=%s" % (
                (u.get("uname") or "")[:18], u.get("mid"), u.get("fans")))

    show("relation/followings", 200, body, grab_follow)

    # ---- 3) WBI 签名后的用户信息与 UP 主视频 ----
    print("\n[3] WBI 签名接口（此前未登录分别是 -352 / -403）")
    img, sub = wbi_keys()
    mk = mixin(img, sub) if img and sub else ""
    print("      WBI keys: img=%d字符 sub=%d字符 mixin=%d字符" % (len(img), len(sub), len(mk)))

    if mk:
        _, body = get(signed("/x/space/wbi/acc/info", {"mid": 2267573}, mk))
        show("space/wbi/acc/info", 200, body, lambda j: print(
            "      name=%s" % ((j.get("data") or {}).get("name"))))

        _, body = get(signed("/x/space/wbi/arc/search", {"mid": 2267573, "ps": 10, "pn": 1}, mk))

        def grab_arc(j):
            d = (j.get("data") or {})
            vlist = ((d.get("list") or {}).get("vlist") or [])
            print("      返回视频=%d 条" % len(vlist))
            for v in vlist[:4]:
                print("        - %-30s %s" % ((v.get("title") or "")[:30], v.get("bvid")))

        show("space/wbi/arc/search", 200, body, grab_arc)

        # 动态
        _, body = get(signed(
            "/x/polymer/web-dynamic/v1/feed/space", {"host_mid": 2267573}, mk))
        show("polymer/feed/space", 200, body, lambda j: print(
            "      动态条数=%d" % len(((j.get("data") or {}).get("items") or []))))

    # ---- 4) 登录专属：观看历史 ----
    print("\n[4] 登录专属接口")
    _, body = get("https://api.bilibili.com/x/web-interface/history/cursor?ps=20")
    show("history/cursor", 200, body, lambda j: print(
        "      历史条数=%d" % len(((j.get("data") or {}).get("list") or []))))

    _, body = get("https://api.bilibili.com/x/v2/history/toview")
    show("history/toview", 200, body, lambda j: print(
        "      稍后再看=%d" % len(((j.get("data") or {}).get("list") or []))))

    # ---- 5) 评论（此前 -403）----
    print("\n[5] 评论接口（此前无登录是 -403）")
    if mk:
        aid = 115751935613951
        params = {
            "oid": aid, "type": 1, "mode": 3, "plat": 1,
            "pagination_str": json.dumps({"offset": ""}),
            "web_location": 1315875,
        }
        _, body = get(signed("/x/v2/reply/wbi/main", params, mk))
        show("reply/wbi/main", 200, body, lambda j: print(
            "      主评论=%d 条  is_end=%s" % (
                len(((j.get("data") or {}).get("replies") or [])),
                ((j.get("data") or {}).get("cursor") or {}).get("is_end"))))

    print("\n" + "=" * 72)
    print("DONE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
