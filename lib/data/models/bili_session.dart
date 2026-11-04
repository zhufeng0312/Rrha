/// B 站账号会话（登录凭据）。
///
/// **安全约定（HANDOVER §8）**：本类的实例**只能**经 [BiliCredentialStore]
/// 写入系统钥匙串（Android Keystore），严禁落到 SharedPreferences、日志、
/// 崩溃上报或源码里。
///
/// 因此这里刻意做了两件事：
/// 1. **不覆盖 `toString()`** —— Dart 默认的 `Instance of 'BiliSession'`
///    不会泄露任何字段，比任何「记得别打日志」的约定都可靠；
/// 2. 需要展示时一律走 [maskedSummary]（只给长度与末 4 位）。
class BiliSession {
  const BiliSession({
    required this.sessData,
    required this.biliJct,
    required this.dedeUserId,
    required this.obtainedAt,
    this.dedeUserIdCkMd5,
    this.refreshToken,
    this.uname,
    this.mid,
  });

  /// 主登录票据。请求 B 站接口时必须带上，否则风控码满天飞。
  final String sessData;

  /// CSRF token（`bili_jct`）。读取接口不强依赖，写操作必需。
  final String biliJct;

  /// 账号 uid（`DedeUserID`）。
  final String dedeUserId;

  /// `DedeUserID__ckMd5`：B 站登录时下发的一致性校验值，可选。
  final String? dedeUserIdCkMd5;

  /// 扫码成功时一并下发的 `refresh_token`。
  ///
  /// 阶段 1 **只保存不使用**（续期逻辑留到需要时再做，避免过度设计）。
  final String? refreshToken;

  /// 昵称，由 `/x/web-interface/nav` 取回，**仅用于界面展示**。
  final String? uname;

  /// 账号 mid，同上。
  final int? mid;

  /// 拿到这份凭据的时间（用于展示「登录于 x 天前」）。
  final DateTime obtainedAt;

  // ---------------------------------------------------------------- 派生

  /// 拼成请求头用的 Cookie 串。
  ///
  /// ⚠️ 这是**唯一**会产生完整凭据字符串的地方，只允许交给网络层，
  /// 不要放进日志、异常 detail 或 UI。
  String get cookieHeader {
    final parts = <String>[
      'SESSDATA=$sessData',
      'bili_jct=$biliJct',
      'DedeUserID=$dedeUserId',
    ];
    final md5 = dedeUserIdCkMd5;
    if (md5 != null && md5.isNotEmpty) {
      parts.add('DedeUserID__ckMd5=$md5');
    }
    return parts.join('; ');
  }

  /// 凭据是否完整到「可以拿去请求」的程度。
  bool get isUsable =>
      sessData.isNotEmpty && biliJct.isNotEmpty && dedeUserId.isNotEmpty;

  Duration get age => DateTime.now().difference(obtainedAt);

  /// 是否已经放了很久。
  ///
  /// SESSDATA 自身不带过期时间，这里只是一个**提示性**判断：
  /// 超过 7 天就在设置页提醒「可能已过期，建议重新登录」，而不是当成事实。
  bool get isStale => age.inDays >= 7;

  /// 设置页展示用的脱敏摘要：只给长度与末 4 位，绝不回显完整值。
  String get maskedSummary {
    String mask(String v) {
      if (v.isEmpty) return '(空)';
      if (v.length <= 4) return '****';
      return '****${v.substring(v.length - 4)}';
    }

    final who = (uname != null && uname!.isNotEmpty) ? uname! : 'uid $dedeUserId';
    return '$who · SESSDATA ${mask(sessData)} · bili_jct ${mask(biliJct)}';
  }

  // ---------------------------------------------------------------- 序列化

  /// 序列化后**只写入钥匙串**，不要写进 SharedPreferences 或文件。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'sessdata': sessData,
        'bili_jct': biliJct,
        'dede_user_id': dedeUserId,
        if (dedeUserIdCkMd5 != null) 'dede_user_id_ckmd5': dedeUserIdCkMd5,
        if (refreshToken != null) 'refresh_token': refreshToken,
        if (uname != null) 'uname': uname,
        if (mid != null) 'mid': mid,
        'obtained_at': obtainedAt.toUtc().toIso8601String(),
        'v': 1,
      };

  /// 反序列化：任何字段缺失/损坏都返回 `null`，由调用方当作「未登录」处理，
  /// 绝不让一份坏掉的凭据把 App 拖进崩溃。
  static BiliSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);

    String str(String key) => '${map[key] ?? ''}'.trim();

    final sess = str('sessdata');
    final jct = str('bili_jct');
    final uid = str('dede_user_id');
    if (sess.isEmpty || jct.isEmpty || uid.isEmpty) return null;

    final obtained = DateTime.tryParse(str('obtained_at')) ?? DateTime.now();
    final md5 = str('dede_user_id_ckmd5');
    final refresh = str('refresh_token');
    final uname = str('uname');

    return BiliSession(
      sessData: sess,
      biliJct: jct,
      dedeUserId: uid,
      obtainedAt: obtained,
      dedeUserIdCkMd5: md5.isEmpty ? null : md5,
      refreshToken: refresh.isEmpty ? null : refresh,
      uname: uname.isEmpty ? null : uname,
      mid: map['mid'] is num ? (map['mid'] as num).toInt() : null,
    );
  }

  BiliSession copyWith({String? uname, int? mid}) => BiliSession(
        sessData: sessData,
        biliJct: biliJct,
        dedeUserId: dedeUserId,
        obtainedAt: obtainedAt,
        dedeUserIdCkMd5: dedeUserIdCkMd5,
        refreshToken: refreshToken,
        uname: uname ?? this.uname,
        mid: mid ?? this.mid,
      );
}
