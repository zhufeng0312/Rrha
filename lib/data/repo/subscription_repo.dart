import '../../core/net/app_error.dart';
import '../../core/storage/prefs.dart';
import '../models/content_item.dart';
import '../models/subscription.dart';

/// 添加订阅的结果。
class AddSubscriptionResult {
  const AddSubscriptionResult.success(this.subscription)
      : error = null,
        ok = true;

  const AddSubscriptionResult.failure(this.error)
      : subscription = null,
        ok = false;

  final bool ok;
  final String? error;
  final Subscription? subscription;
}

/// 订阅源管理（增 / 删 / 改别名）。
///
/// UID 校验放在这一层：网络层不该关心「用户填的是不是一串数字」。
class SubscriptionRepository {
  SubscriptionRepository({required Prefs prefs}) : _prefs = prefs;

  final Prefs _prefs;

  List<Subscription> all() => _prefs.subscriptions;

  List<Subscription> byPlatform(Platform platform) =>
      all().where((s) => s.platform == platform).toList();

  Future<AddSubscriptionResult> add({
    required Platform platform,
    required String uidInput,
    Set<FeedRoute>? routes,
    String? alias,
  }) async {
    final uid = uidInput.trim();
    if (uid.isEmpty) {
      return const AddSubscriptionResult.failure('请填写 UID');
    }

    switch (platform) {
      case Platform.bilibili:
        if (!RegExp(r'^\d{1,20}$').hasMatch(uid)) {
          return const AddSubscriptionResult.failure('B 站 UID 必须是纯数字（在空间页地址里）');
        }
        break;
      case Platform.weibo:
        if (!RegExp(r'^\d{4,20}$').hasMatch(uid)) {
          return const AddSubscriptionResult.failure('微博 UID 必须是纯数字（在主页地址里）');
        }
        break;
    }

    final id = '${platform.key}:$uid';
    if (all().any((s) => s.id == id)) {
      return const AddSubscriptionResult.failure('这个订阅源已经添加过了');
    }

    final effectiveRoutes = (routes == null || routes.isEmpty)
        ? FeedRoute.defaultsFor(platform).toSet()
        : routes;

    final sub = Subscription(
      platform: platform,
      uid: uid,
      routes: effectiveRoutes,
      alias: (alias == null || alias.trim().isEmpty) ? null : alias.trim(),
      addedAt: DateTime.now().toUtc(),
    );
    await _prefs.addSubscription(sub);
    return AddSubscriptionResult.success(sub);
  }

  Future<void> remove(String id) => _prefs.removeSubscription(id);

  Future<void> updateAlias(String id, String? alias) async {
    final list = all();
    final index = list.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final cleaned = (alias == null || alias.trim().isEmpty) ? null : alias.trim();
    list[index] = list[index].copyWith(alias: cleaned);
    await _prefs.setSubscriptions(list);
  }

  Future<void> toggleRoute(String id, FeedRoute route, bool enabled) async {
    final list = all();
    final index = list.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final current = list[index];
    final routes = Set<FeedRoute>.from(current.routes);
    if (enabled) {
      routes.add(route);
    } else {
      routes.remove(route);
      // 不允许把某平台的路由清空：至少保留一个，否则这个订阅没有意义。
      if (routes.where((r) => r.platform == current.platform).isEmpty) {
        routes.addAll(FeedRoute.defaultsFor(current.platform).take(1));
      }
    }
    list[index] = current.copyWith(routes: routes);
    await _prefs.setSubscriptions(list);
  }

  /// 构造用于 UI 展示的错误提示（供添加流程使用）。
  static AppError toError(String message) => AppError(AppErrorKind.unknown, message);
}
