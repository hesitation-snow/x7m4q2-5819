/// Read-only interpretation of treasure responses. This is not a completion
/// reporter: the activity attribution protocol is not documented in this repo.
class TreasureTask {
  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static dynamic _field(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (map[key] != null) return map[key];
    }
    return null;
  }

  static int _int(dynamic value) => int.tryParse('$value') ?? 0;

  /// Only unwrap known containers; never search another box's nested metadata.
  static Map<String, dynamic> detail(Map<String, dynamic> response) {
    if (_field(response, ['boxes', 'box_list', 'list']) is List) {
      return response;
    }
    for (final key in ['detail', 'treasure_box', 'data']) {
      final nested = _map(response[key]);
      if (nested.isNotEmpty) {
        final found = detail(nested);
        if (found.isNotEmpty) return found;
      }
    }
    return <String, dynamic>{};
  }

  /// A prerequisite flag alone does not confirm time/unlock/reward eligibility.
  static bool isClaimable(Map<String, dynamic> box) {
    final status =
        '${_field(box, ['status', 'box_status']) ?? ''}'.toLowerCase();
    final action =
        '${_field(box, ['button_action', 'buttonAction']) ?? ''}'.toLowerCase();
    return status == 'claimable' || (status.isEmpty && action == 'claim');
  }

  /// Explicit server type wins over ambiguous display text.
  static String prerequisite(Map<String, dynamic> box) {
    final type =
        '${_field(box, ['prerequisite_type', 'prerequisiteType']) ?? ''}'
            .toLowerCase();
    if (type.isNotEmpty) return type;
    final text =
        '${_field(box, ['prerequisite_text', 'prerequisiteText']) ?? ''}';
    if (text.contains('收藏') || text.contains('书架')) return 'collect_book';
    if (text.contains('浏览') || text.contains('阅读')) return 'read_book';
    if (text.contains('广告')) return 'watch_ad';
    return '';
  }

  /// Keep chapter and volume tied to the same book. Incomplete targets should
  /// open book detail, where the real catalogue determines a valid chapter.
  static ({int bookId, int volumeId, int chapterId, String title}) target(
      Map<String, dynamic> box) {
    final reader = _map(_field(box, ['reader_target', 'readerTarget']));
    final book = _map(_field(box, ['target_book', 'targetBook']));
    final readerId = _int(_field(reader, ['book_id', 'bookId']));
    final chosen = readerId > 0 ? reader : book;
    return (
      bookId: _int(_field(chosen, ['book_id', 'bookId'])),
      volumeId:
          readerId > 0 ? _int(_field(reader, ['volume_id', 'volumeId'])) : 0,
      chapterId:
          readerId > 0 ? _int(_field(reader, ['chapter_id', 'chapterId'])) : 0,
      title: '${chosen['title'] ?? ''}',
    );
  }

  /// Local route provenance only. Do not invent task/source fields on API calls.
  static Map<String, dynamic> routeContext(
      Map<String, dynamic> response, Map<String, dynamic> box, int boxIndex) {
    final result = <String, dynamic>{'task_id': 300007, 'box_index': boxIndex};
    for (final key in ['task_key', 'source']) {
      final value = box[key] ?? response[key];
      if (value != null) result[key] = value;
    }
    return result;
  }
}
