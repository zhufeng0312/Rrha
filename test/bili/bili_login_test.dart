import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/bili_client.dart';
import 'package:rrha/data/bili/bili_login.dart';
import 'package:rrha/data/models/bili_session.dart';

/// 阶段 1（扫码登录 + 凭据存储）的离线单测。
///
/// 覆盖的都是**容易写错、且错了很难从现象反推**的地方：
/// - 轮询状态码映射（外层 code 与 data.code 混用是经典坑）；
/// - 从 `Set-Cookie` 响应头抠凭据（body 里根本没有凭据）；
/// - Cookie 头拼接顺序与分隔符（错了就表现为「登录了却依然未登录」）；
/// - 凭据模型的序列化与**脱敏**（后者是安全约定，必须由测试守住）。

BiliSession _session({DateTime? obtainedAt, String? uname}) => BiliSession(
      sessData: 'SESSION-DATA-VALUE-1234',
      biliJct: 'JCT-VALUE-5678',
      dedeUserId: '365707715',
      dedeUserIdCkMd5: 'CKMD5-VALUE-9012',
      obtainedAt: obtainedAt ?? DateTime.now(),
      uname: uname,
    );

/// 扫码成功时 B 站真实下发的形态（一行一个 cookie，带 Path/Domain/HttpOnly）。
List<String> _setCookies({bool withCkMd5 = true}) => <String>[
      'SESSDATA=abc%2Cdef%2Cghi; Path=/; Domain=.bilibili.com; HttpOnly',
      'bili_jct=0123456789abcdef0123456789abcdef; Path=/; Domain=.bilibili.com',
      'DedeUserID=365707715; Path=/; Domain=.bilibili.com',
      if (withCkMd5)
        'DedeUserID__ckMd5=abcdef1234567890; Path=/; Domain=.bilibili.com',
      'sid=notneeded; Path=/; Domain=.bilibili.com',
    ];

