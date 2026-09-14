import 'package:shared_preferences/shared_preferences.dart';

/// 服务端领取状态短暂延迟时的本地补充，不跨账号或跨日期沿用。
class DailyTaskClaims {
  DailyTaskClaims({required this.uid, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final int Function() uid;
  final DateTime Function() _now;
  final Set<String> _keys = {};
  String? _loadedKey;

  String get storageKey {
    final date = _now();
    final day = '${date.year.toString().padLeft(4, '0')}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}';
    final id = uid();
    return 'welfare_daily_claimed_v1_${id > 0 ? id : 'guest'}_$day';
  }

  void _select(String key) {
    if (_loadedKey == key) return;
    _loadedKey = key;
    _keys.clear();
  }

  bool contains(String signature) {
    _select(storageKey);
    return _keys.contains(signature);
  }

  Future<void> load() async {
    final key = storageKey;
    _select(key);
    final prefs = await SharedPreferences.getInstance();
    if (key != storageKey) return;
    _select(key);
    _keys.addAll(prefs.getStringList(key) ?? const []);
  }

  Future<void> record(Iterable<String> signatures,
      {required String expectedKey}) async {
    // 领取请求期间跨天或切换账号，交给新一轮服务端状态确认。
    if (expectedKey != storageKey) return;
    _select(expectedKey);
    _keys.addAll(signatures);
    final prefs = await SharedPreferences.getInstance();
    if (expectedKey != storageKey) return;
    await prefs.setStringList(
        expectedKey,
        {
          ...?prefs.getStringList(expectedKey),
          ..._keys,
        }.toList());
  }
}
