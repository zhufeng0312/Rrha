/// B 站用户（UP 主）。
///
/// 有两个来源，JSON 形态**不同**，所以给两个工厂而不是硬塞一个：
/// - `/x/relation/followings` 的列表项（关注列表，字段扁平：`uname` / `face` / `fans`）；
/// - `/x/space/wbi/acc/info` 的 `data`（用户主页，字段更全且名字不同：`name` / `face`）。
class BiliUser {
  const BiliUser({
    required this.mid,
    required this.uname,
    this.face,
    this.sign,
    this.fans = 0,
    this.officialTitle,
    this.vipType = 0,
  });

  /// 账号 mid（B 站的用户唯一 id）。
  final int mid;

  final String uname;

  /// 头像地址（**已规范化**，见 [avatarUrl]）。
  final String? face;

  final String? sign;

  final int fans;

  /// 认证文案（如「bilibili 知名UP主」）；空表示未认证。
  final String? officialTitle;

  /// 0 = 非大会员。
  final int vipType;

  String get uid => '$mid';

  String get displayName {
    final n = uname.trim();
    return n.isEmpty ? 'UP $mid' : n;
  }

  bool get isVerified => (officialTitle ?? '').trim().isNotEmpty;

  bool get isVip => vipType > 0;

  /// 补全协议并转 https。
  ///
  /// B 站返回的头像经常是协议相对地址（`//i2.hdslb.com/bfs/face/x.jpg`）或
  /// 明文 http，直接塞给 `Image.network` 在部分机型上会解析失败。
  String? get avatarUrl => normalizeImageUrl(face);

  // ---------------------------------------------------------------- 工厂

  /// 关注列表项（`/x/relation/followings` → `data.list[]`）。
  static BiliUser? fromFollowingJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final mid = _asInt(map['mid']);
    if (mid == null || mid <= 0) return null;

    final official = map['official_verify'];
    final vip = map['vip'];

    return BiliUser(
      mid: mid,
      uname: '${map['uname'] ?? ''}',
      face: _asString(map['face']),
      sign: _asString(map['sign']),
      fans: _asInt(map['fans']) ?? 0,
      officialTitle: official is Map
          ? _asString(Map<String, dynamic>.from(official)['desc'])
          : null,
      vipType: vip is Map
          ? (_asInt(Map<String, dynamic>.from(vip)['vipType']) ?? 0)
          : (_asInt(map['vipType']) ?? 0),
    );
  }

  /// 用户主页（`/x/space/wbi/acc/info` → `data`）。
  ///
  /// 注意这里昵称字段叫 `name` 而不是 `uname` —— 抄错会得到一屏「UP 0」。
  static BiliUser? fromSpaceInfoJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final mid = _asInt(map['mid']);
    if (mid == null || mid <= 0) return null;

    final official = map['official'];
    final vip = map['vip'];

    return BiliUser(
      mid: mid,
      uname: '${map['name'] ?? map['uname'] ?? ''}',
      face: _asString(map['face']),
      sign: _asString(map['sign']),
      fans: _asInt(map['fans']) ?? 0,
      officialTitle: official is Map
          ? _asString(Map<String, dynamic>.from(official)['title'])
          : null,
      vipType: vip is Map
          ? (_asInt(Map<String, dynamic>.from(vip)['type']) ?? 0)
          : 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mid': mid,
        'uname': uname,
        'face': face,
        'sign': sign,
        'fans': fans,
        'officialTitle': officialTitle,
        'vipType': vipType,
      };

  static BiliUser? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final mid = _asInt(map['mid']);
    if (mid == null || mid <= 0) return null;
    return BiliUser(
      mid: mid,
      uname: '${map['uname'] ?? ''}',
      face: _asString(map['face']),
      sign: _asString(map['sign']),
      fans: _asInt(map['fans']) ?? 0,
      officialTitle: _asString(map['officialTitle']),
      vipType: _asInt(map['vipType']) ?? 0,
    );
  }

  // ---------------------------------------------------------------- 工具

  /// 把 `//host/path`、`http://host/path` 统一成 `https://host/path`。
  ///
  /// 公开是为了可单测：图片地址错一个字符就是「封面全部加载失败」这种
  /// 看着像网络问题的表象。
  static String? normalizeImageUrl(String? raw) {
    final v = raw?.trim();
    if (v == null || v.isEmpty) return null;
    if (v.startsWith('//')) return 'https:$v';
    if (v.startsWith('http://')) return 'https://${v.substring(7)}';
    if (v.startsWith('https://')) return v;
    return v;
  }

  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String? _asString(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty ? null : s;
  }
}

/// 一页关注列表。
class BiliFollowingPage {
  const BiliFollowingPage({
    required this.users,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  final List<BiliUser> users;

  /// 关注总数（服务端给的 `data.total`）。
  final int total;

  final int page;
  final int pageSize;

  bool get isEmpty => users.isEmpty;

  /// 是否还有下一页。
  bool get hasMore => page * pageSize < total;

  static const BiliFollowingPage empty = BiliFollowingPage(
    users: <BiliUser>[],
    total: 0,
    page: 1,
    pageSize: 0,
  );

  /// 从 `/x/relation/followings` 的完整响应体解析。
  static BiliFollowingPage fromJson(
    Map<String, dynamic> json, {
    required int requestedPage,
    required int requestedPageSize,
  }) {
    final data = json['data'];
    if (data is! Map) return empty;
    final map = Map<String, dynamic>.from(data);

    final rawList = map['list'];
    final users = <BiliUser>[];
    if (rawList is List) {
      for (final e in rawList) {
        final u = BiliUser.fromFollowingJson(e);
        if (u != null) users.add(u);
      }
    }

    final total = (map['total'] as num?)?.toInt() ?? users.length;
    return BiliFollowingPage(
      users: users,
      total: total,
      page: requestedPage,
      pageSize: requestedPageSize == 0 ? users.length : requestedPageSize,
    );
  }
}
