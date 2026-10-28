import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/comments_page.dart';
import 'package:yomiru/pages/home_book_actions.dart';
import 'package:yomiru/pages/home_page.dart';
import 'package:yomiru/widgets/common.dart';

http.Response response(Object data) =>
    http.Response(jsonEncode({'code': 0, 'data': data}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    LKStore.hideBraveBooks.value = false;
    LKStore.gridColumnCount.value = 2;
  });
  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
  });

  for (final listMode in [false, true]) {
    testWidgets(
        'home ${listMode ? 'list' : 'grid'} long press uses local shelf and preserves tap',
        (tester) async {
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        if (request.url.path.endsWith('home-recent-updates-feed-v1')) {
          return response({
            'list': [
              {'book_id': 42, 'title': '测试书籍'}
            ]
          });
        }
        return response({'list': []});
      }));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FeedTab(
                  channelCode: 'recent',
                  path: '/api/bff/home-recent-updates-feed-v1',
                  listMode: listMode))));
      await tester.pumpAndSettle();
      final card = find.byType(listMode ? BookCard : BookGridCard);
      expect(card, findsOneWidget);
      await tester.longPress(card);
      await tester.pumpAndSettle();
      expect(find.text('加入书架'), findsOneWidget);
      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();
      expect((await LKStore.localShelf()).map((b) => b.bookId), [42]);
      expect(find.text('已加入书架'), findsWidgets);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('recommended book long press targets recommendation',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final isPromo = request.url.path.endsWith('home-promo-v1');
      final title = isPromo ? '推荐作品' : '信息流作品';
      final id = isPromo ? 71 : 72;
      return response({
        'list': [
          {'book_id': id, 'title': title}
        ],
        'has_more': false,
      });
    }));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FeedTab(
                channelCode: 'hot',
                path: '/api/bff/home-feed-v1',
                listMode: false))));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('推荐作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle();
    expect((await LKStore.localShelf()).single.bookId, 71);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('review route carries selected book identity', (tester) async {
    LKApi.client = LKClient.forTesting(
        httpClient: MockClient((_) async => response({'list': []})));
    final book =
        LKBook(bookId: 99, title: '目标书籍', authorName: '', coverUrl: '');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showHomeBookActions(context, book),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看书评'));
    await tester.pumpAndSettle();
    final page = tester.widget<CommentsPage>(find.byType(CommentsPage));
    expect(page.bookId, 99);
    expect(page.bookTitle, '目标书籍');
    Navigator.pop(tester.element(find.byType(CommentsPage)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'cloud error retries and concurrent reopen does not duplicate add',
      (tester) async {
    LKClient.shared.session.securityKey = 'test';
    var calls = 0;
    var inShelf = false;
    var failLoad = true;
    final add = Completer<void>();
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('get-book-library-state')) {
        if (failLoad) {
          failLoad = false;
          return http.Response('offline', 500);
        }
        return response({'in_shelf': inShelf ? 'true' : 0});
      }
      if (request.url.path.endsWith('toggle-book-shelf')) {
        calls++;
        expect(jsonDecode(request.body)['book_id'], 81);
        await add.future;
        inShelf = true;
        return response({});
      }
      return response({'list': []});
    }));
    final book =
        LKBook(bookId: 81, title: '云端书籍', authorName: '', coverUrl: '');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showHomeBookActions(context, book),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入书架'));
    await tester.pump();
    expect(calls, 1);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(calls, 1);
    add.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已加入书架'), findsOneWidget);
    expect(calls, 1);
    expect((await LKStore.localShelf()).single.bookId, 81);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
