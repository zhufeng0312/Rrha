"""探测 RSSHub 公共实例的可用性。

背景：实测发现 https://rsshub.app 现在挂了 Cloudflare 的人机校验
（返回 403 + "Just a moment..." 挑战页），普通 HTTP 客户端拿不到 RSS。
这直接决定 Rrha 的默认基地址该填什么、以及 403 的处理文案该怎么写。

用法：
    python tools/probe_instances.py
"""

import re
import time
import urllib.error
import urllib.request

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
PROXY = "http://127.0.0.1:7897"

# 官方文档站 https://docs.rsshub.app/zh/guide/instances 抓取到的实例列表
INSTANCES = [
    "https://rsshub.app",
    "https://isrss.com",
    "https://rsshub.isrss.com",
    "https://rss.4040940.xyz",
    "https://rss.datuan.dev",
    "https://rss.littlebaby.life/rsshub",
    "https://rss.owo.nz",
    "https://rss.spriple.org",
    "https://rss.wudifeixue.com",
    "https://rsshub-balancer.virworks.moe",
    "https://rsshub.cups.moe",
    "https://rsshub.email-once.com",
    "https://rsshub.rss.tips",
    "https://rsshub.umzzz.com",
    "https://rsshub.henry.wang",
    "https://rsshub.pseudoyu.com",
    "https://rsshub.rssforever.com",
    "https://rsshub.ktachibana.party",
    "https://rsshub.owo.nz",
]

UID = "2267573"
ROUTE = "/bilibili/user/video/{}?limit=2".format(UID)


def opener():
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
    )


def probe(base):
    url = base.rstrip("/") + ROUTE
    started = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with opener().open(req, timeout=25) as r:
            body = r.read(200000)
            ms = int((time.time() - started) * 1000)
            text = body.decode("utf-8", "replace")
            items = len(re.findall(r"<item>", text))
            title = ""
            m = re.search(r"<title>(.*?)</title>", text, re.S)
            if m:
                title = m.group(1).strip()[:40]
            kind = classify(r.status, text, items)
            return r.status, ms, len(body), items, title, kind
    except urllib.error.HTTPError as e:
        ms = int((time.time() - started) * 1000)
        try:
            text = e.read(4000).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            text = ""
        return e.code, ms, 0, 0, "", classify(e.code, text, 0)
    except Exception as e:  # noqa: BLE001
        ms = int((time.time() - started) * 1000)
        return None, ms, 0, 0, "", "{}: {}".format(type(e).__name__, str(e)[:60])


def classify(status, text, items):
    low = text.lower()
    if items > 0:
        return "✅ 可用"
    if "just a moment" in low or "cf-chl" in low or "challenge" in low:
        return "⛔ Cloudflare 人机校验"
    if status == 403:
        return "⛔ 403"
    if status == 404:
        return "❓ 404（可能不是 RSSHub）"
    if status == 429:
        return "⏳ 限流 429"
    if status is None:
        return "❌ 连接失败"
    if status >= 500:
        return "❌ 服务端错误 {}".format(status)
    if "cookie" in low:
        return "🔑 需要 Cookie"
    if status == 200:
        return "⚠️ 200 但无 item"
    return "❓ HTTP {}".format(status)


def main():
    print("探测 {} 个公共实例（route = {}）".format(len(INSTANCES), ROUTE))
    print("=" * 96)
    usable = []
    for base in INSTANCES:
        status, ms, size, items, title, kind = probe(base)
        print("{:<42} {:>6}  {:>6}ms  {:>7}B  item={:<3} {}".format(
            base, str(status), ms, size, items, kind))
        if "✅" in kind:
            usable.append(base)
    print("=" * 96)
    if usable:
        print("可用实例（可作为默认基地址）：")
        for u in usable:
            print("   " + u)
    else:
        print("没有找到可直接返回 RSS 的公共实例。")
        print("结论：公共实例普遍上了 Cloudflare 反爬，客户端直连拿不到数据；")
        print("      需要自建实例，或改用带鉴权的转发方案。")


if __name__ == "__main__":
    main()
