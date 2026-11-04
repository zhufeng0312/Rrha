import '../../core/net/app_error.dart';
import 'content_item.dart';

/// RSSHub 路由类型。
enum FeedRoute {
  bilibiliVideo(Platform.bilibili, '/bilibili/user/video/:uid', '视频'),
  bilibiliDynamic(Platform.bilibili, '/bilibili/user/dynamic/:uid', '动态'),
  weiboUser(Platform.weibo, '/weibo/user/:uid', '微博');

  const FeedRoute(this.platform, this.template, this.label);

  final Platform platform;

  /// RSSHub 路由模板。
  final String template;

  final String label;

  /// 用人填的 UID 生成实际路径。
  String path(String uid) => template.replaceAll(':uid', uid);

  String get key => name;

  static FeedRoute? fromKey(String? key) {
    if (key == null) return null;
    for (final r in FeedRoute.values) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// 某平台在添加订阅时默认勾选的路由。
  static List<FeedRoute> defaultsFor(Platform platform) {
    switch (platform) {
      case Platform.bilibili:
        return <FeedRoute>[FeedRoute.bilibiliVideo, FeedRoute.bilibiliDynamic];
      case Platform.weibo:
        return <FeedRoute>[FeedRoute.weiboUser];
    }
  }
}

/// 一个订阅源 = 一个（平台 + UID + 路由集合）。
class Subscription {
  const Subscription({
    required this.platform,
    required this.uid,
    required this.routes,
    this.alias,
    required this.addedAt,
  });

  final Platform platform;
  final String uid;

  /// 勾选的路由。B 站可同时要视频与动态。
  final Set<FeedRoute> routes;

  /// 用户可编辑的别名（UP 名要联网才知道，别名让列表更好认）。
  final String? alias;

  final DateTime addedAt;

  /// 稳定 id：`{platform}:{uid}`。
  String get id => '${platform.key}:$uid';

  String get displayName {
    final a = alias?.trim();
    if (a != null && a.isNotEmpty) return a;
    switch (platform) {
      case Platform.bilibili:
        return 'B 站 UP $uid';
      case Platform.weibo:
        return '微博 $uid';
    }
  }

  /// 参与拉取的路由（保持稳定顺序，便于测试）。
  List<FeedRoute> get activeRoutes {
    final list = routes.where((r) => r.platform == platform).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (list.isEmpty) return FeedRoute.defaultsFor(platform);
    return list;
  }

  Subscription copyWith({String? alias, Set<FeedRoute>? routes}) => Subscription(
        platform: platform,
        uid: uid,
        routes: routes ?? this.routes,
        alias: alias ?? this.alias,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform.key,
        'uid': uid,
        'routes': routes.map((r) => r.key).toList(),
        'alias': alias,
        'addedAt': addedAt.toIso8601String(),
      };

  static Subscription? fromJson(Map<String, dynamic> json) {
    final platform = Platform.fromKey(json['platform'] as String?);
    final uid = json['uid'];
    if (platform == null || uid is! String || uid.isEmpty) return null;
    final rawRoutes = json['routes'];
    final routes = <FeedRoute>{};
    if (rawRoutes is List) {
      for (final r in rawRoutes) {
        final parsed = FeedRoute.fromKey(r as String?);
        if (parsed != null) routes.add(parsed);
      }
    }
    if (routes.isEmpty) routes.addAll(FeedRoute.defaultsFor(platform));
    return Subscription(
      platform: platform,
      uid: uid,
      routes: routes,
      alias: json['alias'] as String?,
      addedAt: DateTime.tryParse('${json['addedAt']}') ?? DateTime.now().toUtc(),
    );
  }

  @override
  bool operator ==(Object other) => other is Subscription && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 订阅源的运行态（不持久化，每次刷新重建）。
class SourceStatus {
  const SourceStatus({
    required this.subscriptionId,
    this.route,
    this.lastSuccessAt,
    this.error,
    this.errorKind,
    this.fromCache = false,
    this.cachedAgeLabel,
    this.itemCount = 0,
  });

  final String subscriptionId;
  final FeedRoute? route;
  final DateTime? lastSuccessAt;

  /// 用户可读的错误文案（AppError.message）。
  final String? error;

  /// 错误的分类（[AppError.kind]）。
  ///
  /// 单独带一份的原因：UI 需要区分「登录类错误」和「其它错误」—— 前者该引导
  /// 用户去内置浏览器登录一次，后者只是「换浏览器打开主页」。靠文案子串判断
  /// 太脆（改一个字就失效），而把整个 [AppError] 放进状态又会让状态变重、
  /// 且 `SourceStatus` 要能被无脑比较。**可空**：调用方不传就是「未分类」。
  final AppErrorKind? errorKind;

  /// 本次结果是否来自缓存（降级）。
  final bool fromCache;

  /// 缓存年龄描述（「3 分钟前」）。
  final String? cachedAgeLabel;

  final int itemCount;

  bool get hasError => error != null;

  /// 是否为「登录类」错误（未登录 / 登录失效）：UI 据此决定该怎么引导用户。
  bool get isAuthError => errorKind == AppErrorKind.auth;

  SourceStatus copyWith({
    DateTime? lastSuccessAt,
    String? error,
    AppErrorKind? errorKind,
    bool? fromCache,
    String? cachedAgeLabel,
    int? itemCount,
    bool clearError = false,
  }) =>
      SourceStatus(
        subscriptionId: subscriptionId,
        route: route,
        lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
        error: clearError ? null : (error ?? this.error),
        errorKind: clearError ? null : (errorKind ?? this.errorKind),
        fromCache: fromCache ?? this.fromCache,
        cachedAgeLabel: cachedAgeLabel ?? this.cachedAgeLabel,
        itemCount: itemCount ?? this.itemCount,
      );
}
