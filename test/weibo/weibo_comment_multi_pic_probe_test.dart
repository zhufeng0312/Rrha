import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/weibo/weibo_comment_multi_pic_probe.dart';

/// `WeiboCommentMultiPicProbe` 的离线验收。
///
/// 真机取证结论（2026-10-20，curl + 真机）：
/// - `http://t.cn/X` 与 `https://t.cn/X` **都 302**，`Location` 完全一致；
/// - 落点 `https://photo.weibo.com/h5/comment/compic_id/1022:230597…`，
///   是一个 467 字节的极简 H5 页，HTML 里只有一个 `<img src>`；
/// - `<img src>` 是 `https://wx*.sinaimg.cn/bmiddle/<pid>.jpg`
///   （bmiddle = 长边 690 缩略），换成 `/large/` 即原图；
/// - 图床**认 Referer**：不带 403，带 `https://weibo.com/` 才 200。
///
/// 这里把这些判据全部钉死：真机上一旦拿到响应，翻译成人话那一步不会再错。

/// 落地页 HTML（与真机 curl 拿到的原文同构，只有 pid 换了）。
const String _pageHtml = '''
<html>
<head>
<meta charset="UTF-8">
<title>图片</title>
</head>
<body>
	<div class="wrap-box">
		<div class="img-box" style="max-height: 100%;">
			<img
				src="https://wx3.sinaimg.cn/bmiddle/84395e04ly1ii67kl0dzkj20xw21swpi.jpg">
		</div>
	</div>
</body>
</html>
''';

Map<String, dynamic> _comment({
  String id = '5355083253417410',
  int picNum = 3,
  List<Object?>? mix,
  List<Map<String, dynamic>>? replies,
  String name = '_TOMARU_',
}) =>
    <String, dynamic>{
      'id': id,
      'mid': id,
      'pic_num': picNum,
      if (mix != null) 'mix_media_ids': mix,
      'user': <String, dynamic>{'screen_name': name},
      if (replies != null) 'comments': replies,
    };

