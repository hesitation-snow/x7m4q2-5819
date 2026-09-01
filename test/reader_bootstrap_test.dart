import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('reader bootstrap preserves the effective history target', () {
    final bootstrap = LKReaderBootstrap.fromJson({
      'book': {
        'book_id': 587,
        'title': '测试作品',
        'author_name': '作者',
        'cover_url': 'https://example.com/cover.jpg',
      },
      'book_summary': {'summary_short': '简介'},
      'book_stats': {'volume_count': 8, 'chapter_count': 120},
      'read_target': {
        'default_volume_id': 10,
        'default_chapter_id': 100,
      },
      'library_state': {
        'in_shelf': 1,
        'has_history': 1,
        'last_read_volume_id': 12,
        'last_read_chapter_id': 234,
        'last_read_chapter_title': '上次读到的章节',
      },
      'effective_read_target': {
        'volume_id': 12,
        'chapter_id': 234,
        'chapter_title': '续读章节',
        'source': 'history',
        'resume_available': 1,
      },
    });

    expect(bootstrap.book.bookId, 587);
    expect(bootstrap.book.summary, '简介');
    expect(bootstrap.book.volumeCount, 8);
    expect(bootstrap.book.chapterCount, 120);
    expect(bootstrap.book.defaultVolumeId, 10);
    expect(bootstrap.book.defaultChapterId, 100);
    expect(bootstrap.inShelf, isTrue);
    expect(bootstrap.hasHistory, isTrue);
    expect(bootstrap.resumeAvailable, isTrue);
    expect(bootstrap.readVolumeId, 12);
    expect(bootstrap.readChapterId, 234);
    expect(bootstrap.readChapterTitle, '续读章节');
  });

  test('reader bootstrap falls back to the default reading target', () {
    final bootstrap = LKReaderBootstrap.fromJson({
      'book': {'book_id': 42, 'title': '新作品'},
      'book_summary': '完整简介',
      'default_volume': {'volume_id': 9, 'first_chapter_id': 91},
      'effective_read_target': {
        'volume_id': 9,
        'chapter_id': 91,
        'source': 'default',
        'resume_available': 0,
      },
      'library_state': {'in_shelf': 0, 'has_history': 0},
    });

    expect(bootstrap.book.summary, '完整简介');
    expect(bootstrap.book.defaultVolumeId, 9);
    expect(bootstrap.book.defaultChapterId, 91);
    expect(bootstrap.hasHistory, isFalse);
    expect(bootstrap.resumeAvailable, isFalse);
    expect(bootstrap.readChapterId, 91);
  });
}
