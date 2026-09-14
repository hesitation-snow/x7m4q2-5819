import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/follow_list_page.dart';
import 'package:yomiru/pages/settings_page.dart';
import 'package:yomiru/pages/dm_chat_page.dart';
import 'package:yomiru/pages/comments_page.dart';
import 'package:yomiru/pages/medal_shop_page.dart';
import 'package:yomiru/pages/medal_center_page.dart';
import 'package:yomiru/pages/messages_page.dart';
import 'package:yomiru/pages/welfare_page.dart';
import 'package:yomiru/services/app_motion.dart';

// Regression coverage for the app polish pass. All HTTP is mocked.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
    LKClient.shared.session
      ..securityKey = 'audit'
      ..uid = 10;
  });
  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = false;
    LKClient.followChanged.value = null;
  });
  http.Response response(Map<String, dynamic> data) =>
      http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});

  testWidgets(
      'reordered message tabs keep both private messages and fans usable',
      (tester) async {
    LKApi.client = LKClient.forTesting(
        httpClient: MockClient((_) async =>
            response({'items': [], 'list': [], 'has_more': false})));
    await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
    await tester.pumpAndSettle();
    final labels =
        find.descendant(of: find.byType(TabBar), matching: find.byType(Text));
    expect(tester.widgetList<Text>(labels).map((text) => text.data).toList(),
        ['回复', '提及', '点赞', '私信', '系统', '关注']);
    await tester.ensureVisible(find.text('私信'));
    await tester.tap(find.text('私信'));
    await tester.pumpAndSettle();
    expect(find.text('暂时没有私信'), findsOneWidget);
    await tester.ensureVisible(find.text('关注'));
    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();
    expect(find.text('暂时没有关注消息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover blur appears above hide brave books in settings',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();
    await tester.ensureVisible(find.text('隐藏勇者书籍'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('封面模糊')).dy,
        lessThan(tester.getTopLeft(find.text('隐藏勇者书籍')).dy));
    expect(tester.takeException(), isNull);
  });

  for (final option in ['主题模式', '封面模糊']) {
    testWidgets('$option fits on 800x390 landscape', (tester) async {
      tester.view.physicalSize = const Size(800, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pump();
      if (option == '封面模糊') {
        await tester.drag(find.byType(ListView), const Offset(0, -350));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(option));
      await tester.pumpAndSettle();
      final error = tester.takeException();
      expect(error, isNull);
    });
  }

  testWidgets('unfollow updates fans and following without re-entering',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('user-follow')) {
        return response({
          'items': [
            {'uid': 20, 'nickname': 'AuditUser', 'followed': true}
          ],
          'total': 1,
          'has_more': false
        });
      }
      return response({});
    }));
    LKApi.client.session
      ..securityKey = 'audit'
      ..uid = 10;
    await tester
        .pumpWidget(const MaterialApp(home: FollowListPage(initialTab: 1)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '已关注').first);
    await tester.pumpAndSettle();
    expect(find.text('已取消关注'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '已关注'), findsNothing);
    expect(find.widgetWithText(FilledButton, '关注'), findsOneWidget);
  });

  testWidgets('double tap sends one private message', (tester) async {
    final pending = Completer<http.Response>();
    var sends = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('dm-send')) {
        sends++;
        return pending.future;
      }
      return response({'list': [], 'items': []});
    }));
    LKApi.client.session
      ..securityKey = 'audit'
      ..uid = 10;
    await tester.pumpWidget(
        const MaterialApp(home: DMChatPage(peerUid: 20, peerName: 'Audit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'local mock only');
    await tester.tap(find.text('发送'));
    await tester.tap(find.text('发送'));
    await tester.pump();
    expect(sends, 1);
    await tester.enterText(find.byType(TextField), 'next draft');
    pending.complete(response({}));
    await tester.pumpAndSettle();
    expect(find.text('next draft'), findsOneWidget);
  });

  testWidgets('failed follow pagination waits for explicit retry',
      (tester) async {
    var failedRequests = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path.endsWith('user-following-v1')) {
        if (body['page'] == 1) {
          return response({
            'items': [
              {'uid': 20, 'nickname': 'AuditUser'}
            ],
            'total': 2,
            'has_more': true
          });
        }
        failedRequests++;
        return http.Response('error', 500);
      }
      return response({'items': [], 'total': 0, 'has_more': false});
    }));
    LKApi.client.session
      ..securityKey = 'audit'
      ..uid = 10;
    await tester.pumpWidget(const MaterialApp(home: FollowListPage()));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(failedRequests, 1);
    await tester.tap(find.text('加载失败，点击重试'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(failedRequests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('failed all-device logout preserves the local session', () async {
    LKApi.client = LKClient.forTesting(
        httpClient: MockClient((_) async => http.Response('unavailable', 500)));
    LKApi.client.session
      ..securityKey = 'audit'
      ..uid = 10;
    await expectLater(
        LKApi.logout(allDevices: true), throwsA(isA<LKException>()));
    expect(LKApi.client.session.isLoggedIn, isTrue);
  });

  for (final type in ['book', 'volume', 'dynamic']) {
    testWidgets('double tap publishes one $type comment', (tester) async {
      final pending = Completer<http.Response>();
      var publishes = 0;
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        if (request.url.path.contains('publish') &&
            request.url.path.contains('comment')) {
          publishes++;
          return pending.future;
        }
        return response(
            {'list': [], 'items': [], 'groups': [], 'has_more': false});
      }));
      LKApi.client.session
        ..securityKey = 'audit'
        ..uid = 10;
      await tester.pumpWidget(MaterialApp(
          home: CommentsPage(
              bookId: 1,
              bookTitle: 'Audit',
              volumeId: type == 'volume' ? 2 : 0,
              dynamicId: type == 'dynamic' ? 3 : 0)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'local mock only');
      await tester.tap(find.text('发布'));
      await tester.tap(find.text('发布'));
      await tester.pump();
      expect(publishes, 1);
      await tester.enterText(find.byType(TextField), 'next draft');
      pending.complete(response({}));
      await tester.pumpAndSettle();
      expect(find.text('next draft'), findsOneWidget);
    });
  }

  testWidgets('emoji panel fits landscape viewport', (tester) async {
    tester.view.physicalSize = const Size(800, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('emoji')) {
        return response({
          'list': [
            {
              'name': 'Audit',
              'items': [
                {'code': ':)'}
              ]
            }
          ]
        });
      }
      return response({'items': [], 'has_more': false});
    }));
    await tester.pumpWidget(const MaterialApp(home: CommentsPage(bookId: 1)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle();
    final error = tester.takeException();
    expect(error, isNull);
  });

  testWidgets('medal tabs fit a small viewport with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    LKApi.client =
        LKClient.forTesting(httpClient: MockClient((_) async => response({})));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!),
      home: const MedalShopPage(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '兑换勋章'));
    await tester.pumpAndSettle();
    final error = tester.takeException();
    expect(error, isNull);
  });

  testWidgets('account-only data disappears when the session expires',
      (tester) async {
    LKApi.client = LKClient.forTesting(
        httpClient: MockClient((_) async => response({
              'items': [
                {'uid': 20, 'nickname': 'OldAccountFollow'}
              ],
              'has_more': false,
            })));
    await tester.pumpWidget(const MaterialApp(home: FollowListPage()));
    await tester.pumpAndSettle();
    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    await tester.pump();
    expect(find.text('OldAccountFollow'), findsNothing);
    expect(find.text('登录后才能查看关注与粉丝'), findsOneWidget);
  });
  testWidgets('coin records pagination failure also waits for explicit retry',
      (tester) async {
    var attempts = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['page'] == 1) {
        return response({
          'items': [
            {'title': 'mock reward', 'amount': 2}
          ],
          'has_more': true
        });
      }
      attempts++;
      return http.Response('unavailable', 500);
    }));
    await tester.pumpWidget(const MaterialApp(home: WelfareCoinRecordsPage()));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(attempts, 1);
    await tester.tap(find.text('加载失败，点击重试'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(attempts, 2);
  });

  for (final entry in <String, Widget>{
    '消息中心': const MessagesPage(),
    '私信': const DMChatPage(peerUid: 20, peerName: 'Peer'),
    '轻币记录': const WelfareCoinRecordsPage(),
    '勋章中心': const MedalCenterPage(),
    '勋章商城': const MedalShopPage(),
  }.entries) {
    testWidgets('${entry.key} ignores late responses from an expired session',
        (tester) async {
      final pending = Completer<http.Response>();
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((_) => pending.future));
      await tester.pumpWidget(MaterialApp(home: entry.value));
      await tester.pump();
      LKClient.shared.session.clear();
      LKClient.sessionRev.value++;
      await tester.pump();
      pending.complete(response({'items': [], 'list': []}));
      await tester.pumpAndSettle();
      expect(find.text('登录后才能查看${entry.key}'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('my_medals_cache_10'), isFalse);
    });
  }

  testWidgets('medal refresh preserves exchange tab, scroll and lazy rendering',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0;
    final data = {
      'exchange_medals': List.generate(
          100,
          (index) =>
              {'medal_id': index + 1, 'name': 'Medal $index', 'price': 10})
    };
    LKApi.client = LKClient.forTesting(httpClient: MockClient((_) async {
      requests++;
      if (requests == 1) return response(data);
      return pending.future;
    }));
    await tester.pumpWidget(const MaterialApp(home: MedalShopPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '兑换勋章'));
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey('medal-shop-false'));
    await tester.drag(list, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Medal 99'), findsNothing);
    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first);
    final offset = scrollable.position.pixels;
    final refresh = tester
        .widget<MotionRefreshIndicator>(
            find.byType(MotionRefreshIndicator).last)
        .onRefresh();
    await tester.pump();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(scrollable.position.pixels, offset);
    pending.complete(response(data));
    await tester.pumpAndSettle();
    await refresh;
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(scrollable.position.pixels, offset);
    expect(tester.takeException(), isNull);
  });

  test(
      'local logout makes no server request; a late logout cannot clear a new account',
      () async {
    var requests = 0;
    final pending = Completer<http.Response>();
    LKApi.client = LKClient.forTesting(httpClient: MockClient((_) {
      requests++;
      return pending.future;
    }));
    LKApi.client.session
      ..uid = 10
      ..securityKey = 'old';
    await LKApi.logout(allDevices: false);
    expect(requests, 0);
    expect(LKApi.client.session.isLoggedIn, isFalse);
    LKApi.client.session
      ..uid = 10
      ..securityKey = 'old';
    final logout = LKApi.logout(allDevices: true);
    LKApi.client.session
      ..uid = 20
      ..securityKey = 'new';
    pending.complete(response({}));
    await logout;
    expect(requests, 1);
    expect(LKApi.client.session.uid, 20);
    expect(LKApi.client.session.securityKey, 'new');
  });
}
