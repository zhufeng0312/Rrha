# 多会话协作方案（总设计）

> **面向**：用户 + 三个开发会话（B 站 / 微博 / 界面）
> **生成**：2026-10-18，工程 `D:\Rrha`（App `0.2.1+4`，`flutter test` 434 全绿，**无 git 仓库**）
> **本文档回答一个问题**：三个会话同时开工，会不会互相踩？怎么安排才不踩。

---

## 1. 结论先说

**会冲突，而且不是小概率事件。** 但有解，分两种情况：

| 方案 | 可行性 | 代价 | 结论 |
| --- | --- | --- | --- |
| **A. 三个会话并行，改同一个 `D:\Rrha`** | ❌ 不可行 | 会互相覆盖文件、抢 Gradle 锁、抢同一台手机 | **不要这样做** |
| **B. 三个会话并行，各自用独立目录副本**（如 `D:\Rrha-ui`），我在主目录合并 | ⚠️ 可行但笨重 | 每份副本 + 手工 diff 合并；项目无 git，合并全靠人眼 | 仅在「真的赶时间」时用 |
| **C. 串行推进 + 我这一个会话管公共层**（推荐） | ✅ 可行 | 总时长是各段之和 | **建议按这个来** |

**推荐形态**：

```
           ┌───────────────────────────────┐
           │  本会话（总设计 + 公共层）      │
           │  providers / timeline_repo /   │
           │  合并逻辑 / 最终验收 / 文档     │
           └───────────┬───────────────────┘
                       │ 交接（串行）
     ┌─────────────────┼─────────────────┐
     ▼                 ▼                 ▼
 ┌────────┐      ┌──────────┐      ┌────────┐
 │ 界面会话 │      │ B站会话   │      │ 微博会话 │
 │ 卡片/主题│      │ 播放/数据 │      │ 微博取数 │
 └────────┘      └──────────┘      └────────┘
```

---

## 2. 冲突到底在哪（具体到文件）

### 2.1 同一个文件被多人改 → 直接覆盖

| 文件 | 界面 | B 站 | 微博 | 冲突等级 |
| --- | --- | --- | --- | --- |
| `lib/features/timeline/content_card.dart` | ✅ 改卡片结构 | ⚠️ 可能加时长角标 | ⚠️ 可能加微博角标 | **高** |
| `lib/features/timeline/timeline_page.dart` | ✅ 列表/空态 | — | ✅ `_WeiboModeHint` 文案 | **中** |
| `lib/providers.dart` | ✅ `setMode` 快照 | ✅ 登录态重建 | ✅ 关注流合并 | **最高**（三个都要碰） |
| `lib/data/repo/timeline_repo.dart` | — | ⚠️ | ✅ 双源合并 | **中** |
| `lib/core/storage/prefs.dart` | ✅ 新增 UI 偏好 | ✅ 新增播放偏好 | — | **中** |
| `lib/features/player/player_page.dart` | ✅ 界面重排 | ✅ 统计/简介/清晰度 | — | **高** |
| `docs/HANDOVER.md`、`README.md` | ✅ | ✅ | ✅ | **高**（append 型，仍会冲突） |

### 2.2 工程级冲突（比文件冲突更难缠）

| 冲突源 | 表现 |
| --- | --- |
| **`build/` 与 Gradle 锁** | 两个会话同时 `assembleProfile` → `Timeout waiting to lock buildOutputCleanup`，或者互相把对方产物覆盖掉 |
| **`flutter test` 并发** | 抢 `.dart_tool` 锁，偶发 `Failed to load kernel` |
| **只有一台真机** | `adb install -r` 会杀掉正在跑的 App。A 会话正在截图取证，B 会话装了个包 → A 的截图全是别的东西 |
| **没有 git** | 没有任何回滚手段。改坏了只能凭记忆恢复 |
| **`.env/` 探针脚本** | 多个会话都会往里加 `probe_*.py`，文件名撞了会互相覆盖（好在影响小） |

