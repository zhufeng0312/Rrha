"""网络连通性诊断（不经 Schannel）。

背景：本机 curl.exe 走 Windows Schannel，在受限子进程里会失败于
    schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS
而 Git / Node / Python 用的是 OpenSSL，不受影响。

用法：
    python tools/netcheck.py                # 直连 + 代理都测
    python tools/netcheck.py --proxy=http://127.0.0.1:7897
"""

import sys
import time
import urllib.request
import urllib.error

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

DEFAULT_PROXY = "http://127.0.0.1:7897"

TARGETS = [
    "https://www.baidu.com",
    "https://api.bilibili.com/x/web-interface/nav",
    "https://comment.bilibili.com",
    "https://rsshub.app",
    "https://pub.dev",
    "https://storage.googleapis.com",
]


def fetch(url, proxy=None, timeout=25):
    if proxy:
        handlers = [urllib.request.ProxyHandler({"http": proxy, "https": proxy})]
    else:
        # 显式清空代理，避免受环境变量影响，保证测试结果可解释
        handlers = [urllib.request.ProxyHandler({})]
    opener = urllib.request.build_opener(*handlers)

    started = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read(400)
            elapsed = int((time.time() - started) * 1000)
            return True, "HTTP {}  {}ms  {}B".format(resp.status, elapsed, len(body))
    except urllib.error.HTTPError as e:
        elapsed = int((time.time() - started) * 1000)
        return True, "HTTP {}  {}ms  (HTTPError，说明链路是通的)".format(e.code, elapsed)
    except Exception as e:  # noqa: BLE001 - 诊断脚本，需要看到所有异常
        elapsed = int((time.time() - started) * 1000)
        return False, "FAIL  {}ms  {}: {}".format(elapsed, type(e).__name__, str(e)[:140])


def main():
    proxy = DEFAULT_PROXY
    for arg in sys.argv[1:]:
        if arg.startswith("--proxy="):
            proxy = arg.split("=", 1)[1]

    print("proxy = {}".format(proxy))
    print("=" * 78)
    for url in TARGETS:
        ok_direct, msg_direct = fetch(url, proxy=None)
        print("[直连] {}\n       {}".format(url, msg_direct))
        ok_proxy, msg_proxy = fetch(url, proxy=proxy)
        print("[代理] {}\n       {}".format(url, msg_proxy))
        print("-" * 78)


if __name__ == "__main__":
    main()
