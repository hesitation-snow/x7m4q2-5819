import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/pages/messages_page.dart';

http.Response _utf8Response(Map<String, dynamic> data, [int status = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LKMessageUser and LKMessageItem Like Parsing Tests', () {
    test('LKMessageUser handles empty and valid json correctly', () {
      final empty = LKMessageUser.fromJson(const {});
      expect(empty.uid, 0);
      expect(empty.nickname, '');
      expect(empty.avatar, '');

      final valid = LKMessageUser.fromJson(const {
        'uid': '10086',
        'nickname': '测试点赞人',
        'headimgurl': 'https://example.com/avatar.png',
      });
      expect(valid.uid, 10086);
      expect(valid.nickname, '测试点赞人');
      expect(valid.avatar, 'https://example.com/avatar.png');
    });

    test('LKMessageItem parses single user like on dynamic', () {
      final item = LKMessageItem.fromJson(const {
        'message_id': 101,
        'target_type': 'dynamic',
        'target_dynamic_id': 2026,
        'users': [
          {
            'uid': 555,
            'nickname': '夏娜',
            'avatar': 'https://example.com/shana.png',
          }
        ],
        'quote_text': '今天发布了新卷插画',
        'is_read': 0,
        'created_at': '2026-09-05 10:00:00',
      }, type: 'like');

      expect(item.id, 101);
      expect(item.type, 'like');
      expect(item.targetType, 'dynamic');
      expect(item.targetDynamicId, 2026);
      expect(item.likeUsers, hasLength(1));
      expect(item.likeUsers.first.uid, 555);
      expect(item.likeUsers.first.nickname, '夏娜');
      expect(item.likeCount, 1);
      expect(item.quoteText, '今天发布了新卷插画');
      expect(item.unread, isTrue);
    });

    test('LKMessageItem parses multiple users like on paragraph comment', () {
      final item = LKMessageItem.fromJson(const {
        'message_id': 102,
        'target_type': 'paragraph_comment',
        'like_count': 32,
        'users': [
          {'uid': 1, 'nickname': '用户1', 'avatar': 'https://example.com/1.png'},
          {'uid': 2, 'nickname': '用户2', 'avatar': 'https://example.com/2.png'},
          {'uid': 3, 'nickname': '用户3', 'avatar': 'https://example.com/3.png'},
        ],
        'book': {
          'book_id': 14162,
          'title': '勇者之书',
        },
        'chapter': {
          'chapter_id': 9999,
          'id': 9999,
        },
        'target_text': '这一段描写真的很绝妙！',
        'created_at': '2026-09-05 10:30:00',
        'unread': 1,
      }, type: 'like');

      expect(item.id, 102);
      expect(item.targetType, 'paragraph_comment');
      expect(item.likeUsers, hasLength(3));
      expect(item.likeCount, 32);
      expect(item.targetBookId, 14162);
      expect(item.targetChapterId, 9999);
      expect(item.targetBookTitle, '勇者之书');
      expect(item.quoteText, '这一段描写真的很绝妙！');
      expect(item.unread, isTrue);
    });

    test(
        'LKMessageItem falls back to single peer/source when users list is absent',
        () {
      final item = LKMessageItem.fromJson(const {
        'message_id': 103,
        'target_type': 'comment',
        'source': {
          'uid': '777',
          'nickname': '单人点赞者',
          'avatar_url': 'https://example.com/single.jpg',
        },
        'target_comment_id': 404,
        'target_dynamic_id': 808,
        'quote_info': '评论内容预览',
        'is_read': 1,
      }, type: 'like');

      expect(item.id, 103);
      expect(item.likeUsers, hasLength(1));
      expect(item.likeUsers.first.uid, 777);
      expect(item.likeUsers.first.nickname, '单人点赞者');
      expect(item.likeUsers.first.avatar, 'https://example.com/single.jpg');
      expect(item.likeCount, 1);
      expect(item.targetCommentId, 404);
      expect(item.targetDynamicId, 808);
      expect(item.quoteText, '评论内容预览');
      expect(item.unread, isFalse);
    });

    test('LKMessageItem parses jump metadata correctly', () {
      final item = LKMessageItem.fromJson(const {
        'message_id': 104,
        'message_jump': {
          'type': 'book',
          'value': '1338',
          'target': 'book_detail',
        },
        'target_book_title': '关于邻家的天使大人',
        'quote_text': '真好看的一本书',
      }, type: 'like');

      expect(item.jumpType, 'book');
      expect(item.jumpValue, '1338');
      expect(item.jumpTarget, 'book_detail');
      expect(item.targetBookId, 1338);
      expect(item.targetBookTitle, '关于邻家的天使大人');
    });

    test('LKMessagePage parses like message list correctly', () {
      final page = LKMessagePage.fromJson(const {
        'items': [
          {
            'message_id': 201,
            'target_type': 'dynamic',
            'users': [
              {'uid': 11, 'nickname': '读者A'}
            ],
            'quote_text': '动态测试',
          },
          {
            'message_id': 202,
            'target_type': 'book_comment',
            'users': [
              {'uid': 12, 'nickname': '读者B'}
            ],
            'quote_text': '书评测试',
          }
        ],
        'pagination': {
          'page': 1,
          'page_size': 20,
          'total': 2,
          'has_next': 0,
        },
      }, type: 'like');

      expect(page.items, hasLength(2));
      expect(page.items[0].id, 201);
      expect(page.items[0].likeUsers.first.nickname, '读者A');
      expect(page.items[1].id, 202);
      expect(page.items[1].likeUsers.first.nickname, '读者B');
      expect(page.total, 2);
      expect(page.hasMore, isFalse);
    });
  });

  group('MessagesPage Like Message Tab UI Tests', () {
    setUp(() {
      LKClient.shared.session
        ..uid = 10
        ..securityKey = 'mock-session';
    });
    tearDown(() {
      LKApi.client = LKClient.shared;
      LKClient.shared.session.clear();
    });

    testWidgets('Renders empty state with official text 暂无点赞消息',
        (tester) async {
      final mock = MockClient((request) async {
        return _utf8Response({
          'code': 0,
          'data': {
            'items': [],
            'pagination': {'total': 0, 'page_size': 20, 'has_next': 0},
          }
        });
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MessagesPage(),
          ),
        ),
      );

      // Initial pump
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Switch to like tab (index 2: 回复=0, 提及=1, 点赞=2)
      final likeTabFinder = find.text('点赞');
      expect(likeTabFinder, findsOneWidget);
      await tester.tap(likeTabFinder);
      await tester.pumpAndSettle();

      // Verify official empty copy
      expect(find.text('暂无点赞消息'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    });

    testWidgets('Renders single and multi user like message cards',
        (tester) async {
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('message-likes-v1')) {
          return _utf8Response({
            'code': 0,
            'data': {
              'items': [
                {
                  'message_id': 301,
                  'target_type': 'dynamic',
                  'target_dynamic_id': 777,
                  'users': [
                    {'uid': 55, 'nickname': '亚丝娜', 'avatar': ''}
                  ],
                  'quote_text': '今天阳光明媚',
                  'created_at': '2026-09-05 11:00:00',
                  'unread': 0,
                },
                {
                  'message_id': 302,
                  'target_type': 'comment',
                  'like_count': 6,
                  'users': [
                    {'uid': 61, 'nickname': '桐人', 'avatar': ''},
                    {'uid': 62, 'nickname': '诗乃', 'avatar': ''},
                  ],
                  'target_book_title': '刀剑神域',
                  'quote_text': '星爆气流斩',
                  'created_at': '2026-09-05 11:05:00',
                  'unread': 1,
                }
              ],
              'pagination': {'total': 2, 'page_size': 20, 'has_next': 0},
            }
          });
        }
        return _utf8Response({
          'code': 0,
          'data': {
            'items': [],
            'pagination': {'total': 0, 'page_size': 20, 'has_next': 0},
          }
        });
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MessagesPage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final likeTabFinder = find.text('点赞');
      await tester.tap(likeTabFinder);
      await tester.pumpAndSettle();

      // Verify single like text
      expect(find.text('亚丝娜'), findsOneWidget);
      expect(find.textContaining('赞了你的动态'), findsOneWidget);
      expect(find.text('今天阳光明媚'), findsOneWidget);

      // Verify multi like text
      expect(find.text('桐人'), findsOneWidget);
      expect(find.textContaining('等 6 人赞了你的评论'), findsOneWidget);
      expect(find.text('刀剑神域'), findsOneWidget);
      expect(find.text('星爆气流斩'), findsOneWidget);
    });

    testWidgets('Renders error state with official error text', (tester) async {
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('message-likes-v1')) {
          return _utf8Response({
            'code': 500,
            'msg': 'Internal Server Error',
          }, 500);
        }
        return _utf8Response({
          'code': 0,
          'data': {
            'items': [],
            'pagination': {'total': 0, 'page_size': 20, 'has_next': 0},
          }
        });
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MessagesPage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final likeTabFinder = find.text('点赞');
      await tester.tap(likeTabFinder);
      await tester.pumpAndSettle();

      // Verify official error text
      expect(find.text('点赞消息刷新失败，请稍后重试'), findsOneWidget);
    });
  });
}
