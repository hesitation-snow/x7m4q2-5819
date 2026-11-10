import 'home_channels.dart';
import 'lk_api.dart';
import 'models.dart';

/// EPUB 作品不在普通搜索的 `work_type=epub` 结果里。那条过滤会把目录中的书排除掉，
/// 关键词因此总是空的。目录以首页 EPUB 信息流为准，翻页缓存在本次进程里。
class EpubCatalog {
  static const _pageSize = 50;
  static const _maxPages = 80;
  static final List<LKBook> books = [];
  static final Set<int> _seen = {};
  static var _nextPage = 1;
  static var done = false;
  static Future<void> _gate = Future<void>.value();

  static void reset() {
    books.clear();
    _seen.clear();
    _nextPage = 1;
    done = false;
    _gate = Future<void>.value();
  }

  /// 继续向后翻，直到至少有 [needed] 本符合 [match]，或目录翻完。
  static Future<void> collect(
    int needed,
    bool Function(LKBook book) match,
  ) {
    final run = _gate.then((_) => _collect(needed, match));
    _gate = run.catchError((Object _) {});
    return run;
  }

  static Future<void> _collect(
    int needed,
    bool Function(LKBook book) match,
  ) async {
    while (!done && books.where(match).length < needed) {
      if (_nextPage > _maxPages) {
        done = true;
        return;
      }
      final page = _nextPage;
      _nextPage++;
      final items = await LKApi.channelFeed(
        homeChannelByCode('epub').path,
        page,
        pageSize: _pageSize,
      );
      if (items.isEmpty) {
        done = true;
        return;
      }
      var fresh = 0;
      for (final book in items) {
        if (book.bookId > 0 && _seen.add(book.bookId)) {
          books.add(book);
          fresh++;
        }
      }
      if (fresh == 0 || items.length < _pageSize) done = true;
    }
  }
}

bool epubBookMatches(LKBook book, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  bool contains(String value) => value.toLowerCase().contains(needle);
  return contains(book.title) ||
      contains(book.authorName) ||
      book.tags.any(contains);
}
