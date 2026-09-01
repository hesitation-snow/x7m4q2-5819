import '../api/lk_api.dart';
import '../api/models.dart';

/// 进程内共享的站点表情目录，避免动态、评论和发布页重复请求同一接口。
class YomiruEmojiCatalog {
  YomiruEmojiCatalog._();

  static List<LKEmojiGroup> _groups = const [];
  static Map<String, String> _urls = const {};
  static Future<List<LKEmojiGroup>>? _loading;

  static List<LKEmojiGroup> get groups => _groups;
  static Map<String, String> get urls => _urls;

  static String normalizeUrl(String url) =>
      url.replaceFirst('api.lightnovel.fun/static/', 'static.lightnovel.fun/');

  static Future<List<LKEmojiGroup>> load() {
    if (_groups.isNotEmpty) return Future.value(_groups);
    final running = _loading;
    if (running != null) return running;
    final request = _loadFromNetwork();
    _loading = request;
    return request.whenComplete(() {
      if (identical(_loading, request)) _loading = null;
    });
  }

  static Future<List<LKEmojiGroup>> _loadFromNetwork() async {
    final groups = await LKApi.commentEmojis();
    final urls = <String, String>{};
    for (final group in groups) {
      for (final item in group.items) {
        if (item.isImage && item.code.isNotEmpty) {
          urls[item.code] = normalizeUrl(item.url);
        }
      }
    }
    _groups = List<LKEmojiGroup>.unmodifiable(groups);
    _urls = Map<String, String>.unmodifiable(urls);
    return _groups;
  }
}
