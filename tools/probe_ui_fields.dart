// 探针：核对卡片要用的三个字段（头像 face / 评论·点赞·转发计数）。
//
// 为什么是 Dart 而不是 .env 里的 Python 脚本：这台机器上的 `python.exe`
// 是 Windows Store 的占位程序（直接返回 exit 49/9009，根本没装），而 Flutter
// SDK 自带 dart，用它发 HTTP 最省事、也不引入任何新依赖。
//
// 只打 **一个** 请求（feed/all 第一页），打印真实字段路径与样例值。
// 用法：dart run tools/probe_ui_fields.dart
import 'dart:convert';
import 'dart:io';

const String _sessionPath = r'C:\gradle-home\tmp\bili_login\session.json';

const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

Future<void> main() async {
  final File sessionFile = File(_sessionPath);
  if (!sessionFile.existsSync()) {
    stdout.writeln('会话文件不存在：$_sessionPath');
    exit(1);
  }
  final Map<String, dynamic> session =
      jsonDecode(sessionFile.readAsStringSync()) as Map<String, dynamic>;
  final Map<String, dynamic> cookies =
      Map<String, dynamic>.from(session['cookies'] as Map);
  final String cookie =
      cookies.entries.map((MapEntry<String, dynamic> e) => '${e.key}=${e.value}').join('; ');

  // feed/all 需要 WBI 签名；这里只要字段结构，先用不带签名的公开形态试一次，
  // 失败就明确提示（不硬编码签名逻辑，避免和 App 里的实现重复维护）。
  const String url =
      'https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all'
      '?type=all&page=1&offset=&timezone_offset=-480&platform=web'
      '&features=itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote';

  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', _ua);
    req.headers.set('Referer', 'https://www.bilibili.com/');
    req.headers.set('Origin', 'https://www.bilibili.com');
    req.headers.set('Cookie', cookie);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    final HttpClientResponse resp = await req.close();
    final String body = await resp.transform(utf8.decoder).join();

    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    stdout.writeln('http=${resp.statusCode} code=${json['code']} msg=${json['message']}');
    if (json['code'] != 0) {
      stdout.writeln('接口没返回 0，说明缺 WBI 签名；字段结构请用 App 运行日志或 --dump 缓存核对。');
      exit(2);
    }

    final List<dynamic> items =
        ((json['data'] as Map?)?['items'] as List?) ?? <dynamic>[];
    stdout.writeln('items=${items.length}\n');

    for (int i = 0; i < items.length && i < 6; i++) {
      final Map<String, dynamic> it = items[i] as Map<String, dynamic>;
      final Map<String, dynamic> mods =
          (it['modules'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final Map<String, dynamic> au =
          (mods['module_author'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final Map<String, dynamic> st =
          (mods['module_stat'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

      stdout.writeln('=== item $i  type=${it['type']}');
      stdout.writeln('  module_author.face = ${au['face']}');
      stdout.writeln('  module_author.name = ${au['name']}');
      stdout.writeln('  module_stat keys   = ${st.keys.toList()..sort()}');
      for (final String k in <String>['comment', 'like', 'forward', 'repost']) {
        final Object? v = st[k];
        if (v is Map) {
          stdout.writeln('  module_stat.$k.count = ${v['count']}');
        } else {
          stdout.writeln('  module_stat.$k = $v');
        }
      }
      final Map<String, dynamic> md =
          (mods['module_dynamic'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final Map<String, dynamic> arch =
          ((md['major'] as Map?)?['archive'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{};
      if (arch.isNotEmpty) {
        stdout.writeln('  major.archive.stat = ${arch['stat']}');
        stdout.writeln('  major.archive.duration_text = ${arch['duration_text']}');
      }
      stdout.writeln();
    }
  } finally {
    client.close(force: true);
  }
}
