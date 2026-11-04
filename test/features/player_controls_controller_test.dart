import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/features/player/player_controls_controller.dart';

/// 控制栏显隐控制器的**时序**单测。
///
/// 这一组测试存在的理由：这些时序 bug 在真机上的表现都极其模糊
/// （「点了没反应」「看着看着按钮没了」「拖到一半消失了」「一直显示点不掉」），
/// 靠手工点击很难稳定复现；而它们完全不依赖 widget，纯单测就能钉死。
///
/// ⚠️ 其中「暂停时仍然自动隐藏」这条是**被真机推翻后改回来的**规则：
/// 最初的实现让暂停时停表（想「让用户安心看画面」），
/// 结果视频一进暂停/加载态控制栏就永久遮住画面 —— 正是用户报的「点不掉」。
void main() {
  group('单击显隐', () {
    test('初始可见', () {
      final c = PlayerControlsController();
      expect(c.visible, isTrue);
      c.dispose();
    });

    test('单击隐藏、再单击显示', () {
      final c = PlayerControlsController();
      c.toggle();
      expect(c.visible, isFalse);
      c.toggle();
      expect(c.visible, isTrue);
      c.dispose();
    });

    test('隐藏后不应再被「到点的旧定时器」唤回', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 30),
      );
      var changes = 0;
      c.onChanged = () => changes++;

      c.toggle(); // 隐藏：必须先取消那个已排队的定时器
      expect(c.visible, isFalse);
      expect(c.timerActive, isFalse, reason: '隐藏的同时必须停表');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.visible, isFalse, reason: '旧定时器不能把控制栏唤回来');
      expect(changes, 1, reason: '只应触发一次「隐藏」通知');
      c.dispose();
    });

    test('隐藏状态下 bump 不会把控制栏弹出来', () {
      final c = PlayerControlsController();
      c.toggle();
      expect(c.visible, isFalse);
      c.bump();
      expect(c.visible, isFalse, reason: '交互不等于要显示');
      c.dispose();
    });
  });

  group('3 秒自动隐藏', () {
    test('到点自动隐藏', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 40),
      );
      c.bump();
      expect(c.visible, isTrue);
      expect(c.timerActive, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.visible, isFalse);
      c.dispose();
    });

    test('每次交互都重置计时（不到点就不会隐藏）', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 80),
      );
      for (int i = 0; i < 4; i++) {
        c.bump();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(c.visible, isTrue, reason: '第 $i 次交互后不应隐藏');
      }
      // 停止交互后到点才隐藏。
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(c.visible, isFalse);
      c.dispose();
    });

    test('暂停时**仍然**自动隐藏（这是被真机推翻后改回来的规则）', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 40),
      );
      // 先让计时器跑起来（模拟「用户刚点出来」），再进入暂停。
      c.bump();
      expect(c.timerActive, isTrue);
      c.setPaused(true);
      expect(c.timerActive, isTrue, reason: '暂停不能让已经在跑的计时器停下');

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        c.visible,
        isFalse,
        reason: '暂停时也必须能自动隐藏 —— 否则视频一暂停，控制栏就永久遮住画面、'
            '而用户每次点击又可能落进双击判定窗口，表现就是「点不掉」',
      );
      c.dispose();
    });

    test('加载/暂停期间反复 setPaused 不会把控制栏「钉」在可见态', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 40),
      );
      // 用户点出控制栏（起表），随后播放状态抖动
      // ——加载完成、通道回退、暂停取样都会触发 setPaused。
      c.bump();
      for (int i = 0; i < 3; i++) {
        c.setPaused(true);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        c.setPaused(false);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.visible, isFalse, reason: '状态抖动不能把控制栏永久钉在可见态');
      c.dispose();
    });

    test('拖动期间停表，拖动结束后重新计时', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 40),
      );
      c.beginDrag();
      expect(c.timerActive, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.visible, isTrue, reason: '拖到一半不能消失');

      c.endDrag();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.visible, isFalse);
      c.dispose();
    });

    test('拖动期间用户手动隐藏 → 拖动结束后不应被唤回', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 40),
      );
      c.beginDrag();
      c.toggle(); // 用户把控制栏点掉了
      expect(c.visible, isFalse);

      c.endDrag();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.visible, isFalse, reason: 'endDrag 不能把用户明确关掉的控制栏打开');
      c.dispose();
    });

    test('autoHideAllowed 的约束：只有「已隐藏」与「持续交互中」不允许计时', () {
      final c = PlayerControlsController();
      expect(c.autoHideAllowed, isTrue);

      c.beginDrag();
      expect(c.autoHideAllowed, isFalse, reason: '拖动中不允许自动隐藏');

      c.endDrag();
      c.hide();
      expect(c.autoHideAllowed, isFalse, reason: '已经隐藏了就没什么可隐藏的');

      // 暂停**不再**是例外。
      c.show();
      c.setPaused(true);
      expect(c.autoHideAllowed, isTrue, reason: '暂停不该阻止自动隐藏');
      c.dispose();
    });
  });

  group('通知与释放', () {
    test('隐藏是「立即生效」的：hide() 当场翻转并把通知发出去', () {
      final c = PlayerControlsController();
      final log = <bool>[];
      c.onChanged = () => log.add(c.visible);

      c.hide();
      expect(log, <bool>[false]);

      c.show();
      expect(log, <bool>[false, true]);
      c.dispose();
    });

    test('dispose 之后定时器不再触发通知', () async {
      final c = PlayerControlsController(
        autoHideDelay: const Duration(milliseconds: 30),
      );
      var changes = 0;
      c.onChanged = () => changes++;
      c.bump();
      c.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(changes, 0, reason: '已释放的控制器不该再回调（会 setState after dispose）');
    });
  });
}
