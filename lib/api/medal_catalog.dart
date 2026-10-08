import 'dart:convert';

/// Opt-in local build; normal builds retain the official first-page view.
const allMedalsBuild = bool.fromEnvironment('YOMIRU_ALL_MEDALS');

typedef MedalPageLoader = Future<Map<String, dynamic>> Function(int page);

int? _number(dynamic value) => int.tryParse('$value');

Map? _pageInfo(dynamic value) {
  if (value is! Map) return null;
  for (final key in ['page_info', 'pagination']) {
    if (value[key] is Map) return value[key] as Map;
  }
  for (final child in value.values) {
    final found = _pageInfo(child);
    if (found != null) return found;
  }
  return null;
}

String _identity(dynamic value) {
  if (value is Map) {
    for (final key in ['goods_id', 'task_id', 'medal_id', 'id']) {
      if ((_number(value[key]) ?? 0) > 0) return '$key:${value[key]}';
    }
    // Some responses group medals by title instead of assigning a group ID.
    if (value.values.any((child) => child is List)) {
      for (final key in ['title', 'name', 'group_name']) {
        if (value[key] != null) return 'group:$key:${value[key]}';
      }
    }
  }
  return jsonEncode(value);
}

dynamic _merge(dynamic first, dynamic next) {
  if (first is List && next is List) {
    final result = List<dynamic>.of(first);
    final indices = <String, int>{
      for (var i = 0; i < result.length; i++) _identity(result[i]): i,
    };
    for (final item in next) {
      final key = _identity(item);
      final index = indices[key];
      if (index == null) {
        indices[key] = result.length;
        result.add(item);
      } else {
        result[index] = _merge(result[index], item);
      }
    }
    return result;
  }
  if (first is Map && next is Map) {
    final result = Map<String, dynamic>.from(first);
    for (final entry in next.entries) {
      final key = entry.key.toString();
      // Preserve the first response's account state and pagination metadata.
      if (key == 'page_info' || key == 'pagination') continue;
      result[key] = result.containsKey(key)
          ? _merge(result[key], entry.value)
          : entry.value;
    }
    return result;
  }
  return first;
}

/// Read every server-returned page, without filtering test/unavailable medals.
/// Failed pages fail the load rather than misrepresenting a partial catalogue.
Future<Map<String, dynamic>> loadAllMedalPages(MedalPageLoader load) async {
  var result = await load(0);
  var latest = result;
  var requestedPage = 0;
  final firstInfo = _pageInfo(result);
  final firstCursor = _number(firstInfo?['cur'] ?? firstInfo?['page']);
  final zeroBased = firstCursor == 0;
  final seen = <String>{};
  for (var reads = 1; reads <= 200; reads++) {
    final info = _pageInfo(latest);
    if (info == null) return result;
    final count =
        _number(info['count'] ?? info['total'] ?? info['total_count']);
    final size = _number(info['size'] ?? info['pageSize'] ?? info['page_size']);
    final current = _number(info['cur'] ?? info['page']) ?? requestedPage;
    final hasNext = info['has_next'] ?? info['has_more'];
    if (hasNext == false || hasNext == 0 || hasNext == '0') return result;
    // Most endpoints normalize page=0 to page 1. Honour the returned cursor.
    final pages = count != null && size != null && size > 0
        ? (count / size).ceil()
        : null;
    if (pages != null && current >= pages - (zeroBased ? 1 : 0)) return result;
    if (pages == null && hasNext != true && hasNext != 1 && hasNext != '1') {
      throw StateError('勋章分页信息不完整，无法确认已加载全部条目');
    }
    if (reads == 200) throw StateError('勋章分页超过安全上限，未加载完整');
    requestedPage = current + 1;
    if (!seen.add('$current:${jsonEncode(latest)}')) {
      throw StateError('勋章接口重复返回同一页，未加载完整');
    }
    final next = await load(requestedPage);
    final merged = Map<String, dynamic>.from(_merge(result, next) as Map);
    if (jsonEncode(merged) == jsonEncode(result)) {
      throw StateError('勋章后续分页未返回新条目，未加载完整');
    }
    result = merged;
    latest = next;
  }
  return result;
}
