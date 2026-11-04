# 微博详情页正文对齐 B 站：交接说明

> **面向**：负责微博模块的会话
> **提出**：2026-11-02，用户原话：「我想让微博的纯文字卡片里的详情页的正文和你的一样（不包括评论区）」
> **工程**：`D:\Rrha`（Flutter 3.47.7 / Dart 3.13.5 / Android，包名 `com.rrha.rrha`，**无 git 仓库**）
> **当前基线**：`flutter test` **1313 全绿**，`dart analyze lib test` 干净

---

## 0. 一句话说清要做什么

把微博内容详情页的**正文区**（作者行 → 标题 → 正文 → 原动态 → 图片 → 数据栏）换成 B 站动态详情页那套骨架。**评论区一行都不要动。**

「那套骨架」已经是一个现成组件：`lib/features/timeline/bili_dynamic_body.dart` 里的 `BiliDynamicBody`。任务本质是**让它对微博也可用**，不是照着截图重写一遍。

> ⚠️ 这件事不是纯排版工作。微博侧存在一个**和 B 站一模一样的缺陷**（正文画两遍），必须一起修，见 §2。

---

## 1. 先看目标长什么样

B 站详情页（真机截图 `tools/shots/g1-opus-text-only.png`）的骨架，顺序严格如下：

```
◯48  作者昵称（16px 粗体）              ← 作者行，一条 Row
     2026-11-02 18:08（12px 灰）

[独立标题 17px 粗体]                    ← 仅当「真的有独立标题」才渲染，见 §2
正文（纯文字 16px / 带图 15px，行高 1.6）

[原动态区块]                            ← 仅转发时有
[图片区 PhotoGrid]                      ← 仅 images 非空时
评论 1142    赞和转发 2907              ← 数据栏（评论数品牌粉 #FB7299 加粗）
─────────────────────────
评论区（CommentSection，内建 16 左右 padding）
```

对照微博**现在**的样子（`ContentDetailPage` 的老排版）：

| 顺序 | 微博现状 | B 站骨架 | 备注 |
| --- | --- | --- | --- |
| 1 | **媒体区在最上面** | 媒体区在正文之后 | 顺序相反 |
| 2 | `item.displayTitle` 当大标题 | 仅真标题才渲染 | **正文会重复，见 §2** |
| 3 | `SourceBadge` + `KindBadge` + 时间，一行 | 无徽章行 | 见 §5「要不要保留徽章」 |
| 4 | 作者名单独一行、小字灰色 | 48px 头像 + 16px 粗体昵称 + 12px 时间 | 结构完全不同 |
| 5 | `Divider(height: 28)` | 作者行后无分割线 | — |
| 6 | 正文 `SelectableText` + `bodyMedium` | `Text` + 15/16px 显式字号 | 微博自动可长按复制，B 站不能 |
| 7 | 原动态块 `OriginBlock` | 同左（作为参数传入） | 可复用 |
| 8 | 无数据栏 | `评论 N　赞和转发 M` | 微博三个计数都已解析，见 §4 |
| 9 | 评论区 + 链接文本 | 评论区 | **不动** |
| 10 | `ListView` padding 16/12/16/32 | `EdgeInsets.zero` + 内层 16/12/16/0 | — |

---

## 2. 必须一起修的缺陷：正文画两遍

这是 B 站那边刚刚修完的同一个 bug，微博**有一模一样的问题**。

微博解析器 `lib/data/weibo/weibo_parser.dart:429`：

```dart
static String _title(String summary) {
  final String line = HtmlText.singleLine(summary);
  if (line.isEmpty) return '';
  return HtmlText.truncate(line, _titleMaxChars);   // _titleMaxChars = 60
}
```

也就是**微博的 `title` 字段本身就是「正文截 60 字」的兜底**。老排版把 `item.displayTitle` 当大标题画一次，又把 `item.summary` 画一次 —— 纯文字微博的正文必然出现两遍。

⚠️ 注意一个容易写错的细节（本文档初稿就写错了，已由
`test/features/weibo_detail_align_doc_test.dart` 钉住）：`HtmlText.singleLine`
会把换行**压成空格**，所以 `title` 是「**全文单行化后**的前 60 字」，
不是「第一段」。实测：

