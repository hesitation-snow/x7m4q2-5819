/// Loads a paginated endpoint until its final page is reached.
///
/// Duplicate-only pages terminate the loop as a safeguard for endpoints that
/// accidentally repeat their final full page.
Future<List<T>> collectPaged<T>({
  required Future<List<T>> Function(int page, int pageSize) loadPage,
  required Object Function(T item) keyOf,
  int pageSize = 50,
  int maxPages = 200,
}) async {
  if (pageSize < 1) throw ArgumentError.value(pageSize, 'pageSize');
  if (maxPages < 1) throw ArgumentError.value(maxPages, 'maxPages');

  final items = <T>[];
  final keys = <Object>{};
  for (var page = 1; page <= maxPages; page++) {
    final batch = await loadPage(page, pageSize);
    var added = 0;
    for (final item in batch) {
      if (keys.add(keyOf(item))) {
        items.add(item);
        added++;
      }
    }
    if (batch.length < pageSize || added == 0) break;
  }
  return items;
}
