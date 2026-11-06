import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('volume pagination respects server page counts and smaller page sizes',
      () {
    final page = LKVolumePage.fromJson({
      'list': List.generate(20, (i) => {'volume_id': i + 1}),
      'pagination': {'page': 1, 'page_size': 20, 'total': 45, 'page_count': 3},
    }, fallbackPage: 1, fallbackPageSize: 50);
    expect(page.pageSize, 20);
    expect(page.total, 45);
    expect(page.hasMore, isTrue);
    final end = LKVolumePage.fromJson({
      'list': [
        {'volume_id': 45}
      ],
      'pagination': {'page': 3, 'page_size': 20, 'total': 45, 'page_count': 3}
    }, fallbackPage: 3, fallbackPageSize: 50);
    expect(end.hasMore, isFalse);
  });

  test('missing or malformed volume lists are not empty complete catalogs', () {
    for (final data in <Map<String, dynamic>>[
      {},
      {'list': 'bad'},
      {
        'list': [1]
      }
    ]) {
      expect(
          () => LKVolumePage.fromJson(data,
              fallbackPage: 1, fallbackPageSize: 50),
          throwsFormatException);
    }
  });

  test('known chapter totals end an exact full page without an extra request',
      () {
    final items = List.generate(
        50, (i) => {'chapter_id': i + 1, 'access_type': 'public'});
    final page = LKChapterPage.fromJson({
      'list': items,
      'pagination': {'page': 1, 'page_size': 50, 'total': 50, 'page_count': 1}
    });
    expect(page.hasKnownTotal, isTrue);
    expect(page.total, 50);
    expect(page.hasMore, isFalse);
  });

  test('absent and explicitly zero chapter totals have different meanings', () {
    final items = List.generate(50, (i) => {'chapter_id': i + 1});
    final missing = LKChapterPage.fromJson({'list': items});
    expect(missing.hasKnownTotal, isFalse);
    expect(missing.hasMore, isTrue);
    final zero = LKChapterPage.fromJson({
      'list': items,
      'pagination': {'total': 0}
    });
    expect(zero.hasKnownTotal, isTrue);
    expect(zero.total, 0);
    // The verifier, not this parser, rejects the contradictory nonempty page.
    expect(zero.hasMore, isFalse);
  });
}
