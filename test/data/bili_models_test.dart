import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/bili_models.dart';

void main() {
  group('PlayUrlResult.fromJson', () {
    test('durl 非空 → 通道 A（MP4 单文件）', () {
      final r = PlayUrlResult.fromJson(<String, dynamic>{
        'quality': 32,
        'format': 'mp4',
        'timelength': 120000,
        'durl': <dynamic>[
          <String, dynamic>{'url': 'https://x/video.mp4', 'size': 1},
        ],
        'support_formats': <dynamic>[
          <String, dynamic>{'quality': 32, 'new_description': '480P 清晰'},
        ],
      }, requestedQn: 64);

      expect(r.channel, PlayChannel.mp4);
      expect(r.url, 'https://x/video.mp4');
      expect(r.isPlayable, isTrue);
      expect(r.duration, const Duration(milliseconds: 120000));
      expect(r.qualities.single.label, '480P 清晰');
      expect(r.qualities.single.qn, 32);
    });

    test('durl 为空 + dash → 通道 B，优先 AVC 且不超过请求清晰度', () {
      final r = PlayUrlResult.fromJson(<String, dynamic>{
        'dash': <String, dynamic>{
          'video': <dynamic>[
            <String, dynamic>{
              'id': 80,
              'codecid': 7,
              'baseUrl': 'https://x/80.m4s',
              'bandwidth': 1000,
            },
            <String, dynamic>{
              'id': 64,
              'codecid': 7,
              'baseUrl': 'https://x/64.m4s',
              'bandwidth': 1000,
            },
            <String, dynamic>{
              'id': 64,
              'codecid': 12,
              'baseUrl': 'https://x/hevc.m4s',
              'bandwidth': 1000,
            },
          ],
          'audio': <dynamic>[
            <String, dynamic>{
              'id': 30216,
              'baseUrl': 'https://x/a1.m4s',
              'bandwidth': 60000,
            },
            <String, dynamic>{
              'id': 30280,
              'baseUrl': 'https://x/a2.m4s',
              'bandwidth': 192000,
            },
          ],
        },
      }, requestedQn: 64);

      expect(r.channel, PlayChannel.dash);
      expect(r.videoUrl, 'https://x/64.m4s', reason: '应选 AVC(codecid=7) 且 qn<=64');
      expect(r.audioUrl, 'https://x/a2.m4s', reason: '音频应取码率最高的一条');
      expect(r.quality, 64);
      expect(r.videoCodecId, 7);
    });

    test('所有流都高于请求清晰度时取最低，而不是返回空', () {
      final r = PlayUrlResult.fromJson(<String, dynamic>{
        'dash': <String, dynamic>{
          'video': <dynamic>[
            <String, dynamic>{'id': 112, 'codecid': 7, 'baseUrl': 'https://x/112.m4s'},
            <String, dynamic>{'id': 80, 'codecid': 7, 'baseUrl': 'https://x/80.m4s'},
          ],
        },
      }, requestedQn: 32);

      expect(r.channel, PlayChannel.dash);
      expect(r.videoUrl, 'https://x/80.m4s');
    });

    test('无 AVC 时退化为任意可用编码', () {
      final r = PlayUrlResult.fromJson(<String, dynamic>{
        'dash': <String, dynamic>{
          'video': <dynamic>[
            <String, dynamic>{'id': 64, 'codecid': 12, 'baseUrl': 'https://x/hevc.m4s'},
          ],
        },
      }, requestedQn: 64);

      expect(r.videoUrl, 'https://x/hevc.m4s');
      expect(r.videoCodecId, 12);
    });

    test('空数据 / null → none（不抛异常）', () {
      expect(
        PlayUrlResult.fromJson(null, requestedQn: 64).channel,
        PlayChannel.none,
      );
      expect(
        PlayUrlResult.fromJson(<String, dynamic>{}, requestedQn: 64).channel,
        PlayChannel.none,
      );
      expect(
        PlayUrlResult.fromJson(<String, dynamic>{'durl': <dynamic>[]}, requestedQn: 64)
            .isPlayable,
        isFalse,
      );
    });

    test('兼容 base_url / backup_url 命名', () {
      final r = PlayUrlResult.fromJson(<String, dynamic>{
        'dash': <String, dynamic>{
          'video': <dynamic>[
            <String, dynamic>{'id': 64, 'base_url': 'https://x/b.m4s'},
          ],
        },
      }, requestedQn: 64);
      expect(r.videoUrl, 'https://x/b.m4s');

      final r2 = PlayUrlResult.fromJson(<String, dynamic>{
        'dash': <String, dynamic>{
          'video': <dynamic>[
            <String, dynamic>{
              'id': 64,
              'backup_url': <dynamic>['https://x/backup.m4s'],
            },
          ],
        },
      }, requestedQn: 64);
      expect(r2.videoUrl, 'https://x/backup.m4s');
    });
  });

  /// 【回归】B 站把 baseUrl 调度到 PCDN 节点（不可达），可达的标准 CDN
  /// 只在 backupUrl 里。旧实现只取 baseUrl，导致真机上：
  /// 「Failed to open」黑屏 / 「有画面没声音」（视频通了、音频节点不通）。
  group('BiliCdn：候选节点排序', () {
    test('PCDN 是 baseUrl 时，标准 CDN 必须排到第一个', () {
      final urls = BiliCdn.candidatesOf(<String, dynamic>{
        'baseUrl': 'https://809ak83l.edge.mountaintoys.cn:4483/upgcxcode/v.m4s',
        'backupUrl': <dynamic>[
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/v.m4s',
          'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/v.m4s',
        ],
      });

      expect(urls.first, contains('upos-sz-mirrorcos.bilivideo.com'));
      expect(urls.last, contains('mountaintoys'));
      expect(urls, hasLength(3));
    });

    test('mcdn:8082 同样被识别为 PCDN 并垫底', () {
      expect(BiliCdn.isPcdn('https://xy39x184x180x110xy.mcdn.bilivideo.cn:8082/v.m4s'), isTrue);
      expect(BiliCdn.isPcdn('https://upos-sz-mirrorhw.bilivideo.com/v.m4s'), isFalse);

      final urls = BiliCdn.candidatesOf(<String, dynamic>{
        'base_url': 'https://a.mcdn.bilivideo.cn:8082/v.m4s',
        'backup_url': <dynamic>['https://upos-sz-mirrorhwo1.bilivideo.com/v.m4s'],
      });
      expect(urls.first, contains('upos-sz-mirrorhwo1'));
    });

    test('只有 PCDN 时仍然可用（垫底而不是丢弃）', () {
      final urls = BiliCdn.candidatesOf(<String, dynamic>{
        'baseUrl': 'https://x.edge.mountaintoys.cn:4483/v.m4s',
      });
      expect(urls, hasLength(1));
      expect(urls.single, contains('mountaintoys'));
    });

    test('durl 的 url / backup_url 也要收进候选', () {
      final r = PlayUrlResult.fromJson(<String, dynamic>{
        'durl': <dynamic>[
          <String, dynamic>{
            'url': 'https://19e949o.edge.mountaintoys.cn:4483/v.mp4',
            'backup_url': <dynamic>['https://upos-sz-estghw.bilivideo.com/v.mp4'],
          },
        ],
      }, requestedQn: 64);

      expect(r.channel, PlayChannel.mp4);
      expect(r.urls.first, contains('upos-sz-estghw.bilivideo.com'));
      expect(r.url, contains('upos-sz-estghw.bilivideo.com'),
          reason: 'url 取候选首位，即最可信节点');
    });

    test('视频与音频各自排序（音频节点不可达正是「有画面没声音」）', () {
      final r = PlayUrlResult.fromJson(<String, dynamic>{
        'dash': <String, dynamic>{
          'video': <dynamic>[
            <String, dynamic>{
              'id': 64,
              'codecid': 7,
              'baseUrl': 'https://v.edge.mountaintoys.cn:4483/v.m4s',
              'backupUrl': <dynamic>['https://upos-sz-mirrorhw.bilivideo.com/v.m4s'],
            },
          ],
          'audio': <dynamic>[
            <String, dynamic>{
              'id': 30280,
              'bandwidth': 170698,
              'baseUrl': 'https://a.edge.mountaintoys.cn:4483/a.m4s',
              'backupUrl': <dynamic>['https://upos-sz-mirrorhw.bilivideo.com/a.m4s'],
            },
          ],
        },
      }, requestedQn: 64);

      expect(r.videoUrls.first, contains('upos-sz-mirrorhw.bilivideo.com'));
      expect(r.audioUrls.first, contains('upos-sz-mirrorhw.bilivideo.com'));
      expect(r.videoUrls.last, contains('mountaintoys'));
      expect(r.audioUrls.last, contains('mountaintoys'));
    });
  });

  group('BiliVideoInfo.fromJson', () {
    test('解析 view 响应（含分 P 与统计）', () {
      final info = BiliVideoInfo.fromJson(<String, dynamic>{
        'bvid': 'BV1xx411c7mD',
        'aid': 123,
        'cid': 456,
        'title': '标题',
        'pic': 'https://x/c.jpg',
        'desc': '简介',
        'duration': 100,
        'pubdate': 1700000000,
        'owner': <String, dynamic>{
          'name': 'UP',
          'mid': 999,
          'face': 'https://x/f.jpg',
        },
        'stat': <String, dynamic>{
          'view': 1000,
          'danmaku': 20,
          'reply': 5,
          'like': 3,
        },
        'pages': <dynamic>[
          <String, dynamic>{'cid': 456, 'page': 1, 'part': 'P1', 'duration': 100},
          <String, dynamic>{'cid': 457, 'page': 2, 'part': 'P2', 'duration': 200},
        ],
      });

      expect(info.bvid, 'BV1xx411c7mD');
      expect(info.aid, 123);
      expect(info.ownerName, 'UP');
      expect(info.ownerMid, 999);
      expect(info.view, 1000);
      expect(info.danmakuCount, 20);
      expect(info.isMultiPart, isTrue);
      expect(info.cidForPage(2), 457);
      expect(info.cidForPage(99), 456, reason: '未知分 P 回落到第一 P');
      expect(info.pubdate, DateTime.utc(2023, 11, 14, 22, 13, 20));
    });

    test('缺字段时不抛异常', () {
      final info = BiliVideoInfo.fromJson(<String, dynamic>{});
      expect(info.bvid, '');
      expect(info.ownerName, '');
      expect(info.isMultiPart, isFalse);
      expect(info.pubdate, isNull);
    });
  });
}