void main() {
  group('轮询状态码映射', () {
    test('0 → success', () {
      expect(BiliLoginClient.stateFromCode(0), QrPollState.success);
    });

    test('86101 → waiting（未扫码）', () {
      expect(BiliLoginClient.stateFromCode(86101), QrPollState.waiting);
    });

    test('86090 → scanned（已扫待确认）', () {
      expect(BiliLoginClient.stateFromCode(86090), QrPollState.scanned);
    });

    test('86038 → expired', () {
      expect(BiliLoginClient.stateFromCode(86038), QrPollState.expired);
    });

    test('字符串形式的码同样识别（B 站有时把数字传成字符串）', () {
      expect(BiliLoginClient.stateFromCode('86101'), QrPollState.waiting);
      expect(BiliLoginClient.stateFromCode('0'), QrPollState.success);
    });

    test('未知码归为 unknown，而不是当成失败', () {
      expect(BiliLoginClient.stateFromCode(12345), QrPollState.unknown);
      expect(BiliLoginClient.stateFromCode(null), QrPollState.unknown);
    });
  });

  group('从 Set-Cookie 提取凭据', () {
    test('三个必需项齐全时得到完整会话', () {
      final s = BiliLoginClient.sessionFromCookies(_setCookies());
      expect(s, isNotNull);
      expect(s!.sessData, 'abc%2Cdef%2Cghi'); // 原样保留，不做 URL 解码
      expect(s.biliJct, '0123456789abcdef0123456789abcdef');
      expect(s.dedeUserId, '365707715');
      expect(s.dedeUserIdCkMd5, 'abcdef1234567890');
      expect(s.isUsable, isTrue);
    });

    test('缺 ckMd5 时仍然可用（它是可选的一致性校验值）', () {
      final s = BiliLoginClient.sessionFromCookies(_setCookies(withCkMd5: false));
      expect(s, isNotNull);
      expect(s!.dedeUserIdCkMd5, isNull);
      expect(s.isUsable, isTrue);
    });

    test('缺任一必需项都返回 null（不存残缺凭据）', () {
      for (final missing in <String>['SESSDATA', 'bili_jct', 'DedeUserID']) {
        final headers = _setCookies()
            .where((line) => !line.startsWith('$missing='))
            .toList();
        expect(
          BiliLoginClient.sessionFromCookies(headers),
          isNull,
          reason: '缺少 $missing 时不应产出会话',
        );
      }
    });

    test('空列表 / 畸形行不会崩', () {
      expect(BiliLoginClient.sessionFromCookies(<String>[]), isNull);
      expect(
        BiliLoginClient.sessionFromCookies(<String>['garbage', '=nokey', 'k=']),
        isNull,
      );
    });

    test('refresh_token 只在非空时带上', () {
      final a = BiliLoginClient.sessionFromCookies(_setCookies(), refreshToken: 'rt-1');
      final b = BiliLoginClient.sessionFromCookies(_setCookies(), refreshToken: '');
      expect(a!.refreshToken, 'rt-1');
      expect(b!.refreshToken, isNull);
    });

    test('obtainedAt 可注入，便于断言', () {
      final t = DateTime(2026, 10, 15, 12);
      final s = BiliLoginClient.sessionFromCookies(_setCookies(), now: t);
      expect(s!.obtainedAt, t);
    });
  });

  group('Cookie 头拼接', () {
    test('账号凭据在前、buvid3 在后，用 "; " 分隔', () {
      final header = BiliClient.composeCookieHeader(
        account: 'SESSDATA=x; bili_jct=y',
        buvid3: 'BV-123',
      );
      expect(header, 'SESSDATA=x; bili_jct=y; buvid3=BV-123');
    });

    test('只有账号凭据时不带 buvid3', () {
      expect(
        BiliClient.composeCookieHeader(account: 'SESSDATA=x'),
        'SESSDATA=x',
      );
    });

    test('只有 buvid3 时行为与旧版一致', () {
      expect(BiliClient.composeCookieHeader(buvid3: 'BV-1'), 'buvid3=BV-1');
    });

    test('两者都没有时返回 null（调用方不应设置 Cookie 头）', () {
      expect(BiliClient.composeCookieHeader(), isNull);
      expect(
        BiliClient.composeCookieHeader(account: '   ', buvid3: ''),
        isNull,
      );
    });

    test('首尾空白被裁掉', () {
      expect(
        BiliClient.composeCookieHeader(account: '  a=1  ', buvid3: ' b '),
        'a=1; buvid3=b',
      );
    });
  });

  group('BiliSession 凭据模型', () {
    test('cookieHeader 按 B 站要求拼装', () {
      expect(
        _session().cookieHeader,
        'SESSDATA=SESSION-DATA-VALUE-1234; bili_jct=JCT-VALUE-5678; '
        'DedeUserID=365707715; DedeUserID__ckMd5=CKMD5-VALUE-9012',
      );
    });

    test('缺 ckMd5 时 cookieHeader 不含该项', () {
      final s = BiliSession(
        sessData: 'a',
        biliJct: 'b',
        dedeUserId: 'c',
        obtainedAt: DateTime.now(),
      );
      expect(s.cookieHeader, 'SESSDATA=a; bili_jct=b; DedeUserID=c');
    });

    test('JSON 往返保持一致', () {
      // 用占位昵称而非真实账号名：本仓库是公开的，测试数据不应暴露使用者身份。
      final s = _session(uname: '测试用户');
      final back = BiliSession.fromJson(s.toJson());
      expect(back, isNotNull);
      expect(back!.sessData, s.sessData);
      expect(back.biliJct, s.biliJct);
      expect(back.dedeUserId, s.dedeUserId);
      expect(back.dedeUserIdCkMd5, s.dedeUserIdCkMd5);
      expect(back.uname, '测试用户');
    });

    test('缺关键字段 / 非 Map 时返回 null，不抛异常', () {
      expect(BiliSession.fromJson(null), isNull);
      expect(BiliSession.fromJson('not a map'), isNull);
      expect(BiliSession.fromJson(<String, dynamic>{}), isNull);
      expect(
        BiliSession.fromJson(<String, dynamic>{
          'sessdata': 'a',
          'bili_jct': 'b',
          // 缺 dede_user_id
        }),
        isNull,
      );
    });

    test('时间戳损坏时回落到当前时间而不是崩', () {
      final s = BiliSession.fromJson(<String, dynamic>{
        'sessdata': 'a',
        'bili_jct': 'b',
        'dede_user_id': 'c',
        'obtained_at': '这不是时间',
      });
      expect(s, isNotNull);
      expect(
        DateTime.now().difference(s!.obtainedAt).inMinutes.abs(),
        lessThan(2),
      );
    });

    test('isStale 以 7 天为界', () {
      final fresh = _session(obtainedAt: DateTime.now().subtract(const Duration(hours: 3)));
      final old = _session(obtainedAt: DateTime.now().subtract(const Duration(days: 8)));
      expect(fresh.isStale, isFalse);
      expect(old.isStale, isTrue);
    });

    test('isUsable 要求三项都非空', () {
      expect(_session().isUsable, isTrue);
      expect(
        BiliSession(sessData: '', biliJct: 'b', dedeUserId: 'c', obtainedAt: DateTime.now())
            .isUsable,
        isFalse,
      );
    });

    // ---- 安全约定：这两条测试是为了「以后有人不小心把它打出来」时能立刻发现 ----

    test('maskedSummary 只暴露末 4 位，不含完整凭据', () {
      final s = _session();
      final summary = s.maskedSummary;
      expect(summary.contains(s.sessData), isFalse);
      expect(summary.contains(s.biliJct), isFalse);
      expect(summary.contains(s.dedeUserIdCkMd5!), isFalse);
      expect(summary.contains('****'), isTrue);
    });

    test('toString 不泄露任何凭据字段', () {
      final s = _session();
      final text = s.toString();
      expect(text.contains(s.sessData), isFalse);
      expect(text.contains(s.biliJct), isFalse);
      expect(text.contains(s.dedeUserId), isFalse);
    });
  });
}
