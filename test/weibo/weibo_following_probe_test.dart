import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/weibo/weibo_diagnostics.dart';

/// `WeiboFollowingProbe` 的离线验收。
///
/// 探针本体要真机跑才能出结论，但**判定逻辑全是纯函数**，所以这里把
/// 「列表在哪、字段叫什么、翻页去重、P2 能不能算关注流、URL/Markdown 脱敏、
/// 请求节制」逐条钉死：真机上一旦拿到响应，翻译成人话的那一步不会再出错。
///
/// 响应结构按 `m.weibo.cn` 的 `231093_-_selffollowed` 实际形态构造
/// （`data.cards[].card_group[].user`），并额外覆盖两种差异形态，确认
/// 探针是**扫出来的**而不是照某个固定路径写死的。

/// 一个用户对象（字段名按微博真实接口）。
Map<String, dynamic> _user({
  Object? id = 1782488734,
  String? idstr,
  String screenName = '测试博主',
  String avatarHd = 'https://tvax1.sinaimg.cn/crop.0.0.1080.1080.180/avatar.jpg',
}) =>
    <String, dynamic>{
      'id': id,
      if (idstr != null) 'idstr': idstr,
      'screen_name': screenName,
      'profile_image_url': 'https://tvax1.sinaimg.cn/crop/profile.jpg',
      'avatar_hd': avatarHd,
      'followers_count': 12345,
      'verified': true,
    };

/// 一页关注列表响应：`data.cards[].card_group[].user`。
String _followingBody({
  required List<Map<String, dynamic>> users,
  int? total,
  String title = '关注 128 人',
}) {
  final List<Map<String, dynamic>> groups = users
      .map((Map<String, dynamic> u) => <String, dynamic>{
            'card_type': 10,
            'user': u,
          })
      .toList();
  return '{"ok":1,"data":{'
      '${total == null ? '' : '"total":$total,'}'
      '"cards":[{"card_type":11,"title":"$title"},'
      '{"card_type":11,"card_group":${_json(groups)}}]}}';
}

String _json(Object? value) {
  if (value == null) return 'null';
  if (value is String) return '"${value.replaceAll('"', r'\"')}"';
  if (value is num || value is bool) return '$value';
  if (value is List) {
    return '[${value.map(_json).join(',')}]';
  }
  if (value is Map) {
    return '{${value.entries.map((MapEntry<Object?, Object?> e) => '"${e.key}":${_json(e.value)}').join(',')}}';
  }
  return 'null';
}

