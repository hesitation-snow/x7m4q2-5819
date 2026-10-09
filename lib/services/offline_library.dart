import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/pagination.dart';

/// 主动下载与可淘汰的阅读缓存分开，正文仅保存在所属账号的目录中。
class OfflineLibrary extends ChangeNotifier {
  OfflineLibrary._() {
    LKClient.sessionRev.addListener(cancel);
  }
  static final shared = OfflineLibrary._();
  bool busy = false;
  int? activeBookId;
  String? error;
  int _serial = 0;
  int get ownerUid =>
      LKClient.shared.session.isLoggedIn ? LKClient.shared.session.uid : 0;
  String _key(int uid, int bookId) => 'offline_book_${uid}_$bookId';

  Future<File> _file(int uid, int bookId, int chapterId) async {
    if (uid < 0 || bookId <= 0 || chapterId <= 0) throw StateError('无效的离线书籍');
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/offline_library');
    await dir.create(recursive: true);
    return File('${dir.path}/${uid}_${bookId}_$chapterId.json');
  }

  Future<List<Map<String, dynamic>>> books() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = ownerUid;
    final result = <Map<String, dynamic>>[];
    for (final key in prefs
        .getKeys()
        .where((key) => key.startsWith('offline_book_${uid}_'))) {
      try {
        result.add(jsonDecode(prefs.getString(key)!) as Map<String, dynamic>);
      } catch (_) {}
    }
    result.removeWhere((b) =>
        b['book_id'] is! int ||
        b['title'] is! String ||
        b['chapters'] is! List ||
        !(b['chapters'] as List).every((c) =>
            c is Map<String, dynamic> &&
            c['id'] is int &&
            c['volume'] is int &&
            c['title'] is String &&
            c['status'] is String));
    result.sort(
        (a, b) => '${b['updated'] ?? ''}'.compareTo('${a['updated'] ?? ''}'));
    return result;
  }

  Future<LKChapterDetail?> read(int bookId, int chapterId,
      {required int ownerUid}) async {
    try {
      final file = await _file(ownerUid, bookId, chapterId);
      if (!await file.exists()) return null;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final detail = LKChapterDetail.fromCacheJson(data);
      if (detail.chapterId != chapterId ||
          (detail.locked && !detail.unlocked) ||
          (detail.bodyText.isEmpty && (detail.bodyHtml?.isEmpty ?? true))) {
        return null;
      }
      return detail;
    } catch (_) {
      return null;
    }
  }

  void cancel() {
    _serial++;
    error = null;
    notifyListeners();
  }

  Future<void> download(int bookId, String title, List<LKVolume> volumes,
      {List<int>? volumeOrder}) async {
    if (busy) throw StateError('请先暂停当前下载');
    final uid = ownerUid;
    if (uid < 0 || (LKClient.shared.session.isLoggedIn && uid == 0)) {
      throw StateError('请重新登录');
    }
    final revision = LKClient.sessionRev.value;
    final serial = ++_serial;
    bool current() =>
        serial == _serial &&
        uid == ownerUid &&
        revision == LKClient.sessionRev.value;
    busy = true;
    activeBookId = bookId;
    error = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(uid, bookId));
      final book = raw == null
          ? <String, dynamic>{
              'book_id': bookId,
              'title': title,
              'chapters': <dynamic>[]
            }
          : jsonDecode(raw) as Map<String, dynamic>;
      final chapters =
          (book['chapters'] as List).cast<Map<String, dynamic>>().toList();
      final order = volumeOrder ??
          (book['volume_order'] as List?)?.cast<int>() ??
          volumes.map((v) => v.volumeId).toList();
      book['volume_order'] = order;
      Future<void> persist() async {
        book['chapters'] = chapters;
        book['updated'] = DateTime.now().toUtc().toIso8601String();
        if (!await prefs.setString(_key(uid, bookId), jsonEncode(book))) {
          throw StateError('无法保存下载进度，请检查存储空间');
        }
        notifyListeners();
      }

      for (final volume in volumes) {
        final items = await collectPaged<LKChapter>(
            loadPage: (page, pageSize) async {
              if (!current()) return [];
              final batch = await LKApi.chapters(bookId, volume.volumeId, page,
                  pageSize: pageSize);
              return current() ? batch : [];
            },
            keyOf: (chapter) => chapter.chapterId);
        if (!current()) return;
        for (var chapterIndex = 0;
            chapterIndex < items.length;
            chapterIndex++) {
          final chapter = items[chapterIndex];
          if (chapter.chapterId <= 0 ||
              chapters.any((c) => c['id'] == chapter.chapterId)) {
            continue;
          }
          chapters.add({
            'id': chapter.chapterId,
            'volume': volume.volumeId,
            'title': chapter.title,
            'status': 'pending',
            'bytes': 0,
            'order': chapterIndex
          });
        }
        chapters.sort((a, b) {
          final volumeComparison =
              order.indexOf(a['volume']).compareTo(order.indexOf(b['volume']));
          return volumeComparison != 0
              ? volumeComparison
              : ((a['order'] as int?) ?? 0)
                  .compareTo((b['order'] as int?) ?? 0);
        });
        await persist();
      }
      // 已下载的章节不会重复请求；重试只处理未完成／失败的章节。
      for (final chapter in chapters) {
        if (!current()) return;
        if (chapter['status'] == 'ready' &&
            await read(bookId, chapter['id'] as int, ownerUid: uid) != null) {
          continue;
        }
        File? pendingFile;
        try {
          final detail =
              await LKApi.chapterDetail(bookId, chapter['id'] as int);
          if (!current()) return;
          if (detail.chapterId != chapter['id']) {
            throw StateError('服务器返回了不同章节，请重试');
          }
          if (detail.locked && !detail.unlocked) {
            throw StateError('章节尚未解锁，请先在线解锁');
          }
          if (detail.bodyText.isEmpty && (detail.bodyHtml?.isEmpty ?? true)) {
            throw StateError('正文为空');
          }
          final file = await _file(uid, bookId, detail.chapterId);
          if (!current()) return;
          final temp = File('${file.path}.tmp');
          pendingFile = temp;
          await temp.writeAsString(jsonEncode(detail.toCacheJson()),
              flush: true);
          if (!current()) {
            await temp.delete();
            return;
          }
          if (await file.exists()) await file.delete();
          await temp.rename(file.path);
          chapter['status'] = 'ready';
          chapter['bytes'] = await file.length();
          chapter.remove('error');
        } catch (e) {
          if (!current()) return;
          chapter['status'] = 'failed';
          chapter['error'] = e.toString();
        } finally {
          try {
            if (pendingFile != null && await pendingFile.exists()) {
              await pendingFile.delete();
            }
          } catch (_) {}
        }
        if (!current()) return;
        await persist();
      }
    } catch (e) {
      if (current()) error = e.toString();
    } finally {
      busy = false;
      activeBookId = null;
      notifyListeners();
    }
  }

  Future<void> remove(int bookId) async {
    if (busy) throw StateError('请先暂停下载，等待当前请求结束');
    final uid = ownerUid;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(uid, bookId));
    if (raw != null) {
      final book = jsonDecode(raw) as Map<String, dynamic>;
      for (final chapter in book['chapters'] as List) {
        final file = await _file(uid, bookId, chapter['id'] as int);
        if (await file.exists()) await file.delete();
        final temp = File('${file.path}.tmp');
        if (await temp.exists()) await temp.delete();
      }
      await prefs.remove(_key(uid, bookId));
    }
    notifyListeners();
  }
}
