import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/comments_page.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/pages/user_profile_page.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';

void _setSession({required int uid, required String securityKey}) {
  LKClient.shared.session
    ..uid = uid
    ..securityKey = securityKey
    ..nickname = 'tester_$uid';
  LKApi.client.session
    ..uid = uid
    ..securityKey = securityKey
    ..nickname = 'tester_$uid';
}

http.Response _okJson(Map<String, dynamic> data) => http.Response(
      jsonEncode({'code': 0, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKClient.dynamicDeleted.value = null;
    LKClient.dynamicCommentCountChanged.value = null;
  });

  group('LKApi dynamic delete & comment delete', () {
    test(
        'deleteDynamic sends expected body, parses deleted flags, invalidates caches, and notifies listeners',
        () async {
      SharedPreferences.setMockInitialValues({});
      dynamic deletedFlag = 1;
      final bodies = <Map<String, dynamic>>[];
      var userFeedFetches = 0;
      var userHomeFetches = 0;

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/api/dynamic/delete-dynamic-v1')) {
            bodies.add(body);
            return _okJson({'dynamic_id': 4137, 'deleted': deletedFlag});
          }
          if (request.url.path.endsWith('/api/dynamic/get-user-feed-v1')) {
            userFeedFetches++;
            return _okJson({'list': [], 'has_more': false});
          }
          if (request.url.path.endsWith('/api/bff/public-user-home-v1')) {
            userHomeFetches++;
            return _okJson({
              'profile': {'uid': 7, 'nickname': 'Me'},
              'publications': [],
            });
          }
          return _okJson({});
        }),
      );
      _setSession(uid: 7, securityKey: 'sec-7');

      await LKApi.publicUserDynamics(7);
      await LKApi.publicUserHome(7, 1);
      expect(userFeedFetches, 1);
      expect(userHomeFetches, 1);

      final feedCacheKey = LKStore.pageCacheKey(
        kind: 'dynamic_feed',
        uid: 7,
        variant: 'follow',
      );
      await LKStore.cacheDynamicPage(feedCacheKey, [
        LKDynamicItem(dynamicId: 4137, authorUid: 7, summary: 'to remove'),
        LKDynamicItem(dynamicId: 4138, authorUid: 8, summary: 'keep me'),
      ]);

      final events = <int>[];
      void listener() {
        final v = LKClient.dynamicDeleted.value;
        if (v != null) events.add(v.dynamicId);
      }

      LKClient.dynamicDeleted.addListener(listener);
      addTearDown(() => LKClient.dynamicDeleted.removeListener(listener));

      expect(await LKApi.deleteDynamic(4137), isTrue);
      expect(bodies.single['security_key'], 'sec-7');
      expect(bodies.single['dynamic_id'], 4137);
      expect(events, [4137]);

      final cachedAfter = await LKStore.cachedDynamicPage(feedCacheKey);
      expect(cachedAfter?.map((e) => e.dynamicId).toList(), [4138]);

      await LKApi.publicUserDynamics(7);
      await LKApi.publicUserHome(7, 1);
      expect(userFeedFetches, 2);
      expect(userHomeFetches, 2);

      deletedFlag = '1';
      expect(await LKApi.deleteDynamic(4139), isTrue);
      deletedFlag = true;
      expect(await LKApi.deleteDynamic(4140), isTrue);

      deletedFlag = 0;
      final beforeEvents = events.length;
      expect(await LKApi.deleteDynamic(4141), isFalse);
      deletedFlag = false;
      expect(await LKApi.deleteDynamic(4142), isFalse);
      expect(events.length, beforeEvents);
    });

    test(
        'deleteDynamicComment parses root_comment_id string/int, clears caches, and notifies listeners',
        () async {
      SharedPreferences.setMockInitialValues({});
      dynamic deletedFlag = 1;
      dynamic rootCommentId = '99';
      final bodies = <Map<String, dynamic>>[];

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/api/dynamic/delete-comment-v1')) {
            bodies.add(body);
            return _okJson({
              'dynamic_id': 4114,
              'comment_id': 123456,
              'root_comment_id': rootCommentId,
              'deleted': deletedFlag,
            });
          }
          return _okJson({});
        }),
      );
      _setSession(uid: 7, securityKey: 'sec-7');

      final countEvents = <({int dynamicId, int delta})>[];
      void listener() {
        final v = LKClient.dynamicCommentCountChanged.value;
        if (v != null) {
          countEvents.add((dynamicId: v.dynamicId, delta: v.delta));
        }
      }

      LKClient.dynamicCommentCountChanged.addListener(listener);
      addTearDown(
          () => LKClient.dynamicCommentCountChanged.removeListener(listener));

      final res = await LKApi.deleteDynamicComment(4114, 123456);
      expect(res.deleted, isTrue);
      expect(res.rootCommentId, 99);
      expect(bodies.single['security_key'], 'sec-7');
      expect(bodies.single['dynamic_id'], 4114);
      expect(bodies.single['comment_id'], 123456);
      expect(countEvents, [(dynamicId: 4114, delta: -1)]);

      deletedFlag = 0;
      rootCommentId = 0;
      final res2 = await LKApi.deleteDynamicComment(4114, 123457);
      expect(res2.deleted, isFalse);
      expect(countEvents, hasLength(1));
    });
  });

  group('DynamicPage deletion UI & confirmation guards', () {
    testWidgets(
        'shows delete only for own dynamic, cancel keeps item, failure shows error, confirm removes to empty state',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      var deleteMode = 'fail_flag'; // fail_flag | throw | ok
      final deleteCalls = <int>[];

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final path = request.url.path;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (path.endsWith('/api/dynamic/get-feed-v1')) {
            return _okJson({
              'list': [
                {
                  'dynamic_id': 101,
                  'author_uid': 7,
                  'nickname': '我自己',
                  'content': '我发布的测试动态',
                },
                {
                  'dynamic_id': 102,
                  'author_uid': 99,
                  'nickname': '其他用户',
                  'content': '别人的测试动态',
                },
              ],
              'has_more': false,
            });
          }
          if (path.endsWith('/api/dynamic/get-detail-v1')) {
            return _okJson({
              'dynamic': {
                'dynamic_id': body['dynamic_id'],
                'interaction_state': {'liked': false},
              }
            });
          }
          if (path.endsWith('/api/dynamic/delete-dynamic-v1')) {
            deleteCalls.add(body['dynamic_id'] as int);
            if (deleteMode == 'throw') {
              return http.Response(
                jsonEncode({'code': 500, 'message': 'server error'}),
                200,
              );
            }
            return _okJson({
              'dynamic_id': body['dynamic_id'],
              'deleted': deleteMode == 'ok' ? 1 : 0,
            });
          }
          return _okJson({});
        }),
      );
      _setSession(uid: 7, securityKey: 'sec-7');

      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();

      // 1. Others' dynamic must NOT show '删除动态'.
      await tester.longPress(find.text('别人的测试动态'));
      await tester.pumpAndSettle();
      expect(find.byType(M3MenuSheet), findsOneWidget);
      expect(find.text('删除动态'), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      // 2. Own dynamic shows '删除动态', cancel keeps item without API call.
      await tester.longPress(find.text('我发布的测试动态'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      expect(find.text('删除后无法恢复，确定删除这条动态？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(deleteCalls, isEmpty);
      expect(find.text('我发布的测试动态'), findsOneWidget);

      // 3. deleted: 0 treats failure cleanly and keeps item.
      await tester.longPress(find.text('我发布的测试动态'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(deleteCalls, [101]);
      expect(find.text('删除失败，请稍后再试'), findsOneWidget);
      expect(find.text('我发布的测试动态'), findsOneWidget);

      // 4. API error also preserves item and surfaces error message.
      deleteMode = 'throw';
      await tester.longPress(find.text('我发布的测试动态'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(deleteCalls, [101, 101]);
      expect(find.text('删除失败，请稍后再试'), findsWidgets);
      expect(find.text('我发布的测试动态'), findsOneWidget);

      // 5. Successful delete removes item from DynamicPage.
      deleteMode = 'ok';
      await tester.longPress(find.text('我发布的测试动态'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(deleteCalls, [101, 101, 101]);
      expect(find.text('我发布的测试动态'), findsNothing);
      expect(find.text('别人的测试动态'), findsOneWidget);
    });

    testWidgets('deleting the last dynamic transitions cleanly to empty state',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/api/dynamic/get-feed-v1')) {
            return _okJson({
              'list': [
                {
                  'dynamic_id': 201,
                  'author_uid': 7,
                  'nickname': '我自己',
                  'content': '最后一条动态',
                },
              ],
              'has_more': false,
            });
          }
          if (path.endsWith('/api/dynamic/delete-dynamic-v1')) {
            return _okJson({'dynamic_id': 201, 'deleted': 1});
          }
          return _okJson({});
        }),
      );
      _setSession(uid: 7, securityKey: 'sec-7');

      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();
      expect(find.text('最后一条动态'), findsOneWidget);

      await tester.longPress(find.text('最后一条动态'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('最后一条动态'), findsNothing);
      expect(find.text('暂无动态'), findsOneWidget);
    });
  });

  group('Cross-page sync (DynamicPage <-> UserProfilePage <-> CommentsPage)',
      () {
    testWidgets(
        'deleting on UserProfilePage syncs to DynamicPage and prevents memory/disk cache resurrection',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final serverFeed = <Map<String, dynamic>>[
        {
          'dynamic_id': 301,
          'author_uid': 7,
          'nickname': '我自己',
          'content': '同步删除动态 301',
        },
        {
          'dynamic_id': 302,
          'author_uid': 7,
          'nickname': '我自己',
          'content': '保留动态 302',
        },
      ];

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final path = request.url.path;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (path.endsWith('/api/dynamic/get-feed-v1')) {
            return _okJson({'list': serverFeed, 'has_more': false});
          }
          if (path.endsWith('/api/bff/public-user-home-v1')) {
            return _okJson({
              'profile': {
                'uid': 7,
                'nickname': '我自己',
                'public_bookshelf': false,
              },
              'publications': [],
            });
          }
          if (path.endsWith('/api/dynamic/get-user-feed-v1')) {
            return _okJson({'list': serverFeed, 'has_more': false});
          }
          if (path.endsWith('/api/dynamic/delete-dynamic-v1')) {
            final id = body['dynamic_id'] as int;
            serverFeed.removeWhere((e) => e['dynamic_id'] == id);
            return _okJson({'dynamic_id': id, 'deleted': 1});
          }
          return _okJson({});
        }),
      );
      _setSession(uid: 7, securityKey: 'sec-7');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: DynamicPage(embedded: true)),
                Expanded(child: UserProfilePage(uid: 7)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('同步删除动态 301'), findsNWidgets(2));
      expect(find.text('保留动态 302'), findsNWidgets(2));

      // Long-press on the UserProfilePage side (second match).
      await tester.longPress(find.text('同步删除动态 301').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('同步删除动态 301'), findsNothing);
      expect(find.text('保留动态 302'), findsNWidgets(2));

      // Re-mount DynamicPage alone and verify neither memory cache nor disk cache resurrects 301.
      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();
      expect(find.text('同步删除动态 301'), findsNothing);
      expect(find.text('保留动态 302'), findsOneWidget);
    });

    testWidgets(
        'deleting on DynamicPage removes from UserProfilePage, and deleting from CommentsPage pops and syncs both',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final serverFeed = <Map<String, dynamic>>[
        {
          'dynamic_id': 401,
          'author_uid': 7,
          'nickname': '我自己',
          'content': '首页先删这条 401',
        },
        {
          'dynamic_id': 402,
          'author_uid': 7,
          'nickname': '我自己',
          'content': '详情页删这条 402',
        },
      ];

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final path = request.url.path;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (path.endsWith('/api/dynamic/get-feed-v1')) {
            return _okJson({'list': serverFeed, 'has_more': false});
          }
          if (path.endsWith('/api/bff/public-user-home-v1')) {
            return _okJson({
              'profile': {
                'uid': 7,
                'nickname': '我自己',
                'public_bookshelf': false,
              },
              'publications': [],
            });
          }
          if (path.endsWith('/api/dynamic/get-user-feed-v1')) {
            return _okJson({'list': serverFeed, 'has_more': false});
          }
          if (path.endsWith('/api/dynamic/get-detail-v1')) {
            final id = body['dynamic_id'] as int;
            final found = serverFeed.firstWhere(
              (e) => e['dynamic_id'] == id,
              orElse: () => {'dynamic_id': id, 'author_uid': 7, 'content': ''},
            );
            return _okJson({'dynamic': found});
          }
          if (path.endsWith('/api/dynamic/get-comments-v1')) {
            return _okJson({'list': [], 'has_more': false});
          }
          if (path.endsWith('/api/dynamic/delete-dynamic-v1')) {
            final id = body['dynamic_id'] as int;
            serverFeed.removeWhere((e) => e['dynamic_id'] == id);
            return _okJson({'dynamic_id': id, 'deleted': 1});
          }
          return _okJson({});
        }),
      );
      _setSession(uid: 7, securityKey: 'sec-7');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: DynamicPage(embedded: true)),
                Expanded(child: UserProfilePage(uid: 7)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('首页先删这条 401'), findsNWidgets(2));
      expect(find.text('详情页删这条 402'), findsNWidgets(2));

      // Delete 401 from DynamicPage -> disappears from UserProfilePage too.
      await tester.longPress(find.text('首页先删这条 401').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('首页先删这条 401'), findsNothing);

      // Open CommentsPage for 402 and delete it from detail menu -> pops & removes from both.
      await tester.tap(find.text('详情页删这条 402').first);
      await tester.pumpAndSettle();
      expect(find.byType(CommentsPage), findsOneWidget);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除动态'));
      await tester.tap(find.text('删除动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.byType(CommentsPage), findsNothing);
      expect(find.text('详情页删这条 402'), findsNothing);
    });
  });

  group('CommentsPage dynamic comment & reply deletion', () {
    testWidgets(
        'deletes own root comment and reply, refreshes floor by root_comment_id, and syncs commentCount to feeds',
        (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copiedText;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      SharedPreferences.setMockInitialValues({});
      final rootComments = <Map<String, dynamic>>[
        {
          'comment_id': 501,
          'root_comment_id': 0,
          'user_uid': 7,
          'nickname': '我自己',
          'content': '我的一级评论',
          'reply_count': 2,
          'replies': [
            {
              'comment_id': 601,
              'root_comment_id': 501,
              'user_uid': 7,
              'nickname': '我自己',
              'content': '我的楼中楼回复',
            },
            {
              'comment_id': 602,
              'root_comment_id': 501,
              'user_uid': 88,
              'nickname': '别人',
              'content': '别人的楼中楼回复',
            },
          ],
        },
        {
          'comment_id': 502,
          'root_comment_id': 0,
          'user_uid': 88,
          'nickname': '别人',
          'content': '别人的一级评论',
          'reply_count': 0,
        },
      ];
      final feedItem = {
        'dynamic_id': 700,
        'author_uid': 88,
        'nickname': '别人',
        'content': '动态正文 700',
        'stats': {'like_count': 0, 'comment_count': 3, 'favorite_count': 0},
      };
      final replyFetches = <int>[];
      final deleteRequests = <Map<String, dynamic>>[];

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          final path = request.url.path;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (path.endsWith('/api/dynamic/get-feed-v1') ||
              path.endsWith('/api/dynamic/get-user-feed-v1')) {
            return _okJson({'list': [feedItem], 'has_more': false});
          }
          if (path.endsWith('/api/bff/public-user-home-v1')) {
            return _okJson({
              'profile': {
                'uid': 7,
                'nickname': '我自己',
                'public_bookshelf': false,
              },
              'publications': [],
            });
          }
          if (path.endsWith('/api/dynamic/get-detail-v1')) {
            return _okJson({'dynamic': feedItem});
          }
          if (path.endsWith('/api/dynamic/get-comments-v1')) {
            final cid = body['comment_id'] as int;
            if (cid == 501) {
              replyFetches.add(cid);
              final parent =
                  rootComments.firstWhere((e) => e['comment_id'] == 501);
              return _okJson({
                'list': parent['replies'],
                'has_more': false,
              });
            }
            return _okJson({'list': rootComments, 'has_more': false});
          }
          if (path.endsWith('/api/dynamic/delete-comment-v1')) {
            deleteRequests.add(body);
            final cid = body['comment_id'] as int;
            if (cid == 601) {
              final replies =
                  rootComments[0]['replies'] as List<Map<String, dynamic>>;
              replies.removeWhere((e) => e['comment_id'] == 601);
              rootComments[0]['reply_count'] = 1;
              (feedItem['stats'] as Map<String, dynamic>)['comment_count'] = 2;
              return _okJson({
                'dynamic_id': 700,
                'comment_id': 601,
                'root_comment_id': '501',
                'deleted': 1,
              });
            }
            if (cid == 501) {
              rootComments.removeWhere((e) => e['comment_id'] == 501);
              (feedItem['stats'] as Map<String, dynamic>)['comment_count'] = 1;
              return _okJson({
                'dynamic_id': 700,
                'comment_id': 501,
                'root_comment_id': '0',
                'deleted': 1,
              });
            }
          }
          return _okJson({});
        }),
      );
      _setSession(uid: 7, securityKey: 'sec-7');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: DynamicPage(embedded: true)),
                Expanded(child: UserProfilePage(uid: 7)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open CommentsPage for dynamic 700.
      await tester.tap(find.text('动态正文 700').first);
      await tester.pumpAndSettle();
      expect(find.byType(CommentsPage), findsOneWidget);
      expect(find.text('评论 3 · 赞 0'), findsOneWidget);
      expect(find.text('我的一级评论'), findsOneWidget);
      expect(find.text('我的楼中楼回复'), findsOneWidget);
      expect(find.text('别人的一级评论'), findsOneWidget);

      // Long-press on someone else's comment copies instead of opening delete menu.
      await tester.longPress(find.text('别人的一级评论'));
      await tester.pumpAndSettle();
      expect(find.text('删除评论'), findsNothing);
      expect(copiedText, '别人的一级评论');
      expect(find.text('已复制评论'), findsOneWidget);

      // Delete own reply comment 601 (root_comment_id = "501").
      await tester.longPress(find.text('我的楼中楼回复'));
      await tester.pumpAndSettle();
      expect(find.text('删除评论'), findsOneWidget);
      await tester.tap(find.text('删除评论'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(deleteRequests.last['comment_id'], 601);
      expect(replyFetches, [501]);
      expect(find.text('我的楼中楼回复'), findsNothing);
      expect(find.text('别人的楼中楼回复'), findsOneWidget);
      expect(find.text('评论 2 · 赞 0'), findsOneWidget);

      // Delete own root comment 501.
      await tester.longPress(find.text('我的一级评论'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除评论'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(deleteRequests.last['comment_id'], 501);
      expect(find.text('我的一级评论'), findsNothing);
      expect(find.text('评论 1 · 赞 0'), findsOneWidget);

      // Pop back and verify DynamicPage + UserProfilePage both synced to 评论 1.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('赞 0 · 评论 1'), findsNWidgets(2));
    });
  });
}
