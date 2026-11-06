import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'reading_position.dart';

/// 本机书签：不含会话凭据，与阅读进度使用不同存储键。
class ReaderBookmark {
  const ReaderBookmark(
      {required this.id,
      required this.bookId,
      required this.chapterId,
      required this.chapterTitle,
      required this.position,
      required this.context,
      required this.contextOffset,
      required this.createdAt,
      this.imageFingerprint});
  final String id;
  final int bookId, chapterId;
  final String chapterTitle, context;
  final ReadingPosition position;
  final int contextOffset;
  final DateTime createdAt;
  final String? imageFingerprint;

  Map<String, Object?> toJson() => {
        'id': id,
        'book': bookId,
        'chapter': chapterId,
        'title': chapterTitle,
        'position': position.toJson(),
        'context': context,
        'contextOffset': contextOffset,
        'createdAt': createdAt.toIso8601String(),
        if (imageFingerprint != null) 'image': imageFingerprint
      };

  static ReaderBookmark? fromJson(Object? raw) {
    try {
      if (raw is! Map) return null;
      final position = ReadingPosition.fromJson(raw['position']);
      final id = raw['id'];
      final book = raw['book'];
      final chapter = raw['chapter'];
      final title = raw['title'];
      final context = raw['context'];
      final offset = raw['contextOffset'];
      final time = DateTime.tryParse(raw['createdAt'] as String);
      final image = raw['image'];
      if (position == null ||
          id is! String ||
          book is! int ||
          chapter is! int ||
          title is! String ||
          context is! String ||
          offset is! int ||
          offset < 0 ||
          offset > context.length ||
          time == null ||
          (image != null && image is! String)) {
        return null;
      }
      return ReaderBookmark(
          id: id,
          bookId: book,
          chapterId: chapter,
          chapterTitle: title,
          position: position,
          context: context,
          contextOffset: offset,
          createdAt: time,
          imageFingerprint: image as String?);
    } catch (_) {
      return null;
    }
  }
}

/// A short, stable non-cryptographic fingerprint; never persists illustration URLs.
String bookmarkImageFingerprint(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}

/// Resolve an exact context, or uniquely relocate it after blocks move.
/// A missing or ambiguous match is not safe to jump to.
ReadingPosition? resolveBookmark(
    ReaderBookmark bookmark, List<({String text, String? image})> blocks) {
  if (bookmark.imageFingerprint != null) {
    bool matches(int i) =>
        blocks[i].image != null &&
        bookmarkImageFingerprint(blocks[i].image!) == bookmark.imageFingerprint;
    final matchesList = [
      for (var i = 0; i < blocks.length; i++)
        if (matches(i)) i
    ];
    return matchesList.length == 1
        ? bookmark.position.copyWith(blockIndex: matchesList.single)
        : null;
  }
  final context = bookmark.context;
  if (context.isEmpty) return null;
  final locations = <ReadingPosition>[];
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].image != null) continue;
    final text = blocks[i].text;
    var start = text.indexOf(context);
    while (start >= 0) {
      locations.add(ReadingPosition.text(
          blockIndex: i, offset: start + bookmark.contextOffset));
      if (locations.length > 1) return null;
      start = text.indexOf(context, start + 1);
    }
  }
  return locations.length == 1 ? locations.single : null;
}

class ReaderBookmarkStore {
  static Future<void>? _pending;
  static String _key(int uid, int book, int chapter) =>
      'reader_bookmarks_v1_${uid}_${book}_$chapter';
  static Future<List<ReaderBookmark>> list(
      {required int uid, required int bookId, required int chapterId}) async {
    if (uid < 0 || bookId <= 0 || chapterId <= 0) return [];
    final pending = _pending;
    if (pending != null) await pending;
    return _read(await SharedPreferences.getInstance(), uid, bookId, chapterId);
  }

  static List<ReaderBookmark> _read(
      SharedPreferences prefs, int uid, int book, int chapter) {
    final key = _key(uid, book, chapter);
    if (!prefs.containsKey(key)) return [];
    try {
      final raw = jsonDecode(prefs.getString(key)!);
      if (raw is! List) throw const FormatException();
      final items = <ReaderBookmark>[];
      for (final entry in raw) {
        final item = ReaderBookmark.fromJson(entry);
        if (item == null || item.bookId != book || item.chapterId != chapter) {
          throw const FormatException();
        }
        items.add(item);
      }
      return items;
    } catch (_) {
      throw const FormatException('Invalid bookmark data');
    }
  }

  static Future<void> _mutate(int uid, int book, int chapter,
      void Function(List<ReaderBookmark>) change) {
    if (uid < 0 || book <= 0 || chapter <= 0) {
      return Future.error(ArgumentError('Invalid bookmark scope'));
    }
    Future<void> write() async {
      final prefs = await SharedPreferences.getInstance();
      final items = _read(prefs, uid, book, chapter);
      change(items);
      final ok = await prefs.setString(_key(uid, book, chapter),
          jsonEncode(items.map((b) => b.toJson()).toList()));
      if (!ok) throw StateError('Bookmark write failed');
    }

    final previous = _pending;
    final operation =
        previous == null ? write() : previous.then((_) => write());
    late final Future<void> barrier;
    barrier = operation.then<void>((_) {
      if (identical(_pending, barrier)) _pending = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_pending, barrier)) _pending = null;
    });
    _pending = barrier;
    return operation;
  }

  static Future<void> add(
          {required int uid, required ReaderBookmark bookmark}) =>
      _mutate(uid, bookmark.bookId, bookmark.chapterId,
          (items) => items.add(bookmark));
  static Future<void> delete(
          {required int uid,
          required int bookId,
          required int chapterId,
          required String id}) =>
      _mutate(uid, bookId, chapterId,
          (items) => items.removeWhere((b) => b.id == id));
}