```
输入: "今天天气不错，出门走走。\n\n顺便拍了些照片，晚点发出来。"
title: "今天天气不错，出门走走。 顺便拍了些照片，晚点发出来。"   ← 空格不是换行
```

这影响的是 `hasOwnTitle` 里哪一道判据生效：多段短正文时 `s.startsWith(t)`
**不**成立（因为 `s` 未单行化、含 `\n\n`），真正兜住它的是最后那行
`t != HtmlText.truncate(HtmlText.singleLine(s), 60)`。两道判据都在，所以
结论不变 —— 但如果你为了「优化」删掉最后那行，多段微博就会重新画两遍。

B 站的修法是加了一个判据，位置在 `bili_dynamic_body.dart:205`：

```dart
static bool hasOwnTitle(ContentItem item) {
  final String t = item.title.trim();
  if (t.isEmpty) return false;
  if (_placeholderTitles.contains(t)) return false;   // [图片]/[视频]/[动态]/（无标题）
  final String s = item.summary.trim();
  if (s.isEmpty) return true;                         // 只有标题没有正文 → 标题要显示
  if (s.startsWith(t)) return false;                  // 正文以标题开头 → 是兜底标题
  return t != HtmlText.truncate(HtmlText.singleLine(s), 60);
}
```

**这个函数对微博同样适用，不需要改**（微博的兜底长度也是 60，`_titleMaxChars == 60` 与 `ContentItem.displayTitle` 的 60 一致，是刻意对齐的）。

⚠️ 两种微博形态分别由哪道判据兜住，别搞混（`weibo_detail_align_doc_test.dart` 逐条验证过）：

| 微博形态 | `title` 形态 | 生效的判据 |
| --- | --- | --- |
| 单段长正文 | 前 60 字 + `…` | `s.startsWith(t)` 不成立（有省略号）→ 靠 `truncate` 那行 |
| **多段正文** | 单行化后的全文（≤60 字时无省略号） | `s.startsWith(t)` 也不成立（`s` 含 `\n\n`）→ **仍靠 `truncate` 那行** |
| 纯图微博 | 空串 | `t.isEmpty` 直接返回 false |
| 正文无换行且短 | 与 summary 相同 | `s.startsWith(t)` 命中 |

结论：**最后那行 `t != HtmlText.truncate(HtmlText.singleLine(s), 60)` 是主力**，上面几行是快路径。别为了「简化」把它删掉。

⚠️ 不要把判据写成「`title` 等于 `summary` 首行」以外的弱条件。三种兜底形态都要挡：正文首行、`[图片]` 这类占位符、`（无标题）`。

> 这三条判据现在有可执行的验证：`test/features/weibo_detail_align_doc_test.dart`
> 用微博的真实兜底形态（多段短正文 / 单段长正文 / 纯图 / 真标题）逐条跑过
> `hasOwnTitle`，结果符合预期。你可以直接跑它确认自己的改动没破坏这个前提。

---

## 3. 推荐实施路径

有两个方案。**推荐 A**，理由在下面。

### 方案 A（推荐）：B 站会话先把骨架泛化，微博会话只改判定

现状是 `BiliDynamicBody` 只被 `ContentDetailPage` 的 **B 站分支**和 `OpusDetailPage` 使用，微博分支走老排版：

```dart
// content_detail_page.dart:60
bool get _usesDynamicLayout =>
    item.platform == Platform.bilibili && item.kind != ContentKind.video;
```

问题在于骨架**写死了「媒体区只可能是图片」**（`_media` 直接返回 `PhotoGrid`）。微博视频必须在页内就地播放（`InlineVideoPlayer`，这是用户明确要求过的），套不进 `PhotoGrid`。

所以需要有人给 `BiliDynamicBody` 加一个媒体区注入点，与现有的 `originBlock` 同构：

```dart
class BiliDynamicBody extends StatelessWidget {
  const BiliDynamicBody({
    super.key,
    required this.item,
    required this.commentSection,
    this.originBlock,
    this.media,          // ← 新增：为 null 时走默认 PhotoGrid
  });

  /// 媒体区。为 null 时按 [item.images] 渲染 [PhotoGrid]。
  ///
  /// 存在的理由：微博视频必须在页内自动播放（`InlineVideoPlayer`），
  /// 而 [PhotoGrid] 只会把它渲染成一张静态封面 —— 正是 2026-10-27
  /// 「点视频封面只显示一张照片」那个缺陷。
  final Widget? media;
```

