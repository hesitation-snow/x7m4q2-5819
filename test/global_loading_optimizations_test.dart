import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/channel_page.dart';
import 'package:yomiru/pages/dm_chat_page.dart';
import 'package:yomiru/pages/follow_list_page.dart';
import 'package:yomiru/pages/home_page.dart';
import 'package:yomiru/pages/medal_shop_page.dart';
import 'package:yomiru/pages/search_page.dart';
import 'package:yomiru/pages/tts_settings_page.dart';
import 'package:yomiru/pages/user_profile_page.dart';
import 'package:yomiru/services/reader_tts_preferences.dart';
import 'package:yomiru/services/system_tts.dart';
import 'package:yomiru/widgets/common.dart';

http.Response _ok(Object data) => http.Response.bytes(
      utf8.encode(jsonEncode({'code': 0, 'data': data})),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _fail([int status = 500, String msg = 'server error']) =>
    http.Response.bytes(
      utf8.encode(jsonEncode({'code': status, 'msg': msg})),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _FakeSystemTts extends SystemTts {
  _FakeSystemTts({
    required this.enginesFuture,
    required this.voicesFuture,
  });

  final Future<List<SystemTtsEngine>> enginesFuture;
  final Future<List<SystemTtsVoice>> voicesFuture;

  @override
  Future<List<SystemTtsEngine>> getEngines() => enginesFuture;

  @override
  Future<void> setEngine(String engineId) async {}

  @override
  Future<List<SystemTtsVoice>> getVoices() => voicesFuture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    LKStore.contentCacheEpoch++;
    LKStore.dataSaverMode.value = true;
    LKStore.hideBraveBooks.value = false;
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    LKStore.contentCacheEpoch++;
    LKStore.dataSaverMode.value = false;
    LKStore.hideBraveBooks.value = false;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'RankPage shows LkLoadingIndicator initially and during retry after error',
      (tester) async {
    var call = 0;
    final firstCompleter = Completer<http.Response>();
    final retryCompleter = Completer<http.Response>();

    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) {
      if (request.url.path.contains('book-rank-list-v1')) {
        call++;
        if (call == 1) return firstCompleter.future;
        return retryCompleter.future;
      }
      return Future.value(_ok({'list': []}));
    }));

    await tester.pumpWidget(const MaterialApp(home: RankPage()));
    await tester.pump();
    expect(find.byType(LkLoadingIndicator), findsOneWidget);

    firstCompleter.complete(_fail());
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.text('重试'), findsNothing);
    expect(find.byType(LkLoadingIndicator), findsOneWidget);

    retryCompleter.complete(_ok({
      'list': [
        {'book_id': 11, 'title': '榜单第一作'},
      ],
    }));
    await tester.pumpAndSettle();
    expect(find.text('榜单第一作'), findsOneWidget);
  });

  testWidgets(
      'MyTab clears previous user profile on account switch even when new profile request fails',
      (tester) async {
    LKClient.shared.session
      ..uid = 101
      ..securityKey = 'key-a'
      ..nickname = '用户A';

    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.contains('my-home-v1')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final uid = body['uid'] as int? ?? 0;
        if (uid == 101) {
          return _ok({
            'profile': {
              'uid': 101,
              'nickname': '用户A',
              'group_name': 'LvA',
            },
          });
        }
        return _fail(500, 'uid $uid failed');
      }
      return _ok({});
    }));

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MyTab())),
    );
    await tester.pumpAndSettle();
    expect(find.text('用户A'), findsOneWidget);

    LKClient.shared.session
      ..uid = 202
      ..securityKey = 'key-b'
      ..nickname = '';
    LKClient.sessionRev.value++;

    await tester.pumpAndSettle();
    expect(find.text('用户A'), findsNothing);
  });

  testWidgets(
      'SearchPage initialTag avoids empty flash while loading and refresh failure preserves results',
      (tester) async {
    final taxonomyCompleter = Completer<http.Response>();
    final search1Completer = Completer<http.Response>();
    final search2Completer = Completer<http.Response>();
    var searchCalls = 0;

    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) {
      if (request.url.path.contains('taxonomy')) {
        return taxonomyCompleter.future;
      }
      searchCalls++;
      if (searchCalls == 1) return search1Completer.future;
      return search2Completer.future;
    }));

    await tester.pumpWidget(
      const MaterialApp(home: SearchPage(initialTag: 'fantasy')),
    );
    await tester.pump();
    expect(find.byType(LkLoadingIndicator), findsOneWidget);
    expect(find.text('没有找到相关作品'), findsNothing);

    taxonomyCompleter.complete(_ok({
      'channels': const [],
      'tabs': [
        {
          'groups': [
            {
              'sections': [
                {
                  'tag_items': [
                    {'title': '奇幻', 'jump_type': 'tag', 'jump_value': 'fantasy'}
                  ],
                }
              ],
            }
          ],
        }
      ],
    }));
    await tester.pump();
    expect(find.text('没有找到相关作品'), findsNothing);
    expect(find.byType(LkLoadingIndicator), findsOneWidget);

    search1Completer.complete(_ok({
      'list': [
        {'book_id': 77, 'title': '标签检索作品 0'},
      ],
      'has_more': false,
    }));
    await tester.pumpAndSettle();
    expect(find.text('标签检索作品 0'), findsOneWidget);

    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, 400),
      1000,
    );
    await tester.pump();
    search2Completer.complete(_fail());
    await tester.pumpAndSettle();

    expect(find.text('标签检索作品 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'UserProfilePage loads home & dynamics in parallel and preserves dynamic cursor on failed refresh',
      (tester) async {
    final homeCompleter1 = Completer<http.Response>();
    final dynamicCompleter1 = Completer<http.Response>();
    var homeCalls = 0;
    var dynamicCalls = 0;
    final dynamicCursors = <String>[];

    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.contains('public-user-home-v1')) {
        homeCalls++;
        if (homeCalls == 1) return homeCompleter1.future;
        return _ok({
          'profile': {
            'uid': 77,
            'nickname': '目标作者',
            'public_bookshelf': false,
          },
          'articles': [],
        });
      }
      if (path.contains('get-user-feed-v1')) {
        dynamicCalls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        dynamicCursors.add((body['cursor'] ?? '').toString());
        if (dynamicCalls == 1) return dynamicCompleter1.future;
        if (dynamicCalls == 2) return _fail();
        return _ok({
          'list': [
            {'dynamic_id': 900, 'uid': 77, 'nickname': '目标作者', 'content': '第二页动态'},
          ],
          'next_cursor': '',
          'has_more': 0,
        });
      }
      return _ok({});
    }));

    await tester.pumpWidget(const MaterialApp(home: UserProfilePage(uid: 77)));
    await tester.pump();

    expect(homeCalls, 1);
    expect(dynamicCalls, 1);

    homeCompleter1.complete(_ok({
      'profile': {
        'uid': 77,
        'nickname': '目标作者',
        'public_bookshelf': false,
      },
      'articles': [],
    }));
    dynamicCompleter1.complete(_ok({
      'list': List.generate(
        10,
        (i) => {
          'dynamic_id': 500 + i,
          'uid': 77,
          'nickname': '目标作者',
          'content': '首屏动态消息 #$i',
        },
      ),
      'next_cursor': 'cursor_page_2',
      'has_more': 1,
    }));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('动态').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('首屏动态消息 #0'), findsOneWidget);

    await tester.fling(
      find.byType(ListView).first,
      const Offset(0, 450),
      1000,
    );
    await tester.pumpAndSettle();

    expect(dynamicCalls, 2);
    expect(find.textContaining('首屏动态消息 #0'), findsOneWidget);

    final listFinder = find.byType(ListView).first;
    for (var i = 0; i < 6 && dynamicCalls < 3; i++) {
      await tester.drag(listFinder, const Offset(0, -600));
      await tester.pumpAndSettle();
    }

    expect(dynamicCalls, greaterThanOrEqualTo(3));
    expect(dynamicCursors.last, 'cursor_page_2');
    expect(find.textContaining('第二页动态'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'FollowListPage pull-to-refresh inside tab works and preserves follow overrides on failure',
      (tester) async {
    LKClient.shared.session
      ..uid = 100
      ..securityKey = 'follow-key';

    var followersCalls = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path.contains('user-followers-v1')) {
        followersCalls++;
        if (followersCalls == 1) {
          return _ok({
            'list': [
              {'uid': 201, 'nickname': '粉丝甲', 'followed': false},
            ],
            'total': 1,
            'page': 1,
            'has_more': false,
          });
        }
        return _fail();
      }
      if (path.contains('user-following-v1')) {
        return _ok({'list': [], 'total': 0, 'page': 1, 'has_more': false});
      }
      if (path.contains('toggle-user-follow-v1')) {
        return _ok({});
      }
      return _ok({});
    }));

    await tester.pumpWidget(
      const MaterialApp(home: FollowListPage(initialTab: 1)),
    );
    await tester.pumpAndSettle();

    expect(find.text('粉丝甲'), findsOneWidget);
    expect(find.text('关注'), findsOneWidget);

    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.text('已关注'),
      ),
      findsOneWidget,
    );

    await tester.fling(
      find.byType(ListView).first,
      const Offset(0, 450),
      1000,
    );
    await tester.pumpAndSettle();

    expect(followersCalls, 2);
    expect(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.text('已关注'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('DMChatPage surfaces _loadMoreError retry action and retries page',
      (tester) async {
    LKClient.shared.session
      ..uid = 100
      ..securityKey = 'dm-key';

    var page2Calls = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('dm-messages-v1')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final page = body['page'] as int? ?? 1;
        if (page == 1) {
          return _ok({
            'list': List.generate(
              30,
              (i) => {
                'id': 100 + i,
                'sender_uid': i.isEven ? 100 : 202,
                'content_text': '最新聊天消息 #$i',
              },
            ),
          });
        }
        page2Calls++;
        if (page2Calls == 1) return _fail();
        return _ok({
          'list': [
            {'id': 10, 'sender_uid': 202, 'content_text': '更早的历史记录'},
          ],
        });
      }
      return _ok({});
    }));

    await tester.pumpWidget(
      const MaterialApp(home: DMChatPage(peerUid: 202, peerName: '书友B')),
    );
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    for (var i = 0;
        i < 12 && find.text('加载更早记录失败，点击重试').evaluate().isEmpty;
        i++) {
      await tester.drag(listFinder, const Offset(0, 500));
      await tester.pumpAndSettle();
    }

    final retryFinder = find.text('加载更早记录失败，点击重试');
    expect(page2Calls, 1);
    expect(retryFinder, findsOneWidget);
    await tester.drag(listFinder, const Offset(0, 200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(retryFinder);
    await tester.pumpAndSettle();

    await tester.tap(retryFinder);
    await tester.pumpAndSettle();

    expect(page2Calls, 2);
    expect(find.text('更早的历史记录'), findsOneWidget);
  });

  testWidgets(
      'TtsSettingsPage does not flash empty system voices during initial system-mode load',
      (tester) async {
    await ReaderTtsPreferences.save(
      ReaderTtsPreferences.defaults.copyWith(sourceMode: 'system'),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final enginesCompleter = Completer<List<SystemTtsEngine>>();
      final voicesCompleter = Completer<List<SystemTtsVoice>>();
      final fakeTts = _FakeSystemTts(
        enginesFuture: enginesCompleter.future,
        voicesFuture: voicesCompleter.future,
      );

      await tester.pumpWidget(
        MaterialApp(home: TtsSettingsPage(systemTts: fakeTts)),
      );

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.text('系统未提供可用语音'), findsNothing);
      }
      expect(find.byKey(const ValueKey('tts-settings-list')), findsOneWidget);
      expect(find.text('系统未提供可用语音'), findsNothing);

      enginesCompleter.complete(const [
        SystemTtsEngine(
            id: 'com.example.tts', label: '测试引擎', isSystem: true),
      ]);
      await tester.pump();
      expect(find.text('系统未提供可用语音'), findsNothing);

      voicesCompleter.complete(const [
        SystemTtsVoice(
          id: 'zh-CN-Tingting',
          name: 'Tingting',
          locale: 'zh-CN',
          engine: 'com.example.tts',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.textContaining('Tingting'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'MedalShopPage restores cached medals immediately on re-entry without blocking indicator',
      (tester) async {
    LKClient.shared.session
      ..uid = 9991
      ..securityKey = 'shop-key-1';

    var calls = 0;
    final secondCompleter = Completer<http.Response>();
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) {
      if (request.url.path.contains('my-medal-center-v1')) {
        calls++;
        if (calls == 1) {
          return Future.value(_ok({
            'task_medals': [
              {'task_id': 1, 'name': '首发缓存勋章'},
            ],
            'exchange_medals': const [],
          }));
        }
        return secondCompleter.future;
      }
      return Future.value(_ok({}));
    }));

    await tester.pumpWidget(const MaterialApp(home: MedalShopPage()));
    await tester.pumpAndSettle();
    expect(find.text('首发缓存勋章'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: MedalShopPage()));
    await tester.pump();

    expect(find.text('首发缓存勋章'), findsOneWidget);
    expect(find.byType(LkLoadingIndicator), findsNothing);

    secondCompleter.complete(_ok({
      'task_medals': [
        {'task_id': 1, 'name': '首发缓存勋章'},
      ],
      'exchange_medals': const [],
    }));
    await tester.pumpAndSettle();
  });
}