void main() {
  group('P1 解析：列表路径与字段', () {
    test('card_group[].user 形态 → 扫到用户，路径归一化带 [i]', () {
      final FollowingPageStat s = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[
            _user(screenName: '甲'),
            _user(id: 2, screenName: '乙'),
          ],
        ),
      );
      expect(s.httpStatus, 200);
      expect(s.okRaw, '1');
      expect(s.userCount, 2);
      expect(
        s.listPaths,
        contains('data.cards[i].card_group[i].user'),
      );
      expect(s.sampleUsers.first.screenName, '甲');
    });

    test('uid 优先取 idstr（String），没有 idstr 时退回 id（int）', () {
      final FollowingPageStat s = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[
            _user(id: 1782488734, idstr: '1782488734'),
            _user(id: 42, screenName: '乙'),
          ],
        ),
      );
      expect(s.sampleUsers[0].uid, '1782488734');
      expect(s.sampleUsers[0].uidField, 'idstr');
      expect(s.sampleUsers[0].uidType, 'String');
      expect(s.sampleUsers[1].uid, '42');
      expect(s.sampleUsers[1].uidField, 'id');
      expect(s.sampleUsers[1].uidType, 'int');
    });

    test('昵称与头像字段按实测名字报出，不拿别的字段顶', () {
      final FollowingPageStat s = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[_user(screenName: '若叶睦')],
        ),
      );
      final FollowingUser u = s.sampleUsers.first;
      expect(u.nameField, 'screen_name');
      expect(u.screenName, '若叶睦');
      expect(u.avatarField, 'avatar_hd');
      expect(u.avatar, contains('sinaimg.cn'));
    });

    test('没有任何用户对象时 userCount=0，字段结论为空（不编造）', () {
      final FollowingPageStat s = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: '{"ok":1,"data":{"cards":[{"card_type":11,"title":"关注"}]}}',
      );
      expect(s.userCount, 0);
      expect(s.fieldAnswers, isEmpty);
      expect(s.userTrees, isEmpty);
    });

    test('扁平 data.cards[].user 也能扫到（不写死路径）', () {
      final FollowingPageStat s = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: '{"ok":1,"data":{"cards":[{"card_type":10,"user":'
            '${_json(_user(screenName: '扁平'))}}]}}',
      );
      expect(s.userCount, 1);
      expect(s.listPaths, contains('data.cards[i].user'));
      expect(s.sampleUsers.first.screenName, '扁平');
    });

    test('同一 uid 重复出现只算一个（避免总数虚高）', () {
      final FollowingPageStat s = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[
            _user(idstr: '7', screenName: '甲'),
            _user(idstr: '7', screenName: '甲'),
          ],
        ),
      );
      expect(s.userCount, 1);
    });

    test('总数：优先读字段，读不到时从卡片标题捞线索', () {
      final FollowingPageStat withField = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[_user()],
          total: 128,
        ),
      );
      expect(withField.totalField, 'total');
      expect(withField.totalValue, 128);

      final FollowingPageStat fromTitle = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[_user()],
          title: '关注 128 人',
        ),
      );
      expect(fromTitle.totalField, isNull);
      expect(fromTitle.totalHints.join(), contains('关注 128 人'));
    });

    test('非法 JSON / 空 body 按空页处理，不抛异常', () {
      for (final String body in <String>['', 'not json', '<html>']) {
        final FollowingPageStat s = WeiboFollowingProbe.parsePage(
          pageNo: 1,
          httpStatus: 432,
          body: body,
        );
        expect(s.userCount, 0);
        expect(s.okRaw, '（无 ok）');
      }
    });
  });

  group('P1 解析：翻页去重', () {
    test('第 2 页与第 1 页重叠时 duplicateWithPrev 数对', () {
      final Set<String> seen = <String>{};
      final FollowingPageStat p1 = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[
            _user(idstr: '1'),
            _user(idstr: '2'),
          ],
        ),
        seenUids: seen,
      );
      expect(p1.duplicateWithPrev, 0);

      final FollowingPageStat p2 = WeiboFollowingProbe.parsePage(
        pageNo: 2,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[
            _user(idstr: '2'),
            _user(idstr: '3'),
          ],
        ),
        seenUids: seen,
      );
      expect(p2.userCount, 2);
      expect(p2.duplicateWithPrev, 1);
    });

    test('第 2 页 0 用户时判「翻页无效」，绝不写成「不重复=有效」', () async {
      // 真机实测：&page=2 返回 200 + ok=1 但 0 个用户。
      final FollowingProbeResult r = FollowingProbeResult(
        pages: <FollowingPageStat>[
          FollowingPageStat(
            pageNo: 1,
            httpStatus: 200,
            okRaw: '1',
            topKeys: const <String>[],
            dataKeys: const <String>[],
            cardShape: const <String>[],
            listPaths: const <String>[],
            userCount: 9,
            duplicateWithPrev: 0,
            totalValue: null,
            totalField: null,
            totalCandidates: const <String>[],
            totalHints: const <String>[],
            cursorCandidates: const <String>[],
            fieldAnswers: const <String>[],
            userTrees: const <String>[],
            sampleUsers: const <FollowingUser>[],
            bodyHead: '',
          ),
          FollowingPageStat(
            pageNo: 2,
            httpStatus: 200,
            okRaw: '1',
            topKeys: const <String>[],
            dataKeys: const <String>[],
            cardShape: const <String>[],
            listPaths: const <String>[],
            userCount: 0,
            duplicateWithPrev: 0,
            totalValue: null,
            totalField: null,
            totalCandidates: const <String>[],
            totalHints: const <String>[],
            cursorCandidates: const <String>[],
            fieldAnswers: const <String>[],
            userTrees: const <String>[],
            sampleUsers: const <FollowingUser>[],
            bodyHead: '',
          ),
        ],
        page2Param: 'page=2',
        guest: null,
        guestBodyHead: '',
        feeds: const <FeedProbeStat>[],
        requestLog: const <String>[],
        requestCount: 2,
        saw432: false,
        max432Streak: 0,
        note: '',
      );
      final String md = r.toMarkdown(cookieLength: 1, date: '2026-10-19');
      expect(md, contains('翻页无效'));
      expect(md, isNot(contains('不重复（分页有效）')));
    });

    test('第 2 页完全新数据时重复为 0（分页有效）', () {
      final Set<String> seen = <String>{'1', '2'};
      final FollowingPageStat p2 = WeiboFollowingProbe.parsePage(
        pageNo: 2,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[
            _user(idstr: '3'),
            _user(idstr: '4'),
          ],
        ),
        seenUids: seen,
      );
      expect(p2.duplicateWithPrev, 0);
    });
  });

  group('P2 判定：能否算「关注动态流」', () {
    String feedBody(int authors) {
      final List<Map<String, dynamic>> cards = <Map<String, dynamic>>[];
      for (int i = 0; i < authors; i++) {
        cards.add(<String, dynamic>{
          'card_type': 9,
          'mblog': <String, dynamic>{
            'id': '${1000 + i}',
            'text': 'hi',
            'user': <String, dynamic>{'id': 100 + i, 'screen_name': 'u$i'},
          },
        });
      }
      return '{"ok":1,"data":{"cards":${_json(cards)}}}';
    }

    FeedProbeStat judge(String body, {int? status = 200, bool cand = true}) =>
        WeiboFollowingProbe.parseFeed(
          label: 't',
          url: 'https://m.weibo.cn/feed/friends',
          isFollowingFeedCandidate: cand,
          httpStatus: status,
          body: body,
        );

    test('多作者 + 200/ok=1 → YES', () {
      final FeedProbeStat s = judge(feedBody(3));
      expect(s.mblogCount, 3);
      expect(s.distinctAuthors, 3);
      expect(s.verdict, startsWith('YES'));
    });

    test('只有一个作者 → UNKNOWN（样本不足，不硬判 YES）', () {
      final FeedProbeStat s = judge(feedBody(1));
      expect(s.verdict, startsWith('UNKNOWN'));
    });

    test('432 → NO', () {
      expect(judge('', status: 432).verdict, startsWith('NO'));
    });

    test('ok≠1 → NO', () {
      expect(judge('{"ok":-100}').verdict, startsWith('NO'));
    });

    test('200 但 0 条 mblog → NO', () {
      expect(judge('{"ok":1,"data":{"cards":[]}}').verdict, startsWith('NO'));
    });

    test('推荐流对照即使有内容也不算关注流', () {
      final FeedProbeStat s = judge(feedBody(5), cand: false);
      expect(s.verdict, startsWith('NO'));
      expect(s.verdict, contains('对照'));
    });

    test('mblog 内的转发原帖 user 不会虚高作者数', () {
      final String body = '{"ok":1,"data":{"cards":[{"card_type":9,"mblog":'
          '{"id":"1","user":{"id":1,"screen_name":"a"},'
          '"retweeted_status":{"user":{"id":2,"screen_name":"b"}}}}]}}';
      final FeedProbeStat s = judge(body);
      expect(s.mblogCount, 1);
      expect(s.distinctAuthors, 1);
    });

    test('裸列表 data.statuses[]（feed/friends 实际形态）→ YES', () {
      // 这是第一轮真机踩到的假阴性：微博对象**没有** mblog 外壳。
      final String body = '{"ok":1,"data":{"statuses":['
          '{"id":"1","mid":"1","text":"a","user":{"id":11,"screen_name":"a"}},'
          '{"id":"2","mid":"2","text":"b","user":{"id":22,"screen_name":"b"}},'
          '{"id":"3","mid":"3","text":"c","user":{"id":11,"screen_name":"a"}}'
          ']}}';
      final s = judge(body);
      expect(s.mblogCount, 3);
      expect(s.bareCount, 3);
      expect(s.wrappedCount, 0);
      expect(s.distinctAuthors, 2);
      expect(s.listPaths, contains('data.statuses[i]'));
      expect(s.verdict, startsWith('YES'));
    });

    test('两种形态混合也能全数统计', () {
      final String body = '{"ok":1,"data":{"cards":[{"card_type":9,"mblog":'
          '{"id":"1","user":{"id":1},"text":"x"}}],"statuses":['
          '{"id":"2","mid":"2","text":"y","user":{"id":2}}]}}';
      final FeedProbeStat s = judge(body);
      expect(s.mblogCount, 2);
      expect(s.wrappedCount, 1);
      expect(s.bareCount, 1);
      expect(s.distinctAuthors, 2);
    });

    test('用户卡片（有 user 但无 text/mid）不算微博', () {
      final String body = '{"ok":1,"data":{"cards":[{"card_type":10,'
          '"user":{"id":1,"screen_name":"a"}}]}}';
      expect(judge(body).mblogCount, 0);
    });

    test('关注流响应里的 since_id / page 会被报出游标候选', () {
      final String body = '{"ok":1,"data":{"since_id":"4912","statuses":['
          '{"id":"1","mid":"1","text":"a","user":{"id":1}},'
          '{"id":"2","mid":"2","text":"b","user":{"id":2}}]}}';
      final FeedProbeStat s = judge(body);
      expect(s.cursorCandidates.join(), contains('since_id'));
    });
  });

  group('URL 脱敏', () {
    test('凭据类参数一律打码，普通参数原样保留', () {
      final String masked = WeiboFollowingProbe.maskUrl(
        'https://m.weibo.cn/api/x?a=1&token=SECRET&SUB=abc&st=xyz',
      );
      expect(masked, contains('token=***'));
      expect(masked, contains('SUB=***'));
      expect(masked, contains('st=***'));
      expect(masked, contains('a=1'));
      expect(masked, isNot(contains('SECRET')));
      expect(masked, isNot(contains('abc')));
    });

    test('长参数值不再截断（否则 URL 无法复现）；凭据仍打码', () {
      final String masked = WeiboFollowingProbe.maskUrl(
        'https://m.weibo.cn/api/x?since_id=12345678901234567890&token=T',
      );
      expect(masked, contains('since_id=12345678901234567890'));
      expect(masked, contains('token=***'));
    });

    test('无 query 的 URL 原样返回', () {
      expect(
        WeiboFollowingProbe.maskUrl('https://m.weibo.cn/'),
        'https://m.weibo.cn/',
      );
    });
  });

  group('URL 拼装', () {
    test('第 1 页不带任何分页参数', () {
      expect(
        WeiboFollowingProbe.followingUrl(),
        WeiboFollowingProbe.followingEndpoint,
      );
      expect(WeiboFollowingProbe.followingUrl(pageParam: '  '), endsWith('selffollowed'));
    });

    test('第 2 页只追加 page=2，不改 containerid', () {
      final String url = WeiboFollowingProbe.followingUrl(pageParam: 'page=2');
      expect(url, contains('containerid=231093_-_selffollowed&page=2'));
    });
  });

  group('请求节制（假适配器，无真实网络）', () {
    test('连续 432 达到 3 次立刻停，后续请求不再发出', () async {
      final _StubAdapter stub = _StubAdapter(status: 432, body: '');
      final WeiboFollowingProbe probe =
          WeiboFollowingProbe(dio: _dioWith(stub));
      final FollowingProbeResult r = await probe.run(cookie: 'COOKIE_VALUE');

      expect(r.saw432, isTrue);
      expect(r.max432Streak, lessThanOrEqualTo(3));
      // 3 次 432 之后就停：请求数不可能超过硬上限，也不会继续翻页。
      expect(r.requestCount, lessThanOrEqualTo(3));
      expect(stub.calls, lessThanOrEqualTo(3));
      expect(probe.aborted, isTrue);
      expect(r.pages.length, lessThanOrEqualTo(1));
      // P2 可能刚好是第 3 次 432（叫停发生在它之后），所以最多 1 条。
      expect(r.feeds.length, lessThanOrEqualTo(1));
    });

    test('200 + 空列表：不翻页、不发 P2，只发 1 个请求', () async {
      final _StubAdapter stub = _StubAdapter(
        status: 200,
        body: '{"ok":1,"data":{"cards":[]}}',
      );
      final WeiboFollowingProbe probe =
          WeiboFollowingProbe(dio: _dioWith(stub));
      final FollowingProbeResult r = await probe.run(
        cookie: 'COOKIE_VALUE',
        withGuestCheck: false,
        withFeedProbe: false,
      );
      expect(stub.calls, 1);
      expect(r.pages.length, 1);
      expect(r.page2Param, isNull);
    });

    test('可用数据时总请求数不超过硬上限', () async {
      final _StubAdapter stub = _StubAdapter(
        status: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[_user(idstr: '1')],
        ),
      );
      final WeiboFollowingProbe probe =
          WeiboFollowingProbe(dio: _dioWith(stub));
      final FollowingProbeResult r = await probe.run(cookie: 'COOKIE_VALUE');
      expect(stub.calls, lessThanOrEqualTo(WeiboFollowingProbe.maxRequests));
      expect(r.requestCount, r.requestLog.length);
    });

    test('cookie 只出现在请求头里，不进结果对象与 Markdown', () async {
      const String cookie = 'SUB=TOPSECRETSUB; SUBP=TOPSECRETSUBP';
      final _StubAdapter stub = _StubAdapter(
        status: 200,
        body: _followingBody(users: <Map<String, dynamic>>[_user()]),
      );
      final WeiboFollowingProbe probe =
          WeiboFollowingProbe(dio: _dioWith(stub));
      final FollowingProbeResult r = await probe.run(cookie: cookie);

      expect(stub.lastCookieHeader, cookie);
      expect(r.toText(), isNot(contains('TOPSECRET')));
      final String md = r.toMarkdown(cookieLength: cookie.length);
      expect(md, isNot(contains('TOPSECRET')));
      expect(md, contains('cookie 长度'));
      expect(md, contains('${cookie.length}'));
      for (final String line in r.requestLog) {
        expect(line, isNot(contains('TOPSECRET')));
      }
    });

    test('未登录对照请求不带 Cookie 头', () async {
      final _StubAdapter stub = _StubAdapter(
        status: 200,
        body: '{"ok":1,"data":{"cards":[]}}',
      );
      final WeiboFollowingProbe probe =
          WeiboFollowingProbe(dio: _dioWith(stub));
      final FollowingProbeResult r = await probe.run(
        cookie: '',
        withFeedProbe: false,
      );
      expect(r.guest, isNotNull);
      expect(stub.cookieHeaders.every((String? c) => c == null || c.isEmpty),
          isTrue);
    });
  });

  group('Markdown 报告结构', () {
    test('六节齐全，且 P1/P2 结论可被直接引用', () {
      final FollowingPageStat p1 = WeiboFollowingProbe.parsePage(
        pageNo: 1,
        httpStatus: 200,
        body: _followingBody(
          users: <Map<String, dynamic>>[
            _user(idstr: '1782488734', screenName: '若叶睦'),
          ],
          total: 128,
        ),
      );
      final FollowingProbeResult r = FollowingProbeResult(
        pages: <FollowingPageStat>[p1],
        page2Param: null,
        guest: null,
        guestBodyHead: '',
        feeds: <FeedProbeStat>[],
        requestLog: const <String>['P1 关注列表第1页 → HTTP 200'],
        requestCount: 1,
        saw432: false,
        max432Streak: 0,
        note: 'P1 可用',
      );
      final String md = r.toMarkdown(cookieLength: 42, date: '2026-10-19');
      expect(md, startsWith('# 微博关注列表探针（2026-10-19）'));
      for (final String section in <String>[
        '## 一、P1 关注列表',
        '## 二、重点关注（逐项回答）',
        '## 三、P2 关注动态流',
        '## 四、未登录态',
        '## 五、给实现者的硬结论',
        '## 六、cookie 长度',
      ]) {
        expect(md, contains(section));
      }
      expect(md, contains('data.cards[i].card_group[i].user'));
      expect(md, contains('若叶睦'));
      expect(md, contains('128'));
      expect(md, contains('42'));
    });

    test('没有 P2 探测时明确写「未探测」，不假装有结论', () {
      final FollowingProbeResult r = FollowingProbeResult(
        pages: const <FollowingPageStat>[],
        page2Param: null,
        guest: null,
        guestBodyHead: '',
        feeds: const <FeedProbeStat>[],
        requestLog: const <String>[],
        requestCount: 0,
        saw432: false,
        max432Streak: 0,
        note: '未发出任何关注列表请求',
      );
      final String md = r.toMarkdown(cookieLength: 0, date: '2026-10-19');
      expect(md, contains('（未探测）'));
      expect(md, contains('未发出任何关注列表请求'));
      expect(r.toText(), contains('（没有发出请求）'));
    });
  });
}

/// 假适配器：不联网，按固定状态码/响应体返回，并记录请求头。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({required this.status, required this.body});

  final int status;
  final String body;

  int calls = 0;
  final List<String?> cookieHeaders = <String?>[];

  String? get lastCookieHeader =>
      cookieHeaders.isEmpty ? null : cookieHeaders.last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    cookieHeaders.add(options.headers['Cookie'] as String?);
    return ResponseBody.fromString(
      body,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) => Dio()..httpClientAdapter = adapter;
