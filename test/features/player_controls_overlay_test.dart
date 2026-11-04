import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/features/player/player_controls_overlay.dart';

/// 控制栏的**命中测试**防回归测试。
///
/// ## 这一组测试存在的唯一理由
///
/// §7.10 修的是一个非常隐蔽的缺陷：控制栏那层「铺满全屏的渐变容器」
/// （`Container(decoration: BoxDecoration(...))`）自身就是命中目标 ——
/// `RenderDecoratedBox` 重写了 `hitTestSelf` 并调用 `Decoration.hitTest`，
/// 而后者默认 `=> true`。它挂在手势层之上，于是**把单击与双击全吃掉**，
/// 表现是「控制栏一显示就再也点不掉，只能等自动隐藏」。
///
/// 这种缺陷靠真机手点极难稳定复现（上轮就被 3 秒自动隐藏掩盖过一次），
/// 所以必须有一组能在**毫秒级、可重复**地派发点击并断言「事件有没有穿透」的测试。
/// 下面每一条都配了**对照用例**（用旧写法构建同一个布局），
/// 用来证明这些断言真的能检出问题 —— 否则测试可能只是恰好通过。
void main() {
  late int screenTaps;
  late int screenDoubleTaps;
  late int playToggles;
  late ValueNotifier<double> progress;

  setUp(() {
    screenTaps = 0;
    screenDoubleTaps = 0;
    playToggles = 0;
    progress = ValueNotifier<double>(1000);
  });

  tearDown(() => progress.dispose());

  PlayerControlsOverlay overlay() => PlayerControlsOverlay(
        title: '测试视频标题',
        danmakuCount: 123,
        playing: false,
        progressMs: progress,
        duration: const Duration(seconds: 100),
        danmakuEnabled: true,
        fullscreen: false,
        progressBar: const SizedBox(height: 24),
        onBack: () {},
        onTogglePlay: () => playToggles++,
        onToggleDanmaku: () {},
        onOpenDanmakuSettings: () {},
        onToggleFullscreen: () {},
      );

  /// 复刻播放页 `_playerStack` 的层级关系：**手势层在下、控制栏在上**。
  ///
  /// 手势层的三个回调与真实代码一一对应：
  /// - `onTap` → `_controls.toggle`（计 [screenTaps]）
  /// - `onDoubleTap` → `_togglePlay`（计 [screenDoubleTaps]）
  /// - 控制栏内播放按钮的 `onTogglePlay`（计 [playToggles]）
  ///
  /// 把「屏幕双击」与「点按钮」分成两个计数，是为了能分别断言
  /// 「双击确实触发了播放/暂停」而「没有触发单击」。
  Widget harness(Widget top) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => screenTaps++,
                    onDoubleTap: () => screenDoubleTaps++,
                  ),
                ),
                Positioned.fill(child: top),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 舞台尺寸（`harness` 里的 `SizedBox`）。
  ///
  /// ⚠️ `Center` 会把它摆在屏幕正中，所以**全局坐标** ≠ 舞台内坐标。
  /// 默认测试画布是 800×600，400×400 的舞台因此位于 (200,100)–(600,500)。
  /// 直接用全局坐标 `Offset(200, 200)` 会落到舞台的左上角**外面** ——
  /// 那样 tap 根本碰不到手势层，断言会以「看起来像被吞掉」的方式假失败。
  const stage = Size(400, 400);
  const stageOrigin = Offset(200, 100);

  /// 舞台内坐标 → 全局坐标。
  Offset at(double x, double y) =>
      Offset(stageOrigin.dx + x, stageOrigin.dy + y);

  /// 舞台正中的大片空白（顶部条约 0–48，底部条约 352–400）。
  final blank = at(stage.width / 2, stage.height / 2);

  /// 双击（两次点击落在同一判定窗口内）。
  Future<void> doubleTapAt(WidgetTester tester, Offset globalAt) async {
    await tester.tapAt(globalAt);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(globalAt);
    // 越过双击判定窗口，让手势竞技场结算。
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('手势穿透（核心）', () {
    testWidgets('控制栏可见时，画面空白处的单击能穿透到手势层', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 400)); // 越过双击窗口

      expect(
        screenTaps,
        1,
        reason: '控制栏的装饰层若参与命中测试，这里会是 0 —— 那就是「控制栏点不掉」',
      );
    });

    testWidgets('控制栏可见时，画面空白处的双击触发播放/暂停，且不翻转控制栏', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      await doubleTapAt(tester, blank);

      expect(screenDoubleTaps, 1, reason: '双击必须能暂停/播放');
      expect(
        screenTaps,
        0,
        reason: '双击时 onTap 不该触发 —— 否则双击会顺带把控制栏翻掉（用户第 4 条要求）',
      );
    });

    testWidgets('顶部条与底部条之间的**每一处空白**都能穿透，不只是正中', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      // 顶部条约占舞台内 0–48，底部条约 352–400，中间都是空白。
      for (final y in <double>[70, 140, 200, 260, 330]) {
        await tester.tapAt(at(200, y));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(screenTaps, 5, reason: '只要有一处被吞掉，就说明前景里还残留可命中节点');
    });

    testWidgets('横向各处空白也都能穿透', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      for (final x in <double>[20, 100, 200, 300, 380]) {
        await tester.tapAt(at(x, 200));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(screenTaps, 5);
    });
  });

  group('前景按钮仍然可点（IgnorePointer 不能连前景一起挡掉）', () {
    testWidgets('底部条的播放按钮可用', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      await tester.tap(find.byTooltip('播放'));
      await tester.pump();

      expect(playToggles, 1);
      expect(screenTaps, 0, reason: '点在按钮上不该穿透成「切换控制栏」');
    });

    testWidgets('顶部条的返回按钮可用', (tester) async {
      var backs = 0;
      await tester.pumpWidget(
        harness(
          PlayerControlsOverlay(
            title: 't',
            danmakuCount: 0,
            playing: false,
            progressMs: progress,
            duration: Duration.zero,
            danmakuEnabled: true,
            fullscreen: false,
            progressBar: const SizedBox(height: 24),
            onBack: () => backs++,
            onTogglePlay: () {},
            onToggleDanmaku: () {},
            onOpenDanmakuSettings: () {},
            onToggleFullscreen: () {},
          ),
        ),
      );

      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      expect(backs, 1);
    });

    testWidgets('弹幕设置 / 全屏按钮可用', (tester) async {
      var settings = 0;
      var full = 0;
      await tester.pumpWidget(
        harness(
          PlayerControlsOverlay(
            title: 't',
            danmakuCount: 0,
            playing: true,
            progressMs: progress,
            duration: Duration.zero,
            danmakuEnabled: true,
            fullscreen: false,
            progressBar: const SizedBox(height: 24),
            onBack: () {},
            onTogglePlay: () {},
            onToggleDanmaku: () {},
            onOpenDanmakuSettings: () => settings++,
            onToggleFullscreen: () => full++,
          ),
        ),
      );

      await tester.tap(find.byTooltip('弹幕设置'));
      await tester.pump();
      await tester.tap(find.byTooltip('全屏'));
      await tester.pump();
      expect(settings, 1);
      expect(full, 1);
    });
  });

  group('对照用例：证明这组断言真的能检出「装饰层吞手势」', () {
    /// 旧写法：`Container(decoration:)` 直接铺满全屏、**不套 IgnorePointer**。
    /// 这正是 §7.10 修掉的那个结构。
    Widget legacyOverlay() => Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Colors.black54, Colors.transparent, Colors.black54],
            ),
          ),
          child: const Column(
            children: <Widget>[
              Row(children: <Widget>[SizedBox(height: 56)]),
              Spacer(),
              Row(children: <Widget>[SizedBox(height: 56)]),
            ],
          ),
        );

    testWidgets('旧写法确实吞掉空白处的单击（所以上面那条断言不是白写的）', (tester) async {
      await tester.pumpWidget(harness(legacyOverlay()));

      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        screenTaps,
        0,
        reason: 'BoxDecoration.hitTest 默认返回 true → 全屏装饰容器自己就是命中目标；'
            '这条对照用例证明测试能检出该问题',
      );
    });

    testWidgets('旧写法同样吞掉双击', (tester) async {
      await tester.pumpWidget(harness(legacyOverlay()));

      await doubleTapAt(tester, blank);

      expect(playToggles, 0, reason: '这就是用户报的「唤出控制栏后双击也不生效」');
    });

    testWidgets('新写法在同一次派发下是穿透的（正反对照）', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 400));

      expect(screenTaps, 1, reason: '同一位置、同一手势，新写法必须穿透');
    });
  });

  group('控制栏自身渲染', () {
    testWidgets('标题、弹幕数、时间文案都在', (tester) async {
      await tester.pumpWidget(harness(overlay()));
      expect(find.text('测试视频标题'), findsOneWidget);
      expect(find.text('弹幕 123'), findsOneWidget);
      expect(find.text('00:01 / 01:40'), findsOneWidget);
    });

    testWidgets('弹幕数为 0 时不显示角标', (tester) async {
      await tester.pumpWidget(
        harness(
          PlayerControlsOverlay(
            title: 't',
            danmakuCount: 0,
            playing: false,
            progressMs: progress,
            duration: Duration.zero,
            danmakuEnabled: false,
            fullscreen: false,
            progressBar: const SizedBox(height: 24),
            onBack: () {},
            onTogglePlay: () {},
            onToggleDanmaku: () {},
            onOpenDanmakuSettings: () {},
            onToggleFullscreen: () {},
          ),
        ),
      );
      expect(find.textContaining('弹幕 '), findsNothing);
    });

    testWidgets('装饰层渲染但不参与命中（存在性 + IgnorePointer 的显式断言）', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      // 渐变装饰层应当真的在（视觉不能退化成没有背景）。
      final decorated = find.descendant(
        of: find.byType(PlayerControlsOverlay),
        matching: find.byType(DecoratedBox),
      );
      expect(decorated, findsWidgets);
      expect(
        find.ancestor(of: decorated.first, matching: find.byType(IgnorePointer)),
        findsWidgets,
        reason: '装饰层必须被 IgnorePointer 包住，否则 RenderDecoratedBox.hitTestSelf 会吃掉点击',
      );
    });

    /// 用户需求：「视频控制栏字体是灰色的，改成白色」。
    ///
    /// 根因：这层永远叠在**黑色视频**上，但文字颜色原先没指定，
    /// 于是继承了亮色主题的深色文字 —— 在视频上几乎看不见。
    testWidgets('标题与时间文字都是白色（不能继承主题的深色）', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      final TextStyle? titleStyle = tester.widget<Text>(find.text('测试视频标题')).style;
      expect(titleStyle?.color, PlayerControlsOverlay.foreground);

      final TextStyle? timeStyle = tester.widget<Text>(find.text('00:01 / 01:40')).style;
      expect(timeStyle?.color, PlayerControlsOverlay.foreground);

      // 前景色就是白色本身，不是“某个主题色碰巧在亮色下看起来像白”。
      expect(PlayerControlsOverlay.foreground, isNotNull);
      final Color fg = PlayerControlsOverlay.foreground;
      expect((fg.r * 255).round(), 255);
      expect((fg.g * 255).round(), 255);
      expect((fg.b * 255).round(), 255);
    });

    testWidgets('弹幕数是白色（半透明白，仍然可读）', (tester) async {
      await tester.pumpWidget(harness(overlay()));
      final TextStyle? style = tester.widget<Text>(find.text('弹幕 123')).style;
      expect(style?.color, PlayerControlsOverlay.foregroundSecondary);
    });

    testWidgets('控制栏图标也是白色（返回/播放/弹幕/全屏）', (tester) async {
      await tester.pumpWidget(harness(overlay()));

      // `overlay()` 是「未播放 + 弹幕开」的状态，所以是 play_arrow + subtitles。
      for (final IconData icon in <IconData>[
        Icons.arrow_back_rounded,
        Icons.play_arrow_rounded,
        Icons.subtitles_rounded,
        Icons.tune_rounded,
        Icons.fullscreen_rounded,
      ]) {
        final Icon w = tester.widget<Icon>(find.byIcon(icon).first);
        expect(
          w.color,
          PlayerControlsOverlay.foreground,
          reason: '$icon 的图标色必须是白色，否则在黑色视频上看不清',
        );
      }
    });
  });

  group('formatDuration', () {
    test('分秒与时分秒', () {
      expect(PlayerControlsOverlay.formatDuration(Duration.zero), '00:00');
      expect(
        PlayerControlsOverlay.formatDuration(const Duration(seconds: 5)),
        '00:05',
      );
      expect(
        PlayerControlsOverlay.formatDuration(const Duration(minutes: 3, seconds: 7)),
        '03:07',
      );
      expect(
        PlayerControlsOverlay.formatDuration(
          const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
        '1:02:03',
      );
      // 负数（未加载时长时可能出现）不能崩。
      expect(
        PlayerControlsOverlay.formatDuration(const Duration(seconds: -1)),
        '00:00',
      );
    });
  });
}
