"""阶段 0 验证：B 站扫码登录闭环。

目的：确认「App 内扫码登录」这条路线真的可行 —— 即
  1. /x/passport-login/web/qrcode/generate 能拿到 qrcode_key
  2. 本地生成二维码（绝不经过任何在线服务，否则等于泄露登录凭据）
  3. /x/passport-login/web/qrcode/poll 轮询能走到成功态
  4. 成功时响应头里确实带回了 SESSDATA / bili_jct / DedeUserID

安全约定：
  - 二维码在本地生成，不外发
  - 凭据只写到本机临时目录，且**日志只打印凭据的键名与长度，绝不打印值**
  - 本脚本是一次性验证工具，不是产品代码
"""

import http.cookiejar
import json
import os
import sys
import time
import urllib.request

import segno

OUT = r"C:\gradle-home\tmp\bili_login"
QR_PATH = os.path.join(OUT, "qr.png")
SESSION_PATH = os.path.join(OUT, "session.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

# 轮询状态码（B 站约定）
POLL_OK = 0
POLL_EXPIRED = 86038
POLL_SCANNED = 86090
POLL_WAITING = 86101


def main() -> int:
    os.makedirs(OUT, exist_ok=True)

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.ProxyHandler({}),  # 直连，模拟手机网络路径
    )
    opener.addheaders = [
        ("User-Agent", UA),
        ("Referer", "https://www.bilibili.com/"),
    ]

    # ---------- 1) 申请二维码 ----------
    resp = opener.open(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/generate",
        timeout=25,
    )
    payload = json.loads(resp.read().decode("utf-8"))
    if payload.get("code") != 0:
        print("GENERATE_FAILED code=%s msg=%s" % (payload.get("code"), payload.get("message")))
        return 2

    data = payload["data"]
    qrcode_key = data["qrcode_key"]
    login_url = data["url"]
    print("GENERATE_OK key=%s...%s" % (qrcode_key[:12], qrcode_key[-4:]))

    # ---------- 2) 本地生成二维码 ----------
    # scale 调大以便手机屏幕识别；border 留足静默区
    segno.make(login_url, error="m").save(QR_PATH, scale=12, border=4)
    print("QR_SAVED %s" % QR_PATH)
    print("等待扫码（有效期约 180 秒）...")
    sys.stdout.flush()

    # ---------- 3) 轮询 ----------
    poll_url = (
        "https://passport.bilibili.com/x/passport-login/web/qrcode/poll"
        "?qrcode_key=" + qrcode_key
    )
    deadline = time.time() + 180
    last_state = None
    attempt = 0

    while time.time() < deadline:
        attempt += 1
        try:
            r = opener.open(poll_url, timeout=25)
            body = json.loads(r.read().decode("utf-8"))
        except Exception as exc:  # 网络抖动不算失败，继续轮询
            print("  [%02d] poll error: %s" % (attempt, str(exc)[:60]))
            time.sleep(2)
            continue

        inner = body.get("data") or {}
        state = inner.get("code")
        if state is None:
            state = body.get("code")

        if state != last_state:
            label = {
                POLL_WAITING: "未扫码",
                POLL_SCANNED: "已扫码，等待确认",
                POLL_OK: "登录成功",
                POLL_EXPIRED: "二维码已过期",
            }.get(state, "未知状态(%s)" % state)
            print("  [%02d] state=%s %s" % (attempt, state, label))
            sys.stdout.flush()
            last_state = state

        if state == POLL_OK:
            break
        if state == POLL_EXPIRED:
            print("EXPIRED 请重新运行脚本")
            return 3

        time.sleep(2)
    else:
        print("TIMEOUT 超时未完成扫码")
        return 4

    # ---------- 4) 落地凭据（只记键名与长度，绝不打印值）----------
    cookies = {c.name: c.value for c in jar}
    with open(SESSION_PATH, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "cookies": cookies,
                "login_url": login_url,
                "obtained_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            },
            fh,
            ensure_ascii=False,
            indent=2,
        )

    print("LOGIN_OK 凭据已写入 %s" % SESSION_PATH)
    print("获得 %d 个 cookie：" % len(cookies))
    for name, value in sorted(cookies.items()):
        print("   %-14s 长度=%d" % (name, len(value)))

    # 关键凭据是否齐全（只报存在性）
    for must in ("SESSDATA", "bili_jct", "DedeUserID"):
        print("   [%s] %s" % ("有" if must in cookies else "缺", must))

    print("DONE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
