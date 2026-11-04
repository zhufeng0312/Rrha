import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 动态详情页**排版骨架**的防腐测试（2026-11-02，第三轮修订）。
///
/// 用户给了参考稿（`桌面/动态内部.html`）要求「动态点开之后参考这个 html」，
/// 第二轮之后又指出「纯文字动态你还是没有按照提供的 html 文件来做，
/// 动态内容出现两次」。
///
/// ## 参考稿里其实有**两屏**，不是一个
///
/// | 参考稿 | id | 昵称色 | 正文字号 |
/// | --- | --- | --- | --- |
/// | 带图动态 | `page-detail-image` | `text-pink` 品牌粉 | `text-[15px]` |
/// | 纯文字动态 | `page-detail-text` | `text-primary` 深色 | `text-[16px]` |
///
/// 所以「严格按纯文字动态的样子做」= 按第二屏做，而不是把两屏混成一种。
///
/// ## 为什么断言落在 `bili_dynamic_body.dart`
///
/// 第二轮把这些样式写在 `opus_detail_page.dart` 里，但真机截图证明用户点进
/// 的是 **另一个** 详情页（`ContentDetailPage`）——「按 BV 号打开」和
/// 「时间线点开」是两个入口。骨架抽到 [BiliDynamicBody] 后两个入口共用，
/// 所以防腐点也应当落在那里，否则下一次改动照样会分叉。
///
/// 页面依赖真实网络（detail + 评论两个接口），起不来完整 widget 测试，
/// 行为级断言在 `bili_dynamic_body_test.dart`，这里只做「某一块被删掉了」
/// 这类源码级回归。
void main() {
  final String bodyRaw =
      File('lib/features/timeline/bili_dynamic_body.dart').readAsStringSync();
  final String opusRaw =
      File('lib/features/timeline/opus_detail_page.dart').readAsStringSync();
  final String detailRaw =
      File('lib/features/timeline/content_detail_page.dart').readAsStringSync();

  /// 去掉**整行注释**后的源码。
  ///
  /// 为什么需要：本文件多处刻意写着「不做 IP 属地 / 不放点赞按钮」这类
  /// 说明，直接对全文做「不得包含某词」的断言会把注释也当成违规。
  /// 要防的是**代码**里真的做了这些事，所以先剥掉整行注释再断言。
  String codeOnly(String src) => src
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final String body = codeOnly(bodyRaw);
  final String opus = codeOnly(opusRaw);
  final String detail = codeOnly(detailRaw);

  group('骨架按参考稿', () {
    test('作者头像 48px（参考稿 w-12 h-12）', () {
      expect(body.contains('avatarSize = 48'), isTrue);
    });

    test('昵称 16px 粗体（参考稿 text-[16px] font-bold）', () {
      expect(body.contains('nameSize = 16'), isTrue);
      expect(body.contains('FontWeight.w700'), isTrue);
    });

    test('正文行高 1.6（参考稿 leading-relaxed）', () {
      expect(body.contains('bodyHeight = 1.6'), isTrue);
    });

    test('两档正文字号：纯文字 16px / 带图 15px', () {
      expect(body.contains('bodySizeTextOnly = 16'), isTrue);
      expect(body.contains('bodySizeWithMedia = 15'), isTrue);
      expect(body.contains('item.images.isEmpty ? bodySizeTextOnly : bodySizeWithMedia'),
          isTrue);
    });

    test('两档昵称色：纯文字正文深色 / 带图品牌粉', () {
      expect(
        body.contains('item.images.isEmpty ? AppColors.textPrimary : AppColors.weiboName'),
        isTrue,
      );
    });

    test('数据栏文案是「评论 N / 赞和转发 M」', () {
      expect(body.contains("'评论 "), isTrue);
      expect(body.contains("'赞和转发 "), isTrue);
    });

    test('评论数用品牌粉加粗（参考稿 text-pink font-bold）', () {
      final int idx = body.indexOf("'评论 ");
      expect(idx, greaterThan(0));
      final String chunk = body.substring(idx, idx + 400);
      expect(chunk.contains('FontWeight.w700'), isTrue);
      expect(chunk.contains('AppColors.weiboName'), isTrue);
    });

    test('数据栏字号 14px（参考稿 text-[14px]）', () {
      expect(body.contains('statSize = 14'), isTrue);
    });
  });

  group('内容只渲染一次（真机缺陷回归的源码级守卫）', () {
    test('标题必须先过 hasOwnTitle 才渲染', () {
      expect(body.contains('BiliDynamicStyle.hasOwnTitle(item)'), isTrue,
          reason: '无条件渲染 title 会让兜底标题变成第二份正文');
    });

    test('占位标题（[图片] 等）被显式挡掉', () {
      expect(body.contains('_placeholderTitles'), isTrue);
      expect(body.contains("'[图片]'"), isTrue);
    });

    test('两个详情页都走同一套骨架，不再各写一份', () {
      expect(opus.contains('BiliDynamicBody('), isTrue);
      expect(detail.contains('BiliDynamicBody('), isTrue);
    });

    test('ContentDetailPage 的旧版大标题排版只留给非 B 站动态', () {
      // 旧路径用 displayTitle + SourceBadge/KindBadge 那一套；
      // 它必须被 _usesDynamicLayout 挡在 B 站动态之外。
      expect(detail.contains('_usesDynamicLayout'), isTrue);
      final int gate = detail.indexOf('if (_usesDynamicLayout)');
      final int legacy = detail.indexOf('SourceBadge(platform: item.platform)');
      expect(gate, greaterThan(0));
      expect(legacy, greaterThan(gate), reason: '旧排版必须在新骨架之后（只作兜底）');
    });
  });

  group('明确不做的东西（参考稿去掉的 / 本 App 没能力的）', () {
    test('不渲染 IP 属地', () {
      expect(body.contains('IP属地'), isFalse, reason: '参考稿明确去掉了 IP 属地');
      expect(opus.contains('IP属地'), isFalse);
    });

    test('不放点赞/投币等写操作按钮（本 App 没有这些能力）', () {
      for (final String forbidden in <String>['onLike', '点赞按钮', '投币']) {
        expect(body.contains(forbidden), isFalse, reason: forbidden);
        expect(opus.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('不重复贴来源徽章（AppBar 标题已经写了 Bilibili · 动态）', () {
      expect(body.contains('SourceBadge'), isFalse);
      expect(body.contains('KindBadge'), isFalse);
    });
  });

  group('图片区按微博板块那套规则', () {
    test('用 PhotoGrid（与微博详情页同一个组件）', () {
      expect(body.contains('PhotoGrid('), isTrue);
    });

    test('点开走 ImageGalleryPage 全屏预览', () {
      expect(body.contains('ImageGalleryPage('), isTrue);
    });

    test('单图 fill 用 cover（与微博详情页一致）', () {
      expect(body.contains('singleFit: BoxFit.cover'), isTrue);
    });
  });

  group('计数语义：接口没给就不渲染，不显示 0', () {
    test('评论数判空后才渲染', () {
      expect(body.contains('if (comment != null)'), isTrue);
    });

    test('赞和转发都为空时整项跳过', () {
      expect(body.contains('if (like != null || repost != null)'), isTrue);
    });
  });
}
