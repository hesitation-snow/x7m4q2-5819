import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';

void main() {
  test('message summary accepts nested counts and clears notification types',
      () {
    final summary = LKMessageSummary.fromJson({
      'total_unread': 21,
      'counts': {
        'reply_count': '2',
        'mention_count': 3,
        'like_count': 4,
        'fan_count': 1,
        'system_count': 5,
        'dm_count': 6,
      },
    });

    expect(summary.unreadCount, 21);
    expect(summary.countFor('mention'), 3);
    expect(summary.clearCategory('mention').unreadCount, 18);
    expect(summary.clearNotifications().unreadCount, 6);
    expect(summary.clearNotifications().dmCount, 6);
    expect(summary.clearCategory('dm').dmCount, 0);
    expect(summary.clearCategory('dm').unreadCount, 15);
    expect(summary.clearDm(2).dmCount, 4);
    expect(summary.clearDm(2).unreadCount, 19);
  });

  test('notification preserves actor, content and navigation targets', () {
    final item = LKMessageItem.fromJson({
      'message_id': '77',
      'message_kind': 'reply',
      'category_code': 'dynamic_reply',
      'source': {
        'uid': '1246722',
        'nickname': '测试用户',
        'avatar': 'https://example.com/avatar.webp',
      },
      'title': '回复了你的动态',
      'content_text': '回复内容',
      'quote_text': '被回复的内容',
      'related_title': '动态标题',
      'target_dynamic_id': 0,
      'target_comment_id': 0,
      'target_reply_id': 0,
      'content_target_url': '/activity/3630?comment_id=57&reply_id=59',
      'is_read': 0,
      'created_at': '2026-08-26 12:30:00',
    }, type: 'reply');

    expect(item.id, 77);
    expect(item.uid, 1246722);
    expect(item.sourceName, '测试用户');
    expect(item.content, '回复内容');
    expect(item.quoteText, '被回复的内容');
    expect(item.targetDynamicId, 3630);
    expect(item.targetCommentId, 57);
    expect(item.rootCommentId, 57);
    expect(item.targetReplyId, 59);
    expect(item.unread, isTrue);
  });

  test('message page keeps zero-id system notices and pagination state', () {
    final page = LKMessagePage.fromJson({
      'items': [
        {
          'title': '系统维护通知',
          'content': '维护完成',
          'unread': 1,
        },
      ],
      'pagination': {
        'page_size': 20,
        'total': 41,
        'has_next': 1,
      },
    }, type: 'system', fallbackPage: 2, fallbackPageSize: 20);

    expect(page.items, hasLength(1));
    expect(page.items.single.title, '系统维护通知');
    expect(page.page, 2);
    expect(page.total, 41);
    expect(page.hasMore, isTrue);
  });

  test('conversation accepts live aliases and nested last message time', () {
    final conversation = LKConversation.fromJson({
      'thread_id': '9',
      'target_user': {
        'uid': '88',
        'nickname': '对方',
        'avatar_url': 'https://example.com/peer.png',
      },
      'last_message': {
        'preview': '最后一条私信',
        'created_at': '2026-08-26 09:00:00',
      },
      'unread_count': '3',
    });

    expect(conversation.conversationId, 9);
    expect(conversation.peerUid, 88);
    expect(conversation.peerName, '对方');
    expect(conversation.lastMessage, '最后一条私信');
    expect(conversation.unread, 3);
    expect(conversation.updatedAt, '2026-08-26 09:00:00');
  });
}