---

## 3. 方案 C：串行 + 公共层归我（推荐）

### 3.1 谁拥有什么

**本会话（总设计）独占**：

| 文件 | 理由 |
| --- | --- |
| `lib/providers.dart` | 三个模块的状态都在这里，最容易被三方同时改 |
| `lib/data/repo/timeline_repo.dart` | B 站 feed 与微博的合并逻辑 |
| `lib/data/repo/subscription_repo.dart` | 订阅源增删改 |
| `docs/HANDOVER.md`、`README.md` | 交付文档的最终归属 |
| 版本号（`android/local.properties`） | 只能有一处升 |

**三个开发会话各自的领地**：

| 会话 | 可改（独占） | 只能读 |
| --- | --- | --- |
| **界面** | `lib/main.dart`（主题）、`lib/features/timeline/content_card.dart`、`lib/features/timeline/timeline_page.dart`、`lib/widgets/*`（除 `native_webview.dart`）、`lib/features/player/player_controls_overlay.dart`、**以及全仓库「颜色硬编码」的单行改动**（见下） | `providers.dart`、`content_item.dart`、`lib/features/player/player_adapter.dart` |
| **B 站** | `lib/data/bili/*`、`lib/features/player/*`（除 `player_controls_overlay.dart`）、`lib/features/comments/*`、`lib/features/settings/*` | `content_card.dart`、`providers.dart` |
| **微博** | `lib/data/weibo/*`、`lib/features/weibo/*`、`lib/widgets/native_webview.dart`、`lib/core/net/weibo_cookie_source.dart` | `content_card.dart`、`providers.dart` |

> **交界处**：`providers.dart`、`timeline_repo.dart`、`content_item.dart`、`prefs.dart` **一律由我改**，会话提需求即可；`content_card.dart` 是界面的产物，归**界面会话**。

> ⚠️ **亮色化是一次全局排他改动**（2026-10-18 新增）。深色主题下散落在各页面里的硬编码颜色（清单见 `docs/UI_HANDOFF.md` §3.4）分布在 `settings_page.dart`、`subscriptions_page.dart`、`content_detail_page.dart`、`comment_section.dart`、`bili_login_section.dart`、`photo_grid.dart`、`cached_image.dart` 等文件里——这些平时属于别人的领地。
>
> 处理约定：**R1（界面会话）进行期间，其它会话不开工**；界面会话只许改这些文件里的**颜色/字号单行值**，不许顺手动任何逻辑。做完一轮、我复验通过后，再把它们交还原主。这是一次性的排他窗口，不是长期授权。

### 3.2 串行顺序（有依赖关系，别乱序）

| 轮次 | 会话 | 交付 | 为什么要这个顺序 |
| --- | --- | --- | --- |
| **R0** | 本会话 | ✅ **已完成（2026-10-18）**：六项决策已落定并写进 `docs/UI_HANDOFF.md` §0.5（D1~D6）| 卡片结构一变，B 站/微博各自要补的字段才能确定；这三个决定不定，UI 会话会卡住 |
| **R1** | **界面会话** | ✅ **主体已完成（2026-10-19）**：全 App 深色 → 亮色（`AppColors` + `main.dart` 已切 light）、卡片重构（`content_card.dart` 472 行 + `content_media.dart` 219 行）、「旧画面」修复（`setMode` 双模式快照已落地）。**遗留 N4（点封面进不了播放）与 N6（控制栏黑字）**——见 §5.2 | 先把「壳」定下来，后面两轮都往这个壳里填数据，避免改两遍 |
| **R2** | **微博会话** | 关注列表 / 关注流探针 + `WeiboTimelineSource` 新能力；**N3 微博评论**（先探针） | 产出数据能力，不碰 UI |
| **R3** | **B 站会话** | 统计行、简介、清晰度、倍速、进度记忆（按 `docs/BILI_HANDOFF.md` §10）+ **N1 长按快进、N2 博主头像** | 播放页重排依赖 R1 定下的视觉基线（亮色下 `Colors.grey/white38` 必须先修完） |
| **R4** | 本会话 | 把 R2 的能力接进 `timeline_repo` 合并 + **补 `ContentItem` 计数字段（D5）与视频时长/播放量（D6）** + **N5 微博订阅名回填** + 验收 + 文档 | 跨模块合并与模型改动只能在一个地方算 |

