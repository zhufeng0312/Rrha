# 界面 / UI 优化：接手建议（Rrha）

> **面向**：新会话（负责「界面与交互打磨」）
> **生成**：2026-10-18（**v2**，按用户 2026-10-18 的「亮色主题 + B 站动态页卡片」规范重写）
> **更新**：**2026-10-27**（R1 续，追加 **§8.5**：时间线「只剩一侧 / 闪烁」的根因修复、
> 时间格式、点 tab 回顶部；并纠正 §8 里两条被实测推翻的环境说法）
> **工程**：`D:\Rrha`（Flutter 3.47.7 / Android，包名 `com.rrha.rrha`，**无 git 仓库**）
> **视觉基准**：用户给的原型 `<某桌面目录>\ui界面.html`（白底版，430px 容器，Tailwind 类）
> **定位**：你不改数据接口、不改播放链路。你负责「看得见的部分」——主题、卡片、列表、反馈。
> **标注约定**：【已证实】= 已在代码里核对过；【做不到】= 现有字段撑不住（见 §2.2）；【待确认】= 先看一眼再动手。

> ### ⚠️ 先读这两条，能省你半天
> 1. **§8.5.3 列了 4 个被真机证伪的方案**（GlobalKey / findChildIndexCallback /
>    viewport anchor / 单侧水位翻页）。时间线相关的缺陷**不要再往渲染层猜**，
>    先看 `loadMore#N` 那行诊断日志。
> 2. **§8 的环境说明已纠错**：用 `flutter analyze`，**不是** `dart analyze`
>    （后者在本机会无限挂起）。

---

## 0. 本轮范围（重要：v1 的卡片方案已作废）

用户这一轮把界面要求**整体换代**：从「深色主题 + 右侧 116×74 小封面」改成「**亮色主题 + B 站动态页式卡片**」。

| v1 方案（已作废） | v2 方案（本文档） |
| --- | --- |
| 卡片右侧 116×74 缩略封面 | **全宽 16:9 / 双列 / 九宫格**媒体区 |
| 头像 22–24 | **44×44** |
| 深色卡片 `0xFF1E1E1E` | **纯白卡片 + `0xFFF4F5F7` 页面底色** |
| 平台徽标在左上角 | 平台体现在**昵称颜色**（B 站深黑 / 微博粉 `0xFFFB7299`） |

**保留不变**的旧要求（新规范没覆写，仍然有效）：

- **无图时不渲染媒体区**（已并入 §1.3）；
- **点开「精选订阅」不要先闪「占位卡 + 转圈」** → 见 §4。

### 0.5 已确认的决策（2026-10-18 用户拍板，不用再问）

| # | 议题 | 决定 | 影响 |
| --- | --- | --- | --- |
| **D1** | 评论预览框 | **选 A：本轮不做** | 卡片结构为「媒体区 → 分割线 → 操作栏」，中间**不插**评论预览条；§1.2 布局图里那一块跳过 |
| **D2** | 4 张图的列数 | **卡片 3 列；详情页保持 2 列** | 卡片走新建的 `ContentMedia`（`count == 2 ? 2 : 3`）；**不改** `PhotoGrid.columnsFor` 的默认值 |
| **D3** | 单图比例（卡片） | **16:9 全宽**，不复用 `PhotoGrid` 的单图分支（它是 4:3 + 限高 260） | 单图一律 `AspectRatio(16/9)` |
| **D4** | 图片加载组件 | **继续用项目自带的 `CachedImage`**，不引入 `cached_network_image`，也不用裸 `Image.network` | 已有 LRU 磁盘缓存（200MB/1000 张，飞行模式可显示）；裸 `Image.network` 没有磁盘缓存，滚动往返会重新下载 |
| **D5** | 操作栏数字（转发/评论/点赞） | **数据层补字段**（`ContentItem` 加 3 个 `int?`），UI 先做「图标 + 可选数字」两态 | 补字段由总设计会话负责（§2.2 ②）；UI 侧 `count == null` 时不渲染数字 |
| **D6** | 视频卡左下角的「时长 + 播放量」 | **数据层补字段**（同 D5 的方式），UI 先只画播放图标 | §2.2 ③；字段路径需先用探针核对 |

> 结论一句话：**UI 会话本轮只做「主题 + 卡片 + 媒体区 + 旧画面修复」，不碰数据模型**；D5/D6 的数据字段由总设计会话补齐后，卡片会自动多出数字（布局留好位置即可）。

---

## 0.6 2026-10-19 新增需求（分配给你这个会话的）

用户又提了 6 条，其中 **3 条归界面会话**（另 3 条在 `docs/BILI_HANDOFF.md` §0.6 与 `docs/WEIBO_HANDOFF.md` §13）。总表见 `docs/COLLAB_PLAN.md` §5。

### N4 **点视频封面打不开视频，只显示封面图片**（用户原话）

**根因【已证实】**：`lib/features/timeline/content_card.dart:87-88`

```dart
isVideo: item.kind == ContentKind.video,
onTap: (int i) => _openGallery(context, i),   // ← 不管是不是视频，点媒体区都打开全屏看图
```

`ContentMedia` 里的播放图标只是**装饰**，点它同样走 `_openGallery` → 用户点视频封面，只会看到一张大图（`ImageGalleryPage`），永远进不了播放页。

**要做的事**：媒体区的点击按「能不能播」分流。

```dart
onTap: (int i) {
  // 视频优先进播放/详情（由外层 onTap 决定，它内部会按 bvid 分发到 PlayerPage），
  // 图文才进全屏预览。否则视频卡片的封面永远只能被“看图”。
  if (item.kind == ContentKind.video && item.isPlayable) {
    onTap();          // 复用卡片自己的点击回调，别另写一套跳转
    return;
  }
  _openGallery(context, i);
},
```

要点：

1. **复用 `onTap()`**（也就是 `timeline_page.dart` 的 `_openItem`），它会按 `item.videoRef.bvid` 分发到 `PlayerPage`，微博视频则进详情页——**不要在卡片里再写一份跳转逻辑**，两份一定会走偏。
2. `item.isPlayable` 的定义在 `content_item.dart:181`（B 站看 `bvid`，微博看 `directVideoUrl`）。**不可播的视频卡片**（微博直链没解析出来）仍然走看图，这是对的。
3. **`•••` 菜单里已有「查看详情」**（`_CardMenu.detail`），所以即使媒体区被改成"直接播放"，用户想看详情仍有入口。
4. 视频卡如果**同时有多张图**（B 站动态带多图 + 视频封面）——按 `kind == video` 优先播放，图片可在详情页看。

**验收**：时间线点一个 B 站视频卡的封面 → **直接进播放页并开始播放**；点一条微博图文卡 → 进全屏预览；点一条微博视频卡（直链已解析）→ 进详情页并停在视频区块。

### N6 视频播放**控制栏字体由黑色改成白色**（用户原话）

**根因【已证实】**：控制栏叠在**半透明黑色渐变**上（`player_controls_overlay.dart:95-113`，`0xB3000000`），但它自己的文字与图标**没写死颜色、继承了亮色主题的深色**：

