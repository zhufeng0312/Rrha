import '../../core/net/app_error.dart';

/// B 站业务错误码 → 用户可读中文。
///
/// 需求明确要求「WBI 签名失败必须显示可读错误，而不是黑屏」，
/// 所以 -352 / -412 这类风控码必须在这里穷尽，不能落到 unknown。
class BiliCodes {
  BiliCodes._();

  static AppError toError(int code, String? message, {String? detail}) {
    final raw = (message ?? '').trim();
    final suffix = raw.isEmpty ? '' : '（$raw）';
    final d = detail == null ? null : '$detail -> code=$code';

    switch (code) {
      case -352:
        return AppError.bili(
          code,
          'B 站风控校验失败（-352），签名或设备指纹被拒绝，请稍后重试',
          detail: d,
        );
      case -412:
        return AppError.bili(
          code,
          '请求被 B 站风控拦截（-412），请稍后重试',
          detail: d,
        );
      case -509:
        return AppError.bili(code, '请求过于频繁（-509），请稍后重试', detail: d);
      case -101:
        return AppError.bili(code, '该接口需要登录状态（-101）$suffix', detail: d);
      case -403:
        return AppError.bili(code, '没有访问权限（-403）$suffix', detail: d);
      case -404:
        return AppError.bili(code, '内容不存在或已被删除（-404）', detail: d);
      case -400:
        return AppError.bili(code, '请求参数有误（-400）$suffix', detail: d);
      case -10403:
        return AppError.bili(
          code,
          '该内容需要登录后才能访问（-10403），本轮原型不支持登录',
          detail: d,
        );
      case 62002:
        return AppError.bili(code, '稿件不可见（62002），可能已被 UP 主设为私密', detail: d);
      case 62004:
        return AppError.bili(code, '稿件正在审核中（62004），请稍后再试', detail: d);
      case 62012:
        return AppError.bili(code, '仅 UP 主可见（62012）', detail: d);
      default:
        return AppError.bili(
          code,
          'B 站接口返回错误（$code）$suffix',
          detail: d,
        );
    }
  }

  /// 是否是「重刷 WBI 密钥后可能成功」的风控码。
  static bool isRiskCode(int? code) => code == -352 || code == -412;
}
