"""阶段 2 诊断：复现 App 侧的两个 B 站官方接口调用。

背景：App 里时间线是空态，但设置页「数据源状态」显示绿勾（接口成功、没有错误），
所以必须区分两件事：
  a) 服务端确实没返回内容（例如该 UP 主无投稿）；
  b) 服务端返回了，但 App 侧解析成了 0 条。

本脚本用**同一份登录态**把这两个请求原样打一遍，打印原始形态与条数，
再给出「App 的取值路径」是否命中的判断。

用法：
  python -X utf8 tools/probe_stage2_fetch.py
  python -X utf8 tools/probe_stage2_fetch.py --mid 2267573
"""

from __future__ import annotations

import argparse
import hashlib
import json
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

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)


def load_cookie() -> str:
    with open(SESSION, "r", encoding="utf-8") as fh:
        sess = json.load(fh)
    return "; ".join("%s=%s" % (k, v) for k, v in sess["cookies"].items())


def make_getter(cookie: str):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    opener.addheaders = [
        ("User-Agent", UA),
        ("Referer", "https://www.bilibili.com/"),
        ("Origin", "https://www.bilibili.com"),
        ("Cookie", cookie),
        ("Accept", "application/json, text/plain, */*"),
    ]

    def get(url: str, timeout: int = 25):
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


def show(tag: str, status, body: str) -> dict | None:
    try:
        j = json.loads(body)
    except Exception:
        print("  %-24s HTTP %-5s 非 JSON：%s" % (tag, status, body[:90].replace("\n", " ")))
        return None
    print("  %-24s HTTP %-5s code=%-8s msg=%s" % (tag, status, j.get("code"), (j.get("message") or "")[:40]))
    return j


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mid", type=int, default=2267573)
    ap.add_argument("--ps", type=int, default=20)
    args = ap.parse_args()

    print("=" * 96)
    print("阶段 2 诊断：复现 App 侧的两个官方接口调用（mid=%d）" % args.mid)
    print("=" * 96)

    ck = load_cookie()
    get = make_getter(ck)

    status, body = get("https://api.bilibili.com/x/web-interface/nav")
    try:
        nav = json.loads(body)
        d = nav.get("data") or {}
        print("登录态：isLogin=%s uname=%s mid=%s" % (d.get("isLogin"), d.get("uname"), d.get("mid")))
    except Exception:
        print("登录态：无法解析 nav")

    mk = wbi_mixin(get)
    print("WBI mixin：%d 字符" % len(mk))
    if not mk:
        print("WBI 密钥缺失，无法继续")
        return 2

    # ---- 1) 投稿视频：App 取的是 data.list.vlist ----
    print("\n[1] /x/space/wbi/arc/search —— App 里对应「视频」路由")
    url = signed_url(
        "/x/space/wbi/arc/search",
        {
            "mid": args.mid,
            "ps": args.ps,
            "pn": 1,
            "order": "pubdate",
            "tid": 0,
            "platform": "web",
            "web_location": 1550101,
        },
        mk,
    )
    status, body = get(url)
    j = show("space/wbi/arc/search", status, body)
    if j:
        data = j.get("data") or {}
        lst = data.get("list")
        print("      data 的 keys        : %s" % list(data.keys()))
        if isinstance(lst, dict):
            print("      data.list 的 keys   : %s" % list(lst.keys()))
            vlist = lst.get("vlist")
            print("      vlist 条数          : %s" % (len(vlist) if isinstance(vlist, list) else vlist))
            if isinstance(vlist, list) and vlist:
                first = vlist[0]
                keys = ["bvid", "aid", "title", "pic", "created", "author", "mid", "description"]
                print("      首项关键字段：")
                for k in keys:
                    v = first.get(k)
                    if isinstance(v, str) and len(v) > 60:
                        v = v[:60] + "..."
                    print("        %-12s = %r" % (k, v))
            else:
                print("      !! vlist 为空 —— App 侧解析成 0 条是「如实反映服务端」")
        else:
            print("      !! data.list 不是对象：%r" % (lst,))

    # ---- 2) 动态：App 取的是 data.items ----
    print("\n[2] /x/polymer/web-dynamic/v1/feed/space —— App 里对应「动态」路由")
    url = signed_url(
        "/x/polymer/web-dynamic/v1/feed/space",
        {
            "host_mid": args.mid,
            "timezone_offset": -480,
            "platform": "web",
            "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote",
        },
        mk,
    )
    status, body = get(url)
    j = show("polymer/feed/space", status, body)
    if j:
        data = j.get("data") or {}
        print("      data 的 keys        : %s" % list(data.keys()))
        items = data.get("items")
        print("      items 条数          : %s" % (len(items) if isinstance(items, list) else items))
        if isinstance(items, list) and items:
            first = items[0]
            print("      首项 id_str/type    : %r / %r" % (first.get("id_str"), first.get("type")))
            mods = first.get("modules") or {}
            print("      modules 的 keys     : %s" % list(mods.keys()))
            author = (mods.get("module_author") or {})
            print("      author.name/pub_ts  : %r / %r" % (author.get("name"), author.get("pub_ts")))
            dyn = (mods.get("module_dynamic") or {})
            print("      dynamic 的 keys     : %s" % list(dyn.keys()))
            major = dyn.get("major") or {}
            print("      major.type          : %r" % major.get("type"))

    print("\n" + "=" * 96)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
