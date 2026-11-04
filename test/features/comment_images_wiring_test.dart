import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// B 站评论配图的**接线**防腐测试（2026-11-02）。
///
/// ## 背景：用户报「bilibili 卡片的评论区里的评论没有图片」
///
/// 真实根因是 `BiliContentParser.parseOne` 从来没读 `content.pictures[]`，
/// 于是 `comment.images` 恒为空，`comment_section.dart` 里
/// `if (comment.images.isNotEmpty)` 那段永远进不去。
///
/// UI 侧本来就完整（微博评论的图就是这么显示的），所以这次真正的活只有两件：
/// 1. 解析层填 `images`（`test/bili/comment_pictures_test.dart` 逐条覆盖）；
/// 2. UI 层把**宽高比**传下去，长截图才不会只显一条缝。
///
/// 第 2 件事没法用普通 widget 测试覆盖（要起整个评论列表 + 真实网络），
/// 所以这里退一步做源码级断言 —— 它拦得住「有人重构时把参数丢了」这类回归，
/// 而那种回归在真机上表现为「图又变成一条细线」，很难第一时间联想到接线问题。
void main() {
  final parserSource =
      File('lib/data/bili/comment_parser.dart').readAsStringSync();
  final sectionSource =
      File('lib/features/comments/comment_section.dart').readAsStringSync();
  final gridSource = File('lib/widgets/photo_grid.dart').readAsStringSync();

  group('解析层：B 站评论必须填 images 与宽高比', () {
    test('parseOne 里调用了 parsePictures', () {
      expect(
        parserSource.contains('images: parsePictures(contentMap)'),
        isTrue,
        reason: '不填 images 的话，评论区那段 if 永远不成立 —— 这就是用户报的现象',
      );
    });

    test('parseOne 里同时填了 imageAspectRatios', () {
      expect(
        parserSource.contains('imageAspectRatios: parsePictureAspectRatios(contentMap)'),
        isTrue,
        reason: '缺宽高比时超长截图会被裁成一条缝',
      );
    });

    test('图片地址走 normalizeImageUrl（http → https）', () {
      expect(
        parserSource.contains('BiliUser.normalizeImageUrl'),
        isTrue,
        reason: '服务端给的是 http://，Android 9+ 禁明文，不转会一片灰',
      );
    });

    test('读的字段是 img_src（不是微博那套 url / large.url）', () {
      expect(parserSource.contains("map['img_src']"), isTrue);
    });

    test('B 站 imageCount 恒为 0（接口给几张就是几张，没有「声称更多」）', () {
      // UI 里 `imageCount > images.length` 会渲染「共 N 张 · 点此加载全部」，
      // 那是微博独有的分支；B 站若也填非 0 就会挂一个永远点不出东西的提示。
      expect(
        RegExp(r'imageCount:\s*0,').hasMatch(parserSource),
        isTrue,
      );
    });
  });

  group('UI 层：把宽高比与 contain 传下去', () {
    test('_CommentImages 把 aspectRatios 传给 PhotoGrid', () {
      expect(
        sectionSource.contains('aspectRatios: comment.imageAspectRatios'),
        isTrue,
      );
    });

    test('_CommentImages 用 contain（不裁掉内容）', () {
      expect(sectionSource.contains('singleFit: BoxFit.contain'), isTrue);
    });
  });

  group('PhotoGrid：长图只露一段', () {
    test('被裁时从顶部露（长截图的开头才是关键信息）', () {
      expect(gridSource.contains('Alignment.topCenter'), isTrue);
    });

    test('⚠️ 不再有「长图 · 点击查看」角标（用户要求去掉）', () {
      // 2026-11-02 第四轮：角标压在图上挡内容，用户要求去掉。
      // 去掉的是**提示**，不是裁切行为 —— 下面那条仍在守裁切。
      //
      // ⚠️ 这里只能断言「没有角标**组件**」，不能断言源码里不含那段字样：
      // `_single` 的文档注释必须写明「为什么没有这个角标」，否则下一个人
      // 会以为是漏写了又加回去。所以查的是角标用到的图标与文案构造。
      expect(
        gridSource.contains('open_in_full_rounded'),
        isFalse,
        reason: '角标已按要求移除，重新加回来会挡住长图内容',
      );
      expect(
        gridSource.contains("'长图 · 点击查看'"),
        isFalse,
        reason: '文案本身不该再出现在代码里（注释里的说明不算）',
      );
    });

    test('裁切判据基于实际布局（neededHeight > containerHeight），不是死阈值',
        () {
      expect(gridSource.contains('neededHeight > containerHeight'), isTrue);
    });
  });
}