> **R1 的验收教训（值得写下来）**：亮色化 + 卡片重构做完后，用户仍报了两条问题（N4 / N6），都不是"没做"，而是**验收清单没覆盖到**：
> - N4：媒体区点击被 `_openGallery` 劫持——测「卡片能不能点开播放」时，点的是**文字区域**，没点封面；
> - N6：控制栏文字继承亮色主题的深色——测「播放页能不能看」时，看的是**视频画面**，没看浮层文字。
>
> 结论：**验收要按"用户会碰的每个热区/每块浮层"逐个点，而不是按"功能有没有实现"检查。** 这一条已经补进 `docs/UI_HANDOFF.md` §7。

**如果你更想并行**（比如想快点看到效果），唯一安全的并行组合是：

- **界面（R1）∥ 微博（R2）**：两者几乎不碰同一批文件（界面不碰 `lib/data/weibo/*`，微博不碰 `content_card.dart`）。
- **不要**把 B 站放进并行组——它要改 `player_page.dart` 的界面结构，和界面会话正面相撞。

但即使这样也建议**分时使用真机**：谁要装机截图，先在群里（对话里）说一声。

### 3.3 每个会话开工前必做（写进它们的 prompt）

1. 先读自己的交接文档（`docs/UI_HANDOFF.md` / `docs/BILI_HANDOFF.md` / `docs/WEIBO_HANDOFF.md`）+ 本文档；
2. **开工前先确认三件事**：① 有没有别人正在改我领地的文件；② 真机现在有没有人在用；③ 版本号有没有被别人动过（`android/local.properties`）；
3. 改完必须跑 `dart analyze` + `flutter test` + `assembleProfile`，**并且自己真机验证**（改 UI 就截图，改数据就探针取证）；
4. 收尾时**只在对话里报告改了哪些文件**，不要顺手改 `README.md`/`HANDOVER.md`——交给本会话统一写。

---

## 4. 方案 B 的补充说明（万一要并行）

如果确实要三个会话同时跑，就必须：

1. **复制工程**：`robocopy D:\Rrha D:\Rrha-ui /E /XD build .dart_tool .env`（排除产物与探针目录），`pub-cache` 可共享（`D:\Rrha\.env\pub-cache`）；
2. **各自独立构建**：副本目录里的 `android/local.properties` 路径会自动指向副本，互不干扰；
3. **真机排队**：只有一个会话能装 APK，其它用「同一份 APK 拷贝到各自副本」不现实，只能轮着来——这是并行方案最大的隐性成本；
4. **合并**：由我把副本里改过的**文件列表**逐一 `diff` 回主目录。**没有 git 时，这一步完全靠人，出错只能靠手工比对**。

> 我的判断：本工程体量（1.8 万行 Dart）与并行收益不匹配，**方案 C 更划算**。

---

## 5. 要求的最终归属（两张表）

### 5.1 第一轮（2026-10-18）