| 位置 | 现状 | 亮色下的结果 |
| --- | --- | --- |
| `player_controls_overlay.dart:140` 标题 | `TextStyle(fontSize: 13)`（无 color） | 深色文字压在半透明黑上 → **看不清** |
| `player_controls_overlay.dart:172` 时长 | `TextStyle(fontSize: 11)`（无 color） | 同上 |
| `:130 / :160 / :176 / :185 / :190` 五个 `IconButton` | 未传 `color`，走 `IconTheme` | 图标继承深色 → 同样看不清 |
| `:148`「弹幕 N」 | `Colors.white70` | **正常**（少数写死了的） |

**推荐修法（一处解决全部图标 + 文字）**：在 `build()` 的前景 `Column` 外面包一层：

```dart
IconTheme.merge(
  data: const IconThemeData(color: Colors.white),
  child: DefaultTextStyle.merge(
    style: const TextStyle(color: Colors.white),
    child: Column(children: <Widget>[_topBar(), const Spacer(), _bottomBar()]),
  ),
),
```

`Text` 的 `style` 里 color 为 null 时会与 `DefaultTextStyle` 合并，所以**不用逐个改 5 个 IconButton 和 2 个 Text**；写死颜色的 `Colors.white70` 不受影响。

**还要检查进度条**：`_progressBar()` 在 `player_page.dart`（约 1094 行）构建，如果它用了主题色（`colorScheme.primary`），亮色下可能变浅。目标是**在黑色视频区上可见**，必要时显式给白色/亮色。

**注意**：这里只改颜色，**不许动层叠与命中结构**——那个全屏装饰层必须继续是 `IgnorePointer`，否则会重演「控制栏点不动」（`docs/HANDOVER.md` §7.10）。

**验收**：播放页（含全屏）截图，返回箭头、标题、时长、播放/暂停、弹幕开关、设置、全屏五个图标全部清晰可辨；进度条可见。

### N5 **微博订阅源名字显示成「微博 + UID」**

**归数据层（总设计会话）**，但你要知道结论免得重复劳动：

- `lib/data/models/subscription.dart:67-75` 的 `displayName`：有 `alias` 用 alias，否则 B 站回 `'B 站 UP $uid'`、微博回 `'微博 $uid'`；
- **B 站不受影响**：从关注列表导入时已经写了 `alias: user.displayName`（`following_import_sheet.dart:146`）；
- **微博受影响**：微博是手动填 UID 添加的，`alias` 为 null → 显示成 `'微博 1782488734'`。

**修法（我这边做，零额外请求）**：微博时间线拉回数据后，若某微博订阅 `alias` 为空，用该源第一条内容的 `authorName` 回填 alias（数据已经在手上了）。若要"添加时就显示名字"，则需在添加时请求一次博主信息——**这是额外请求，我倾向不这么做**。

**你这边**：`subscriptions_page.dart` 三处都读 `subscription.displayName`（110 / 242 / 287 行），**不用改**；数据回填后自然显示博主名。**回归时确认一下**：改名后这三处（列表项、菜单标题、删除确认弹窗）都同步变了。

---

## 1. 视觉规范（逐条可执行，别自己发挥）

> 单位说明：用户写「sp」，Flutter 的 `fontSize` 就是逻辑像素（≈ dp/sp，跟随系统字体缩放）。**不要按物理像素换算**。

### 1.1 全局主题与配色

| 项 | 值 | 落点 |
| --- | --- | --- |
| `themeMode` | `ThemeMode.light` | `lib/main.dart:92` |
| 页面背景 | `Color(0xFFF4F5F7)` | `ThemeData.scaffoldBackgroundColor`（`main.dart:106`） |
| 卡片背景 | `Colors.white` | `content_card.dart`（删掉硬编码 `0xFF1E1E1E`） |
| 主标题 / 正文 | `Color(0xFF18191C)` | |
| 次要信息（时间、操作栏） | `Color(0xFF9499A0)` | |
| 链接「全文」 | `Color(0xFF00AEEC)` | |
| 分割线 | `Color(0xFFE3E5E7)`，1px | `Divider(height:1, thickness:1)` 或 `BorderSide(width:1)` |
| 微博昵称 | `Color(0xFFFB7299)` | `item.platform == Platform.weibo` |
| B 站昵称 | `Color(0xFF18191C)` | |
| 头像占位底色 | `Color(0xFFE3E5E7)` | 原型 `.avatar` 背景 |

`main.dart` 现状【已证实】：

```dart
theme: _buildTheme(Brightness.dark),                 // ← 改成 light
darkTheme: _buildTheme(Brightness.dark),
themeMode: ThemeMode.dark,                           // ← 改成 ThemeMode.light
scaffoldBackgroundColor: const Color(0xFF121212),    // ← 改成 0xFFF4F5F7
appBarTheme: ... backgroundColor: Color(0xFF121212)  // ← 改成浅色
navigationBarTheme: ... Color(0xFF1A1A1A)            // ← 改成白
```

> `_buildTheme(Brightness)` 虽然带 `brightness` 参数，内部却把底色全写死了。**建议直接删掉 `darkTheme`、只留 light**（本项目没有夜间模式需求，留着会让人误以为支持双主题）。

### 1.2 卡片排版

```
┌───────────────────────────────────────────────┐  白底 / 圆角 12 / 内边距 12
│ (44×44 头像)  昵称 15 bold                ••• │  昵称颜色按平台
│               时间 13 灰                       │
│                                               │
│ 正文 15 / 行高 1.5 / 最多 4 行 / 末尾「... 全文」│
│                                               │
│ ┌───────────────────────────────────────────┐ │  媒体区（规则见 §1.3）
│ └───────────────────────────────────────────┘ │
│                                               │
│ ┌───────────────────────────────────────────┐ │  评论预览（决策 D1：本轮不做，跳过）
│ └───────────────────────────────────────────┘ │
│ ───────────────────────────────────────────── │  1px 0xFFE3E5E7
│    ↗ 转发        💬 评论        👍 点赞        │  三列平分居中
└───────────────────────────────────────────────┘
```

- 卡片圆角 **12**（原型 `rounded-xl`）、内边距 **12**（`p-3`）、卡片间距 **8**（`space-y-2`）；
- 页面左右边距 **8–12**（原型容器 `padding:8px`；列表沿用现有 `padding: (12,12,12,24)`）；
- 头像 **44×44** 圆形（`ClipOval` + 现有 `CachedImage`，**别用 `Image.network`**，会用掉磁盘缓存）；
- 昵称 **15 / `FontWeight.w700`**；时间 **13 / `0xFF9499A0`**；两者在头像右侧**上下堆叠**；
- 右上角 `•••`：`Icons.more_horiz` + `0xFF9499A0`，**点击区不小于 40×40**（原型是纯文本 `•••`，Flutter 里要包 `IconButton`/`InkWell`）。

### 1.3 媒体区（按条件渲染）

| 图片数 | 规则 |
| --- | --- |
| 0 | **不渲染**（不留空、不留占位） |
| 1（图） | 全宽，`AspectRatio(16/9)`，圆角 8，`BoxFit.cover` |
| 1（视频） | 同上 + 居中播放图标；左下角「时长/播放量」【做不到】，见 §2.2 |
| 2 | 两列均分，`AspectRatio(1/1)`，间距 4，圆角 8 |
| ≥3 | **三列九宫格**，`AspectRatio(1/1)`，间距 4，圆角 8，**最多 9 张** |