内部把 `_media(context)` 换成 `media ?? _media(context)` 即可，改动约 5 行。

**这个改动归 B 站会话做**（文件是我这边的）。你接手时可以：
1. 先问一句「`BiliDynamicBody` 加 `media` 注入点做完了吗」，没做就让 B 站会话做；
2. 或者在文档末尾「§9 交接记录」里登记后自己改 —— 但**务必只做这一处最小改动**，别顺手重排里边的东西，否则我们两边又分叉。

### 方案 B（不推荐）：微博单独写一个 `WeiboDynamicBody`

改动看着独立，代价是同一套骨架存在两份实现。这个项目的教训已经写在 `docs/HANDOVER.md` 里了：B 站详情页当初就是「页面有两个入口、排版各写一套」，结果同一条动态从两条路进去长得不一样，用户连着两轮报「内容出现两次」。别重演。

---

## 4. 接骨架时需要传的参数

### 4.1 `item` —— 直接传，无需改造

`BiliDynamicBody` 只读 `ContentItem` 的公共字段，微博的解析器**全都填了**：

| 骨架用到的字段 | 微博来源 | 状态 |
| --- | --- | --- |
| `authorName` | `user.screen_name` | ✅ |
| `authorAvatar` | `user.avatar_hd` → `profile_image_url` → `avatar_large` | ✅ |
| `publishedAt` / `hasReliableTime` | `created_at` 经 `TimeParse.parseWeibo` | ✅ 解析失败时 `hasReliableTime=false`，骨架会显示「抓取于 …」 |
| `title` / `summary` | 见 §2 | ✅ |
| `images` | `pics[].large.url` | ✅ |
| `commentCount` | `comments_count` | ✅ |
| `likeCount` | `attitudes_count`（微博这边叫这名，不是 `like_count`） | ✅ |
| `repostCount` | `reposts_count` | ✅ |
| `displayTitle` | 用于相册页标题 | ✅ |

**计数全是 `int?`**：骨架已经在「接口没给」时整项不渲染（不是显示 0）。别在微博侧再补一个 `?? 0`，那会把「不知道」伪装成「确实是 0」。

### 4.2 `commentSection` —— 复用现有的 `_CommentSection`

`content_detail_page.dart:690` 的私有 `_CommentSection` 已经处理了微博的 mid 解析和 hotflow 调用。**原样传进去**即可，不用改。

### 4.3 `originBlock` —— 直接复用

```dart
item.origin == null
    ? null
    : OriginBlock(
        origin: item.origin!,
        onOpen: () => ContentOpener.open(context, item.origin!, headerLabel: '原动态'),
      )
```

`OriginBlock` 已经从私有改成公开类了，可以直接用。

### 4.4 `media` —— 微博视频在这里注入

```dart
isWeibo && item.kind == ContentKind.video && directUrl != null
    ? InlineVideoPlayer(
        url: directUrl,
        referer: 'https://weibo.com/',   // 必须带，否则微博 CDN 返回 403
        posterUrl: item.videoRef?.coverUrl,
        hintDuration: item.videoRef?.duration,
        isVertical: item.videoRef?.isVertical,
      )
    : null   // 图片走骨架默认的 PhotoGrid
```

---

## 5. 需要你决定的三个点

这三个我没有替你定，因为它们属于产品取向，不是实现细节。

### 5.1 微博视频要不要也走骨架？

- **走**：微博视频详情页的正文也统一了，但媒体区在正文**之后**（B 站骨架的顺序）。用户习惯了「视频在最上面、点开就能看」，视频排到数据栏上面可能需要滚动才能看到。
- **不走**：`_usesDynamicLayout` 加一条 `item.kind != ContentKind.video`，视频保持老排版。代价是同是微博内容、两种详情页长得不一样 —— 正是这次要消灭的那种分叉。

**我的看法**：走。但把视频**放在作者行之后、正文之前**（即给骨架加一个 `mediaFirst` 之类的开关，或让 `media` 自己决定位置）。这需要 B 站会话再动一点骨架，先谈。