void main() {
  group('withPrefix：短链前缀归一', () {
    test('接口给的 http 短链能被升级成 https', () {
      expect(
        WeiboCommentMultiPicProbe.withPrefix(
          'http://t.cn/AXlmgHJ6',
          MultiPicPrefix.https,
        ),
        'https://t.cn/AXlmgHJ6',
      );
    });

    test('已经是 https 时不会变成 https://https', () {
      expect(
        WeiboCommentMultiPicProbe.withPrefix(
          'https://t.cn/AXlmgHJ6',
          MultiPicPrefix.https,
        ),
        'https://t.cn/AXlmgHJ6',
      );
    });

    test('保留 http 前缀（对照用）', () {
      expect(
        WeiboCommentMultiPicProbe.withPrefix(
          'https://t.cn/AXlmgHJ6',
          MultiPicPrefix.http,
        ),
        'http://t.cn/AXlmgHJ6',
      );
    });

    test('无 scheme 的串也能拼', () {
      expect(
        WeiboCommentMultiPicProbe.withPrefix('t.cn/abc', MultiPicPrefix.https),
        'https://t.cn/abc',
      );
    });
  });

  group('maskLink：脱敏', () {
    test('前 12 字符 + 长度，不含完整值', () {
      final String m = WeiboCommentMultiPicProbe.maskLink('http://t.cn/AXlmgHJ6');
      expect(m, startsWith('http://t.cn/'));
      expect(m, contains('位）'));
      expect(m, isNot(contains('AXlmgHJ6')));
    });

    test('空串不抛', () {
      expect(WeiboCommentMultiPicProbe.maskLink(''), '（空）');
    });
  });

  group('firstImgSrc：从落地页提取图片', () {
    test('双引号写法（真机原文）', () {
      expect(
        WeiboCommentMultiPicProbe.firstImgSrc(_pageHtml),
        'https://wx3.sinaimg.cn/bmiddle/84395e04ly1ii67kl0dzkj20xw21swpi.jpg',
      );
    });

    test('单引号写法也认', () {
      expect(
        WeiboCommentMultiPicProbe.firstImgSrc(
          "<img src='https://wx1.sinaimg.cn/bmiddle/a.jpg'>",
        ),
        'https://wx1.sinaimg.cn/bmiddle/a.jpg',
      );
    });

    test('无引号写法也认', () {
      expect(
        WeiboCommentMultiPicProbe.firstImgSrc(
          '<img src=https://wx1.sinaimg.cn/bmiddle/a.jpg>',
        ),
        'https://wx1.sinaimg.cn/bmiddle/a.jpg',
      );
    });

    test('协议相对补 https，http 升级成 https', () {
      expect(
        WeiboCommentMultiPicProbe.firstImgSrc('<img src="//wx1.sinaimg.cn/a.jpg">'),
        'https://wx1.sinaimg.cn/a.jpg',
      );
      expect(
        WeiboCommentMultiPicProbe.firstImgSrc('<img src="http://wx1.sinaimg.cn/a.jpg">'),
        'https://wx1.sinaimg.cn/a.jpg',
      );
    });

    test('页面里没有 img / 空串 → null', () {
      expect(WeiboCommentMultiPicProbe.firstImgSrc(''), isNull);
      expect(WeiboCommentMultiPicProbe.firstImgSrc('<html>无图</html>'), isNull);
    });

    test('多个 img 只取第一个', () {
      expect(
        WeiboCommentMultiPicProbe.firstImgSrc(
          '<img src="https://a/1.jpg"><img src="https://a/2.jpg">',
        ),
        'https://a/1.jpg',
      );
    });
  });

  group('toOriginal：缩略 → 原图', () {
    test('bmiddle → large（真机实测两档都 200）', () {
      expect(
        WeiboCommentMultiPicProbe.toOriginal(
          'https://wx3.sinaimg.cn/bmiddle/84395e04ly1ii67kl0dzkj20xw21swpi.jpg',
        ),
        'https://wx3.sinaimg.cn/large/84395e04ly1ii67kl0dzkj20xw21swpi.jpg',
      );
    });

    test('orj360 / thumbnail 也升级', () {
      expect(
        WeiboCommentMultiPicProbe.toOriginal(
          'https://wx2.sinaimg.cn/orj360/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg',
        ),
        'https://wx2.sinaimg.cn/large/6a3e9e9egy1ii5jxawqooj20e805igm8.jpg',
      );
      expect(
        WeiboCommentMultiPicProbe.toOriginal('https://a/thumbnail/x.jpg'),
        'https://a/large/x.jpg',
      );
    });

    test('已经是 large 就不动（幂等）', () {
      const String u = 'https://wx3.sinaimg.cn/large/a.jpg';
      expect(WeiboCommentMultiPicProbe.toOriginal(u), u);
      expect(
        WeiboCommentMultiPicProbe.toOriginal(
          WeiboCommentMultiPicProbe.toOriginal(u),
        ),
        u,
      );
    });

    test('末段里出现 size 字样不误伤（只换路径段）', () {
      const String u = 'https://a/bmiddle/bmiddle.jpg';
      expect(WeiboCommentMultiPicProbe.toOriginal(u), 'https://a/large/bmiddle.jpg');
    });
  });

  group('extractMixMediaIds', () {
    test('List 形态逐项取出', () {
      expect(
        WeiboCommentMultiPicProbe.extractMixMediaIds(
          _comment(mix: <Object?>['http://t.cn/A', 'http://t.cn/B']),
        ),
        <String>['http://t.cn/A', 'http://t.cn/B'],
      );
    });

    test('Map 形态取 values', () {
      expect(
        WeiboCommentMultiPicProbe.extractMixMediaIds(<String, dynamic>{
          'mix_media_ids': <String, dynamic>{'0': 'http://t.cn/A'},
        }),
        <String>['http://t.cn/A'],
      );
    });

    test('缺失 / null / 非 Map 一律空列表，不抛', () {
      expect(WeiboCommentMultiPicProbe.extractMixMediaIds(null), isEmpty);
      expect(WeiboCommentMultiPicProbe.extractMixMediaIds('x'), isEmpty);
      expect(WeiboCommentMultiPicProbe.extractMixMediaIds(_comment()), isEmpty);
      expect(
        WeiboCommentMultiPicProbe.extractMixMediaIds(
          <String, dynamic>{'mix_media_ids': <Object?>[]},
        ),
        isEmpty,
      );
    });
  });

  group('classify / looksLikeCommentPicPage', () {
    test('落点识别为「评论配图 H5 页」', () {
      const String loc =
          'https://photo.weibo.com/h5/comment/compic_id/1022:230597ad57';
      expect(WeiboCommentMultiPicProbe.looksLikeCommentPicPage(loc), isTrue);
      expect(WeiboCommentMultiPicProbe.classify(loc), '评论配图 H5 页');
    });

    test('图床 / 微博网页 / 其它 分得清', () {
      expect(
        WeiboCommentMultiPicProbe.classify('https://wx3.sinaimg.cn/large/a.jpg'),
        '图片 CDN',
      );
      expect(
        WeiboCommentMultiPicProbe.classify('https://m.weibo.cn/status/1'),
        '微博网页',
      );
      expect(
        WeiboCommentMultiPicProbe.classify('https://example.com/x'),
        contains('example.com'),
      );
      expect(WeiboCommentMultiPicProbe.classify(null), '（无）');
    });
  });

  group('findMultiPicComment：在评论列表里找多图评论', () {
    test('找到 pic_num>1 且 mix_media_ids 非空的那一条', () {
      final MultiPicHit? hit = WeiboCommentMultiPicProbe.findMultiPicComment(
        '{"ok":1,"data":{"data":['
        '{"id":"1","pic_num":1,"mix_media_ids":["http://t.cn/A"]},'
        '{"id":"2","pic_num":3,"mix_media_ids":'
        '["http://t.cn/AXlmgHJ6","http://t.cn/AXlmgHJS","http://t.cn/AXlmgHJa"]}'
        ']}}',
      );
      expect(hit, isNotNull);
      expect(hit!.commentId, '2');
      expect(hit.picNum, 3);
      expect(hit.mixMediaIds, hasLength(3));
      expect(hit.location, 'data.data[1]');
      expect(hit.author, isNull);
    });

    test('二级评论里的多图也能找到', () {
      final MultiPicHit? hit = WeiboCommentMultiPicProbe.findMultiPicComment(
        '{"ok":1,"data":{"data":['
        '{"id":"1","pic_num":1,"comments":['
        '{"id":"9","pic_num":2,"mix_media_ids":["http://t.cn/X","http://t.cn/Y"]}'
        ']}'
        ']}}',
      );
      expect(hit, isNotNull);
      expect(hit!.commentId, '9');
      expect(hit.location, 'data.data[0].comments[0]');
    });

    test('没有多图时退回第一个带 mix_media_ids 的（不谎报）', () {
      final MultiPicHit? hit = WeiboCommentMultiPicProbe.findMultiPicComment(
        '{"ok":1,"data":{"data":[{"id":"1","pic_num":1,'
        '"mix_media_ids":["http://t.cn/A"]}]}}',
      );
      expect(hit, isNotNull);
      expect(hit!.picNum, 1);
      expect(hit.mixMediaIds, hasLength(1));
    });

    test('全都没有 mix_media_ids → null', () {
      expect(
        WeiboCommentMultiPicProbe.findMultiPicComment(
          '{"ok":1,"data":{"data":[{"id":"1","pic_num":3}]}}',
        ),
        isNull,
      );
    });

    test('坏 JSON / 空 body / 结构不对一律 null，不抛', () {
      for (final String body in <String>[
        '',
        'not json',
        '{}',
        '{"data":null}',
        '{"data":{"data":"x"}}',
        '{"data":{"data":[]}}',
      ]) {
        expect(
          WeiboCommentMultiPicProbe.findMultiPicComment(body),
          isNull,
          reason: body,
        );
      }
    });
  });

  group('MultiPicLinkResult：三态判定', () {
    MultiPicLinkResult link({int? status, String? image, String? loc}) =>
        MultiPicLinkResult(
          index: 0,
          rawLink: 'http://t.cn/…（14 位）',
          probeUrl: 'https://t.cn/…（15 位）',
          prefix: MultiPicPrefix.https,
          httpStatus: status,
          location: loc,
          pageStatus: status,
          // 200 且没有 img = 「拿到了网页但没图」，这是 PAGE 而不是 FAILED。
          pageChars: status == 200 ? 467 : 0,
          imgSrc: image,
          imageUrl: image,
        );

    test('拿到图片 → IMAGE', () {
      final MultiPicLinkResult l = link(
        status: 200,
        image: 'https://wx3.sinaimg.cn/large/a.jpg',
        loc: 'https://photo.weibo.com/h5/comment/compic_id/x',
      );
      expect(l.verdict, 'IMAGE');
      expect(l.hasImage, isTrue);
      expect(l.toLine(), contains('HTTP 200'));
    });

    test('只拿到网页 → PAGE', () {
      expect(link(status: 200, image: null).verdict, 'PAGE');
    });

    test('无状态码 / 4xx → FAILED', () {
      expect(link(status: null).verdict, 'FAILED');
      expect(link(status: 404).verdict, 'FAILED');
    });
  });

  group('CommentMultiPicProbeResult：结论与落盘', () {
    CommentMultiPicProbeResult build({
      List<MultiPicLinkResult>? links,
      List<String> mix = const <String>['http://t.cn/…（12 位）'],
      String? commentId = '5355083253417410',
    }) {
      final List<MultiPicLinkResult> use = links ?? <MultiPicLinkResult>[];
      return CommentMultiPicProbeResult(
        mid: '5355066445792642',
        commentId: commentId,
        author: '_TOMARU_',
        picNum: 3,
        mixMediaIds: mix,
        commentLocation: 'data.data[2]',
        links: use,
        pagesFetched: 2,
        requestLog: const <String>['#1 C1 → HTTP 200'],
        requestCount: use.length + 1,
        saw432: false,
        max432Streak: 0,
        note: '命中 data.data[2]',
      );
    }

    MultiPicLinkResult okLink(int i) => MultiPicLinkResult(
          index: i,
          rawLink: 'http://t.cn/…（12 位）',
          probeUrl: 'https://t.cn/…（13 位）',
          prefix: MultiPicPrefix.https,
          httpStatus: 200,
          location: 'https://photo.weibo.com/h5/comment/compic_id/1022:230597$i',
          pageStatus: 200,
          pageChars: 467,
          imgSrc: 'https://wx3.sinaimg.cn/bmiddle/pid$i.jpg',
          imageUrl: 'https://wx3.sinaimg.cn/large/pid$i.jpg',
          imageIsOriginal: true,
        );

    test('三张全拿到 → IMAGE，成本 = 短链数', () {
      final CommentMultiPicProbeResult r =
          build(links: <MultiPicLinkResult>[okLink(0), okLink(1), okLink(2)]);
      expect(r.verdict, 'IMAGE');
      expect(r.imageCount, 3);
      expect(r.linkCount, 3);
      expect(r.usable, isTrue);
      expect(r.requestsPerComment, 3);
      expect(r.workingPrefix, 'https');
      expect(r.locationShape, 'photo.weibo.com/h5');
      expect(r.imageShape, 'sinaimg.cn/large/<pid>.jpg');
      expect(r.conclusions.join('\n'), contains('**能**'));
      expect(r.conclusions.join('\n'), contains('3 个短链请求'));
    });

    test('没有链接 → NOT_FOUND', () {
      final CommentMultiPicProbeResult r =
          build(links: const <MultiPicLinkResult>[], mix: const <String>[]);
      expect(r.verdict, 'NOT_FOUND');
      expect(r.locationShape, '（无 Location）');
      expect(r.workingPrefix, 'none');
      expect(r.conclusions.join('\n'), contains('未验证'));
    });

    test('只有网页没图片 → PAGE', () {
      final CommentMultiPicProbeResult r = build(
        links: <MultiPicLinkResult>[
          MultiPicLinkResult(
            index: 0,
            rawLink: 'http://t.cn/…（12 位）',
            probeUrl: 'https://t.cn/…（13 位）',
            prefix: MultiPicPrefix.https,
            httpStatus: 200,
            location: 'https://photo.weibo.com/h5/comment/compic_id/x',
            pageStatus: 200,
            pageChars: 12,
          ),
        ],
      );
      expect(r.verdict, 'PAGE');
      expect(r.imageCount, 0);
    });

    test('全部失败 → FAILED', () {
      final CommentMultiPicProbeResult r = build(
        links: <MultiPicLinkResult>[
          MultiPicLinkResult(
            index: 0,
            rawLink: 'http://t.cn/…（12 位）',
            probeUrl: 'https://t.cn/…（13 位）',
            prefix: MultiPicPrefix.https,
            httpStatus: 404,
          ),
        ],
      );
      expect(r.verdict, 'FAILED');
    });

    test('toText 不含 cookie、含关键小节', () {
      final CommentMultiPicProbeResult r =
          build(links: <MultiPicLinkResult>[okLink(0)]);
      final String t = r.toText();
      expect(t, contains('微博评论多图探针'));
      expect(t, contains('短链跟随'));
      expect(t, contains('结论'));
      expect(t, isNot(contains('SUB=')));
      // mid / 评论 id 必须脱敏
      expect(t, isNot(contains('5355066445792642')));
      expect(t, isNot(contains('5355083253417410')));
    });

    test('toMarkdown 七节齐全、脱敏、只写 cookie 长度', () {
      final CommentMultiPicProbeResult r =
          build(links: <MultiPicLinkResult>[okLink(0), okLink(1)]);
      final String md = r.toMarkdown(cookieLength: 573, date: '2026-10-20');
      for (final String section in const <String>[
        '## 一、样本',
        '## 二、T1 t.cn 跟随结果（逐链接）',
        '## 三、T2/T3 结果（若走到）',
        '## 四、T4 字段全扫（若做到）',
        '## 五、结论（逐条回答）',
        '## 六、若可行：实现建议',
        '## 七、未取证',
      ]) {
        expect(md, contains(section), reason: section);
      }
      expect(md, contains('573'));
      expect(md, isNot(contains('5355066445792642')));
      expect(md, contains('| 链接序号 | 前缀 | HTTP | Location | 是否为图片 |'));
      expect(md, contains('**N 个**'));
      expect(md, contains('403'));
    });

    test('未找到样本时 Markdown 也不炸，并写 NO_SAMPLE 语义', () {
      final CommentMultiPicProbeResult r = build(
        links: const <MultiPicLinkResult>[],
        mix: const <String>[],
        commentId: null,
      );
      final String md = r.toMarkdown(cookieLength: 0, date: '2026-10-20');
      expect(md, contains('## 二、T1 t.cn 跟随结果（逐链接）'));
      expect(md, contains('未发出短链请求'));
      expect(md, contains('（未找到）'));
    });
  });

  group('请求纪律（常量即契约，调用方改不动）', () {
    test('硬上限、间隔、超时、熔断阈值都符合任务要求', () {
      // 6 = ≤3 页评论列表 + ≤3 次短链；仍远低于任务的 18。
      expect(WeiboCommentMultiPicProbe.maxRequests, 6);
      expect(WeiboCommentMultiPicProbe.maxPages, 3);
      expect(WeiboCommentMultiPicProbe.maxLinks, 3);
      expect(WeiboCommentMultiPicProbe.maxConsecutive432, 3);
      expect(
        WeiboCommentMultiPicProbe.minGap.inSeconds,
        greaterThanOrEqualTo(2),
      );
      expect(WeiboCommentMultiPicProbe.itemTimeout.inSeconds, 20);
    });

    test('默认目标是那条已知的多图评论所在微博', () {
      expect(WeiboCommentMultiPicProbe.defaultMid, '5355066445792642');
    });
  });
}
