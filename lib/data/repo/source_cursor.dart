import '../../core/net/app_error.dart';
import '../models/content_item.dart';
import '../models/subscription.dart';
import 'timeline_repo.dart';

/// 「精选订阅」逐源翻页的游标。
///
/// ## 为什么需要它
///
/// 「全部关注」只有两个游标（B 站 `feed/all` 的 offset、微博 `feed/friends`
/// 的 `max_id`），因为它是**一次请求拉所有关注**。而「精选订阅」是
/// 「订阅源 × 路由」逐个拉，每个源各有自己的翻页位置 —— 6 个源就是 6 组游标。
///
/// 早先 `load()` 每个源只拉**第一页**（B 站 `pn=1` / 无 offset，微博无
/// `since_id`），所以用户只能看到每个源最近的 12~20 条：
/// 微博博主发得慢，一页 20 条可能就横跨十来天，于是「10 天前的动态全都没有」
/// （2026-11-08 用户反馈 warma 的情况）。
///
/// ## 两种游标不是一回事
///
/// - B 站**投稿**（`/x/space/wbi/arc/search`）用**页码** `pn`（1 起）；
/// - B 站**动态**（`/x/polymer/web-dynamic/v1/feed/space`）用 **offset 串**
///   （19 位数字，首次请求不传）；
/// - 微博（`getIndex`）用 `since_id`（指向**更早**的那一头，见
///   [WeiboApiClient] 的说明）。
///
/// 三者混用会让翻页跳到毫不相关的位置。所以这里分成三类字段，而不是一个
/// 通用 `String cursor`。
class SourceCursor {
  const SourceCursor({this.page = 1, this.offset, this.sinceId});

  /// B 站投稿的页码（下一页 = page + 1）。
  final int page;

  /// B 站动态的 offset 串；null 表示还没翻过（首屏）。
  final String? offset;

  /// 微博的 `since_id`；null 表示还没翻过（首屏）。
  final String? sinceId;

  /// 首屏游标：三个字段都取默认值。
  static const SourceCursor first = SourceCursor();

  bool get isFirst => page <= 1 && offset == null && sinceId == null;

  SourceCursor copyWith({int? page, String? offset, String? sinceId}) =>
      SourceCursor(
        page: page ?? this.page,
        offset: offset ?? this.offset,
        sinceId: sinceId ?? this.sinceId,
      );

  @override
  String toString() => 'SourceCursor(page=$page, offset=$offset, since=$sinceId)';

  @override
  bool operator ==(Object other) =>
      other is SourceCursor &&
      other.page == page &&
      other.offset == offset &&
      other.sinceId == sinceId;

  @override
  int get hashCode => Object.hash(page, offset, sinceId);
}

/// 一次「精选订阅」翻页的结果：条目 + 每个源的新游标 + 是否还有下一屏。
///
/// `nextCursors` 的键与 [TimelineResult.statuses] 一致（`{subscriptionId}#{routeKey}`），
/// 这样两个 map 可以直接对着看，排查时不必再拼一次 key。
class SelectedPage {
  const SelectedPage({
    required this.items,
    required this.statuses,
    required this.nextCursors,
    required this.hasMore,
    this.lastUpdated,
    this.staleFallbackUsed = false,
    this.fatalError,
    this.emptyHint,
  });

  final List<ContentItem> items;

  /// 本次各源的运行态（首屏要写进 `TimelineState.statuses`）。
  final Map<String, SourceStatus> statuses;

  /// 每个源的**下一页**游标。某个源到底了就不出现在这里。
  final Map<String, SourceCursor> nextCursors;

  /// 是否还有任何一个源能继续翻。false = 整个「精选订阅」到底了。
  final bool hasMore;

  final DateTime? lastUpdated;
  final bool staleFallbackUsed;
  final AppError? fatalError;
  final String? emptyHint;

  static const SelectedPage empty = SelectedPage(
    items: <ContentItem>[],
    statuses: <String, SourceStatus>{},
    nextCursors: <String, SourceCursor>{},
    hasMore: false,
  );
}
