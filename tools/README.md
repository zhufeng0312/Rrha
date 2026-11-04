# 探测脚本

这些脚本是用来**把「待实测」变成结论**的。它们不依赖 Flutter，只需要 Python 3
（`probe_bili_login.py` 额外需要 `segno` 生成二维码），并且**必须走代理** ——
本机直连极慢（实测 baidu 24 秒、bilibili 96 秒），而代理只要 170ms。

```bash
# 统一在命令行传代理，避免每个脚本各写一份
PROXY=http://127.0.0.1:7897
```

| 脚本 | 用途 | 典型用法 |
| --- | --- | --- |
| `netcheck.py` | 连通性诊断：直连 vs 代理、逐个目标站点测速 | `python tools/netcheck.py` |
| `probe_instances.py` | 批量探测公共 RSSHub 实例，分类报告可用/Cloudflare/5xx/TLS 失败 | `python tools/probe_instances.py` |
| `probe_danmaku.py` | 深挖弹幕接口真实形态：响应头、压缩方式、解压、字段号 | `python tools/probe_danmaku.py <cid>` |
| `live_probe.py` | 全链路实测：RSSHub 路由 → WBI 密钥 → 签名 → view → playurl → 弹幕 → 评论 | `python tools/live_probe.py` |
| `probe_bili_login.py` | **阶段 0**：B 站扫码登录闭环。本地生成二维码 → 轮询状态机 → 落地凭据 | `python tools/probe_bili_login.py` |
| `probe_bili_capabilities.py` | **阶段 0**：用登录态验证关注列表 / WBI 接口 / 历史 / 评论，判定新路线可行性 | `python tools/probe_bili_capabilities.py` |
| `probe_comment_retest.py` | **§7.4 悬案**：定位评论 `-403` 的根因（`pagination_str` 的字节形态），并验证分页与 `next_offset` 行为 | `python tools/probe_comment_retest.py --popular` |

## 关于阶段 0 的两个脚本

它们是为「App 内登录 + 直连官方 API」这条新路线做的可行性验证，结论见
[docs/HANDOVER.md](../docs/HANDOVER.md) §2.2。要点：

- `probe_bili_login.py` 复刻了扫码登录的完整状态机
  （`86101` 未扫码 / `86090` 已扫待确认 / `86038` 过期 / `0` 成功），
  可直接作为 Dart 侧实现的参考。
- **二维码必须本地生成**（用 `segno`）。**绝不能用在线二维码服务** ——
  那等于把登录凭据直接发给第三方。
- 凭据只写到 `C:\gradle-home\tmp\bili_login\session.json`（**项目外**），
  且日志**只打印凭据的键名与长度，绝不打印值**。该文件已被 `.gitignore` 的通配规则覆盖，
  请勿复制进工作区。

## 关于 `probe_comment_retest.py`

它是为了了结 HANDOVER §7.4 那个悬案写的：**应用内评论可用，脚本复现却持续 `-403`**，
一度被推断成「本机出口 IP 被风控」。结论是**和 IP 无关**（直连与代理结果完全一致）：

```python
json.dumps({"offset": ""})                        # '{"offset": ""}'  → -403
json.dumps({"offset": ""}, separators=(",", ":")) # '{"offset":""}'   → code=0
```

两者只差一个空格，而 Dart 侧的 `jsonEncode` 产出的正是**紧凑**形态 ——
这就是「应用内能用、脚本不能用」的全部原因。

同一个脚本还顺手确认了分页的一个坑：**`next_offset` 的值不一定推进**
（连续三页返回的 `next_offset` 完全相同，但每页内容都是全新的、0 重复），
所以判断「到底了没有」只能看 `cursor.is_end`。详见 HANDOVER §7.4。

## 为什么不用 curl

本机 `curl.exe` 走 Windows Schannel，在受限子进程里会失败于：

```
schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030E)
```

TCP 是通的、代理隧道也建立成功，唯独 TLS 握手拿不到凭据。
而 Git / Node / Python 用的是 OpenSSL，不受影响——所以这些脚本一律用 Python 的
`urllib`（OpenSSL 栈），并且显式设置 `ProxyHandler`。

如果你在正常环境里，用 curl 也一样，`docs/LIVE_CHECK.md` 里给的就是 curl 写法。

## 复现 2026-10-11 的结论

```bash
# 1. 网络层：确认代理可用
python tools/netcheck.py

# 2. 实例层：19 个公共实例里只有 1 个能返回 RSS
python tools/probe_instances.py

# 3. 接口层：WBI 签名是否被接受、playurl 给不给 durl、弹幕是什么格式
python tools/live_probe.py

# 4. 拿到 live_probe 输出的 cid，深挖弹幕
python tools/probe_danmaku.py <cid>
```

## `live_probe.py` 做了什么

它用**独立实现**复刻了 `lib/data/bili/wbi.dart` 的 WBI 签名算法
（同一张混淆表、同样的 `!'()*` 过滤与参数排序），然后用签名后的请求打
`/x/web-interface/view`。如果 B 站返回 `code:0`，就说明 Dart 侧的算法是对的
——这比单测里的黄金值更有说服力（黄金值只能证明「表没抄错」，证明不了「表是对的」）。

它还顺带验证了两个容易被误解的点：

- **未登录时 `nav` 返回 `code:-101`，但 `data.wbi_img` 仍然存在** —— 不要以为这是错误；
- **`/x/v1/dm/list.so` 现在返回的是裸 deflate 压缩的 XML**，不是 protobuf。
