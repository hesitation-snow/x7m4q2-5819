import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/reader/reader_bookmarks.dart';
import 'package:yomiru/reader/reading_position.dart';

ReaderBookmark bookmark(String id,
        {int chapter = 2,
        ReadingPosition position =
            const ReadingPosition.text(blockIndex: 0, offset: 3),
        String context = 'abcdef',
        int contextOffset = 3,
        String? image}) =>
    ReaderBookmark(
        id: id,
        bookId: 1,
        chapterId: chapter,
        chapterTitle: '第一章',
        position: position,
        context: context,
        contextOffset: contextOffset,
        createdAt: DateTime.utc(2025),
        imageFingerprint: image);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'bookmarks remain separate from progress, accounts, anonymous and chapters',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('existing_progress', 'untouched');
    await Future.wait([
      ReaderBookmarkStore.add(uid: 0, bookmark: bookmark('a')),
      ReaderBookmarkStore.add(uid: 0, bookmark: bookmark('b')),
      ReaderBookmarkStore.add(uid: 1, bookmark: bookmark('c')),
      ReaderBookmarkStore.add(uid: 0, bookmark: bookmark('d', chapter: 3))
    ]);
    expect(
        (await ReaderBookmarkStore.list(uid: 0, bookId: 1, chapterId: 2))
            .map((b) => b.id),
        ['a', 'b']);
    expect(
        (await ReaderBookmarkStore.list(uid: 1, bookId: 1, chapterId: 2))
            .single
            .id,
        'c');
    expect((await ReaderBookmarkStore.list(uid: 2, bookId: 1, chapterId: 2)),
        isEmpty);
    expect(
        (await ReaderBookmarkStore.list(uid: 0, bookId: 1, chapterId: 3))
            .single
            .id,
        'd');
    await ReaderBookmarkStore.delete(uid: 0, bookId: 1, chapterId: 2, id: 'a');
    expect(
        (await ReaderBookmarkStore.list(uid: 0, bookId: 1, chapterId: 2))
            .single
            .id,
        'b');
    expect(prefs.getString('existing_progress'), 'untouched');
  });
  test('round trip retains chapter, logical position, context and time',
      () async {
    final source = bookmark('a');
    await ReaderBookmarkStore.add(uid: 8, bookmark: source);
    final result =
        (await ReaderBookmarkStore.list(uid: 8, bookId: 1, chapterId: 2))
            .single;
    expect(result.position, source.position);
    expect(result.context, source.context);
    expect(result.chapterTitle, source.chapterTitle);
    expect(result.createdAt, source.createdAt);
  });
  test(
      'text anchor resolves exact or uniquely moved context, rejects missing or ambiguous',
      () {
    final b = bookmark('a');
    expect(resolveBookmark(b, [(text: 'abcdef', image: null)]), b.position);
    expect(
        resolveBookmark(b,
            [(text: 'other', image: null), (text: 'xxabcdefyy', image: null)]),
        const ReadingPosition.text(blockIndex: 1, offset: 5));
    expect(resolveBookmark(b, [(text: 'changed', image: null)]), isNull);
    expect(
        resolveBookmark(
            b, [(text: 'abcdef', image: null), (text: 'abcdef', image: null)]),
        isNull);
    expect(
        resolveBookmark(b, [
          (text: 'other', image: null),
          (text: 'abcdefabcdef', image: null)
        ]),
        isNull);
  });
  test('image anchor checks identity and can relocate uniquely', () {
    final b = bookmark('i',
        position: const ReadingPosition.image(blockIndex: 0, fraction: .5),
        context: '',
        contextOffset: 0,
        image: bookmarkImageFingerprint('image-A'));
    expect(
        resolveBookmark(
            b, [(text: '', image: 'image-B'), (text: '', image: 'image-A')]),
        const ReadingPosition.image(blockIndex: 1, fraction: .5));
    expect(resolveBookmark(b, [(text: '', image: 'image-B')]), isNull);
    expect(
        resolveBookmark(
            b, [(text: '', image: 'image-A'), (text: '', image: 'image-A')]),
        isNull);
  });
  test('damaged stored data is reported and never overwritten', () async {
    final prefs = await SharedPreferences.getInstance();
    const raw = '[{"id": 2}, null]';
    await prefs.setString('reader_bookmarks_v1_0_1_2', raw);
    await expectLater(ReaderBookmarkStore.list(uid: 0, bookId: 1, chapterId: 2),
        throwsFormatException);
    await expectLater(
        ReaderBookmarkStore.add(uid: 0, bookmark: bookmark('new')),
        throwsFormatException);
    await expectLater(
        ReaderBookmarkStore.delete(uid: 0, bookId: 1, chapterId: 2, id: 'old'),
        throwsFormatException);
    expect(prefs.getString('reader_bookmarks_v1_0_1_2'), raw);
  });
}
