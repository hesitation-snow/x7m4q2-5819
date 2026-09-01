import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 当前设备的正文缓存。
///
/// 缓存存放在应用私有目录，仅保存已经成功取得阅读权限的章节正文。
/// 它不是安全存储，也不保存 security_key、cookie 或其他会话凭据。
class ReaderContentCache {
  static const _directoryName = 'reader_content_cache';
  static const _maxEntries = 50;
  static const _maxMemoryEntries = 12;
  static Future<Directory>? _directoryFuture;
  static int _writesSincePrune = 0;
  static int _generation = 0;
  static final LinkedHashMap<String, LKChapterDetail> _memory =
      LinkedHashMap<String, LKChapterDetail>();

  /// Changes whenever the user clears reader caches.
  static int get generation => _generation;

  /// UID 0 is the anonymous/public cache scope. Never share a logged-in
  /// account's chapter cache with that scope or with another UID.
  static String _memoryKey(int ownerUid, int bookId, int chapterId) =>
      '$ownerUid:$bookId:$chapterId';

  static void _remember(
      int ownerUid, int bookId, int chapterId, LKChapterDetail detail) {
    final key = _memoryKey(ownerUid, bookId, chapterId);
    _memory.remove(key);
    _memory[key] = detail;
    while (_memory.length > _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  static Future<Directory> _directory() =>
      _directoryFuture ??= _createDirectory();

  static Future<Directory> _createDirectory() async {
    final root = await getApplicationSupportDirectory();
    final dir =
        Directory('${root.path}${Platform.pathSeparator}$_directoryName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static File _file(Directory dir, int ownerUid, int chapterId) => File(
      '${dir.path}${Platform.pathSeparator}chapter_${ownerUid}_$chapterId.json');

  /// Read a cache entry within one account scope. UID 0 is anonymous/public.
  /// Invalid, mismatched, or locked preview entries are ignored.
  static Future<LKChapterDetail?> read(int bookId, int chapterId,
      {required int ownerUid}) async {
    if (ownerUid < 0 || bookId <= 0 || chapterId <= 0) return null;
    final generation = _generation;
    final key = _memoryKey(ownerUid, bookId, chapterId);
    final memory = _memory.remove(key);
    if (memory != null) {
      _memory[key] = memory;
      return memory;
    }
    try {
      final file = _file(await _directory(), ownerUid, chapterId);
      if (generation != _generation) return null;
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (generation != _generation ||
          decoded is! Map<String, dynamic> ||
          decoded['owner_uid'] != ownerUid ||
          decoded['book_id'] != bookId) {
        return null;
      }
      final raw = decoded['detail'];
      if (raw is! Map<String, dynamic>) return null;
      final detail = LKChapterDetail.fromCacheJson(raw);
      if (detail.chapterId != chapterId ||
          (detail.locked && !detail.unlocked)) {
        return null;
      }
      if (generation != _generation) return null;
      // 访问时更新时间,让清理策略保留最近阅读的正文。
      unawaited(file.setLastModified(DateTime.now()).catchError((_) => file));
      _remember(ownerUid, bookId, chapterId, detail);
      return detail;
    } catch (_) {
      return null;
    }
  }

  /// Validate the cached entry before skipping a prefetch. A truncated file or
  /// a mismatched book id must not permanently block a fresh network copy.
  static Future<bool> contains(int bookId, int chapterId,
      {required int ownerUid}) async {
    if (ownerUid < 0 || bookId <= 0 || chapterId <= 0) return false;
    if (_memory.containsKey(_memoryKey(ownerUid, bookId, chapterId))) {
      return true;
    }
    return await read(bookId, chapterId, ownerUid: ownerUid) != null;
  }

  /// 只缓存公开内容或已经解锁的付费章节,避免把未授权试读内容持久化。
  static Future<void> write(int bookId, LKChapterDetail detail,
      {required int ownerUid, int? expectedGeneration}) async {
    if (ownerUid < 0 || bookId <= 0 || detail.chapterId <= 0) return;
    final generation = expectedGeneration ?? _generation;
    if (generation != _generation) return;
    try {
      if (detail.locked && !detail.unlocked) {
        _memory.remove(_memoryKey(ownerUid, bookId, detail.chapterId));
        final file = _file(await _directory(), ownerUid, detail.chapterId);
        if (generation != _generation) return;
        if (await file.exists()) await file.delete();
        return;
      }
      // 空响应可能只是服务端暂时没有返回正文,不覆盖已有有效缓存。
      if (detail.bodyText.isEmpty &&
          (detail.bodyHtml == null || detail.bodyHtml!.isEmpty)) {
        return;
      }
      if (generation != _generation) return;
      _remember(ownerUid, bookId, detail.chapterId, detail);
      final file = _file(await _directory(), ownerUid, detail.chapterId);
      if (generation != _generation) return;
      await file.writeAsString(
        jsonEncode({
          'version': 2,
          'owner_uid': ownerUid,
          'book_id': bookId,
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'detail': detail.toCacheJson(),
        }),
      );
      _writesSincePrune++;
      if (_writesSincePrune >= 5) {
        _writesSincePrune = 0;
        unawaited(_pruneSafely(file.parent));
      }
    } catch (_) {
      // 缓存失败不应影响正常在线阅读。
    }
  }

  static Future<int> count() async {
    try {
      final dir = await _directory();
      return (await dir
              .list()
              .where((e) => e is File && e.path.endsWith('.json'))
              .toList())
          .length;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> sizeBytes() async {
    try {
      final dir = await _directory();
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clear() async {
    _memory.clear();
    _generation++;
    try {
      _directoryFuture = null;
      _writesSincePrune = 0;
      final root = await getApplicationSupportDirectory();
      final dir =
          Directory('${root.path}${Platform.pathSeparator}$_directoryName');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响其他设置和阅读功能。
    }
  }

  static Future<void> _prune(Directory dir) async {
    final files = (await dir
            .list()
            .where((e) => e is File && e.path.endsWith('.json'))
            .toList())
        .whereType<File>()
        .toList();
    if (files.length <= _maxEntries) return;
    final entries = <(File, DateTime)>[];
    for (final file in files) {
      try {
        entries.add((file, await file.lastModified()));
      } catch (_) {}
    }
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    for (final entry in entries.take(entries.length - _maxEntries)) {
      try {
        await entry.$1.delete();
      } catch (_) {}
    }
  }

  static Future<void> _pruneSafely(Directory dir) async {
    try {
      await _prune(dir);
    } catch (_) {
      // 后台清理失败不影响正文缓存与阅读。
    }
  }
}
