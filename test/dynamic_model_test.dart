import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('localizes work activity labels', () {
    expect(dynamicEventLabel('volume created'), '更新了新卷');
    expect(dynamicEventLabel('chapter_published'), '更新了新章节');
    expect(dynamicEventLabel('book_created'), '新作品');
  });

  test('builds the canonical dynamic website URL', () {
    expect(dynamicWebsiteUrl(3630), 'https://www.lightnovel.fun/activity/3630');
  });

  test('uses a title as dynamic body when content is absent', () {
    final titleOnly = LKDynamicItem.fromJson({
      'dynamic_id': 3667,
      'title': '只有标题的动态',
    });
    expect(titleOnly.displayContent, '只有标题的动态');

    final withBody = LKDynamicItem.fromJson({
      'dynamic_id': 3716,
      'title': '动态标题',
      'summary': '动态正文',
    });
    expect(withBody.displayContent, '动态正文');

    final targetBriefTitle = LKDynamicItem.fromJson({
      'dynamic_id': 3667,
      'event_type': 'short_post_published',
      'target_brief': {
        'target_type': 'short_post',
        'target_id': 3667,
        'title': '接口放在 target_brief 的标题',
      },
    });
    expect(targetBriefTitle.displayContent, '接口放在 target_brief 的标题');
  });

  test('pure dynamic target id is not treated as a book id', () {
    final item = LKDynamicItem.fromJson({
      'dynamic_id': 3627,
      'event_type': 'short_post_published',
      'summary': '纯动态',
      'target_brief': {
        'target_type': 'short_post',
        'target_id': 49,
        'title': '纯动态标题',
        'cover_url': '',
      },
      'media': [
        {'url': 'https://example.com/image.jpg', 'width': 1973, 'height': 1600},
      ],
    });

    expect(item.bookId, 0);
    expect(item.isWorkPost, isFalse);
    expect(item.bookTitle, '纯动态标题');
    expect(item.media, hasLength(1));
    expect(item.media.single.width, 1973);
  });

  test('book target keeps book id and card fields', () {
    final item = LKDynamicItem.fromJson({
      'dynamic_id': 3558,
      'event_type': 'book_created',
      'target_brief': {
        'target_type': 'book',
        'target_id': 31592,
        'title': '书名',
        'cover_url': 'https://example.com/cover.jpg',
      },
    });

    expect(item.bookId, 31592);
    expect(item.isWorkPost, isTrue);
    expect(item.bookTitle, '书名');
    expect(item.bookCover, 'https://example.com/cover.jpg');
  });

  test('dynamic comments preserve nested replies', () {
    final comment = LKComment.fromJson({
      'comment_id': 57,
      'reply_count': 1,
      'author': {'uid': 100, 'nickname': '主楼用户'},
      'replies': [
        {
          'comment_id': 59,
          'reply_comment_id': 57,
          'author': {'uid': 101, 'nickname': '回复用户'},
          'content': '楼中楼回复',
        },
      ],
    });

    expect(comment.replyCount, 1);
    expect(comment.replies, hasLength(1));
    expect(comment.replies.single.commentId, 59);
    expect(comment.replies.single.replyToCommentId, 57);
    expect(comment.replies.single.nickname, '回复用户');
  });

  test('dynamic comments accept the live API reply fields', () {
    final comment = LKComment.fromJson({
      'comment_id': 57,
      'replies_count': 2,
      'stats': {'like_count': 4},
      'author': {'uid': '100', 'nickname': '主楼用户'},
    });
    final reply = LKComment.fromJson({
      'comment_id': 59,
      'root_comment_id': 57,
      'reply_to': {'comment_id': 57, 'nickname': '主楼用户'},
      'reply_to_user': {'nickname': '主楼用户'},
      'author': {'uid': '101', 'nickname': '回复用户'},
      'publish_time': '2026-08-22 18:01:10',
    });

    expect(comment.replyCount, 2);
    expect(comment.likeCount, 4);
    expect(reply.replyToCommentId, 57);
    expect(reply.replyToNickname, '主楼用户');
  });
}
