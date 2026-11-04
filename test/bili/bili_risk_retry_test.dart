import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/core/net/app_error.dart';
import 'package:rrha/data/bili/bili_client.dart';

/// 回归测试：偶发 HTTP 412。
///
/// 412 是**网关层**拦截，响应里没有业务 JSON，因此走的是 `_unwrap()` 的
/// `status >= 400` 分支，`bizCode` 为 null。早先「是否强刷 WBI 密钥重试」
/// 只判业务码 -352/-412，于是 HTTP 412 既不重试、文案也落进泛化分支。
void main() {
  group('风控失败判定（决定是否强刷 WBI 密钥重试一次）', () {
    test('业务码 -352 / -412 命中', () {
      expect(
        BiliClient.isRiskFailure(AppError.bili(-352, '风控校验失败')),
        isTrue,
      );
      expect(
        BiliClient.isRiskFailure(AppError.bili(-412, '请求被拦截')),
        isTrue,
      );
    });

    test('HTTP 412 命中（本次修复的核心）', () {
      final e = AppError.fromStatus(412, detail: 'GET /x/v2/reply/wbi/main');
      expect(e.bizCode, isNull, reason: '412 没有业务码，只有状态码');
      expect(BiliClient.isRiskFailure(e), isTrue);
    });

    test('其它失败不命中，避免无谓刷新密钥', () {
      expect(BiliClient.isRiskFailure(AppError.fromStatus(403)), isFalse);
      expect(BiliClient.isRiskFailure(AppError.fromStatus(404)), isFalse);
      expect(BiliClient.isRiskFailure(AppError.fromStatus(429)), isFalse);
      expect(BiliClient.isRiskFailure(AppError.fromStatus(500)), isFalse);
      expect(BiliClient.isRiskFailure(AppError.bili(-509, '过于频繁')), isFalse);
      expect(BiliClient.isRiskFailure(AppError.bili(null, '其它错误')), isFalse);
    });
  });
}
