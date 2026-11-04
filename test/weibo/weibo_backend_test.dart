import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/weibo/weibo_backend.dart';

/// 微博降级形态与文案的验收。
///
/// 除了「当前就是 webView」这种状态断言，本轮重点是一条**防腐断言**：
/// 微博已经降级成「内置浏览器打开」，文案里就绝不能再出现以前的那些
/// 承诺 —— 一旦出现，用户会以为评论区/视频还能在 App 内看，结局是
/// 每次点击都失败。这条守卫比任何实现细节都重要，因为它挡住的是
/// 「顺手把老文案粘回来」这种最常见的回归。
void main() {
  group('后端形态', () {
    test('当前采用 webView（微博接口游客态恒 432，不做破解）', () {
      expect(weiboBackend, WeiboBackend.webView);
      expect(weiboBackend, isNot(WeiboBackend.api));
    });

    test('枚举两个值都在（api 是历史形态，保留但未启用）', () {
      expect(WeiboBackend.values.length, 2);
      expect(WeiboBackend.values, contains(WeiboBackend.api));
      expect(WeiboBackend.values, contains(WeiboBackend.webView));
    });
  });

  group('文案', () {
    test('三段文案都非空', () {
      expect(WeiboCopy.statusPanelReason.trim().isNotEmpty, isTrue);
      expect(WeiboCopy.facadeSubtitle.trim().isNotEmpty, isTrue);
      expect(WeiboCopy.facadeTitle('x').trim().isNotEmpty, isTrue);
    });

    test('占位卡标题带上博主名（用户要能分辨是哪一位）', () {
      expect(WeiboCopy.facadeTitle('某博主'), contains('某博主'));
      expect(WeiboCopy.facadeTitle('某博主'), isNot(contains('x')));
    });

    test('状态面板与占位卡说的不是互相矛盾的两件事', () {
      // 两处文案都描述同一个原因，所以必须都提到登录态与内置浏览器；
      // 措辞可以不同（面板讲「打开博主主页」，卡片讲「打开该博主主页」）。
      expect(WeiboCopy.statusPanelReason, contains('登录'));
      expect(WeiboCopy.facadeSubtitle, contains('登录'));
    });
  });

  group('防腐断言：不许再承诺 App 内能看微博内容', () {
    test('三段文案都不含过期承诺与实现细节', () {
      // 为什么钉这条：
      // - 'WEIBO_COOKIE' / 'RSSHub' / '实例未配置' 是**实现侧**的概念，
      //   微博已经不走 RSSHub 了，出现在用户文案里等于告诉记者「换个实例就好」，
      //   而换实例根本救不了（接口要求登录态）。
      // - '能看评论' / '能播放' 是**已经不成立的承诺**，会直接把用户骗进
      //   一个必然失败的操作。
      const List<String> forbidden = <String>[
        'WEIBO_COOKIE',
        '能看评论',
        '能播放',
        'RSSHub',
        '实例未配置',
      ];
      for (final String s in <String>[
        WeiboCopy.statusPanelReason,
        WeiboCopy.facadeSubtitle,
        WeiboCopy.facadeTitle('x'),
      ]) {
        for (final String bad in forbidden) {
          expect(
            s.contains(bad),
            isFalse,
            reason: '文案「$s」不该出现「$bad」',
          );
        }
      }
    });

    test('解释性文案明确指向「内置浏览器」', () {
      // 用户看完必须知道下一步动作是「在浏览器里打开」，否则只剩
      // 「怎么没有内容」的困惑。
      for (final String s in <String>[
        WeiboCopy.statusPanelReason,
        WeiboCopy.facadeSubtitle,
      ]) {
        expect(s, contains('内置浏览器'), reason: '文案「$s」要给出正确引导');
      }
      // 标题为了短，用的是「在浏览器里打开 <博主名>」这种写法（不含「内置」
      // 二字），引导词由同一张卡上的副标题承担，所以这里只要求出现「浏览器」。
      expect(
        WeiboCopy.facadeTitle('某博主'),
        contains('浏览器'),
        reason: '卡片标题也要出现「浏览器」，与副标题一致',
      );
    });
  });
}