**⚠️ 与既有决策的两处冲突，已裁决（见 §0.5 D2/D3）**：

1. **4 张图**：现有 `PhotoGrid.columnsFor()` 把 4 张判成**两列**（那是详情页的用户决策，见 `photo_grid.dart:11-14` 注释），新规范要求「3 张以上 → 3 列」。→ **已定：卡片用 3 列，详情页保持两列**，用参数区分，**不许改 `PhotoGrid` 默认行为**。
2. **单图比例**：`PhotoGrid` 单图是 **4:3 + 限高 260**，新规范要 **16:9 全宽**。→ **已定：卡片不复用** `PhotoGrid` 的单图分支。

**因此新建卡片专用组件** `lib/widgets/content_media.dart`（§3.3 给骨架）。理由：
- `PhotoGrid` 被**详情页**依赖，改默认值会牵动详情页（它的 4:3/两列是有理由的：竖图会把页面顶穿）；
- 新建文件不碰任何现有文件，**天然不与别的会话冲突**（见 `docs/COLLAB_PLAN.md`）。

### 1.4 底部区域

1. **评论预览框**（原型 `bg-gray-50` + `rounded-lg` + `p-2` + 13sp）—— **🔴 决策 D1：本轮不做，直接跳过这一块**
   - 原因：B 站动态流与微博 `getIndex` 的响应里**没有评论内容**，只能额外请求（违反硬性约束 1，且每卡一次请求必触发风控）；详见 §2.2 ①。
   - 因此卡片结构是 **媒体区 → 1px 分割线 → 操作栏**，中间不插任何东西。以后若要做，按 §2.2 的选项 B 补一个「查看评论 ›」入口即可。
2. **操作栏**：三列平分（`Expanded` ×3），图标 + 数字居中，颜色 `0xFF9499A0`，上方 1px `0xFFE3E5E7`；
   - 数字取决于 `ContentItem` 何时补上计数字段（决策 D5）：**先做纯图标版本**，把加数字的位置留好。

---

## 2. 数据可行性核对（★ 开工前必读）

### 2.1 现有字段能支撑的部分【已证实】

`lib/data/models/content_item.dart` 的全部字段：

| 规范要求 | 可用字段 | 备注 |
| --- | --- | --- |
| 头像 | `authorAvatar`（`String?`） | 【待确认】微博侧 `weibo_parser.dart` 读了 `avatar_hd / profile_image_url / avatar_large`，但**不是每个博主都有**；没有时用「姓名首字圆形」兜底，别为头像去改数据层 |
| 昵称 + 颜色 | `authorName` + `platform` | |
| 时间 | `publishedAt` / `fetchedAt` / `hasReliableTime` | `hasReliableTime == false` 时显示「抓取于 …」，别假装是发布时间 |
| 正文 | `summary`（正文纯文本）/ `title` | 正文区用 `summary`，空则退回 `title`；`displayTitle` 会优先返回 `title` |
| 图片 | `images`（已归一化、去重） | `images.isEmpty` 即「无图」 |
| 封面 | `coverUrl` | 语义 = `images` 第一张；单图场景两者等价，**统一用 `images`** |
| 点图看大图 | `lib/features/gallery/image_gallery_page.dart` | **现成可用**：滑动、双指缩放、双击 2.5x、页码 `i / n` |
| 「全文」点击 | `ContentDetailPage(item: item)` | 详情页已存在，直接 push |
| 转发原动态 | `origin` | **卡片已展开嵌套区块**（2026-10-27，见 §8.6）；详情页另有「原动态」区块 |
| 「新内容」标记 | `isNew` | 改版后建议保留在昵称后（小圆点），它是时间线核心交互 |

### 2.2 三项「现有字段撑不住」的议题（均已裁决，见 §0.5）

#### ① 评论预览框（`用户名：评论内容`）—— **✅ 决策 D1：本轮不做**

- B 站动态流（`/x/promo/feed/all`）与微博 `container/getIndex` 的响应里**都没有评论内容**，只有评论数；
- 要拿内容就得再调评论接口（B 站 `/x/v2/reply/main?oid=…`、微博 `buildComments`）——**每张卡一次请求**，20 张 = 20 次，必然触发风控，也直接违反本轮硬性约束「绝对不可发起额外网络请求」。

**✅ 已裁定（2026-10-18）：选 A —— 本轮不做这一行。**

| 选项 | 做法 | 代价 | 状态 |
| --- | --- | --- | --- |
| **A** | 本轮**不做**这一行 | 与原型有视觉差异，但零风险 | **✅ 已采纳** |
| B（留作以后） | 做成「💬 查看评论 ›」入口条（用 `hasComments` 判断，不带内容） | 接近原型，但只有入口没有预览 | 备选 |
| C | 预取首屏前 N 条的评论并缓存 | 最容易出风控事故 | ❌ 明确不采用 |

#### ② 操作栏的数字（转发 / 评论 / 点赞）—— **✅ 决策 D5：数据层补，UI 先做两态**

- `ContentItem` **没有**计数字段；
- 但**原始 JSON 里大概率有，且不需要额外请求**：B 站动态 `module_stat.reply / like / repost / forward`，微博 `mblog.comments_count / reposts_count / attitudes_count`；
  - 【待确认】**字段路径是推断的，动手前先用探针（`.env/probe_*.py`）把一条真实响应打出来核对**，别照抄；
- 所以这是**数据层的活**：给 `ContentItem` 补 3 个 `int?` + 两个 parser 各读一遍 + `toJson/fromJson/copyWith` + 旧缓存缺 key 时回落 `null`。

**分工**：字段由**总设计会话**补（见 `docs/COLLAB_PLAN.md` 领地表，R4）；UI 先做「图标 + 可选数字」两态（`count == null` 时不显示数字），补完字段自动带上数字。**UI 会话不要自己改 `content_item.dart`**——那是三方共用文件。

#### ③ 全宽封面左下角的「时长 + 播放量」（原型 `04:37` / `1409播放`）—— **✅ 决策 D6：数据层补，UI 先只画播放图标**

- `ContentItem` 没有时长也没有播放量；`VideoRef` 只有 `bvid/aid/cid/page/directVideoUrl/coverUrl/sourceUrl`；
- 同样属于「JSON 可能就有、模型没存」：B 站 `module_dynamic.major.archive.duration_text` + `stat.play`【待确认，同上需探针核对】；
- **本轮 UI 只画播放图标**，左下角的渐变文字条留到字段补齐后再加（别自己造数据）。

---

## 3. 实现路线

### 3.1 `lib/main.dart`（先做，影响全局）

```dart
theme: _buildTheme(Brightness.light),
themeMode: ThemeMode.light,
// darkTheme: 直接删掉（本项目不做夜间模式）

scaffoldBackgroundColor: const Color(0xFFF4F5F7),
appBarTheme: const AppBarTheme(
  backgroundColor: Color(0xFFF4F5F7),   // 或 Colors.white
  foregroundColor: Color(0xFF18191C),
  surfaceTintColor: Colors.transparent,
  elevation: 0,
),
navigationBarTheme: NavigationBarThemeData(
  backgroundColor: Colors.white,
  indicatorColor: scheme.primary.withValues(alpha: 0.12),
  labelTextStyle: const WidgetStatePropertyAll<TextStyle?>(
    TextStyle(fontSize: 12, color: Color(0xFF9499A0)),
  ),
),
```

