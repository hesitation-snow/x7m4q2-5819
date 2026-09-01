import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('book comment page reads page_info metadata', () {
    final page = LKCommentPage.fromJson({
      'list': [
        {'comment_id': 1, 'content': 'one'},
        {'comment_id': 2, 'content': 'two'},
      ],
      'page_info': {
        'count': 42,
        'size': 20,
        'cur': 2,
        'has_next': 1,
      },
    });

    expect(page.items.map((item) => item.commentId), [1, 2]);
    expect(page.page, 2);
    expect(page.pageSize, 20);
    expect(page.total, 42);
    expect(page.hasMore, isTrue);
  });

  test('dynamic comment page retains cursor and root comment', () {
    final page = LKCommentPage.fromJson({
      'list': [
        {'comment_id': 59, 'content': 'reply'},
      ],
      'root_comment': {'comment_id': 57, 'content': 'root'},
      'next_cursor': 'next-59',
      'has_more': 1,
      'page_size': 20,
    });

    expect(page.items.single.commentId, 59);
    expect(page.rootComment?.commentId, 57);
    expect(page.nextCursor, 'next-59');
    expect(page.hasMore, isTrue);
  });

  test('explicit final-page flag wins over a full batch', () {
    final page = LKCommentPage.fromJson({
      'list': [
        for (var id = 1; id <= 20; id++) {'comment_id': id},
      ],
      'page_info': {'count': 20, 'size': 20, 'cur': 1, 'has_next': 0},
    });

    expect(page.hasMore, isFalse);
  });
}
