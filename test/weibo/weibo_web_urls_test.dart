import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/data/weibo/weibo_web_urls.dart';

/// 微博 Web URL 工具的离线验收。
///
/// 这一层是纯字符串处理，但**安全性全靠它**：uid / mid 会直接从用户输入
/// 拼进 `m.weibo.cn` 的路径，若不校验就把 `javascript:` 之类塞进 WebView，
/// 等于自己开了一个注入口子。所以这里的断言重点是「非法输入必须抛」和
/// 「危险 scheme 必须拒」。
void main() {
  group('URL 拼接', () {
    test('mbBase 就是移动端站点（桌面 UA 会被重定向，只认这个域名）', () {
      expect(WeiboWebUrls.mbBase, 'https://m.weibo.cn');
      expect(WeiboWebUrls.profile('1').startsWith(WeiboWebUrls.mbBase), isTrue);
      expect(WeiboWebUrls.status('1').startsWith(WeiboWebUrls.mbBase), isTrue);
    });

    test('profile 拼出 https://m.weibo.cn/u/<uid>', () {
      expect(
        WeiboWebUrls.profile('1782488734'),
        contains('https://m.weibo.cn/u/1782488734'),
      );
    });

    test('status 拼出 https://m.weibo.cn/status/<mid>', () {
      expect(
        WeiboWebUrls.status('5000000000000000'),
        contains('https://m.weibo.cn/status/5000000000000000'),
      );
    });
  });

  group('uid / mid 必须是纯数字', () {
    test('profile 拒绝空串、字母、空格、负号', () {
      // 空串会让地址退化成 /u/（落到站点首页），字母/空格能拼出
      // 任意路径，负号不是合法 uid —— 一律在拼接前拦掉。
      for (final bad in <String>['', 'abc', '12 34', '-1']) {
        expect(
          () => WeiboWebUrls.profile(bad),
          throwsA(isA<AppError>()),
          reason: 'profile 必须拒绝「$bad」',
        );
      }
    });

    test('status 拒绝空串与字母', () {
      for (final bad in <String>['', 'abc']) {
        expect(
          () => WeiboWebUrls.status(bad),
          throwsA(isA<AppError>()),
          reason: 'status 必须拒绝「$bad」',
        );
      }
    });

    test('抛的是 parse 类 AppError（能被统一错误模型收口）', () {
      expect(
        () => WeiboWebUrls.profile('abc'),
        throwsA(
          isA<AppError>().having(
            (AppError e) => e.kind,
            'kind',
            AppErrorKind.parse,
          ),
        ),
      );
    });

    test('边界：纯数字但很长也放行（微博 uid 现在就是 10 位）', () {
      expect(WeiboWebUrls.profile('0'), contains('/u/0'));
      expect(
        WeiboWebUrls.profile('1000000000000000000'),
        contains('/u/1000000000000000000'),
      );
    });
  });

  group('isAllowed：只有 http(s) 交给内置 WebView', () {
    test('http/https 放行', () {
      expect(WeiboWebUrls.isAllowed('https://m.weibo.cn/u/1'), isTrue);
      expect(WeiboWebUrls.isAllowed('http://x'), isTrue);
    });

    test('可执行脚本 / 读本地文件 / 内嵌数据的 scheme 一律拒绝', () {
      expect(WeiboWebUrls.isAllowed('javascript:alert(1)'), isFalse);
      expect(WeiboWebUrls.isAllowed('file:///etc/passwd'), isFalse);
      expect(WeiboWebUrls.isAllowed('data:text/html,x'), isFalse);
      expect(WeiboWebUrls.isAllowed('content://x'), isFalse);
    });

    test('空串拒绝', () {
      expect(WeiboWebUrls.isAllowed(''), isFalse);
    });

    test('http: 但没有 host 的串不算可加载地址', () {
      expect(WeiboWebUrls.isAllowed('http:'), isFalse);
      expect(WeiboWebUrls.isAllowed('http://'), isFalse);
    });

    test('大小写：scheme 归一化后再比较，HTTPS://X 放行', () {
      // 实现里 scheme 先 toLowerCase() 再比，所以大写 HTTPS 也是允许的。
      // 这条钉住的是「用户/页面给的大写 scheme 不会被误判为外部协议」。
      expect(WeiboWebUrls.isAllowed('HTTPS://X'), isTrue);
      expect(
        WeiboWebUrls.isExternalScheme('HTTPS://X'),
        isFalse,
        reason: '大写 HTTPS 不能被当成外部 scheme 甩给系统',
      );
    });
  });

  group('isExternalScheme：非 http(s) 交给系统', () {
    test('weibo://、intent://、snssdk:// 都是外部 scheme', () {
      expect(WeiboWebUrls.isExternalScheme('weibo://user?uid=1'), isTrue);
      expect(WeiboWebUrls.isExternalScheme('intent://x'), isTrue);
      expect(WeiboWebUrls.isExternalScheme('snssdk://x'), isTrue);
    });

    test('http(s) 不是外部 scheme', () {
      expect(WeiboWebUrls.isExternalScheme('https://m.weibo.cn'), isFalse);
      expect(WeiboWebUrls.isExternalScheme('http://x'), isFalse);
    });

    test('空串与无 scheme 的相对地址不是外部 scheme', () {
      expect(WeiboWebUrls.isExternalScheme(''), isFalse);
      expect(WeiboWebUrls.isExternalScheme('/u/1'), isFalse);
    });
  });
}
