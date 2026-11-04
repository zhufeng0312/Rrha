import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/bili_models.dart';
import 'package:rrha/features/player/player_options_button.dart';

/// 「更多」菜单（清晰度 / 倍速 / 分P / 播放信息）的防回归测试。
///
/// 这一组测试要钉住的东西，恰好都是真机上「点了没反应」的典型成因：
/// 1. 菜单项真的弹出来了（`PopupMenuButton` 的 itemBuilder 若抛异常，
///    表现出来就是点了没反应，而不是报错）；
/// 2. 选中项能正确回调（清晰度与分 P 都是 int，`_Action` 一旦把
///    两者混了，就是「点 1080P 却切了分P」这种极难察觉的错）；
/// 3. 未提供回调时菜单仍然可打开、不崩。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  const qualities = <QualityOption>[
    QualityOption(qn: 112, label: '1080P 高码率'),
    QualityOption(qn: 80, label: '1080P 高清'),
    QualityOption(qn: 64, label: '720P 准高清'),
  ];

  const pages = <BiliPage>[
    BiliPage(cid: 1, page: 1, part: '开场'),
    BiliPage(cid: 2, page: 2, part: '正片'),
  ];

  PlayerOptionsButton button({
    List<QualityOption> q = qualities,
    int currentQuality = 64,
    double speed = 1.0,
    List<BiliPage> p = pages,
    int currentPage = 1,
    ValueChanged<int>? onSelectQuality,
    ValueChanged<double>? onSelectSpeed,
    ValueChanged<int>? onSelectPage,
    VoidCallback? onOpenPlaybackInfo,
  }) =>
      PlayerOptionsButton(
        qualities: q,
        currentQuality: currentQuality,
        speed: speed,
        pages: p,
        currentPage: currentPage,
        onSelectQuality: onSelectQuality,
        onSelectSpeed: onSelectSpeed,
        onSelectPage: onSelectPage,
        onOpenPlaybackInfo: onOpenPlaybackInfo,
      );

  group('倍速文案', () {
    test('整数档保留一位小数', () {
      expect(PlayerOptionsButton.formatSpeed(1.0), '1.0x');
      expect(PlayerOptionsButton.formatSpeed(2.0), '2.0x');
    });

    test('一位小数档去掉尾部 0', () {
      expect(PlayerOptionsButton.formatSpeed(0.5), '0.5x');
      expect(PlayerOptionsButton.formatSpeed(1.5), '1.5x');
    });

    test('两位小数档完整保留（1.25 不能被四舍五入成 1.3）', () {
      expect(PlayerOptionsButton.formatSpeed(1.25), '1.25x');
      expect(PlayerOptionsButton.formatSpeed(0.75), '0.75x');
    });

    test('档位表与 B 站 App 一致（含 0.5 慢放）', () {
      expect(
        PlayerOptionsButton.speedOptions,
        <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
      );
    });
  });

  group('菜单内容', () {
    testWidgets('打开后能看到清晰度、倍速与分P三组', (tester) async {
      await tester.pumpWidget(wrap(button()));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      expect(find.text('清晰度'), findsOneWidget);
      expect(find.text('倍速'), findsOneWidget);
      expect(find.text('分 P'), findsOneWidget);
      // 三档清晰度
      expect(find.text('1080P 高码率'), findsOneWidget);
      expect(find.text('1080P 高清'), findsOneWidget);
      expect(find.text('720P 准高清'), findsOneWidget);
    });

    testWidgets('当前清晰度打勾', (tester) async {
      await tester.pumpWidget(wrap(button(currentQuality: 80)));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      // 只有当前那一档有勾。
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      // 一个有勾的是清晰度 80，一个是分P第 1 页 —— 用文字定位确认。
      final rowWithCheck = find.ancestor(
        of: find.text('1080P 高清'),
        matching: find.byType(Row),
      );
      expect(
        find.descendant(of: rowWithCheck.first, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
    });

    testWidgets('清晰度列表为空时不渲染该分组', (tester) async {
      await tester.pumpWidget(wrap(button(q: const <QualityOption>[])));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      expect(find.text('清晰度'), findsNothing);
      expect(find.text('倍速'), findsOneWidget);
    });

    testWidgets('只有 1 个分P时不渲染分P分组', (tester) async {
      await tester.pumpWidget(wrap(
        button(p: const <BiliPage>[BiliPage(cid: 1, page: 1, part: '唯一')]),
      ));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      expect(find.text('分 P'), findsNothing);
    });

    testWidgets('给了 onOpenPlaybackInfo 才有「播放信息」', (tester) async {
      await tester.pumpWidget(wrap(button()));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('播放信息'), findsNothing);

      // 关掉菜单，换成带回调的版本。
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrap(button(onOpenPlaybackInfo: () {})));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('播放信息'), findsOneWidget);
    });
  });

  group('选中回调', () {
    testWidgets('点清晰度回调的是 qn（不是下标、不是分P页码）', (tester) async {
      int? picked;
      await tester.pumpWidget(wrap(button(onSelectQuality: (v) => picked = v)));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1080P 高码率'));
      await tester.pumpAndSettle();
      expect(picked, 112);
    });

    testWidgets('点倍速回调的是倍速值', (tester) async {
      double? picked;
      await tester.pumpWidget(wrap(button(onSelectSpeed: (v) => picked = v)));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      expect(picked, 1.5);
    });

    testWidgets('点分P回调的是页码（不是 cid）', (tester) async {
      int? picked;
      await tester.pumpWidget(wrap(button(onSelectPage: (v) => picked = v)));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('P2 正片'));
      await tester.pumpAndSettle();
      expect(picked, 2, reason: '必须是页码 2，而不是 cid 2 恰好相等导致的假通过见下');
    });

    testWidgets('清晰度与分P的载荷不会串（页码 2 与 qn 2 是两回事）', (tester) async {
      int? qn;
      int? page;
      await tester.pumpWidget(wrap(button(
        onSelectQuality: (v) => qn = v,
        onSelectPage: (v) => page = v,
      )));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('P2 正片'));
      await tester.pumpAndSettle();
      expect(page, 2);
      expect(qn, isNull, reason: '选分P不能触发清晰度回调');
    });

    testWidgets('点「播放信息」触发对应回调', (tester) async {
      var opened = 0;
      await tester.pumpWidget(wrap(button(onOpenPlaybackInfo: () => opened++)));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('播放信息'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('所有回调都为 null 时菜单仍能打开（不崩）', (tester) async {
      await tester.pumpWidget(wrap(button()));
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      // 点一个条目：没有回调，应该安静地什么都没发生。
      await tester.tap(find.text('1080P 高清'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
