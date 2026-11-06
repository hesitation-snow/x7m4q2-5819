import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/services/book_catalog_verifier.dart';

LKChapter chapter(int id, {String access = 'public'}) => LKChapter.fromJson({
      'chapter_id': id,
      'chapter_no': id,
      'access_type': access,
    });

LKChapterPage page(List<LKChapter> items,
        {int number = 1, int? total, bool more = false}) =>
    LKChapterPage(
        items: items,
        page: number,
        total: total ?? items.length,
        hasMore: more);

class Fixture {
  LKBook book = LKBook(
      bookId: 7,
      volumeCount: 1,
      chapterCount: 1,
      accessStatus: BookAccessStatus.public);
  List<LKVolume> volumes = [LKVolume(volumeId: 1, chapterCount: 1)];
  final calls = <String>[];
  final pages = <String, LKChapterPage>{
    '1:1': page([chapter(1)])
  };
  Future<LKBook> Function()? bookHook;
  Future<LKChapterPage> Function(int, int)? chapterHook;
  Future<CatalogVolumeBatch> Function(int)? volumeHook;
  DateTime time = DateTime(2026);

  BookCatalogVerifier verifier({int maxEntries = 128}) => BookCatalogVerifier(
        maxEntries: maxEntries,
        now: () => time,
        loadBook: (id, remaining) async {
          expect(remaining, greaterThan(Duration.zero));
          calls.add('book:$id');
          return bookHook == null ? book : await bookHook!();
        },
        loadVolumes: (id, number, size, remaining) async {
          expect(size, 50);
          calls.add('volumes:$number');
          return volumeHook == null
              ? CatalogVolumeBatch(
                  items: volumes,
                  hasMore: false,
                  page: number,
                  total: volumes.length)
              : await volumeHook!(number);
        },
        loadChapters: (id, volume, number, size, remaining) async {
          expect(size, 50);
          calls.add('chapters:$volume:$number');
          return chapterHook == null
              ? pages['$volume:$number']!
              : await chapterHook!(volume, number);
        },
      );
}

