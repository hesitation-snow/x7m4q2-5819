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

/// Appending a page also replaces overlapping items with their newest values.
/// Always returns a growable list, even when either input is fixed-length.
List<T> mergePagedItems<T>(Iterable<T> previous, Iterable<T> incoming,
    {required Object Function(T item) keyOf}) {
  final items = <Object, T>{};
  for (final item in previous) {
    items[keyOf(item)] = item;
  }
  for (final item in incoming) {
    items[keyOf(item)] = item;
  }
  return items.values.toList();
}

class LoadedPage<T> {
  final List<T> items;
  final int page;
  final bool hasMore;
  final String cursor;

  const LoadedPage({
    required this.items,
    required this.page,
    required this.hasMore,
    this.cursor = '',
  });
}

/// Refreshes the visible cached window before replacing it. Previous cached
/// items are never mixed into the authoritative result, so deleted items cannot
/// reappear. Callers keep their old snapshot when any requested page fails.
Future<LoadedPage<T>> refreshPageWindow<T>({
  required Future<LoadedPage<T>> Function(int page, String cursor) loadPage,
  required Object Function(T item) keyOf,
  int targetItems = 0,
  int maxPages = 5,
  bool Function()? isCurrent,
}) async {
  if (maxPages < 1) throw ArgumentError.value(maxPages, 'maxPages');
  var items = <T>[];
  var cursor = '';
  for (var page = 1; page <= maxPages; page++) {
    final result = await loadPage(page, cursor);
    final previousCount = items.length;
    items = mergePagedItems(items, result.items, keyOf: keyOf);
    final repeatedPage =
        page > 1 && items.length == previousCount && result.cursor == cursor;
    final hasMore = result.hasMore && !repeatedPage;
    cursor = result.cursor;
    if (!hasMore ||
        items.length >= targetItems ||
        page == maxPages ||
        isCurrent?.call() == false) {
      return LoadedPage(
          items: items, page: page, hasMore: hasMore, cursor: cursor);
    }
  }
  throw StateError('A refresh must load at least one page');
}