> seed 现在是 `0xFF00A1D6`（B 站蓝）。规范里的链接色是 `0xFF00AEEC`，不要求统一；若想让 `colorScheme.primary` 和「全文」蓝一致，把 seed 改成 `0xFF00AEEC` 即可。
>
> ⚠️ 改完必须**全 App 走一遍**：登录页、设置页、订阅源页、详情页、评论、日志页都可能是「白底白字」。清扫清单见 §3.4。

### 3.2 `lib/features/timeline/content_card.dart`（主体重构）

**改造骨架**（结构照这个走）：

```dart
Widget build(BuildContext context) {
  final item = this.item;
  final hasMedia = item.images.isNotEmpty;                       // 无图不渲染
  final body = item.summary.trim().isNotEmpty ? item.summary : item.title;

  return Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(item),                                        // 头像 + 昵称/时间 + •••
            const SizedBox(height: 8),
            _body(body),                                          // 15sp / 4 行 / 全文
            if (hasMedia) ...<Widget>[
              const SizedBox(height: 8),
              ContentMedia(                                       // 新建，见 §3.3
                images: item.images,
                isVideo: item.kind == ContentKind.video,
                onTap: (i) => _openGallery(context, i),
              ),
            ],
            const SizedBox(height: 8),
            const _DividerLine(),                                 // 1px 0xFFE3E5E7
            _actionBar(),                                         // 三列图标（数字待数据层）
          ],
        ),
      ),
    ),
  );
}
```

**必须注意的实现点**：

1. **用 `Material` + `InkWell`，不要 `Container` + `InkWell`**：白底卡片再套 `Container(color:)` 会把水波纹盖住——深色下不明显，亮色下很突兀。
2. **正文 4 行 +「...全文」**：不要用 `TextOverflow.ellipsis` 再手拼「全文」（会变成省略号 + 两段文字）。两种做法：
   - **简单版（本轮用这个）**：`Text(body, maxLines: 4, overflow: TextOverflow.ellipsis)`，在下方右对齐放一个独立的「全文」文本按钮；
   - 精确版：`TextPainter` 算第 4 行末尾再插行内富文本（成本高，不建议）。
   - 是否真的超长：用 `TextPainter.didExceedMaxLines` 或 `maxLines` 溢出判断，**不要用 `body.length > N` 猜**。
3. **昵称颜色按平台**：`item.platform == Platform.weibo ? const Color(0xFFFB7299) : const Color(0xFF18191C)`。
4. **`isNew` 不要丢**：原左上角的 `NewBadge` 改到昵称后面（小圆点）。
5. **删掉现有 4 种封面角标**（`共 N 张` / `含原动态` / `直链未解析` / 播放圈），改为：
   - 多图：九宫格本身就说明张数，**不需要角标**；
   - 转发：昵称行加 `转发` 小标签；
   - 视频：媒体区中央播放图标。

### 3.3 新建 `lib/widgets/content_media.dart`

```dart
/// 卡片媒体区：1 张 16:9 全宽；2 张两列；≥3 张三列九宫格（最多 9 张）。
/// 无图时返回 SizedBox.shrink()（调用方也可先判空）。
///
/// 为什么不复用 PhotoGrid：详情页那边是「1 张 4:3 限高 / 4 张两列」，
/// 与卡片规范不同；改它的默认值会牵动详情页。
class ContentMedia extends StatelessWidget { ... }
```

要点：

- 单张：`AspectRatio(aspectRatio: 16/9)` + `ClipRRect(radius 8)` + `CachedImage(fit: BoxFit.cover)`；视频再叠播放图标；
- 多张：`LayoutBuilder` 算 `tile = (width - gap*(cols-1)) / cols`，`Wrap(spacing:4, runSpacing:4)`；
  - 列数：`count == 2 ? 2 : 3`（**与 `PhotoGrid.columnsFor` 不同**，别直接抄）；
  - `CachedImage(cacheWidth: (tile*3).round())` —— **`cacheWidth` 必须给**，否则 9 张原图解码会吃光内存（`photo_grid.dart:100-104` 有完整解释）；
- 最多 9 张：`images.take(9)`；超过 9 张时在最后一格叠 `+N`；
- 点击：`onTap(index)` → 调用方 push `ImageGalleryPage(images:, initialIndex:)`（**已有组件，别重写**）。

### 3.4 亮色化清扫清单（照单扫，一处都别漏）

深色下这些硬编码看不出问题，转亮后必然「白底白字」或「深块突兀」：

| 文件 | 行 | 现状 | 处理 |
| --- | --- | --- | --- |
| `lib/main.dart` | 106 / 108 / 113 | `0xFF121212`、`0xFF1A1A1A` | §3.1 |
| `content_card.dart` | 27 | `0xFF1E1E1E` | 白底 |
| `content_detail_page.dart` | 386（+196 注释） | `0xFF1E1E1E` 原动态区块 | 浅灰 `0xFFF4F5F7` |
| `subscriptions_page.dart` | 93 | `0xFF1E1E1E` | 白 / 浅灰 |
| `settings_page.dart` | 645 | `0xFF1A1A1A` | 白 / 浅灰 |
| `photo_grid.dart` | 125 | 占位 `0xFF2A2A2A` | `0xFFE3E5E7`（**会影响详情页，属同一套规范，可接受**） |
| `cached_image.dart` | 占位/错误态 | 深灰 | 同上 |
| `weibo_facade_card.dart` | 3 处 | 深色 | 白卡 |
| `comment_section.dart` | 2 处 | 深色 | 检查 |
| `bili_login_section.dart` | 2 处 | `Colors.white*` 文字 | 改深色文字 |
| `danmaku_stress_test_page.dart` | 133 / 135 / 175 | 黑底 | 测量页黑底有意保留，保证文字可读即可 |
| `image_gallery_page.dart` | 8 处 | 黑底白字 | **全屏看图本就该黑底，保留** |
| `player_page.dart` | 710 / 821 / 831 / 865 | `Colors.black` | **视频区必须保持黑**；只改**视频区下方**文字（`Colors.grey` / `Colors.white38` → `0xFF9499A0` / `0xFF18191C`） |

> 一句话规则：**黑底只留给沉浸式内容（视频区、全屏看图、压测页），其余一律白底深字。**

### 3.5 底部区域（按已定决策 D1 / D5 执行）

- **评论预览：不做**（D1）——媒体区 → 8 间距 → 1px 分割线 → 操作栏，中间不插任何东西；
- **操作栏数字**：`count == null` 时**不渲染数字**（只留图标）；布局提前留好 `Row(Icon, if (n != null) Text('$n'))`，等总设计会话补上 `ContentItem` 的计数字段后自动生效（D5）；
- 若以后想补评论预览，按 §2.2 ① 的选项 B 加一条入口条即可，不需要改其它结构。

---