### 5.2 `SourceBadge` / `KindBadge` 要不要保留？

B 站骨架**故意没有**这两个徽章，理由写在组件文档里：两个页面的 AppBar 标题已经写着「Bilibili · 动态」，「每条内容必须显示来源」这条需求已经满足，正文里不用再贴一次。

微博的 AppBar 同样是「微博 · 动态」。所以建议**跟随 B 站，不保留**。但这会改掉现在微博详情页上看得见的两个徽章 —— 如果用户对微博侧的来源标识有额外要求，先确认。

### 5.3 正文要不要保持可选中复制？

微博现在用 `SelectableText`，B 站骨架用 `Text`（**不可**长按选中复制）。用户说的是「正文和你的一样」，严格讲应该一致。但「不能复制微博正文」可能是个体验倒退 —— 用户转发/引用时经常要复制。

**我的看法**：保持 `Text` 与 B 站一致（用户明确说了「一样」），如果后续被反馈要复制再加。但这一点请你确认，因为改起来只是一个 widget 名。

---

## 6. 改法：具体到文件和行

假设方案 A 的骨架泛化已完成。

`lib/features/timeline/content_detail_page.dart`：

```dart
// 第 60 行附近，改判定
bool get _usesDynamicLayout =>
    item.kind != ContentKind.video || item.images.isNotEmpty;
// ↑ 具体条件取决于 §5.1 的决定。如果微博视频也走骨架，这里甚至可能
//   直接删掉平台判断，只保留「B 站视频进 PlayerPage」那条既有分流。

// build() 里，第 99 行附近
if (_usesDynamicLayout) {
  return Scaffold(
    backgroundColor: AppColors.card,
    appBar: _appBar(baseTitle, label),
    body: BiliDynamicBody(
      item: item,
      media: _mediaOverride(context),        // 见 §4.4
      originBlock: item.origin == null ? null : OriginBlock(...),
      commentSection: _CommentSection(item: item),
    ),
  );
}
```

注意 `_appBar` 现在是 B 站分支专用的，`title` 用 15px。微博沿用没问题（`baseTitle` 已经是 `${item.platform.label} · 动态`，微博会自动变成「微博 · 动态」）。

改完之后，**老排版那一大段（媒体区 + displayTitle + 徽章行 + SelectableText + Divider）会变成死代码**，但要小心：视频和视频无直链的提示还需要它。清理时逐条确认，别把 `_VideoCover` / `_WeiboNoUrlHint` 的引用弄丢。

---

## 7. 会被这次改动打挂的测试

跑 `flutter test` 之前先知道这三处：

| 文件 | 断言 | 处理 |
| --- | --- | --- |
| `test/features/bili_dynamic_body_test.dart:277` | 「微博内容不走 B 站骨架（微博分支完全不动）」 | **必须改**成「微博也走骨架」，这条是旧契约 |
| `test/features/content_detail_page_test.dart` | 微博视频详情页的 InlineVideoPlayer / CommentSection 断言 | 大概率仍通过（组件还在），但若视频改走骨架，`find.byType(InlineVideoPlayer)` 的父路径变了，要复核 |
| `test/features/opus_detail_layout_test.dart` | 源码级断言，检查 `content_detail_page.dart` 里 `BiliDynamicBody(` 存在 | 应仍通过 |

另外有一个**不用改、但请先跑一遍**的文件：
`test/features/weibo_detail_align_doc_test.dart` —— 它用微博的真实兜底形态验证
`hasOwnTitle` 判据成立，是本文档 §2 的事实依据。它现在全绿，改动前先跑它，
能确认「你以为的现状」和「实际的现状」是同一回事。

**新增测试建议**（这几条是这次的核心验收，别省）：

1. 纯文字微博（`title` = 正文截 60 字）：`find.textContaining(...)` 只找到 **1 个**（防「正文两遍」回归）
2. 真独立标题的微博：标题和正文各自找到 1 个
3. 微博数据栏：`评论 N` 用 `AppColors.weiboName` + `w700`；`赞和转发 M` 取 like+repost 之和
4. 微博计数为 null 时整项不渲染（不显示 0）
5. 微博视频：`InlineVideoPlayer` 仍在页面上（不管它在骨架里的哪个位置）

