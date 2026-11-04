/// 时间解析与展示。
///
/// RSS 的 `<pubDate>` 可能是 RFC822（`Wed, 02 Oct 2002 13:00:00 +0800`）、
/// RFC1123（`... GMT`）、ISO8601，甚至缺失。Dart 的 `HttpDate.parse` 只认
/// 严格 RFC1123，所以这里自己写一个宽容的 RFC822 解析器。
class TimeParse {
  TimeParse._();

  static const Map<String, int> _months = <String, int>{
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static final RegExp _rfc822Re = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{2,4})\s+'
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*'
    r'([+-]\d{4}|[A-Za-z]{1,5})?',
  );

  /// 解析 RSS/Atom 的时间字符串，失败返回 null（调用方回落到 fetchedAt）。
  static DateTime? parseRss(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;

    // 1) 纯数字时间戳必须**最先**判断。
    //
    // 实测坑：Dart 的 `DateTime.tryParse('1700000000')` 并不返回 null，而是
    // 把它当作 `yyyyMMdd` 之类的格式，解析出一个荒唐的日期（2138 年），
    // 于是「有发布时间」变成「时间完全错乱」。所以不能让它先跑。
    final asInt = int.tryParse(s);
    if (asInt != null) {
      if (asInt > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true);
      }
      if (asInt > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(asInt * 1000, isUtc: true);
      }
      return null; // 太小的整数不可能是合理的时间戳
    }

    // 2) ISO8601 / "2024-01-01 12:00:00"
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso.toUtc();

    // 3) RFC822 / RFC1123
    return _parseRfc822(s);
  }

  static DateTime? _parseRfc822(String s) {
    final m = _rfc822Re.firstMatch(s);
    if (m == null) return null;
    try {
      final day = int.parse(m.group(1)!);
      final month = _months[m.group(2)!.toLowerCase()];
      if (month == null) return null;
      var year = int.parse(m.group(3)!);
      if (year < 100) year += year < 70 ? 2000 : 1900;
      final hour = int.parse(m.group(4)!);
      final minute = int.parse(m.group(5)!);
      final second = m.group(6) == null ? 0 : int.parse(m.group(6)!);

      var offsetMinutes = 0;
      final tz = m.group(7);
      if (tz != null) {
        if (tz.startsWith('+') || tz.startsWith('-')) {
          final sign = tz.startsWith('-') ? -1 : 1;
          final h = int.tryParse(tz.substring(1, 3)) ?? 0;
          final mm = int.tryParse(tz.substring(3, 5)) ?? 0;
          offsetMinutes = sign * (h * 60 + mm);
        } else {
          // GMT / UTC / Z 视为 0；其他缩写（CST、EST…）无法可靠映射，按 0 处理。
          offsetMinutes = 0;
        }
      }

      final asIfUtc = DateTime.utc(year, month, day, hour, minute, second);
      return asIfUtc.subtract(Duration(minutes: offsetMinutes));
    } catch (_) {
      return null;
    }
  }

  /// 相对时间展示（时间线用）。
  ///
  /// 粒度约定（需求 2026-10-26）：
  /// - 1 小时内 → `N 分钟前`；
  /// - 1 天内   → `N 小时前`；
  /// - 30 天内  → `N 天前 HH:mm`（**带具体时分**，否则「3 天前」太粗，
  ///   同一张卡在当天不同时间刷新会让人以为是不同内容）；
  /// - 更早     → `MM-DD HH:mm`（跨年再加年份）。
  ///
  /// 为什么「分钟/小时前」不追加时分：那两个粒度本身已经比时分更精确，
  /// 再拼一个 14:03 反而自相矛盾（「5 分钟前 14:03」）。
  static String humanize(DateTime? dt, {DateTime? now}) {
    if (dt == null) return '时间未知';
    final ref = (now ?? DateTime.now()).toUtc();
    final local = dt.toUtc();
    final diff = ref.difference(local);
    if (diff.isNegative) return '刚刚';
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';

    final y = local.toLocal();
    final hh = y.hour.toString().padLeft(2, '0');
    final mi = y.minute.toString().padLeft(2, '0');
    final clock = '$hh:$mi';

    if (diff.inDays < 30) return '${diff.inDays} 天前 $clock';

    final mm = y.month.toString().padLeft(2, '0');
    final dd = y.day.toString().padLeft(2, '0');
    if (y.year == ref.toLocal().year) return '$mm-$dd $clock';
    return '${y.year}-$mm-$dd $clock';
  }

  /// 绝对时间（详情页用）。
  static String absolute(DateTime? dt) {
    if (dt == null) return '时间未知';
    final l = dt.toLocal();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}';
  }

  /// 微博 `mblog.created_at`：`Mon Aug 07 20:15:27 +0800 2023`。
  ///
  /// ## 为什么不能直接复用 [parseRss]
  ///
  /// 微博给的时间格式与 RFC822 **长得像但不是**，两个关键差异让它必然失败：
  ///
  /// 1. **年份在最后**：`… +0800 2023`。RFC822 是 `Mon, 07 Aug 2023 20:15:27 +0800`，
  ///    年份在时间**前面**。[_rfc822Re] 的 `(\d{2,4})` 在月份后面，匹配到的是
  ///    `07`（当日期），后面的 `+0800` 位置又对不上 `(\d{2,4})`，于是 `20:15:27`
  ///    被当成时分，年份彻底丢失。
  /// 2. **没有逗号**，星期与日期之间是空格。这条反而不致命（正则没写死逗号）。
  ///
  /// 所以这里单写一个解析器，**不改 [parseRss]**：RSS 的兼容路径上跑着既有
  /// 493 个单测，动它是纯风险。
  ///
  /// ## 容错
  ///
  /// - 月份是英文缩写（`Jan`…`Dec`），大小写不敏感，取前三位；
  /// - `+0800` / `-0430` 都支持，会换算成 UTC（返回值统一是 UTC）；
  /// - 星期几不参与计算（`EEE` 只是展示用，可能与日期不一致，信日期）；
  /// - 秒可选（个别来源省略）；
  /// - 解析不出来返回 null —— 调用方必须把 `hasReliableTime` 置 false，
  ///   **绝不拿 fetchedAt 伪造一个发布时间**。
  static DateTime? parseWeibo(String? raw) {
    if (raw == null) return null;
    final String s = raw.trim();
    if (s.isEmpty) return null;
    final RegExpMatch? m = _weiboRe.firstMatch(s);
    if (m == null) return null;
    try {
      final int? month = _months[m.group(1)!.toLowerCase()];
      if (month == null) return null;
      final int day = int.parse(m.group(2)!);
      final int hour = int.parse(m.group(3)!);
      final int minute = int.parse(m.group(4)!);
      final int second = m.group(5) == null ? 0 : int.parse(m.group(5)!);
      final String tz = m.group(6)!;
      final int year = int.parse(m.group(7)!);

      // 越界值不交给 DateTime 去「自动进位」：DateTime.utc(2023, 8, 32) 会
      // 静默变成 9 月 1 日，那等于伪造时间。宁可返回 null。
      if (day < 1 || day > 31) return null;
      if (hour > 23 || minute > 59 || second > 60) return null;

      final int sign = tz.startsWith('-') ? -1 : 1;
      final int offH = int.tryParse(tz.substring(1, 3)) ?? 0;
      final int offM = int.tryParse(tz.substring(3, 5)) ?? 0;
      final int offsetMinutes = sign * (offH * 60 + offM);

      // 先按「墙上时间」当 UTC 建点，再减去时区偏移得到真正的 UTC。
      // 例：`… 20:15:27 +0800` → UTC 12:15:27。
      final DateTime asIfUtc =
          DateTime.utc(year, month, day, hour, minute, second);
      // 日期越界（如 2 月 30 日）会被 DateTime 进位，这里回查一次。
      if (asIfUtc.month != month || asIfUtc.day != day) return null;
      return asIfUtc.subtract(Duration(minutes: offsetMinutes));
    } catch (_) {
      return null;
    }
  }

  /// `EEE MMM dd HH:mm:ss ZZZZ yyyy` —— 注意 **年份在最后**。
  ///
  /// 分组：1=月 2=日 3=时 4=分 5=秒(可选) 6=时区 7=年。
  /// 星期只占位不捕获（`EEE` 可能与日期不一致，信日期）。
  static final RegExp _weiboRe = RegExp(
    r'^[A-Za-z]{3,9},?\s+([A-Za-z]{3})[a-z]*\s+(\d{1,2})\s+'
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s+'
    r'([+-]\d{4})\s+(\d{4})$',
  );
}