## 4. 保留项：精选订阅的「旧画面」

**根因【已证实】**：`lib/providers.dart:566-571`

```dart
state = TimelineState(mode: mode, subscriptions: _prefs.subscriptions); // ← ① 清空 items
await refresh(force: true);                                            // ← ② 跳过缓存
```

①让列表立刻只剩「占位卡 + 迷你转圈」，②让这个中间态维持数秒（逐源拉 7 个源）。

**修法：双模式快照**

```dart
final Map<TimelineMode, TimelineState> _snapshots = <TimelineMode, TimelineState>{};

Future<void> setMode(TimelineMode mode) async {
  if (state.mode == mode && state.initialized) return;
  await _prefs.setTimelineMode(mode);
  final snap = _snapshots[mode];
  state = snap == null
      ? TimelineState(mode: mode, subscriptions: _prefs.subscriptions)  // 首次进入，只能转圈
      : snap.copyWith(mode: mode, subscriptions: _prefs.subscriptions); // 有快照 → 立刻有内容
  await refresh(force: false);   // 走 5 分钟缓存 → 秒回；过期才真拉
}
```

`refresh` 成功写回 `state` 时同步 `_snapshots[state.mode] = state`。

**不能简单「不清空 items」**：两种模式的 `sourceId` 语义不同（`feed/all` vs `平台:uid#route`），混着显示会让**已读标记与去重失效**——`providers.dart:564-565` 的注释写明过。

> ⚠️ `providers.dart` 是**跨模块公共文件**。动它前先看 `docs/COLLAB_PLAN.md`，并告知总设计会话。

---

## 5. 屏幕适配（430dp 附近）

**实测**：荣耀 Magic8 Pro 物理 1256×2808 @560dpi → dpr 3.5 → **逻辑宽度 ≈ 359dp**（`1256/3.5`）。用户说的 430dp 是原型容器的 `max-width`。

- **不要按 430 写死任何宽度**，用 `LayoutBuilder` / `Expanded` / `MediaQuery`；
- 卡片内边距 12 + 页面边距 12 → 359dp 上可用宽 ≈ `359 - 24 - 24 = 311dp`：
  - 三列九宫格：`(311 - 4*2)/3 ≈ 101dp` → `cacheWidth ≈ 303`，清晰度足够；
  - 两列：`(311 - 4)/2 ≈ 153dp`；
- 字号不随宽度缩放（15sp 在 359 / 430 上都成立），但窄屏上文 4 行装得字更少，属正常；
- 系统「显示大小」会改 dpr，**必须在这台机上实际截图**，别只按公式算。

---

## 6. 硬约束

1. **只用 `ContentItem` 现有字段，绝不发额外网络请求**（尤其 `itemBuilder` 里）。缺字段 → 提给数据会话。
2. **列表项不许用 `Opacity` / `BackdropFilter` / `ShaderMask`**。半透明用 `Color.withValues(alpha:)`（`Opacity` 会触发离屏合成，20 张卡滚动必掉帧）。
3. **圆角性能**：`ClipRRect` 只包图片本身（`PhotoGrid._tile` 现在就是这么写的），别包整卡大面积内容；九宫格 9 个 `ClipRRect` 可接受。
4. **不动播放器核心逻辑**：`player_adapter.dart`、`player_page.dart` 的加载/超时/回退一个字别改（见 `docs/BILI_HANDOFF.md` §5），只改视频区下方文字颜色。
5. **`IgnorePointer` 层叠关系不许动**：播放页曾因一个全屏 `Container` 吃掉点击，修了整整一轮（`docs/HANDOVER.md` §7.10）。
6. `flutter analyze --no-pub lib` 与 `--no-pub test` **0 issue**；`flutter test` **全绿**（当前 **1147**；2026-10-18 写的「434」、2026-10-27 的「1128」均已过时，新增测试后请更新此数）。
7. 卡片保持 `StatelessWidget` 且**不订阅 provider**（现在的 `ContentCard` 就是纯展示组件，保持）。

---

## 7. 真机验收清单

```bash
ADB="C:/Android/sdk/platform-tools/adb.exe"
"$ADB" install -r build/app/outputs/apk/profile/app-profile.apk
"$ADB" shell am force-stop com.rrha.rrha
"$ADB" shell monkey -p com.rrha.rrha -c android.intent.category.LAUNCHER 1
"$ADB" exec-out screencap -p > tools/shots/ui-light-01.png
```

必须覆盖 **6 种状态**：

| # | 状态 | 判据 |
| --- | --- | --- |
| 1 | B 站视频卡（单张 16:9） | 白底、深黑昵称、无「白底白字」 |
| 2 | 微博纯文字卡 | **完全没有媒体占位** |
| 3 | 微博双图 | 两列、正方形、间距 4 |
| 4 | 微博 9 图 | 三列九宫格，不超出卡片宽度 |
| 5 | 长文卡 | 4 行截断 + 蓝色「全文」可点 → 进详情页 |
| 6 | 点九宫格第 5 张 | 全屏预览直接定位第 5 张，滑动/缩放正常 |

**还要回归的页面**（亮色影响面）：设置页、订阅源页、登录页、详情页、评论区、日志页——每个至少截一张，确认没有深色残留块或白字。

### 7.1 两条「按功能检查就漏掉」的教训（2026-10-19 实际踩到）

第一轮验收之后，用户仍然报了两个问题，**都不是功能没实现，而是验收没覆盖到热区**：

| 漏掉的原因 | 已补进文档 |
| --- | --- |
| 测「卡片能不能打开视频」时点的是**文字区域**，没点**封面**（而封面被 `_openGallery` 劫持） | §0.6 N4 |
| 测「播放页亮色下看不清」时看的是**视频画面**，没看**浮层文字**（控制栏继承了深色） | §0.6 N6 |

**所以验收改成「按热区逐个点 + 按浮层逐个看」**：

- 时间线卡片上**每一个可点区域**都要点一遍：头像/昵称、正文、媒体区（视频卡的封面！）、`•••`、操作栏三列、卡片空白处；
- 播放页**每一块浮层**都要看一遍：控制栏（文字+图标+进度条）、快退/快进提示、亮度/音量指示、弹幕设置弹窗、错误面板；
- 亮色主题下"本来就该是深底"的地方（播放页视频区、全屏看图、压测页）**必须保持深底**，只是它内部的文字要显式写白。

---

