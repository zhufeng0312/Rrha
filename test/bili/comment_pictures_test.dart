import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/comment_parser.dart';

/// B 站评论**配图**的解析测试（2026-11-02）。
///
/// ## 这一组测试对应的真实缺陷
///
/// 用户报「bilibili 卡片的评论区里的评论没有图片」。根因不在 UI ——
/// `comment_section.dart` 早就按 `comment.images` 渲染了 `PhotoGrid`
/// （微博评论的图就是这么显示出来的）。真正缺的是 **B 站解析层从来没填过
/// `images`**，所以 `if (comment.images.isNotEmpty)` 那段永远进不去。
///
/// ## 字段路径是探针实测的，不是猜的
///
/// 见 `.env/probe_bili_comment_pics.py`，样本 `BV1RXx169Emu`（视频）与
/// `opus/1266051909563711506`（动态），各 20 条一级评论：
///
/// ```
/// content.pictures[i] = { img_src, img_width, img_height, img_size,
///                         play_gif_thumbnail?, top_right_icon? }
/// ```
///
/// 只有 `img_src` 一个地址字段（**不是**微博那套 `url` / `large.url`），
/// 且服务端给的是明文 `http://` —— 必须转 https，否则 Android 9+ 上
/// 整片走 errorWidget，表现为「评论图一片灰」。
void main() {
  /// 造一条评论，[pictures] 原样塞进 `content.pictures`。
  Map<String, dynamic> comment({
    int rpid = 1,
    List<Object?>? pictures,
    Map<String, dynamic>? picture,
    String message = '看图',
    int rcount = 0,
    List<Object?>? replies,
  }) {
    final content = <String, dynamic>{'message': message};
    if (pictures != null) content['pictures'] = pictures;
    if (picture != null) content['picture'] = picture;
    return <String, dynamic>{
      'rpid': rpid,
      'root': 0,
      'parent': 0,
      'like': 1,
      'ctime': 1700000000,
      'rcount': rcount,
      'member': <String, dynamic>{'mid': 9, 'uname': '某人'},
      'content': content,
      if (replies != null) 'replies': replies,
    };
  }

  Map<String, dynamic> response(List<Map<String, dynamic>> replies) =>
      <String, dynamic>{
        'code': 0,
        'data': <String, dynamic>{
          'replies': replies,
          'top_replies': <dynamic>[],
          'cursor': <String, dynamic>{
            'is_end': true,
            'pagination_reply': <String, dynamic>{'next_offset': ''},
          },
          'page': <String, dynamic>{'count': replies.length},
        },
      };

  /// 实测的图片项（字段完全照抄探针输出）。
  Map<String, dynamic> pic(String src, {bool gif = false}) =>
      <String, dynamic>{
        'img_src': src,
        'img_width': 1080,
        'img_height': 1959,
        'img_size': 188.862,
        if (gif) 'play_gif_thumbnail': true,
        if (gif) 'top_right_icon': 1,
      };

  group('单图与多图', () {
    test('单图评论：images 有 1 项', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('http://i0.hdslb.com/bfs/new_dyn/de1548ff.jpg'),
        ]),
      ]));

      expect(page.comments.single.images, hasLength(1));
    });

    test('三图评论：images 有 3 项，顺序与接口一致', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('http://i0.hdslb.com/a.jpg'),
          pic('http://i0.hdslb.com/b.jpg'),
          pic('http://i0.hdslb.com/c.png'),
        ]),
      ]));

      final images = page.comments.single.images;
      expect(images, hasLength(3));
      // 顺序即用户看图顺序：PhotoGrid 与全屏预览的翻页都依赖它。
      expect(images[0], endsWith('/a.jpg'));
      expect(images[1], endsWith('/b.jpg'));
      expect(images[2], endsWith('/c.png'));
    });

    test('无图评论：images 为空，不报错（评论区里这是绝大多数）', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(),
      ]));

      expect(page.comments.single.images, isEmpty);
    });

    test('pictures 为空 List：等同于无图', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[]),
      ]));

      expect(page.comments.single.images, isEmpty);
    });
  });

  group('⚠️ http → https 归一化（Android 9+ 明文策略）', () {
    test('明文 http 必须升级成 https', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('http://i0.hdslb.com/bfs/new_dyn/x.jpg'),
        ]),
      ]));

      expect(
        page.comments.single.images.single,
        'https://i0.hdslb.com/bfs/new_dyn/x.jpg',
        reason: '不转 https 的话，Android 9+ 默认禁明文 → 评论图全部走 errorWidget',
      );
    });

    test('已经是 https 的原样保留', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('https://i1.hdslb.com/bfs/new_dyn/y.jpg'),
        ]),
      ]));

      expect(
        page.comments.single.images.single,
        'https://i1.hdslb.com/bfs/new_dyn/y.jpg',
      );
    });

    test('协议相对地址（//host/...）补成 https', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('//i2.hdslb.com/bfs/new_dyn/z.jpg'),
        ]),
      ]));

      expect(
        page.comments.single.images.single,
        'https://i2.hdslb.com/bfs/new_dyn/z.jpg',
      );
    });
  });

  group('脏数据容错（评论区的容错优先级高于严格性）', () {
    test('缺 img_src 的项被跳过，而不是产生空串地址', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          <String, dynamic>{'img_width': 1080, 'img_height': 720},
          pic('http://i0.hdslb.com/ok.jpg'),
        ]),
      ]));

      expect(
        page.comments.single.images,
        hasLength(1),
        reason: '空地址会让 CachedImage 显示灰底图标，不如直接不渲染这一张',
      );
    });

    test('img_src 为空串 / 全空白时跳过', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic(''),
          pic('   '),
        ]),
      ]));

      expect(page.comments.single.images, isEmpty);
    });

    test('pictures 里混入非 Map 元素不会崩', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          'not-a-map',
          null,
          42,
          pic('http://i0.hdslb.com/ok.jpg'),
        ]),
      ]));

      expect(page.comments.single.images, hasLength(1));
    });

    test('pictures 不是 List（服务端形态异常）时不崩、当无图', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[]),
      ]));
      expect(page.comments.single.images, isEmpty);

      // 直接构造一个 pictures 是 Map 的脏数据。
      final dirty = comment();
      (dirty['content'] as Map<String, dynamic>)['pictures'] =
          <String, dynamic>{'img_src': 'http://x/y.jpg'};
      final page2 = CommentParser.parseMain(response(<Map<String, dynamic>>[dirty]));
      expect(page2.comments.single.images, isEmpty);
    });

    test('重复地址去重（同一张图不该渲染两次）', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('http://i0.hdslb.com/same.jpg'),
          pic('http://i0.hdslb.com/same.jpg'),
        ]),
      ]));

      expect(page.comments.single.images, hasLength(1));
    });

    test('http 与 https 的同一个地址视为重复', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('http://i0.hdslb.com/same.jpg'),
          pic('https://i0.hdslb.com/same.jpg'),
        ]),
      ]));

      expect(
        page.comments.single.images,
        hasLength(1),
        reason: '归一化之后再比对，否则同一张图会出现两次',
      );
    });
  });

  group('楼中楼与置顶', () {
    test('楼中楼的图片也解析（若接口给了）', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(
          rpid: 1,
          rcount: 1,
          replies: <Object?>[
            comment(
              rpid: 2,
              pictures: <Object?>[pic('http://i0.hdslb.com/sub.jpg')],
            ),
          ],
        ),
      ]));

      final parent = page.comments.single;
      expect(parent.images, isEmpty);
      expect(parent.replies.single.images, hasLength(1));
    });

    test('置顶评论的图片同样解析', () {
      final page = CommentParser.parseMain(<String, dynamic>{
        'code': 0,
        'data': <String, dynamic>{
          'replies': <dynamic>[],
          'top_replies': <dynamic>[
            comment(
              rpid: 900,
              pictures: <Object?>[pic('http://i0.hdslb.com/top.jpg')],
            ),
          ],
          'cursor': <String, dynamic>{'is_end': true},
        },
      });

      expect(page.topComments.single.images, hasLength(1));
    });
  });

  group('老接口形态兜底（content.picture 单数）', () {
    test('picture 是单个 Map 时也取到图', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(picture: pic('http://i0.hdslb.com/legacy.jpg')),
      ]));

      expect(page.comments.single.images, hasLength(1));
    });

    test('pictures 与 picture 同时存在时不重复', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(
          pictures: <Object?>[pic('http://i0.hdslb.com/both.jpg')],
          picture: pic('http://i0.hdslb.com/both.jpg'),
        ),
      ]));

      expect(page.comments.single.images, hasLength(1));
    });
  });

  group('imageCount 语义（不能触发微博那套「共 N 张」分支）', () {
    test('B 站恒为 0 —— 接口给了几张就是几张，没有「声称更多」的情况', () {
      final page = CommentParser.parseMain(response(<Map<String, dynamic>>[
        comment(pictures: <Object?>[
          pic('http://i0.hdslb.com/a.jpg'),
          pic('http://i0.hdslb.com/b.jpg'),
        ]),
      ]));

      final c = page.comments.single;
      expect(c.imageCount, 0);
      expect(
        c.imageCount > c.images.length,
        isFalse,
        reason: '这一条 false 是 UI 里「共 N 张 · 点此加载全部」分支不渲染的前提',
      );
    });
  });

  group('parsePictures 直接调用（纯函数边界）', () {    test('空 content 返回空列表', () {
      expect(CommentParser.parsePictures(<String, dynamic>{}), isEmpty);
    });

    test('动图项也照常解析（play_gif_thumbnail 只是角标线索）', () {
      final images = CommentParser.parsePictures(<String, dynamic>{
        'pictures': <Object?>[pic('http://i0.hdslb.com/anim.gif', gif: true)],
      });

      expect(images.single, 'https://i0.hdslb.com/anim.gif');
    });

    test('超过 9 张不截断（截断会静默吞图，PhotoGrid 自己会折行）', () {
      final images = CommentParser.parsePictures(<String, dynamic>{
        'pictures': <Object?>[
          for (var i = 0; i < 12; i++) pic('http://i0.hdslb.com/$i.jpg'),
        ],
      });

      expect(images, hasLength(12));
    });
  });

  group('图片宽高比：必须与 images 严格同序同长', () {
    test('常见手机截图比例算对', () {
      final ratios = CommentParser.parsePictureAspectRatios(<String, dynamic>{
        'pictures': <Object?>[
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/shot.jpg',
            'img_width': 1080,
            'img_height': 1959,
          },
        ],
      });

      expect(ratios, hasLength(1));
      expect(ratios.single, closeTo(1080 / 1959, 1e-9));
    });

    test('超长竖图（1080×9109）比例是 0.1186，不是 4:3', () {
      final ratios = CommentParser.parsePictureAspectRatios(<String, dynamic>{
        'pictures': <Object?>[
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/tall.jpg',
            'img_width': 1080,
            'img_height': 9109,
          },
        ],
      });

      expect(ratios.single, closeTo(1080 / 9109, 1e-9));
      expect(ratios.single, lessThan(0.2));
    });

    test('⚠️ 跳过缺 img_src 的项后，比例列表仍与 images 下标对齐', () {
      // 这条是防「第 2 张的宽高比配到第 3 张图上」那类偏移错误。
      // parsePictures 会跳过缺地址的项，parsePictureAspectRatios 必须跳得一模一样。
      final content = <String, dynamic>{
        'pictures': <Object?>[
          <String, dynamic>{'img_width': 100, 'img_height': 100}, // 无地址，跳过
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/first.jpg',
            'img_width': 1920,
            'img_height': 1080,
          },
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/second.jpg',
            'img_width': 1080,
            'img_height': 2160,
          },
        ],
      };

      final images = CommentParser.parsePictures(content);
      final ratios = CommentParser.parsePictureAspectRatios(content);

      expect(images, hasLength(2));
      expect(ratios, hasLength(2), reason: '长度必须与 images 一致');
      expect(ratios[0], closeTo(1920 / 1080, 1e-9));
      expect(ratios[1], closeTo(1080 / 2160, 1e-9));
    });

    test('去重规则与 parsePictures 一致（http/https 同一张只占一个下标）', () {
      final content = <String, dynamic>{
        'pictures': <Object?>[
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/same.jpg',
            'img_width': 800,
            'img_height': 600,
          },
          <String, dynamic>{
            'img_src': 'https://i0.hdslb.com/same.jpg',
            'img_width': 400,
            'img_height': 400,
          },
        ],
      };

      expect(CommentParser.parsePictures(content), hasLength(1));
      final ratios = CommentParser.parsePictureAspectRatios(content);
      expect(ratios, hasLength(1));
      // 保留的是**第一条**，所以比例也是第一条的。
      expect(ratios.single, closeTo(800 / 600, 1e-9));
    });

    test('宽或高缺失 → 该位置是 null（UI 退回 4:3，不猜比例）', () {
      final ratios = CommentParser.parsePictureAspectRatios(<String, dynamic>{
        'pictures': <Object?>[
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/a.jpg',
            'img_width': 1080,
            // 没有 img_height
          },
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/b.jpg',
            'img_width': 500,
            'img_height': 500,
          },
        ],
      });

      expect(ratios, hasLength(2));
      expect(ratios[0], isNull);
      expect(ratios[1], 1.0);
    });

    test('宽或高为 0 / 负数 → null（不会算出 Infinity 或负比例）', () {
      final ratios = CommentParser.parsePictureAspectRatios(<String, dynamic>{
        'pictures': <Object?>[
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/a.jpg',
            'img_width': 0,
            'img_height': 100,
          },
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/b.jpg',
            'img_width': 100,
            'img_height': 0,
          },
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/c.jpg',
            'img_width': -5,
            'img_height': 100,
          },
        ],
      });

      expect(ratios, <double?>[null, null, null]);
    });

    test('宽高是数字字符串时也能算（服务端格式不统一过）', () {
      final ratios = CommentParser.parsePictureAspectRatios(<String, dynamic>{
        'pictures': <Object?>[
          <String, dynamic>{
            'img_src': 'http://i0.hdslb.com/a.jpg',
            'img_width': '1920',
            'img_height': '1080',
          },
        ],
      });

      expect(ratios.single, closeTo(1920 / 1080, 1e-9));
    });

    test('没有图片时返回空列表', () {
      expect(
        CommentParser.parsePictureAspectRatios(<String, dynamic>{}),
        isEmpty,
      );
    });
  });
}
