import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/comments_page.dart';
import 'package:yomiru/pages/dm_chat_page.dart';
import 'package:yomiru/pages/dynamic_publish_page.dart';
import 'package:yomiru/pages/user_profile_page.dart';
import 'package:yomiru/widgets/emoji_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
    LKClient.shared.session
      ..securityKey = 'test-key'
      ..uid = 100;
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = false;
  });

  http.Response jsonOk(Map<String, dynamic> data) => http.Response.bytes(
        utf8.encode(jsonEncode({'code': 0, 'data': data})),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  testWidgets(
      'CommentsPage animates emoji panel, back dismisses input before popping, and tap barrier blocks underlying controls',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.contains('comment-emoji-list')) {
        return jsonOk({
          'list': [
            {
              'name': '测试表情',
              'items': [
                {'code': '😀'},
              ],
            }
          ],
        });
      }
      if (path.contains('get-book-comments')) {
        return jsonOk({
          'list': [
            {
              'comment_id': 1,
              'nickname': '评论者',
              'content': '评论正文',
              'avatar': '',
            }
          ],
          'has_more': false,
        });
      }
      return jsonOk({});
    }));

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const CommentsPage(bookId: 1),
              ),
            ),
            child: const Text('打开评论'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开评论'));
    await tester.pumpAndSettle();
    expect(find.byType(CommentsPage), findsOneWidget);

    // 1. Emoji panel animates open smoothly and settles to full height.
    await tester.tap(find.byTooltip('表情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(LkEmojiPanel), findsOneWidget);
    final midDockHeight = tester.getSize(find.byType(LkAnimatedEmojiDock)).height;
    expect(midDockHeight, greaterThan(0));
    await tester.pumpAndSettle();
    final fullDockHeight =
        tester.getSize(find.byType(LkAnimatedEmojiDock)).height;
    expect(fullDockHeight, greaterThan(midDockHeight));
    expect(tester.takeException(), isNull);

    // 2. First Back closes emoji panel instead of popping the route.
    final nav = Navigator.of(tester.element(find.byType(CommentsPage)));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(CommentsPage), findsOneWidget);
    expect(find.byType(LkEmojiPanel), findsNothing);

    // 3. With text field focused, tapping reply button hits barrier & unfocuses without replying.
    await tester.enterText(find.byType(TextField), '草稿');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.tap(find.text('回复').first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isFalse,
    );
    expect(find.text('回复 @评论者'), findsNothing);

    // 4. First Back unfocuses text field; second Back pops the page.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(CommentsPage), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isFalse,
    );

    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(CommentsPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('DynamicPublishPage Back dismisses focused composer before popping',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.contains('comment-emoji-list')) {
        return jsonOk({
          'list': [
            {
              'name': '测试表情',
              'items': [
                {'code': '😀'},
              ],
            }
          ],
        });
      }
      return jsonOk({'list': []});
    }));

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DynamicPublishPage(),
              ),
            ),
            child: const Text('去发动态'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('去发动态'));
    await tester.pumpAndSettle();

    final contentField =
        find.byKey(const ValueKey('dynamic-content-input'));
    await tester.tap(contentField);
    await tester.pump();
    expect(tester.widget<TextField>(contentField).focusNode!.hasFocus, isTrue);

    final nav = Navigator.of(tester.element(find.byType(DynamicPublishPage)));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(DynamicPublishPage), findsOneWidget);
    expect(tester.widget<TextField>(contentField).focusNode!.hasFocus, isFalse);

    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(DynamicPublishPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('DMChatPage Back and tap-outside barrier dismiss focused input',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.contains('dm-messages-v1')) {
        return jsonOk({
          'list': [
            {
              'id': 1,
              'sender_uid': 200,
              'content': '你好，这是一条私信',
              'created_at': '2026-01-01 12:00:00',
            }
          ],
        });
      }
      return jsonOk({});
    }));

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DMChatPage(peerUid: 200, peerName: '对方'),
              ),
            ),
            child: const Text('打开私信'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开私信'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    expect(find.byKey(const ValueKey('dm-input-dismiss-barrier')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dm-input-dismiss-barrier')));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isFalse,
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final nav = Navigator.of(tester.element(find.byType(DMChatPage)));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(DMChatPage), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isFalse,
    );

    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(DMChatPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('UserProfilePage renders dynamic title, topic tags, body, and bold book title',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/public-user-home-v1')) {
        return jsonOk({
          'profile': {
            'uid': 42,
            'nickname': '测试用户',
            'level_name': '侯爵',
          },
        });
      }
      if (path.endsWith('/get-user-feed-v1')) {
        return jsonOk({
          'list': [
            {
              'dynamic_id': 901,
              'author': {'uid': 42, 'nickname': '测试用户'},
              'title': '动态标题示例',
              'summary': '动态正文示例内容',
              'topic_tags': [
                {'tag_id': 7, 'name': '轻小说讨论', 'slug': 'light-novel'},
              ],
              'target_brief': {
                'book_id': 55,
                'title': '关联作品标题',
                'cover': '',
              },
              'stats': {'like_count': 3, 'comment_count': 1},
              'created_at': '2026-05-01 10:00:00',
            }
          ],
          'has_more': false,
        });
      }
      return jsonOk({'list': []});
    }));

    await tester.pumpWidget(const MaterialApp(home: UserProfilePage(uid: 42)));
    await tester.pumpAndSettle();

    expect(find.text('动态标题示例'), findsOneWidget);
    final titleText = tester.widget<Text>(find.text('动态标题示例'));
    expect(titleText.style?.fontWeight, FontWeight.w700);
    expect(titleText.style?.fontSize, 14.5);

    expect(find.text('# 轻小说讨论'), findsOneWidget);
    expect(find.textContaining('动态正文示例内容'), findsOneWidget);

    final bookTitleText = tester.widget<Text>(find.text('关联作品标题'));
    expect(bookTitleText.style?.fontWeight, FontWeight.w600);
    expect(bookTitleText.style?.fontSize, 13);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