## 8. 环境与门槛

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. D:\Rrha\tools\flutter-env.ps1      # 必做，否则 Gradle 因中文用户名崩
dart analyze lib test                # 必须 No issues found
flutter test                         # 必须 All tests passed!
cd android; .\gradlew.bat assembleProfile --offline
```

- ⚠️ **纠错（2026-10-26 实测，覆盖本文档旧说法）**：应当用 `flutter analyze --no-pub lib` / `--no-pub test`；
  **`dart analyze` 在本机会无限挂起**（无输出、进程不退出，连试 4 次）。旧文档写的「用 dart analyze，不要用 flutter analyze」是**反的**。
- 设备：HONOR Magic8 Pro `BKQ-AN10`，serial `<你的设备序列号>`，adb `C:\Android\sdk\platform-tools\adb.exe`。
- **连不上设备（`adb devices` 空列表）**：不是驱动问题，是 adb server 的 USB 后端。必须在**启动 server 的那个 shell 里**设：
  ```powershell
  Stop-Process -Name adb -Force
  $env:ADB_LIBUSB='1'; adb start-server; adb devices
  ```
  逐条命令设 `$env:` 无效——server 是独立进程，环境不跟随。
- 按文本定位点击：`python .env/ndtap.py "精选订阅" --tap`。
- **截图必须走 sdcard**，不要用 `adb exec-out screencap -p > x.png`（PowerShell 会写成 UTF-16，图片打不开）：
  ```powershell
  adb shell screencap -p /sdcard/x.png; adb pull /sdcard/x.png .\tools\shots\x.png; adb shell rm /sdcard/x.png
  ```
- **profile 构建不输出 `Log.d` 到 logcat**。要看本项目自己的日志，走 App 内「设置 → 右上角运行日志」页，或直接截图读。

---

## 8.5 2026-10-26 / 27 本轮交付（R1 续，含一条重要纠错）

> 这一节是**本轮实际做过的改动 + 走过的弯路**。弯路部分请务必看完再动手：
> 「时间线断层」这个缺陷前后试了 5 种方案，前 4 种全部无效甚至更糟，
> 只有第 5 种（显示下界）是根因修复。

### 8.5.1 背景：用户报了 3 个问题

| # | 用户原话（节选） | 状态 |
| --- | --- | --- |
| 1 | 「全部关注」滚动时**只剩微博内容**，继续滚 N 条后**界面闪一下**才恢复正常 | ✅ **已修复**（显示下界） |
| 2 | 「N 天前」的卡片要显示**具体小时分钟** | ✅ 已交付 |
| 3 | 点右下角「时间线」图标 → **回到顶部并刷新** | ✅ 已交付 |

用户后来把验收标准说得非常明确（这句话决定了方案选择）：

> 「就算翻过一大段卡片都只有 bilibili 的内容，没有微博的内容也可以接受。
> 只要他是**严格按照时间排列**的就可以。不接受在**本来应该同时有** bilibili
> 和微博内容的时候只有 bilibili 或微博的内容。」

### 8.5.2 ★ 根因：不是排序、不是渲染，是「把还没拉全的时间段先显示了」

**先记住这条密度事实**（真机日志实测，不是估算）：

| | 一页 20 条覆盖的时间 | 密度 |
| --- | --- | --- |
| B 站 `feed/all` | **几小时**（关注的人多、发得勤） | ≈ 40 条/天 |
| 微博 `/feed/friends` | **3~11 天**（只关注了少数博主） | ≈ 1.7 条/天 |

**密度比约 25 : 1。** 两个游标各自独立翻页，所以每翻一页微博的水位就后退
十几天、B 站只后退几小时。真机日志实测的水位差：

```
loadMore#5  ...  水位 bili=2026-10-24T11:43  weibo=2026-09-02T08:12
```

**B 站停在 10-24，微博已经翻到 09-02 —— 差近两个月。**

于是 183 条合并列表按时间倒序排出来是这样：

```
[10-26 ... 10-24]  90 条 B 站 + 4 条微博   ← 看着是混合的
[10-24 ... 09-02]   0 条 B 站 + 89 条微博  ← 一半的条目落在这里
```

用户看到的就是那后半段。**「闪一下」的真相**：继续翻页时 B 站的新页带回
一批时间戳在 10 月的内容，`sort` 之后它们只能插到**视口上方很远的位置**
（因为 10 月比 9 月新），当前屏内容瞬间下移 —— 这就是那次跳变。

**所以「闪」不是修复，是迟到的数据终于被插回它本该在的位置。**

### 8.5.3 ★ 已试过且**被真机证伪**的方案（不要再试）

| # | 方案 | 结果 |
| --- | --- | --- |
| 1 | 卡片从 `GlobalKey` 改 `ValueKey`，去掉 `_pruneKeys` | 无变化（方向是对的，但不是根因） |
| 2 | 给 `ListView` 加 `findChildIndexCallback` | **无效**。实测它只做 Element 复用，**不补偿滚动偏移**；4 种组合下插入 5 条后 offset 都停在 600 |
| 3 | 翻页前后 `_captureAnchor` / `_restoreAnchor` 用 `jumpTo` 校正视口 | **更糟**。`post-frame` 里 `jumpTo` 与当帧布局打架，用户先看到按新数据布局的画面、再看到校正后的画面，中间差就是新的闪烁。现已 `static const bool _anchorEnabled = false;` 关闭 |
| 4 | 按水位**只翻落后那一侧**（省请求） | **把问题翻到另一边**。日志：`#3 bili=Y weibo=N / #4 bili=Y weibo=N`，微博被跳过水位冻住，用户从「一大段只有微博」变成「一大段只有 B 站」。已回滚 |
| 5 | **显示下界（display floor）** | ✅ **有效**，见下 |

> 教训：前 4 种都在**渲染层**找原因，方向全错。真正的证据来自
> `loadMore#N` 那行诊断日志和两侧水位差。

### 8.5.4 ★ 采用的方案：显示下界

**新增文件** `lib/data/repo/timeline_floor.dart`（纯函数，不碰 IO，可离线单测）。

核心判据：对每一侧算一个**覆盖水位** `W` = 该侧已加载条目里最旧的时间
（表示「比它新的内容已全部加载完」）。那么两侧都完整的区间上界是：

```text
floor  = max(W_bili, W_weibo)     // 取较晚的那个
可见   = 时间 >= floor 的条目
缓冲   = 时间 <  floor 的条目     // 已加载，但扣住不显示
```

代回真机数字：`floor = 10-24`，那么 09-02 → 10-24 那 89 条微博**全部扣进缓冲**，
因为那段区间 B 站还没拉到 —— 显示了就是「本该同时有、却只有微博」。

**由此得到两个结构性保证**（这是本方案的全部价值）：

1. **可见列表永远严格按时间倒序** —— 切分是已排序序列的子序列；
2. **新内容永远只追加在末尾** —— 新页一定比 floor 更旧，已显示的一定不比
   floor 更旧，所以**不存在往视口上方插条目**，闪烁在结构上不可能发生。

第 2 条让前面 1~3 号补丁全部作废：它们修的是症状（插完把视口钉回去），
这里消掉的是成因（不再插入）。

**三条必须记住的实现约束**：

1. **`state.items` 只放可见条目，全量池另存 `followingPool`。**
   loadMore 要在**全量池**上做 `mergeContinuing` 再重新切分 —— 用 `items`
   会把「已加载但被扣住」的算成没加载，白白重复请求。
2. **floor 必须单调（只许变旧）**。`split(previousFloor:)` 做了夹取：
   万一某侧水位因异常数据「变新」，已显示条目会凭空消失 —— 比顺序错更糟。
3. **水位为 null 表示「不构成约束」**，两种情况：
   - 该侧已到底（`biliEnded` / `weiboEnded`）→ 更早的时间点也完整，
     此时**允许**出现真实的纯单一平台段（这正是用户接受的）；
   - 该侧一条内容都没有（未登录）→ 若当约束，floor 会被顶到「现在」，
     整条时间线被隐藏。
   另外 `hasReliableTime == false` 的条目不参与水位计算（它的 `sortKey`
   会回落到抓取时间，会把 floor 顶爆）。

