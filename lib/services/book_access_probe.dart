import '../api/lk_api.dart';
import '../api/store.dart';
import 'background_work_queue.dart';

/// 仅为缺失权限标记的公开书籍补充展示信息，不作为访问权限校验。
class BookAccessProbe {
  BookAccessProbe({required this.query, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static final shared = BookAccessProbe(query: (id, isCurrent) async {
    if (LKStore.isBraveBook(id)) return true;
    final volumes = await LKApi.volumes(id, 1, pageSize: 1);
    if (!isCurrent()) return null;
    if (volumes.isEmpty) return false;
    final page =
        await LKApi.chapterPage(id, volumes.first.volumeId, 1, pageSize: 5);
    if (!isCurrent()) return null;
    final brave = page.items.any((chapter) => chapter.braveOnly);
    if (brave) await LKStore.markBookBrave(id);
    return brave;
  });

  final Future<bool?> Function(int, bool Function()) query;
  final DateTime Function() _now;
  final _queue = BackgroundWorkQueue(concurrency: 2);
  final _checked = <int, (bool, DateTime)>{};
  final _pending = <int, Future<bool?>>{};
  final _listeners = <int, Set<bool Function()>>{};

  Future<bool?> lookup(int id, {required bool Function() isCurrent}) async {
    if (!isCurrent()) return null;
    final checked = _checked[id];
    // 抽样未见勇者章节不等于全书公开，因此短暂复用而不持久化“非勇者”。
    if (checked != null &&
        _now().difference(checked.$2) < const Duration(minutes: 5)) {
      return checked.$1;
    }
    final listeners = _listeners.putIfAbsent(id, () => {});
    listeners.add(isCurrent);
    bool wanted() => listeners.any((listener) => listener());
    final request = _pending.putIfAbsent(
        id,
        () => _queue.run<bool?>(
              () => query(id, wanted),
              isCurrent: wanted,
            ));
    try {
      final result = await request;
      if (result != null && wanted()) {
        if (_checked.length >= 256) _checked.remove(_checked.keys.first);
        _checked[id] = (result, _now());
      }
      return result;
    } catch (_) {
      return null;
    } finally {
      listeners.remove(isCurrent);
      if (identical(_pending[id], request)) {
        _pending.remove(id);
        _listeners.remove(id);
      }
    }
  }
}
