import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';

/// Fallback for successful actions when a feed has no viewer-specific state.
/// Keys are scoped to a positive account UID; no credential is stored.
class DynamicLikeState {
  static String _prefix(int uid) => 'dynamic_like_v1_${uid}_';

  static Future<Map<int, bool>> load(int uid) async {
    if (uid <= 0) return {};
    final prefs = await SharedPreferences.getInstance();
    final prefix = _prefix(uid);
    final result = <int, bool>{};
    for (final key in prefs.getKeys().where((key) => key.startsWith(prefix))) {
      final id = int.tryParse(key.substring(prefix.length));
      final value = prefs.getBool(key);
      if (id != null && id > 0 && value != null) result[id] = value;
    }
    return result;
  }

  static Future<void> save(int uid, int id, bool liked) async {
    if (uid <= 0 || id <= 0) return;
    await (await SharedPreferences.getInstance())
        .setBool('${_prefix(uid)}$id', liked);
  }

  static bool resolve(LKDynamicItem item, Map<int, bool> fallback,
      {required bool authenticated}) {
    if (authenticated && item.hasLikedState) return item.liked;
    return fallback[item.dynamicId] ?? (authenticated ? item.liked : false);
  }
}