测试环境的坑：图片解码在 `flutter_test` 里**永远不完成**，会挂死进程。别对 `CachedImage` 做真实解码断言，只要结构。`BiliDynamicBody` 的既有测试（`bili_dynamic_body_test.dart`）可以直接照抄那套 fixture 写法。

---

## 8. 不要碰的文件

| 文件 | 原因 |
| --- | --- |
| `lib/features/timeline/bili_dynamic_body.dart` | B 站会话的骨架本体。除 §3 里谈好的 `media` 注入点外，别改里边任何排版 |
| `lib/features/timeline/opus_detail_page.dart` | B 站会话，两个详情页共用骨架的契约方 |
| `lib/widgets/photo_grid.dart` | 共用图片组件。2026-11-02 刚按用户要求删掉「长图 · 点击查看」角标，**别再顺手加回来** |
| `lib/features/timeline/content_card.dart`、`lib/providers.dart`、`lib/features/timeline/timeline_page.dart` | 按 `docs/COLLAB_PLAN.md` §3.1，这几个是界面会话的地盘 |
| `lib/data/weibo/weibo_parser.dart` 的 `_title()` | **不要改**。它的 60 字兜底是与 `ContentItem.displayTitle` 刻意对齐的，改了会让列表标题和详情页标题两套长度 |

---

## 9. 顺手可以做的一件好事（可选，不进验收）

微博的图片**比 B 站多一个能力**：解析器能拿到真实宽高。

`.env/weibo_mblog_structure2.md` 实测：

```
mblog.pics[0].geo.width    : int   480
mblog.pics[0].geo.height   : int   270
mblog.pics[0].geo.croped   : bool  false
```

`PhotoGrid` 早就有 `aspectRatios` 参数（B 站评论配图在用），但 `ContentItem` 没有这个字段，所以动态详情页的图目前一律按 4:3 或默认比例算高 —— **普通手机截图会被拉成全宽方图**。

如果要做：给 `ContentItem` 加 `List<double?> imageAspectRatios`，微博解析时从 `pics[i].geo` 算（注意 `large.geo` 在深度限制下未展开，用一级 `geo` 就行），B 站侧留空（`empty`），骨架的 `PhotoGrid` 传进去。B 站那边同样受益，但要 B 站会话配合改解析器，**建议单独立项**，别混在这次里。

---

## 10. 验收标准

- [ ] 纯文字微博详情页：正文**只出现一次**
- [ ] 作者行是 48px 圆头像 + 16px 粗体昵称 + 12px 时间（不再是"小字灰色作者名"）
- [ ] 带图微博：正文 15px，纯文字微博：正文 16px，行高都是 1.6
- [ ] 数据栏显示 `评论 N　赞和转发 M`，评论数品牌粉加粗
- [ ] 接口没给计数时该整项**不出现**（不是显示 0）
- [ ] 评论区与改动前**完全一致**（用户明确说「不包括评论区」）
- [ ] `dart analyze lib test` → No issues found
- [ ] `flutter test` 全绿（基线 1313，改动后数字会变，记录新数字）
- [ ] 真机截图对照（设备 HONOR Magic8 Pro，`adb` 在 `C:/Android/sdk/platform-tools/adb.exe`）

---

## 11. 环境（这个工程有几个非标准配置，不照做会卡住）

