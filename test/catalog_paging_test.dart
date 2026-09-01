import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/pages/catalog_paging.dart';

void main() {
  test('large catalogs switch to paged rendering above 200 chapters', () {
    expect(shouldUsePagedCatalog(200), isFalse);
    expect(shouldUsePagedCatalog(201), isTrue);
    expect(shouldUsePagedCatalog(1259), isTrue);
  });

  test('many single-chapter volumes do not use chapter paging', () {
    final volumes = List.generate(
      413,
      (index) => LKVolume(volumeId: index + 1, chapterCount: 1),
    );

    expect(
      shouldUsePagedCatalogForVolumes(
        volumes,
        bookChapterCount: 413,
      ),
      isFalse,
    );
    expect(
      shouldOfferExpandAllVolumes(
        volumes,
        bookChapterCount: 413,
      ),
      isFalse,
    );
  });

  test('one very large volume still uses chapter paging', () {
    final volumes = [
      LKVolume(volumeId: 1, chapterCount: 1259),
    ];

    expect(
      shouldUsePagedCatalogForVolumes(
        volumes,
        bookChapterCount: 1259,
      ),
      isTrue,
    );
  });

  test('single-volume missing metadata falls back to the book total', () {
    final volume = LKVolume(volumeId: 1);

    expect(
      effectiveVolumeChapterCount(
        volume,
        loadedVolumeCount: 1,
        bookChapterCount: 1259,
      ),
      1259,
    );
  });

  test('matching first and last chapter ids identify a single chapter', () {
    final volume = LKVolume(
      volumeId: 1,
      firstChapterId: 99,
      lastChapterId: 99,
    );

    expect(
      effectiveVolumeChapterCount(
        volume,
        loadedVolumeCount: 413,
        bookChapterCount: 413,
      ),
      1,
    );
  });

  test('1259 chapters map to 26 source pages in descending order', () {
    expect(catalogPageCount(1259, 50), 26);
    expect(
      catalogSourcePage(
        logicalPage: 1,
        total: 1259,
        pageSize: 50,
        descending: true,
      ),
      26,
    );
    expect(
      catalogSourcePage(
        logicalPage: 2,
        total: 1259,
        pageSize: 50,
        descending: true,
      ),
      25,
    );
    expect(
      catalogSourcePage(
        logicalPage: 26,
        total: 1259,
        pageSize: 50,
        descending: true,
      ),
      1,
    );
  });

  test('ascending order keeps logical page numbers', () {
    expect(
      catalogSourcePage(
        logicalPage: 7,
        total: 1259,
        pageSize: 50,
        descending: false,
      ),
      7,
    );
  });

  test('reader catalog opens the page containing the current chapter', () {
    expect(
      catalogPageForChapter(chapterNo: 1, total: 1259, pageSize: 50),
      1,
    );
    expect(
      catalogPageForChapter(chapterNo: 1259, total: 1259, pageSize: 50),
      26,
    );
  });

  test('metadata-only default volume is skipped without reading history', () {
    final volumes = [
      LKVolume(volumeId: 42267, title: '作品信息', chapterCount: 1),
      LKVolume(volumeId: 42269, title: '第九章', chapterCount: 49),
    ];

    expect(
      selectCatalogStartVolume(volumes, preferredVolumeId: 42267)?.volumeId,
      42269,
    );
  });

  test('short descending first page requests another page without scrolling',
      () {
    expect(
      shouldLoadNextCatalogPage(
        extentAfter: 0,
        hasMore: true,
        loading: false,
        hasError: false,
      ),
      isTrue,
    );
    expect(
      shouldLoadNextCatalogPage(
        extentAfter: 1200,
        hasMore: true,
        loading: false,
        hasError: false,
      ),
      isFalse,
    );
  });
}
