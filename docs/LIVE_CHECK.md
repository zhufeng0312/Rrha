# 首次联网后的实测清单

本工程的全部线上接口判断都标为「待实测」——编写环境没有外网，无法验证任何一条。
这份清单把「待实测」变成可执行的步骤：**先用 curl 确认接口形态，再决定是否要改代码**。

每一条都给出了「预期」「失败时怎么办」和「要改哪个文件」。

---

## 0. 准备

```bash
BASE=https://rsshub.app      # 或你自己找到的其他公共实例
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
```

找一个真实存在的 B 站 UID（例如 `2267573`）和微博 UID 备用。

---

## 1. RSSHub：B 站视频路由

```bash
curl -s -o /dev/null -w '%{http_code}\n' -A "$UA" "$BASE/bilibili/user/video/2267573"
curl -s -A "$UA" "$BASE/bilibili/user/video/2267573?limit=5" | head -c 2000
```

| 结果 | 含义 | 动作 |
| --- | --- | --- |
| `200` + `<item>` | 路由可用 | 无需改动 |
| `403` | 实例要求 Cookie 或封了该路由 | 换实例；UI 会显示「公共实例拒绝访问（403）」 |
| `429` | 限流 | 稍后重试；UI 文案已按需求固定为「公共 RSSHub 实例限流，请稍后重试或更换实例」 |
| `503` | 实例过载 | 换实例 |
| `200` 但无 `<item>` | 实例侧未配置 | 看响应体里是否有 `cookie` 等关键字，代码会自动归类提示 |

**同时要核对字段结构**（决定 `lib/data/rss/rss_parser.dart` 的映射是否要校准）：

```bash
# 看 description 里是否有 <img src="封面">
curl -s -A "$UA" "$BASE/bilibili/user/video/2267573?limit=1" | grep -o 'description[^<]*' | head -c 500
# 看 pubDate 的格式（RFC822 / ISO）
curl -s -A "$UA" "$BASE/bilibili/user/video/2267573?limit=1" | grep -o '<pubDate>[^<]*' | head -3
# 看是否有 media:thumbnail / author / dc:creator
curl -s -A "$UA" "$BASE/bilibili/user/video/2267573?limit=1" | grep -Eo '<(media:thumbnail|author|dc:creator)[^>]*>' | head -5
```

判读要点：

- `description` 里若**没有** `<img>`，封面会为空 → 需要改用 `media:thumbnail` 或 `enclosure`（`_cover()` 已按这个优先级实现，只要字段存在就能取到）；
- `pubDate` 若是 `Wed, 02 Oct 2024 13:00:00 +0800` → `TimeParse` 已支持；若是别的形态（例如纯时间戳），检查 `test/core/utils_test.dart` 是否覆盖，没有就补一个用例。

---

## 2. RSSHub：B 站动态路由

```bash
curl -s -A "$UA" "$BASE/bilibili/user/dynamic/2267573?limit=5" | head -c 2000
```

重点看：动态里如果带了视频，`<link>` 或 `<description>` 里是否出现 `BV`。代码会从两者里都找 BV
（`RssParser._videoRef`），所以只要有一处出现就能识别成可播条目。

---

## 3. RSSHub：微博路由（预计失败）

```bash
curl -s -o /dev/null -w '%{http_code}\n' -A "$UA" "$BASE/weibo/user/1234567890"
curl -s -A "$UA" "$BASE/weibo/user/1234567890?limit=3" | head -c 800
```

| 结果 | 结论 |
| --- | --- |
| `200` + 有 `<item>` | 这个实例恰好配了 `WEIBO_COOKIE`，微博源可用，代码无需改动 |
| `403` / `432` / 空 feed / 含 `cookie` 字样的错误页 | **符合预期**。RSSHub 的微博路由要求实例侧配置 `WEIBO_COOKIE`，公共实例不会带。UI 会显示「该实例未配置微博 Cookie」 |

如果你有自己的实例（配了 `WEIBO_COOKIE`），把它填进「设置 → 微博源专属实例」，
客户端代码完全复用，不需要改一行。

---

## 4. B 站：WBI 密钥（注意未登录的返回码）

```bash
curl -s -A "$UA" -H 'Referer: https://www.bilibili.com/' \
  'https://api.bilibili.com/x/web-interface/nav' | head -c 600
```

| 结果 | 含义 |
| --- | --- |
| `"code":0` 且 `data.wbi_img` 有 `img_url`/`sub_url` | 正常，密钥可直接用 |
| `"code":-101`（账号未登录）**但** `data.wbi_img` 仍然存在 | **这也是正常的**——代码专门处理了这种情况（见 `BiliClient._refreshKeys`），不要以为它是错误 |

判读：只要 `data.wbi_img.img_url` 存在，签名就能工作。两个 URL 的文件名各取 32 字符拼成 64 字符 `orig`。

---

## 5. B 站：playurl 到底给不给 MP4（决定走哪个通道）

把 `<BV>`、`<CID>` 换成真实值：

```bash
# 先取 cid
curl -s -A "$UA" -H 'Referer: https://www.bilibili.com/' \
  'https://api.bilibili.com/x/web-interface/view?bvid=<BV>' | head -c 400

# 再试单文件 MP4（fnval=1）
curl -s -A "$UA" -H 'Referer: https://www.bilibili.com/' \
  'https://api.bilibili.com/x/player/wbi/playurl?bvid=<BV>&cid=<CID>&qn=64&fnver=0&fnval=1&fourk=1'
```

