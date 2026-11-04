import '../../core/config/app_config.dart';
import '../bili/bili_client.dart';
import '../models/comment.dart';

/// 评论数据源的最小接口（平台无关）。
///
/// 抽出来是为了让 `CommentListNotifier` 的「排序 / 游标分页 / 楼中楼展开」
/// 状态机可以在完全离线的情况下被单元测试覆盖。
///
/// 参数统一收进 [CommentRequest]：B 站用 `oid + type + upMid`，
/// 微博只有 `mid`。游标（[CommentRequest] 之外）全程是**裸字符串**：
/// - B 站：`cursor.pagination_reply.next_offset`；
/// - 微博：`data.max_id`（原样拼进 URL，不做数值转换）。
abstract class CommentRepositoryLike {
  Future<CommentPage> loadFirst({required CommentRequest req});

  Future<CommentPage> loadMore({
    required CommentRequest req,
    required String cursor,
  });

  Future<SubCommentPage> loadReplies({
    required CommentRequest req,
    required String rootId,
    int page = 1,
  });
}

/// B 站评论仓库：只做「一次请求 = 一页结果」的薄封装，
/// 分页状态由 Controller 持有（属于界面生命周期）。
///
/// 注意：无登录态下 B 站评论接口可能返回 -352 或只给热门评论，
/// 这里不做任何「凑够 20 条」的伪造，失败就如实抛 [AppError]。
class CommentRepository implements CommentRepositoryLike {
  CommentRepository({required BiliClient client}) : _client = client;

  final BiliClient _client;

  /// 每页条数（需求：至少 20 条）。
  static const int pageSize = AppConfig.commentPageSize;

  /// 微博评论的兜底文案（历史常量名保留）。
  ///
  /// 现在微博评论**已实现**（见 `WeiboCommentRepository`），这条文案只在
  /// 微博侧取数失败且需要一句「还能去哪看」的提示时使用。
  static const String weiboCommentPlaceholder =
      '微博评论获取失败：可点下方「在应用内查看这条微博」，用内置浏览器查看';

  @override
  Future<CommentPage> loadFirst({required CommentRequest req}) => _client.comments(
        oid: req.oid,
        type: req.type,
        sort: req.sortValue,
        upMid: req.upMid,
      );

  @override
  Future<CommentPage> loadMore({
    required CommentRequest req,
    required String cursor,
  }) =>
      _client.comments(
        oid: req.oid,
        type: req.type,
        sort: req.sortValue,
        cursor: cursor,
        upMid: req.upMid,
      );

  @override
  Future<SubCommentPage> loadReplies({
    required CommentRequest req,
    required String rootId,
    int page = 1,
  }) {
    // B 站楼中楼接口的 root 是数值 rpid。解析层写进主键时用的就是 `'$rpid'`，
    // 所以回读无损；解析不出数字（不该发生）时按 0 交给服务端报错，不猜。
    final int root = int.tryParse(rootId) ?? 0;
    return _client.replies(
      oid: req.oid,
      type: req.type,
      root: root,
      pn: page,
      upMid: req.upMid,
    );
  }
}
