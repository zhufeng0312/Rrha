import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/theme/app_colors.dart';
import 'package:rrha/widgets/video_stats_row.dart';

/// 播放页统计行（`docs/BILI_HANDOFF.md` §3.1）的防回归测试。
///
/// 这一条之所以需要测试，是因为它修的是「**数据早就在手上、只差显示**」：
/// `BiliVideoInfo` 从第一天起就解析了 like/coin/favorite/share/reply，
/// 而播放页只拼了 view 和 danmaku。也就是说，如果哪次重排又把这几个字段
/// 漏掉，界面依然「看起来正常」（只是少了几个数字），真机上极难发现。
///
/// 因此这里断言的是**字段与图标的对应关系**，而不只是「数字出现了」。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: child),
      );

  VideoStatsRow row({
    int view = 0,
    int danmaku = 0,
    int like = 0,
    int coin = 0,
    int favorite = 0,
    int share = 0,
    int reply = 0,
    VoidCallback? onTapReply,
  }) =>
      VideoStatsRow(
        view: view,
        danmaku: danmaku,
        like: like,
        coin: coin,
        favorite: favorite,
        share: share,
        reply: reply,
        onTapReply: onTapReply,
      );

  group('数字折算', () {
    test('一万以下原样输出', () {
      expect(VideoStatsRow.formatCount(0), '0');
      expect(VideoStatsRow.formatCount(1), '1');
      expect(VideoStatsRow.formatCount(9999), '9999');
    });

    test('万位保留一位小数', () {
      expect(VideoStatsRow.formatCount(10000), '1.0万');
      expect(VideoStatsRow.formatCount(12345), '1.2万');
      expect(VideoStatsRow.formatCount(99999999), '10000.0万');
    });

    test('亿位保留一位小数', () {
      expect(VideoStatsRow.formatCount(100000000), '1.0亿');
      expect(VideoStatsRow.formatCount(234000000), '2.3亿');
    });
  });

  group('七个字段各自渲染', () {
    testWidgets('六个统计数字全部出现在一行里', (tester) async {
      await tester.pumpWidget(wrap(
        row(
          view: 12,
          danmaku: 34,
          like: 56,
          coin: 78,
          favorite: 90,
          share: 11,
          reply: 22,
        ),
      ));

      for (final value in <String>['12', '34', '56', '78', '90', '11', '22']) {
        expect(
          find.text(value),
          findsOneWidget,
          reason: '缺少统计值 $value —— 说明某个字段没被渲染',
        );
      }
    });

    testWidgets('数值与图标的对应关系正确（投币不能显示成收藏数）', (tester) async {
      await tester.pumpWidget(wrap(
        row(
          view: 1,
          danmaku: 2,
          like: 3,
          coin: 4,
          favorite: 5,
          share: 6,
          reply: 7,
        ),
      ));

      // 逐个图标往上找最近的那个 Text，断言它显示的就是对应字段。
      final pairs = <(IconData, String)>[
        (Icons.play_circle_outline_rounded, '1'),
        (Icons.subtitles_outlined, '2'),
        (Icons.thumb_up_outlined, '3'),
        (Icons.paid_outlined, '4'),
        (Icons.star_border_rounded, '5'),
        (Icons.share_outlined, '6'),
        (Icons.chat_bubble_outline_rounded, '7'),
      ];

      for (final (icon, expected) in pairs) {
        final iconFinder = find.byIcon(icon);
        expect(iconFinder, findsOneWidget, reason: '图标 $icon 缺失');
        // Row 的结构是 [Icon, SizedBox, Text]，取同一 Row 里的 Text。
        final textFinder = find.descendant(
          of: find.ancestor(of: iconFinder, matching: find.byType(Row)).first,
          matching: find.byType(Text),
        );
        expect(
          tester.widget<Text>(textFinder).data,
          expected,
          reason: '图标 $icon 旁边应该显示 $expected',
        );
      }
    });

    testWidgets('大数字按万/亿折算显示', (tester) async {
      await tester.pumpWidget(wrap(row(view: 1234567, like: 234000000)));

      expect(find.text('123.5万'), findsOneWidget);
      expect(find.text('2.3亿'), findsOneWidget);
    });

    testWidgets('值为 0 时仍然渲染（不隐藏整行）', (tester) async {
      await tester.pumpWidget(wrap(row()));

      // 七个 0：不隐藏是有意的 —— 「确实是 0」在 B 站侧与「接口没给」
      // 已合流成 int，隐藏会让用户以为是这一行坏了。
      expect(find.text('0'), findsNWidgets(7));
    });
  });

  group('可点性', () {
    testWidgets('给了 onTapReply 时点「评论」触发回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(wrap(
        row(reply: 33, onTapReply: () => taps++),
      ));

      await tester.tap(find.text('33'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('没给 onTapReply 时评论数不可点（点了也不报错）', (tester) async {
      await tester.pumpWidget(wrap(row(reply: 33)));
      // 没有 InkWell，所以点它不该产生任何异常。
      await tester.tap(find.text('33'));
      await tester.pump();
      expect(find.text('33'), findsOneWidget);
    });

    testWidgets('可点项用链接色，不可点项用次要灰', (tester) async {
      await tester.pumpWidget(wrap(
        row(reply: 33, like: 44, onTapReply: () {}),
      ));

      final replyText = tester.widget<Text>(find.text('33'));
      final likeText = tester.widget<Text>(find.text('44'));
      expect(replyText.style?.color, AppColors.link);
      expect(likeText.style?.color, AppColors.textSecondary);
    });

    testWidgets('可点项命中区高度不小于 30px（手指点得准）', (tester) async {
      await tester.pumpWidget(wrap(
        row(reply: 33, onTapReply: () {}),
      ));

      final size = tester.getSize(
        find.ancestor(
          of: find.text('33'),
          matching: find.byType(InkWell),
        ).first,
      );
      expect(size.height, greaterThanOrEqualTo(30));
    });
  });
}