| 用户要求 | 谁做 | 落在哪 |
| --- | --- | --- |
| ① 全部关注 = B 站 + 微博所有关注的人；精选订阅 = 自己添加的博主 | **微博会话**（探针 + 取数）+ **本会话**（合并） | `weibo_timeline_source.dart` / `timeline_repo.dart` / `providers.dart` |
| ② 无图不显示媒体区 | **界面会话** | `content_card.dart`（+ 新建 `content_media.dart`） |
| ③ 卡片改成 B 站动态页式布局（44 头像 / 全宽 16:9 / 双列 / 九宫格 / 操作栏） | **界面会话** | `content_card.dart` + `lib/widgets/content_media.dart` |
| ④ 深色 → **亮色主题**（全 App，对标 B 站动态页） | **界面会话**（排他窗口，见 §3.1） | `main.dart` + 全仓库颜色清扫（清单见 `docs/UI_HANDOFF.md` §3.4） |
| ⑤ 精选订阅点开不要闪旧画面 | **界面会话**（动 `providers.dart` 时先告知本会话） | `providers.dart` → `setMode` |
| ⑥ 操作栏计数 / 视频时长播放量 / 评论预览 | **本会话**（前两项补 `ContentItem` 与两个 parser）；**评论预览选 A，本轮不做** | `content_item.dart` + `bili_content_parser.dart` + `weibo_parser.dart` |

### 5.2 第二轮（2026-10-19，6 条新需求）

| # | 用户原话 | 归谁 | 详细方案在哪 |
| --- | --- | --- | --- |
| N1 | 视频**长按无法快进** | **B 站会话**（播放器） | `docs/BILI_HANDOFF.md` §0.6 N1 |
| N2 | **bilibili 博主头像不显示** | **B 站会话**（解析层补 `authorAvatar`） | `docs/BILI_HANDOFF.md` §0.6 N2 |
| N3 | **微博没评论** | **微博会话**（先探针，再抽象 `CommentSection`） | `docs/WEIBO_HANDOFF.md` §13 |
| N4 | **点视频封面打不开视频，只显示封面图片** | **界面会话** | `docs/UI_HANDOFF.md` §0.6 N4 |
| N5 | **微博订阅源名字显示成「微博+UID」** | **本会话**（数据回填 alias；UI 侧无需改） | `docs/UI_HANDOFF.md` §0.6 N5 |
| N6 | **播放控制栏字体黑 → 白** | **界面会话** | `docs/UI_HANDOFF.md` §0.6 N6 |

> N1 和 N6 都是**上一轮改动的直接后果**，值得记一笔：
> - N6 是**亮色化的回归**——控制栏叠在半透明黑底上，文字却继承了新主题的深色；
> - N1 不是回归，是从来没做过（手势层只实现了拖动调速，没有长按加速）。
>
> 这提醒一件事：**亮色化不只影响白底页面，也影响「本来就该是深底」的浮层**（控制栏、播放页提示条、弹幕设置弹窗）。R1 验收时要把这类浮层单独过一遍。

---

## 6. 给用户的建议（怎么开这三个会话）

1. **顺序开，别同时开**：先开界面会话（它这轮是**亮色化全局改动**，必须独占一段时间），做完验收了再开下一个。三个同时开，最先出问题的永远是「文件被覆盖」和「真机被抢」。
2. **每个会话的提示词只要给两样东西**：对应交接文档路径 + 「先读 `docs/COLLAB_PLAN.md`，按里面的领地表干活」。
3. **汇报口径统一**：改完只报告「改了哪些文件 + 三条门槛结果 + 真机证据（截图/探针）」，不要自行改交付文档。
4. **真机只有一个**：如果两个会话都要装机，请明确告诉它们「现在轮到谁」。

---

## 7. 我（总设计）承诺做的事

- 维护这张领地表，并在每轮交接时更新；
- 独占 `providers.dart` / `timeline_repo.dart` 的改动（或明确授权某个会话临时改）；
- 每轮结束统一更新 `docs/HANDOVER.md`、`README.md`、版本号；
- 交付前做**一次独立复验**（不看会话的自述，自己跑门槛 + 真机看一遍）。

---

*本方案的核心是把「公共文件」收窄到一个人手里。项目没有 git，任何并行修改都必须假设「它会被覆盖」。*