| 结果 | 含义 | 动作 |
| --- | --- | --- |
| `data.durl` 非空 | 通道 A（video_player）可用 | 无需改动 |
| `data.durl` 为空、只有 `data.dash` | 走通道 B（media_kit） | 无需改动，代码会自动二次请求 `fnval=4048` |
| `code:-352` | 风控：签名不对或设备指纹被拒 | 先确认是否开了「匿名设备指纹」；仍失败则是 WBI 算法/混淆表变了 → 跑 `flutter test test/bili/wbi_test.dart`，黄金值断言会直接暴露 |

**注意**：上面的 curl 没有 WBI 签名，`-352` 是正常预期（客户端会签名）。
真正要验证的是「签名后的 `fnval=1` 会不会返回 `durl`」——那只能用 App 实测：
播放页信息行会显示 `通道A(MP4 qn=…)` 或 `通道B(DASH …)`。

---

## 6. 弹幕：两条通道分别测

```bash
# 通道 1：protobuf（应该是 zlib 压缩流，前两字节 0x78 0x9c）
curl -s -A "$UA" -H 'Referer: https://www.bilibili.com/' \
  'https://api.bilibili.com/x/v1/dm/list.so?oid=<CID>' \
  -o dm.bin -w 'http=%{http_code} size=%{size_download} type=%{content_type}\n'
xxd dm.bin | head -2

# 通道 2：传统 XML
curl -s -A "$UA" -H 'Referer: https://www.bilibili.com/' \
  'https://comment.bilibili.com/<CID>.xml' -o dm.xml -w 'http=%{http_code} size=%{size_download}\n'
head -c 400 dm.xml
```

| 观察 | 结论 |
| --- | --- |
| 通道 1 返回二进制、`xxd` 首字节是 `78 9c` | zlib 路径正确，`DanmakuParser.maybeInflate` 会解压 |
| 通道 1 首字节不是 `0x78` | 可能已被 CDN 解压（直接是 protobuf），解析器已兼容 |
| 通道 1 返回 `412` / 需要 wbi | 该通道已收紧，只能依赖通道 2 |
| 通道 2 返回 `<i><d p="…">` | XML 通道可用 |
| 两条都失败 | **播放不受影响**，弹幕层会显示「弹幕加载失败 + 重试」 |

如果两条都失效，需要给 `BiliClient.danmaku()` 加第三条通道（例如 `/x/v2/dm/web/seg.so` 带 wbi 签名），
`DanmakuParser` 是纯函数，补一个解析分支 + fixture 测试即可。

---

## 7. B 站评论：风控程度

```bash
curl -s -A "$UA" -H 'Referer: https://www.bilibili.com/' \
  'https://api.bilibili.com/x/v2/reply/wbi/main?oid=<AID>&type=1&mode=3&ps=20&plat=1&pagination_str=%7B%22offset%22%3A%22%22%7D' \
  | head -c 600
```

（同样因为没签名可能直接 `-352`，这里只看**接口是否存在**：`-352` 说明接口在、只是要签名；
`404` 说明路径变了。）

App 内的判读标准：

| App 里看到 | 结论 |
| --- | --- |
| 正常 20 条 + 可以加载更多 | 无需登录态，最好情况 |
| 只有置顶/热门几条，且 `is_end` 为 true | 接口在无登录态下只给部分数据 → **如实展示**，不伪造 |
| 错误卡片 + 重试按钮，文案含「-352」 | 需要登录态 → 下一步是允许用户粘贴 Cookie 存入钥匙串（`SecureStore` 已就位） |

---

## 8. 弹幕帧率（唯一需要真机的验收项）

```bash
flutter run --profile          # debug 模式读数无意义
```

进入「设置 → 弹幕 → 弹幕压力测试」，等页面稳定 10 秒后读数字：

| 读数 | 判定 |
| --- | --- |
| ≥45 fps | 达标 |
| 30~45 fps | 未达标：先确认是 profile 模式、且不是低端机；再看是否开了「同屏上限 500」 |
| <30 fps | 大概率是我的绘制实现有问题，把 `_avgFrameMs` 和设备型号发我 |

如果未达标，最有价值的排查顺序是：

1. 确认**不是 debug 模式**（这是最常见的误判）；
2. 看「文本缓存」是否有淘汰抖动（诊断行会显示 `文本缓存 n/600`）——频繁淘汰说明缓存太小；
3. 看是否开了透明度 <100%（会启用 `saveLayer` 离屏合成）；
4. 把同屏上限从 500 降到 200 复测，如果帧率明显回升说明瓶颈在绘制条数。

---

## 9. 冷启动时间

```bash
flutter run --profile
# 观察 DevTools → Performance → 首帧时间；或看启动日志里的
# "The Flutter engine started" 到 "first frame" 的间隔
```

`main()` 里只 await 了 `SharedPreferences.getInstance()`，缓存目录、Dio、B 站客户端
全部惰性初始化，正常应该远低于 2 秒。若超时，检查是否在 `main` 之前加了别的东西。

---

## 10. 回填测试

任何一条实测结果与代码假设不符时，**先补一个 fixture 测试再改代码**：

```bash
# 把真实响应脱敏后贴成测试里的字符串常量，例如
# test/rss/rss_parser_test.dart 顶部的 _biliVideoFeed
flutter test
```

这是本工程唯一可靠的「结构变更探针」——因为没有网络，接口形态一旦变化只有测试能提前发现。
