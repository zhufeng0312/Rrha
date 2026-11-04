import 'dart:async';

/// 带并发上限的 map。
///
/// 多个订阅源不能无限并发拉取：B 站与微博都有风控，短时间密集请求会被限流
/// （429 / 微博 432），表现出来就是「刷新一下全红」。限并发是把请求摊平的
/// 最省事办法。
///
/// （这条约束历史上来自公共 RSSHub 实例的共享配额；实例移除后，平台侧风控
/// 让同一个约束继续成立。）
Future<List<R>> mapLimit<T, R>(
  List<T> items,
  int limit,
  Future<R> Function(T item) action,
) async {
  if (items.isEmpty) return <R>[];

  final workerCount = limit < 1 ? 1 : (limit > items.length ? items.length : limit);
  final results = List<R?>.filled(items.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      results[i] = await action(items[i]);
    }
  }

  await Future.wait<void>(
    List<Future<void>>.generate(workerCount, (_) => worker()),
  );

  return results.map((e) => e as R).toList();
}