```bash
# 构建环境必须导出这些，tools/flutter-env.ps1 在 bash 里 source 不了（执行策略限制）
export PATH="/c/flutter/bin:/c/jdk/bin:$PATH"
export FLUTTER_ROOT=/c/flutter
export GRADLE_USER_HOME=/c/gradle-home     # 必须纯 ASCII，用户名含中文会让 Gradle 崩
export APPDATA=/d/Rrha/.env/appdata
export LOCALAPPDATA=/d/Rrha/.env/localappdata
export PUB_CACHE=/d/Rrha/.env/pub-cache

dart analyze lib test
flutter test
cd android && ./gradlew.bat assembleProfile --offline
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

`adb pull` 在 git-bash 下会被 MSYS 路径转换搞坏，先 `export MSYS2_ARG_CONV_EXCL="*"`，并给目标用 Windows 绝对路径（`"D:\\Rrha\\..."`）。

---

## 12. 交接记录

请在下面登记，避免两边同时改同一个文件：

| 日期 | 会话 | 做了什么 | 文件 |
| --- | --- | --- | --- |
| 2026-11-02 | B 站 | 抽出 `BiliDynamicBody`，B 站两个详情页共用；修「正文画两遍」 | `bili_dynamic_body.dart`（新建）、`opus_detail_page.dart`、`content_detail_page.dart` |
| 2026-11-02 | B 站 | 按用户要求删掉长图角标「长图 · 点击查看」 | `photo_grid.dart` |
| 2026-11-02 | 微博 | 微博**图文/纯文字/转发**接入 `BiliDynamicBody`；**视频保持老排版不动** | `content_detail_page.dart`、`bili_dynamic_body_test.dart`、`weibo_detail_skeleton_test.dart`（新建） |

### 微博会话的实施说明（2026-11-02）

用户这次的要求比文档原稿更窄，明确了一句：

> 「按照这个交接文档修改纯文字动态。**视频动态不要动**。」

因此 §5.1「微博视频要不要也走骨架」的开放问题**有了结论：不走**。

于是**没有**给 `BiliDynamicBody` 加 `media` 注入点（那正是为了让视频塞进骨架才需要的），
改动收敛成**一行判定**：

```dart
// 改前
bool get _usesDynamicLayout =>
    item.platform == Platform.bilibili && item.kind != ContentKind.video;

// 改后
bool get _usesDynamicLayout => item.kind != ContentKind.video;
```

平台判断直接去掉 —— 非视频就套骨架，两个平台一视同仁。
`video` 仍然走下面那套老排版（微博走 `InlineVideoPlayer`，B 站进 `PlayerPage`）。

§5.2 / §5.3 两个开放问题按文档建议取了默认值：
- **徽章不保留**（跟随 B 站，AppBar 已有「微博 · 动态」）；
- **正文用 `Text`**（与 B 站一致，不再可长按选中）。

#### 顺手修掉一个真机缺陷：原动态块文字右侧被裁切

真机截图发现转发微博的**原动态块**里，长段落右侧被硬裁掉
（「我会崩」「更久更久更」被切、且没有省略号）。

根因不在 `OriginBlock` 的 `maxLines`，而在它那两个 `Text` **没有宽度约束**：
`Column(crossAxisAlignment: start)` 下文本按单行无限延伸，被外层圆角容器裁掉，
`TextOverflow.ellipsis` 根本没机会画。

修法：两个 `Text` 各包一层 `SizedBox(width: double.infinity)`，让文本在容器内正常换行。

> ⚠️ 这个缺陷**在 B 站详情页同样存在**（`OriginBlock` 是共用的）。
> 本次在 `content_detail_page.dart` 内修复，B 站转发动态一并受益，
> 没有动 `bili_dynamic_body.dart`。

#### 验收结果

| 项 | 结果 |
| --- | --- |
| 纯文字微博正文只出现一次 | ✅ 单测 3 条（单段长 / 多段 / 真标题） |
| 作者行 48px + 16px 粗体 + 12px 时间 | ✅ 真机截图 `tools/shots/weibo-align-12.png` |
| 数据栏 `评论 N`（品牌粉加粗）+ `赞和转发 M` | ✅ 截图同上，单测覆盖颜色与加粗 |
| 计数为 null 时整项不渲染 | ✅ 单测 |
| 评论区与改动前一致 | ✅ 截图底部评论区正常 |
| 微博视频仍走老排版 | ✅ 单测 `微博视频仍然不走骨架` + 截图 `weibo-align-09.png` |
| 原动态块不再裁切 | ✅ 截图 `weibo-align-12.png` |
| `dart analyze` | ✅ No issues found |
| `flutter test --no-pub` | ✅ **1323 passed**（基线 1313，净增 10） |

#### 改动的测试

`test/features/bili_dynamic_body_test.dart` 里那条
「微博内容不走 B 站骨架（微博分支完全不动）」**是旧契约，已按新需求改写**为
「微博图文也走同一套骨架」，并**新增**一条「微博视频仍然不走骨架」把用户这次
「视频不要动」的要求钉死。这是需求变更，不是放宽断言。

