#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
微博视频卡片直链探针
================================================

目标：把「微博视频到底怎么拿到可播直链」从猜测变成实测结论。

已知前提（见 docs/HANDOVER.md §7.17）：
  `mblog.page_info.media_info` 在历史采样里 **0 条样本**，解析器里的字段名全是
  按常见候选猜的（stream_url / mp4_hd_url / ...）。用户这次给了一条真实视频：
  https://weibo.com/tv/show/1034:5358370303967334

本探针要回答四个问题：
  Q1 不带登录 cookie，能否拿到播放信息？（能 → 卡片可直接出直链）
  Q2 真实 JSON 里视频地址到底挂在哪个字段？（决定解析器怎么改）
  Q3 直链播放需要什么请求头？（Referer 缺失会不会 403）
  Q4 封面 / 时长 / 分辨率从哪取？（卡片排版要用）

只做只读 GET/POST，不伪造 cookie、不换 IP、不绕过风控。
输出：.env/weibo_video_probe.md（脱敏，直链只保留 host + 路径前缀 + 参数名）

用法：
  python tools/probe_weibo_video.py
  python tools/probe_weibo_video.py --fid 1034:5358370303967334
"""

import argparse
import json
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

OUT = "D:\\Rrha\\.env\\weibo_video_probe.md"
PROXY = "http://127.0.0.1:7897"
UA = (
    "Mozilla/5.0 (Linux; Android 16; BKQ-AN10 Build/HONORBKQ-AN10) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 "
    "Chrome/120.0 Mobile Safari/537.36"
)
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

lines = []


def say(text=""):
    print(text)
    lines.append(text)


def redact(url):
    """直链脱敏：保留 scheme/host/路径前缀/参数名，值一律打掉（可能带签名）。"""
    try:
        p = urllib.parse.urlsplit(url)
    except Exception:
        return "<unparsable>"
    names = sorted({k for k, _ in urllib.parse.parse_qsl(p.query)})
    path = p.path
    if len(path) > 60:
        path = path[:57] + "..."
    tail = ("?" + ",".join(names)) if names else ""
    return "{}://{}{}{}".format(p.scheme, p.netloc, path, tail)


def fetch(url, *, data=None, headers=None, proxy=PROXY, timeout=25, method=None):
    hdrs = {"User-Agent": UA, "Accept": "*/*"}
    if headers:
        hdrs.update(headers)
    body = None
    if data is not None:
        body = data.encode("utf-8")
        hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    op = urllib.request.build_opener(*handlers, urllib.request.HTTPSHandler(context=CTX))
    t0 = time.time()
    try:
        with op.open(req, timeout=timeout) as r:
            raw = r.read()
            return {
                "status": r.status,
                "headers": dict(r.headers),
                "body": raw,
                "ms": int((time.time() - t0) * 1000),
                "error": None,
            }
    except urllib.error.HTTPError as e:
        raw = b""
        try:
            raw = e.read()
        except Exception:
            pass
        return {
            "status": e.code,
            "headers": dict(e.headers or {}),
            "body": raw,
            "ms": int((time.time() - t0) * 1000),
            "error": None,
        }
    except Exception as e:
        return {
            "status": None,
            "headers": {},
            "body": b"",
            "ms": int((time.time() - t0) * 1000),
            "error": "{}: {}".format(type(e).__name__, e),
        }


def shape(obj, depth=0, maxdepth=4, prefix=""):
    """打印 JSON 形状（类型 + key），值是字符串的只打长度。"""
    pad = "  " * depth
    out = []
    if isinstance(obj, dict):
        for k in obj:
            v = obj[k]
            out.extend(shape(v, depth + 1, maxdepth, prefix + "." + str(k)))
    elif isinstance(obj, list):
        if obj:
            out.append("{}[] len={}".format(pad + prefix, len(obj)))
            if depth < maxdepth:
                out.extend(shape(obj[0], depth + 1, maxdepth, prefix + "[0]"))
        else:
            out.append("{}[] len=0".format(pad + prefix))
    else:
        t = type(obj).__name__
        if isinstance(obj, str):
            out.append("{} : {} len={}".format(pad + prefix, t, len(obj)))
        else:
            out.append("{} : {} = {}".format(pad + prefix, t, obj))
    return out


def json_of(resp):
    try:
        return json.loads(resp["body"].decode("utf-8", "replace"))
    except Exception:
        return None


def find_url_keys(obj, path="", hits=None, saw=None):
    """递归找「像视频地址」的字符串字段，以及记录所有 key 名。"""
    if hits is None:
        hits = []
    if saw is None:
        saw = set()
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = "{}.{}".format(path, k)
            saw.add(k)
            if isinstance(v, str) and re.search(r"\.(mp4|m3u8)|weibocdn|video\.weibo", v, re.I):
                hits.append((p, v))
            else:
                find_url_keys(v, p, hits, saw)
    elif isinstance(obj, list):
        for i, v in enumerate(obj[:3]):
            find_url_keys(v, "{}[{}]".format(path, i), hits, saw)
    return hits, saw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fid", default="1034:5358370303967334")
    ap.add_argument("--no-proxy", action="store_true")
    args = ap.parse_args()
    proxy = None if args.no_proxy else PROXY

    say("# 微博视频直链探针报告")
    say()
    say("时间：{}".format(time.strftime("%Y-%m-%d %H:%M:%S")))
    say("fid：`{}`".format(args.fid))
    say("代理：{}".format(proxy or "直连"))
    say("cookie：**不带**（游客态）")
    say()

    oid = args.fid

    # ---------- S1：weibo.com/tv/api/component（历史上游客可用）----------
    say("## S1 `weibo.com/tv/api/component`（POST，游客态）")
    say()
    url1 = "https://weibo.com/tv/api/component?page={}".format(
        urllib.parse.quote("/tv/show/" + oid, safe="")
    )
    payload = json.dumps(
        {"Component_Play_Playinfo": {"oid": oid}}, separators=(",", ":")
    )
    r1 = fetch(
        url1,
        data="data=" + urllib.parse.quote(payload),
        headers={
            "Referer": "https://weibo.com/tv/show/" + oid,
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/plain, */*",
        },
        proxy=proxy,
    )
    say("- HTTP {} · {} ms · {} bytes".format(r1["status"], r1["ms"], len(r1["body"])))
    if r1["error"]:
        say("- 错误：`{}`".format(r1["error"]))
    j1 = json_of(r1)
    if j1 is None:
        say("- 非 JSON，前 200 字符：`{}`".format(
            r1["body"][:200].decode("utf-8", "replace").replace("\n", " ")))
    else:
        say("- 顶层 key：`{}`".format(", ".join(sorted(j1.keys()))))
        hits, _ = find_url_keys(j1)
        say("- 像视频地址的字段：{}".format(len(hits)))
        for p, v in hits[:12]:
            say("  - `{}` → `{}`".format(p, redact(v)))
        pi = None
        for path in ("data.Component_Play_Playinfo", "Component_Play_Playinfo"):
            cur = j1
            ok = True
            for seg in path.split("."):
                if isinstance(cur, dict) and seg in cur:
                    cur = cur[seg]
                else:
                    ok = False
                    break
            if ok and isinstance(cur, dict):
                pi = cur
                break
        if pi:
            say()
            say("  `Playinfo` 全部 key（{} 个）：".format(len(pi)))
            say("  ```")
            for k in sorted(pi.keys()):
                v = pi[k]
                if isinstance(v, str):
                    if re.search(r"https?://", v):
                        say("  {} : str(len={}) {}".format(k, len(v), redact(v)))
                    else:
                        say("  {} : str = {}".format(k, v[:60]))
                elif isinstance(v, (int, float, bool)) or v is None:
                    say("  {} : {} = {}".format(k, type(v).__name__, v))
                else:
                    say("  {} : {}".format(k, type(v).__name__))
            say("  ```")
            urls = pi.get("urls")
            if isinstance(urls, dict):
                say()
                say("  **`urls` 质量档位表**（这就是卡片的可播候选）：")
                for k, v in urls.items():
                    say("  - `{}` → `{}`".format(k, redact(str(v))))
    say()

    # ---------- S2：m.weibo.cn 状态页 SSR ----------
    time.sleep(1.5)
    say("## S2 `m.weibo.cn/detail/<fid>`（SSR，游客态）")
    say()
    url2 = "https://m.weibo.cn/detail/" + oid
    r2 = fetch(url2, headers={"Referer": "https://m.weibo.cn/"}, proxy=proxy)
    say("- HTTP {} · {} ms · {} bytes".format(r2["status"], r2["ms"], len(r2["body"])))
    if r2["error"]:
        say("- 错误：`{}`".format(r2["error"]))
    txt2 = r2["body"].decode("utf-8", "replace")
    for needle in ("page_info", "media_info", "stream_url", "mp4_", "playInfo", "$render_data"):
        say("- 含 `{}`：{}".format(needle, "✅" if needle in txt2 else "❌"))
    m = re.search(r"\$render_data\s*=\s*(\[.*?\])\s*</script>", txt2, re.S)
    if m:
        say("- 找到 `$render_data`（长度 {}）".format(len(m.group(1))))
        try:
            rd = json.loads(m.group(1))
            mblog = None
            if rd and isinstance(rd, list):
                st = rd[0].get("status") if isinstance(rd[0], dict) else None
                if isinstance(st, dict):
                    mblog = st
            if mblog:
                pi = mblog.get("page_info")
                say("- `status.page_info` 存在：{}".format("✅" if pi else "❌"))
                if isinstance(pi, dict):
                    say("- `page_info` key：`{}`".format(", ".join(sorted(pi.keys()))))
                    mi = pi.get("media_info")
                    if isinstance(mi, dict):
                        say()
                        say("  **`media_info` 真实字段（{} 个）**：".format(len(mi)))
                        say("  ```")
                        for k in sorted(mi.keys()):
                            v = mi[k]
                            if isinstance(v, str):
                                if re.search(r"https?://", v):
                                    say("  {} : str(len={}) {}".format(k, len(v), redact(v)))
                                else:
                                    say("  {} : str = {}".format(k, v[:60]))
                            elif isinstance(v, (int, float, bool)) or v is None:
                                say("  {} : {} = {}".format(k, type(v).__name__, v))
                            else:
                                say("  {} : {} keys={}".format(
                                    k, type(v).__name__,
                                    len(v) if hasattr(v, "__len__") else "?"))
                        say("  ```")
                    else:
                        say("- ⚠️ `media_info` 不是 dict：{}".format(type(mi).__name__))
        except Exception as e:
            say("- `$render_data` 解析失败：`{}`".format(e))
    else:
        say("- ❌ 没找到 `$render_data`")
        say("- 前 300 字符：`{}`".format(txt2[:300].replace("\n", " ")))
    say()

    # ---------- S3：直链能否直接播 ----------
    say("## S3 直链可达性（带/不带 Referer）")
    say()
    cand = []
    if j1:
        pi = None
        cur = j1
        for seg in ("data", "Component_Play_Playinfo"):
            if isinstance(cur, dict) and seg in cur:
                cur = cur[seg]
            else:
                cur = None
                break
        if isinstance(cur, dict):
            pi = cur
        if pi:
            for k, v in (pi.get("urls") or {}).items():
                if isinstance(v, str) and v:
                    cand.append((k, v))
            for k in ("stream_url", "stream_url_hd", "mp4_720p_mp4"):
                v = pi.get(k)
                if isinstance(v, str) and v:
                    cand.append((k, v))
    if not cand:
        say("- 无候选直链（S1 未拿到），跳过")
    else:
        seen = set()
        uniq = []
        for k, v in cand:
            if v in seen:
                continue
            seen.add(v)
            uniq.append((k, v))
        for label, u in uniq[:4]:
            time.sleep(1.2)
            r_no = fetch(u, headers={}, proxy=proxy, timeout=20)
            time.sleep(1.2)
            r_ref = fetch(
                u,
                headers={"Referer": "https://weibo.com/"},
                proxy=proxy,
                timeout=20,
            )
            say("- `{}`".format(label))
            say("  - 无 Referer：HTTP {} · {} bytes".format(r_no["status"], len(r_no["body"])))
            say("  - 带 Referer：HTTP {} · {} bytes".format(r_ref["status"], len(r_ref["body"])))
            ct = r_ref["headers"].get("Content-Type") or r_no["headers"].get("Content-Type")
            say("  - Content-Type：`{}`".format(ct))
    say()

    # ---------- S4：结论 ----------
    say("## S4 结论")
    say()
    say("- S1 游客可用：{}".format("✅" if (j1 and r1["status"] == 200) else "❌"))
    say("- 直链候选数：{}".format(len(cand)))
    say()

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("\n写入：{}".format(OUT))


if __name__ == "__main__":
    main()
