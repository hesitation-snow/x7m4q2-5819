import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('chapter page reads server pagination metadata', () {
    final page = LKChapterPage.fromJson({
      'chapter_count': 1259,
      'list': [
        {
          'chapter_id': 305652,
          'chapter_no': 1,
          'title': '1.异世界很和平',
          'word_count': 6752,
        },
      ],
      'pagination': {
        'page': 1,
        'page_size': 50,
        'total': 1259,
        'page_count': 26,
      },
      'page_info': {
        'has_next': 1,
      },
    });

    expect(page.items, hasLength(1));
    expect(page.items.single.chapterNo, 1);
    expect(page.page, 1);
    expect(page.pageSize, 50);
    expect(page.total, 1259);
    expect(page.hasMore, isTrue);
  });

  test('volume exposes its chapter count for per-volume paging', () {
    final volume = LKVolume.fromJson({
      'volume_id': 43913,
      'title': '正文',
      'chapter_count': 1259,
      'first_chapter_id': 305652,
      'last_chapter_id': 322842,
    });

    expect(volume.chapterCount, 1259);
    expect(volume.firstChapterId, 305652);
    expect(volume.lastChapterId, 322842);
  });
}
