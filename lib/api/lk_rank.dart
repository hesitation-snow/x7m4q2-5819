/// 轻之国度（LK）身份组与升级积分（经验）阶梯。
class LKRankTier {
  final String name;
  final int minExp;

  const LKRankTier({
    required this.name,
    required this.minExp,
  });
}

/// 官方身份组升级所需最低积分表（按从低到高排序）。
const List<LKRankTier> kLKRankTiers = [
  LKRankTier(name: '平民', minExp: 0),
  LKRankTier(name: '骑士', minExp: 251),
  LKRankTier(name: '勋爵', minExp: 1001),
  LKRankTier(name: '子爵', minExp: 2001),
  LKRankTier(name: '伯爵', minExp: 4501),
  LKRankTier(name: '侯爵', minExp: 8001),
  LKRankTier(name: '公爵', minExp: 12501),
  LKRankTier(name: '王爵', minExp: 18001),
  LKRankTier(name: '皇帝', minExp: 50001),
];

class LKRankProgress {
  final int exp;
  final LKRankTier current;
  final LKRankTier? next;

  const LKRankProgress({
    required this.exp,
    required this.current,
    required this.next,
  });

  bool get isMaxRank => next == null;

  int get remainingToNext =>
      next == null ? 0 : (next!.minExp - exp).clamp(0, next!.minExp);

  double get progress {
    final target = next;
    if (target == null) return 1.0;
    final span = target.minExp - current.minExp;
    if (span <= 0) return 1.0;
    return ((exp - current.minExp) / span).clamp(0.0, 1.0);
  }

  /// 例如 `0/251`，满级时显示 `50001`。
  String get ratioText => next == null ? '$exp' : '$exp/${next!.minExp}';

  String get nextHintText => next == null
      ? '已达最高身份组 · ${current.name}'
      : '距${next!.name}还差 ${formatLKExpNumber(remainingToNext)} 积分';
}

LKRankProgress lkRankProgressForExp(int exp) {
  final safeExp = exp < 0 ? 0 : exp;
  var currentIndex = 0;
  for (var i = 0; i < kLKRankTiers.length; i++) {
    if (safeExp >= kLKRankTiers[i].minExp) {
      currentIndex = i;
    } else {
      break;
    }
  }
  final current = kLKRankTiers[currentIndex];
  final next = currentIndex + 1 < kLKRankTiers.length
      ? kLKRankTiers[currentIndex + 1]
      : null;
  return LKRankProgress(exp: safeExp, current: current, next: next);
}

/// 将整数格式化为千分位字符串（如 `12501` -> `12,501`）。
String formatLKExpNumber(int value) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buf.write(',');
    }
    buf.write(digits[i]);
  }
  return negative ? '-$buf' : '$buf';
}