**为什么两侧仍然都翻页**：只翻一侧会让另一侧水位冻住，而
`floor = max(两侧)` 必须靠它推进；一旦它翻页返回重复内容，floor 永远不动，
用户滚到底卡死。两侧都翻则**没有 stall 风险**：微博确实会多翻十几页，
但都进缓冲，等 floor 退到那里时**立即**出现、不需要额外请求 —— 相当于免费预取。

**用户已明确知道并接受的代价**（开工前问过，用户回「接受」）：
- 首屏从 ~183 条降到 **~21-23 条**（真机实测 `可见=23 缓冲=17`）；
- 往回翻的极限深度取决于 B 站（它页小），翻很深会慢。

> 用户还提出过「每次固定拉 6 小时的内容」。**没采纳**，原因写在
> §8.5.6：按密度算，6 小时窗口里微博平均只有 0.4 条，会把问题镜像成
> 「几乎只有 B 站」。用户认可了浮动水位的思路，但同时要求
> 「首屏连续拉 3~5 页再显示」的功能**先不做，后面再说** —— 别自己加。

### 8.5.5 改动清单（本轮）

| 文件 | 改动 |
| --- | --- |
| `lib/data/repo/timeline_floor.dart` | **新增**。`TimelineFloor.watermark()` / `.split()` + `TimelineFloorSplit`（含 `debugLabel()`） |
| `lib/providers.dart` | `TimelineState` 加 `displayFloor` / `followingPool` / `biliEnded` / `weiboEnded` / `bufferedCount` + `allLoaded` getter；`_refreshFollowing` 与 `loadMore` 接入切分；**删掉**被取代的 `_biliWatermark` / `_weiboWatermark`；`markCurrentSeen` / `clearSeenMarks` **连缓冲池一起清**（否则池里的条目晚些被放出来时带着「新」角标冒出） |
| `lib/core/utils/time_parse.dart` | `humanize()`：`<30d` 由「N 天前」改为 **`N 天前 HH:mm`**，更早为 `MM-DD HH:mm` / `YYYY-MM-DD HH:mm` |
| `lib/widgets/home_shell.dart` | 点索引 0 的 tab → `timelineScrollToTopProvider` 自增 + `refresh(force: true)` |
| `lib/features/timeline/timeline_page.dart` | 加 `_scrollToTop()`（250ms `animateTo`）并监听 `timelineScrollToTopProvider`；`_anchorEnabled = false` 停用锚点 |
| `lib/core/config/app_config.dart` | 删掉 `dataSourceDisclaimer`（用户要求删掉时间线底部那两句） |
| `test/data/timeline_floor_test.dart` | **新增 14 条**：水位计算、floor 取较晚侧、单调性、可见严格倒序、**「已显示条目必须是新列表的前缀」**（这条把「不闪」变成可断言性质）、缓冲是预取 |
| `test/features/timeline_floor_paging_test.dart` | **新增 6 条**集成测试（假 repo：B 站每页 20 小时、微博每页约 10 天） |
| `test/features/timeline_scroll_to_top_test.dart` | **新增 4 条** |

**`lib/features/timeline/timeline_page.dart` 的渲染层一行没改** —— `items` 仍然
只存可见条目，`itemBuilder` 自然不用动。这是本方案的一个好处，别去改它。

### 8.5.6 一次「问对问题」的记录（省下的是重写时间）

用户问「把每次拉取从**固定条数**改成**固定时间窗**（比如每次拉 6 小时）
能不能解决」。当时没有动手，先算了一遍：

| 6 小时窗口 | B 站产出 | 微博产出 |
| --- | --- | --- |
| 按 40 条/天、1.7 条/天 折算 | 10 条 | **0.4 条** |

而且两个接口**都没有时间范围参数**（微博只有 `max_id`/`since_id`/`count`，
B 站只有 `offset`/`page`），时间窗只能靠「翻页 + 过滤」模拟。固定 6 小时
等于每发一次微博请求浪费掉 96% 的返回数据，并把「纯微博段」镜像成「纯 B 站段」。

**结论：不存在一个能兼顾两侧的窗口宽度**，这是 25:1 的密度比决定的，
跟窗口选 6h / 12h / 24h 无关。所以选了「浮动水位」（由慢的那一侧决定）。

> 顺带一个产品层面的观察，写下来备查：这个 25:1 是**账号关注结构**的结果。
> 多关注几个活跃的微博博主，比例自己就会变，代码一行不用改。

### 8.5.7 真机验证证据（2026-10-27）

运行日志（设置 → 右上角）实测，floor 单调后退、可见只增不减、缓冲稳定：

```
首屏        floor=2026-10-26T07:02Z  可见=23  缓冲=17
loadMore#2  floor=2026-10-25T09:16Z  可见=48  缓冲=32
loadMore#3  floor=2026-10-24T15:45Z  可见=69  缓冲=50
loadMore#6  floor=2026-10-23T10:00Z  可见=130 缓冲=54
loadMore#7  floor=2026-10-23T03:45Z  可见=150 缓冲=54
loadMore#8  floor=2026-10-22T10:00Z  可见=171 缓冲=53
loadMore#9  floor=2026-10-21T12:57Z  可见=192 缓冲=52
```

截图交叉验证时间严格递减，且「只有 B 站」的那几段是**真实的**
（`拉回 weibo=1`，那段微博确实没发）：`1 天前 15:50` → `2 天前 20:14`
→ `2 天前 20:00` → `5 天前 22:07` → `5 天前 21:14`。

门槛：`flutter analyze --no-pub lib|test` → No issues found；
`flutter test` → **1128 全绿**；`assembleProfile --offline` → BUILD SUCCESSFUL。

### 8.5.8 已知未处理（不是本轮引入的）

- `ImageCacheStore` 反复报 `PathNotFoundException ... index.json.tmp`
  （`image_cache/index.json` 重命名失败）—— **改动前就有**，与时间线无关，本轮没动。
- `HomeShell` 挂载设置页会抛 `ListTile background color or ink splashes may be
  invisible` 断言（`ListTile` 在 `DecoratedBox` 里）—— 同样是既有问题，
  但它会让**挂载 `HomeShell` 的 widget test 失败**。写新的时间线测试时
  **只挂 `TimelinePage`，不要挂 `HomeShell`**。
- 微博置顶微博时间戳很旧但排在首位，天然违反严格时间序。当前**未特殊处理**
  （真机观察到的置顶项没有造成可见错乱）；若以后出问题，在
  `TimelineFloor.split` 里对置顶项豁免即可。

---

## 8.6 2026-10-27 第二轮：转发动态卡片（嵌套原动态区块）

> 这一节**推翻了 §2.1 里的一条旧决策**：「转发原动态 `origin`：卡片暂不展开」。
> 用户随后给了明确原型 `<某桌面目录>\转发动态卡片.html`，
> 要求卡片上直接画出被转发的原动态。§2.1 表格已同步改过。

### 8.6.1 数据层不用动（先确认，省一轮）

转发链路**早就打通了**，本轮没有改任何数据文件：

