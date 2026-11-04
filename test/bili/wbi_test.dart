import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/wbi.dart';

/// 32 个 'a' 与 32 个 'b' 拼成的合法 WBI 密钥对。
/// 用它可以把 mixinKey 的期望值手算出来，从而对混淆表做黄金断言。
const String kImgKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String kSubKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('WbiSigner 混淆表', () {
    test('必须是 0..63 的一个排列（能抓出手抄错误）', () {
      final tab = WbiSigner.mixinKeyEncTab;
      expect(tab.length, 64);
      final sorted = List<int>.from(tab)..sort();
      expect(sorted, List<int>.generate(64, (i) => i));
    });

    test('mixinKey 黄金值（表一旦改动此测试会失败）', () {
      // 手工推导：orig = a*32 + b*32，取表的前 32 个索引，
      // 索引 <32 得 'a'，>=32 得 'b'。
      // 该值同时与联网实测交叉验证过：同一张表在 Python 里算出的签名
      // 被 B 站 playurl/view 接口接受（返回 code=0）。
      const expected = 'bbaabaababaababbababbabaaaababba';
      expect(WbiSigner.mixinKey(kImgKey, kSubKey), expected);
      expect(WbiSigner.mixinKey(kImgKey, kSubKey).length, 32);
    });

    test('密钥长度异常时抛 ArgumentError，而不是静默产出错误签名', () {
      expect(
        () => WbiSigner.mixinKey('tooshort', kSubKey),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('keyFromImageUrl', () {
    test('去掉目录与扩展名', () {
      expect(
        WbiSigner.keyFromImageUrl(
          'https://i0.hdslb.com/bfs/wbi/7cd0849413bcf5f5b6bd4b8a1c22a7e2.png',
        ),
        '7cd0849413bcf5f5b6bd4b8a1c22a7e2',
      );
    });

    test('无扩展名时返回文件名', () {
      expect(WbiSigner.keyFromImageUrl('https://x.com/a/bcd'), 'bcd');
    });

    test('空/null 返回 null', () {
      expect(WbiSigner.keyFromImageUrl(null), isNull);
      expect(WbiSigner.keyFromImageUrl(''), isNull);
    });
  });

  group('WbiSigner.sign', () {
    test('参数按 key 升序拼接，并带上 wts 与 32 位 w_rid', () {
      final query = WbiSigner.sign(
        params: <String, dynamic>{
          'qn': 64,
          'cid': 12345,
          'bvid': 'BV1xx411c7mD',
        },
        imgKey: kImgKey,
        subKey: kSubKey,
        timestampSeconds: 1700000000,
      );

      expect(
        query.startsWith('bvid=BV1xx411c7mD&cid=12345&qn=64&wts=1700000000'),
        isTrue,
        reason: '实际结果：$query',
      );
      expect(query, matches(RegExp(r'&w_rid=[0-9a-f]{32}$')));
    });

    test('值中的 !\'()* 会被剔除（最常见的签名不匹配原因）', () {
      final query = WbiSigner.sign(
        params: <String, dynamic>{'q': "a!b'c(d)e*f"},
        imgKey: kImgKey,
        subKey: kSubKey,
        timestampSeconds: 1700000000,
      );
      expect(query, contains('q=abcdef'));
    });

    test('null 参数被跳过', () {
      final query = WbiSigner.sign(
        params: <String, dynamic>{'a': null, 'b': 'x'},
        imgKey: kImgKey,
        subKey: kSubKey,
        timestampSeconds: 1700000000,
      );
      expect(query.startsWith('b=x&wts=1700000000'), isTrue);
      expect(query.contains('a='), isFalse);
    });

    test('相同输入产生相同输出（纯函数，无隐藏状态）', () {
      final a = WbiSigner.sign(
        params: <String, dynamic>{'x': 1},
        imgKey: kImgKey,
        subKey: kSubKey,
        timestampSeconds: 1700000000,
      );
      final b = WbiSigner.sign(
        params: <String, dynamic>{'x': 1},
        imgKey: kImgKey,
        subKey: kSubKey,
        timestampSeconds: 1700000000,
      );
      expect(a, b);
    });
  });

  group('WbiKeys.fromNavData', () {
    test('从 nav 响应提取密钥（未登录时 code=-101 但仍有 wbi_img）', () {
      final keys = WbiKeys.fromNavData(<String, dynamic>{
        'isLogin': false,
        'wbi_img': <String, dynamic>{
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png',
        },
      });
      expect(keys, isNotNull);
      expect(keys!.imgKey, kImgKey);
      expect(keys.subKey, kSubKey);
    });

    test('缺字段时返回 null 而不是抛异常', () {
      expect(WbiKeys.fromNavData(null), isNull);
      expect(WbiKeys.fromNavData(<String, dynamic>{}), isNull);
      expect(WbiKeys.fromNavData(<String, dynamic>{'wbi_img': 'oops'}), isNull);
    });
  });
}