void main() {
  test(
      'finished unknown catalogs can be rechecked without a fingerprint change',
      () async {
    final f = Fixture();
    f.pages['1:1'] = page([chapter(1, access: '')]);
    final verifier = f.verifier();
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.unknown);
    f.pages['1:1'] = page([chapter(1, access: 'brave')]);
    verifier.beginLookup(7);
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.containsBrave);
  });

  test('13 entries: chapter_no 11 and final character design are brave',
      () async {
    for (final braveAt in [11, 13]) {
      final f = Fixture();
      f.book = LKBook(bookId: 7, volumeCount: 1, chapterCount: 13);
      f.volumes = [LKVolume(volumeId: 1, chapterCount: 13)];
      f.pages['1:1'] = page(List.generate(
          13,
          (i) =>
              chapter(i + 1, access: i + 1 == braveAt ? 'brave' : 'public')));
      final result = await f.verifier().verifyRound(7, isCurrent: () => true);
      expect(result.status, CatalogVerificationStatus.containsBrave);
      expect(result.requests, 3);
    }
  });

  test('public first page does not hide last brave entry on second page',
      () async {
    final f = Fixture();
    f.book = LKBook(bookId: 7, volumeCount: 1, chapterCount: 51);
    f.volumes = [LKVolume(volumeId: 1, chapterCount: 51)];
    f.pages['1:1'] =
        page(List.generate(50, (i) => chapter(i + 1)), total: 51, more: true);
    f.pages['1:2'] = page([chapter(51, access: 'brave')], number: 2, total: 51);
    final result = await f.verifier().verifyRound(7, isCurrent: () => true);
    expect(result.status, CatalogVerificationStatus.containsBrave);
    expect(result.requests, 4);
  });

  test('missing totals still reach brave on a later page', () async {
    final f = Fixture();
    f.book = LKBook(bookId: 7, volumeCount: 1, chapterCount: 2);
    f.volumes = [LKVolume(volumeId: 1, chapterCount: 2)];
    f.pages['1:1'] = LKChapterPage.fromJson({
      'items': [
        {'chapter_id': 1, 'access_type': 'public'}
      ],
      'page': 1,
      'has_more': true,
    });
    f.pages['1:2'] = LKChapterPage.fromJson({
      'items': [
        {'chapter_id': 2, 'access_type': 'brave'}
      ],
      'page': 2,
      'has_more': false,
    });
    expect(f.pages['1:1']!.hasKnownTotal, isFalse);
    expect((await f.verifier().verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.containsBrave);
    expect(f.calls.last, 'chapters:1:2');
  });

  test('server page size 20 is accepted while requests still ask for 50',
      () async {
    final f = Fixture();
    f.book = LKBook(bookId: 7, volumeCount: 1, chapterCount: 21);
    f.volumes = [LKVolume(volumeId: 1, chapterCount: 21)];
    f.pages['1:1'] = LKChapterPage(
        items: List.generate(20, (i) => chapter(i + 1)),
        page: 1,
        pageSize: 20,
        total: 21,
        hasMore: true);
    f.pages['1:2'] = LKChapterPage(
        items: [chapter(21)], page: 2, pageSize: 20, total: 21, hasMore: false);
    expect((await f.verifier().verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.noBrave);
    expect(f.calls.last, 'chapters:1:2');
  });

  test('explicit zero total with nonempty items is a contradiction', () async {
    final f = Fixture();
    f.pages['1:1'] = LKChapterPage.fromJson({
      'items': [
        {'chapter_id': 1, 'access_type': 'public'}
      ],
      'total': 0,
      'has_more': false,
    });
    expect(f.pages['1:1']!.hasKnownTotal, isTrue);
    expect((await f.verifier().verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.unknown);
  });

  test('missing totals can still prove a complete explicitly public catalog',
      () async {
    final f = Fixture();
    f.pages['1:1'] = LKChapterPage.fromJson({
      'items': [
        {'chapter_id': 1, 'access_type': 'public'}
      ],
      'has_more': false,
    });
    expect((await f.verifier().verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.noBrave);
  });

  test('unknown-total full page may end with an extra empty terminal page',
      () async {
    final f = Fixture();
    f.book = LKBook(bookId: 7, volumeCount: 1, chapterCount: 50);
    f.volumes = [LKVolume(volumeId: 1, chapterCount: 50)];
    f.pages['1:1'] = LKChapterPage.fromJson({
      'items': List.generate(
          50, (i) => {'chapter_id': i + 1, 'access_type': 'public'}),
      'page': 1,
    });
    f.pages['1:2'] = LKChapterPage.fromJson({'items': [], 'page': 2});
    expect(f.pages['1:1']!.hasMore, isTrue);
    expect(f.pages['1:2']!.hasMore, isFalse);
    expect((await f.verifier().verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.noBrave);
  });

  test('public book entry and first volume still inspect later volumes',
      () async {
    final f = Fixture();
    f.book = LKBook(
        bookId: 7,
        volumeCount: 2,
        chapterCount: 2,
        accessStatus: BookAccessStatus.public);
    f.volumes.add(LKVolume(volumeId: 2, chapterCount: 1));
    f.pages['2:1'] = page([chapter(2, access: 'brave')]);
    expect((await f.verifier().verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.containsBrave);
    expect(f.calls, ['book:7', 'volumes:1', 'chapters:1:1', 'chapters:2:1']);
  });

  test('only complete explicitly public metadata is a negative', () async {
    final f = Fixture();
    final verifier = f.verifier();
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.noBrave);
    verifier.beginLookup(7);
    f.pages['1:1'] = page([chapter(1, access: '')]);
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.unknown);
    expect(verifier.hasPending(7), isFalse);
  });

  test('four-request rounds resume every page in every volume batch', () async {
    final f = Fixture();
    f.book = LKBook(bookId: 7, volumeCount: 3, chapterCount: 3);
    f.volumeHook = (number) async => CatalogVolumeBatch(
        items: [LKVolume(volumeId: number, chapterCount: 1)],
        hasMore: number < 3,
        total: 3,
        page: number);
    f.pages['2:1'] = page([chapter(2)]);
    f.pages['3:1'] = page([chapter(3)]);
    final verifier = f.verifier();
    final first = await verifier.verifyRound(7, isCurrent: () => true);
    expect(first.status, CatalogVerificationStatus.partial);
    expect(first.requests, 4);
    expect(first.madeProgress, isTrue);
    expect(verifier.hasPending(7), isTrue);
    verifier.beginLookup(7); // Preserve partial even across external lookups.
    final second = await verifier.verifyRound(7, isCurrent: () => true);
    expect(second.status, CatalogVerificationStatus.noBrave);
    expect(f.calls, [
      'book:7',
      'volumes:1',
      'chapters:1:1',
      'volumes:2',
      'book:7',
      'chapters:2:1',
      'volumes:3',
      'chapters:3:1'
    ]);
  });

  test('chapter cursor resumes the middle page instead of sampling endpoints',
      () async {
    final f = Fixture();
    f.book = LKBook(bookId: 7, volumeCount: 1, chapterCount: 151);
    f.volumes = [LKVolume(volumeId: 1, chapterCount: 151)];
    for (var number = 1; number <= 4; number++) {
      final start = (number - 1) * 50;
      f.pages['1:$number'] = page(
          List.generate(
              number == 4 ? 1 : 50,
              (i) => chapter(start + i + 1,
                  access: start + i + 1 == 117 ? 'brave' : 'public')),
          number: number,
          total: 151,
          more: number < 4);
    }
    final verifier = f.verifier();
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.partial);
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.containsBrave);
    expect(f.calls, [
      'book:7',
      'volumes:1',
      'chapters:1:1',
      'chapters:1:2',
      'book:7',
      'chapters:1:3'
    ]);
  });

  test('cancelled late response does not commit its chapter cursor', () async {
    final f = Fixture();
    final delayed = Completer<LKChapterPage>();
    var current = true;
    f.chapterHook = (_, __) => delayed.future;
    final verifier = f.verifier();
    final running = verifier.verifyRound(7, isCurrent: () => current);
    // Flush microtasks without timers or account/network dependencies.
    for (var i = 0; i < 12 && f.calls.length < 3; i++) {
      await Future<void>.value();
    }
    expect(f.calls.last, 'chapters:1:1');
    current = false;
    delayed.complete(page([chapter(1)]));
    expect((await running).status, CatalogVerificationStatus.cancelled);
    f.chapterHook = null;
    current = true;
    expect((await verifier.verifyRound(7, isCurrent: () => current)).status,
        CatalogVerificationStatus.noBrave);
    expect(f.calls.where((call) => call == 'chapters:1:1').length, 2);
  });

  test('count or updatedAt changes invalidate completed checkpoints', () async {
    for (final changeCount in [true, false]) {
      final f = Fixture();
      final verifier = f.verifier();
      await verifier.verifyRound(7, isCurrent: () => true);
      f.book = LKBook(
          bookId: 7,
          volumeCount: 1,
          chapterCount: changeCount ? 2 : 1,
          updatedAt: changeCount ? '' : 'new');
      if (changeCount) {
        f.volumes = [LKVolume(volumeId: 1, chapterCount: 2)];
      }
      f.pages['1:1'] =
          page([chapter(1, access: 'brave'), if (changeCount) chapter(2)]);
      expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
          CatalogVerificationStatus.containsBrave);
      expect(f.calls.where((call) => call == 'volumes:1').length, 2);
    }
  });

  test('duplicate or empty hasMore pages stop automatic continuation',
      () async {
    for (final duplicate in [true, false]) {
      final f = Fixture();
      f.book = LKBook(bookId: 7, volumeCount: 1, chapterCount: 3);
      f.volumes = [LKVolume(volumeId: 1, chapterCount: 3)];
      f.pages['1:1'] = page([chapter(1)], total: 3, more: true);
      f.pages['1:2'] =
          page(duplicate ? [chapter(1)] : [], number: 2, total: 3, more: true);
      final verifier = f.verifier();
      expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
          CatalogVerificationStatus.unknown);
      expect(verifier.hasPending(7), isFalse);
    }
  });

  test('request failure keeps previous cursor and permits explicit retry',
      () async {
    final f = Fixture();
    var fail = true;
    f.chapterHook = (_, __) async {
      if (fail) throw StateError('transient metadata error');
      return page([chapter(1)]);
    };
    final verifier = f.verifier();
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.unknown);
    expect(verifier.hasPending(7), isFalse);
    fail = false;
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.noBrave);
    expect(f.calls.where((call) => call == 'volumes:1').length, 1);
  });

  test('expired response is unknown and does not commit a page', () async {
    final f = Fixture();
    f.chapterHook = (_, __) async {
      f.time = f.time.add(const Duration(seconds: 9));
      return page([chapter(1)]);
    };
    final verifier = f.verifier();
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.unknown);
    f.chapterHook = null;
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.noBrave);
    expect(f.calls.where((call) => call == 'chapters:1:1').length, 2);
  });

  test('invalid IDs, totals and truncation never prove public', () async {
    for (final invalid in [
      page([chapter(0)]),
      page([chapter(1)], total: 2),
      page([]),
    ]) {
      final f = Fixture();
      f.pages['1:1'] = invalid;
      expect((await f.verifier().verifyRound(7, isCurrent: () => true)).status,
          CatalogVerificationStatus.unknown);
    }
  });

  test('idle LRU never evicts an active cursor or creates a second one',
      () async {
    final f = Fixture();
    final gate = Completer<LKBook>();
    f.bookHook = () => gate.future;
    final verifier = f.verifier(maxEntries: 1);
    final running = verifier.verifyRound(7, isCurrent: () => true);
    expect((await verifier.verifyRound(8, isCurrent: () => true)).requests, 0);
    expect((await verifier.verifyRound(7, isCurrent: () => true)).status,
        CatalogVerificationStatus.cancelled);
    gate.complete(f.book);
    expect((await running).status, CatalogVerificationStatus.noBrave);
  });
}