- `ContentItem.origin`（`content_item.dart:115`）本就是模型字段，
  `toJson` / `fromJson` 都支持，`origin.origin` 恒为 null（depth 上限 1）；
- B 站 `bili_content_parser.dart:334` 的 `_parseOrigin` 展开 `orig`；
- 微博 `weibo_parser.dart:359` 的 `_parseOrigin` 展开 `retweeted_status`，
  **实测确认与原 mblog 完全同形**，直接递归复用 `fromMblog`。

所以本轮只动了 UI。**下次遇到「转发」相关需求，先看 `origin` 是不是已经有了**，
不要条件反射去改 parser。

### 8.6.2 新增 `lib/widgets/quoted_origin.dart`

一个纯展示组件（`StatelessWidget`，不订阅 provider，与 `ContentCard` 同一条纪律）。
视觉对齐原型 `bg-nested` 块：底色 `#F6F7F8` / 圆角 8 / 内边距 12。

| 原动态形态 | 渲染 |
| --- | --- |
| 图文 1 张 | 全宽 `AspectRatio(16/9)` |
| 图文 2 张 | 两列正方形 |
| 图文 ≥3 张 | 三列九宫格（最多 9 张，超出叠 `+N`） |
| 视频 | 16:9 封面 + **右下角**播放角标 |

图文分支**直接复用 `ContentMedia`** —— 它的「1 图全宽 / 2 图两列 / 多图九宫格」
规则恰好就是需求要的那条，另写一套必然走偏。

视频分支单独画，因为 `ContentMedia` 的播放角标是**居中**大按钮，
而原型与需求都要求右下角小角标。两套规则没法用一个参数兼容。

### 8.6.3 三个必须记住的判断

1. **判定只看 `origin != null`，不要加 `kind == repost`。**
   微博解析层把「转发了一条视频」归成 `ContentKind.video`（视频优先于转发，
   见 `weibo_parser.dart:95-101`）。只按 kind 判会让这类转发在卡片上
   凭空丢掉原动态块，而点进详情页又能看到 —— 前后矛盾。已写单测钉住。

2. **整块灰色区域是同一个动作。**
   需求原话是「整个内嵌的灰色区域是一个 GestureDetector」。所以九宫格里
   点任意一张图也是**打开原动态页**，不是看大图。`ContentMedia.onTap` 被接成
   `onOpen`，不是 `_openGallery`。

3. **视频没封面也要占住 16:9。**
   那块位置本身就是「这里是个视频」的视觉信号，塌成 0 高度会让人以为是
   纯文字转发。封面优先级：`images.first` → `videoRef.coverUrl` → 灰底占位。

### 8.6.4 刻意省略的两个原型元素（都是「做不到」，不是漏做）

| 原型元素 | 为什么没做 |
| --- | --- |
| `+ 关注` 按钮 | 本 App 没有关注写能力。放一个点了没反应的按钮比不放更糟（与 `_ActionItem` 同一条纪律） |
| 话题高亮（`#明日方舟#` 渲染成微博蓝） | `ContentItem.summary` 是 `HtmlText.toPlainText` 清洗后的**纯文本**，标签信息已丢。要还原得改解析层保留富文本 —— 属数据层接口变更，不归 UI 会话 |

### 8.6.5 新增两个颜色

`app_colors.dart`：

- `nested = 0xFFF6F7F8` —— 嵌套区块底色。**必须与 `card`(白) 和 `page`(0xFFF4F5F7)
  三者可区分**；早先原动态块直接复用 `page`，在白色卡片里完全看不出是独立区域。
- `weiboMention = 0xFF507DAF` —— 「@被转发的人」用色，取自原型 `.text-weibo`。
  与 `weiboName`(`0xFFFB7299` 粉) **是两个色**：粉色是「正文作者」，
  这个灰蓝是「被提及/被转发的原作者」。混用会让转发者与原博主看起来同层级。

### 8.6.6 改动清单

| 文件 | 改动 |
| --- | --- |
| `lib/widgets/quoted_origin.dart` | **新增**。`QuotedOrigin` 组件 + `_PlayBadge` |
| `lib/core/theme/app_colors.dart` | 加 `nested` / `weiboMention` |
| `lib/features/timeline/content_card.dart` | 正文与媒体区之间插入 `QuotedOrigin`；加 `_openOrigin()`（push `ContentDetailPage(item: origin, headerLabel: '原动态')`） |
| `test/features/quoted_origin_test.dart` | **新增 19 条**：存在性、`kind==video` 仍渲染、配色、@昵称、正文回退、1/2/4 图列数、视频 16:9、角标在右下角、无封面占位、`videoRef` 回落、点击换数据源、点图不弹相册、不误触整卡 onTap |

门槛：`flutter analyze --no-pub lib` → No issues found；
`flutter test` → **1147 全绿**（原 1128 + 新增 19）。

> ⚠️ 构建注意：本机 Gradle 依赖缓存（`~/.gradle/caches/modules-2/files-2.1`）
> 可能被清空，此时 `--offline` 会失败（`kotlin-dsl` 插件找不到）。
> 去掉 `--offline` 联网构建一次即可重新填充缓存，之后 `--offline` 恢复可用。

### 8.6.7 详情页的重复表达（有意保留）

`ContentDetailPage` 里**也有**一块 `_OriginBlock`。它与卡片的 `QuotedOrigin`
是两个不同位置的组件，**没有合并**：

- 卡片版：紧凑、3 行正文、点击换页；
- 详情页版：带「原动态」标签、有独立的「查看原动态 / 播放原视频」按钮。

合并会逼着详情页接受卡片的紧凑布局，或让卡片背上详情页的按钮逻辑。
两者都违反「卡片是纯展示组件」的约束。

---

## 9. 建议顺序（按已定决策，可以直接照做）
1. **§3.1 主题**（`main.dart`）—— 一步切亮，立刻暴露全 App 哪里坏了；
2. **§3.4 清扫清单** —— 按表格从上到下扫一遍（不做这步，后面截图全是白底白字）；
3. **§3.3 `content_media.dart`** —— 独立组件，可用现成图片离线自测（单图 **16:9**、4 张 **3 列**，见 D2/D3）；
4. **§3.2 `content_card.dart` 重构** —— 拼装后按 §7 的 6 种状态逐个截图；
5. **§4「旧画面」修复** —— 要动 `providers.dart`，**先确认没人同时改它**；
6. **§3.5 操作栏** —— 纯图标版本先落地；等总设计会话补完 `ContentItem` 计数字段（D5/D6）后，数字会自动出现，届时再各截一张图确认。

> 决策已全部落定（§0.5），**不需要再回头问用户**。遇到规则没覆盖的细节，按「与原型一致」优先处理，并在交付报告里列出你的取舍。

> 每完成一步就跑 `dart analyze` + `flutter test`，别攒到最后——亮色化改动面广，攒起来出错无法二分定位。

---

*本文档覆盖「看得见的部分」。数据能力、播放链路、接口风控属于另外两个会话：见 `docs/BILI_HANDOFF.md`、`docs/WEIBO_HANDOFF.md`；三者协作见 `docs/COLLAB_PLAN.md`。视觉原型：`<某桌面目录>\ui界面.html`。*
