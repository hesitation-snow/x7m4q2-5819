import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/epub_catalog.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/search_page.dart';

http.Response response(Object data) =>
    http.Response(jsonEncode({'code': 0, 'data': data}), 200,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> books(String title,
        {int count = 1, bool brave = false, int startId = 1000}) =>
    {
      'list': List.generate(
          count,
          (i) => {
                'book_id': startId + i,
                'title': '$title $i',
                'is_brave': brave ? 1 : 0,
              })
    };

final taxonomy = {
  'channels': [
    {'code': 'original', 'label': '原创'}
  ],
  'tabs': [
    {
      'groups': [
        {
          'sections': [
            {
              'tag_items': [
                {'title': '奇幻', 'jump_type': 'tag', 'jump_value': 'fantasy'},
                {
                  'title': '最近更新',
                  'jump_type': 'keyword',
                  'jump_value': 'recent'
                }
              ]
            }
          ]
        }
      ]
    }
  ]
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
    LKStore.hideBraveBooks.value = false;
  });
  tearDown(() {
    LKApi.client = LKClient.shared;
    EpubCatalog.reset();
    LKStore.dataSaverMode.value = false;
    LKStore.hideBraveBooks.value = false;
  });

  Future<void> submit(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
  }

  testWidgets(
      'switching criteria clears old results and ignores out-of-order responses',
      (tester) async {
    final calls = <Map<String, dynamic>>[];
    final pending = <Completer<http.Response>>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) {
      if (request.url.path.contains('taxonomy')) {
        return Future.value(response(taxonomy));
      }
      calls.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      final c = Completer<http.Response>();
      pending.add(c);
      return c.future;
    }));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();
    await submit(tester, 'first');
    pending[0].complete(response(books('old')));
    await tester.pumpAndSettle();
    expect(find.text('old 0'), findsOneWidget);
    await tester.tap(find.text('奇幻'));
    await tester.pump();
    expect(find.text('old 0'), findsNothing);
    expect(calls[1]['primary_tag'], 'fantasy');
    await tester.tap(find.text('最新'));
    await tester.pump();
    expect(calls[2]['sort'], 'new');
    pending[2].complete(response(books('new')));
    await tester.pumpAndSettle();
    pending[1].complete(response(books('late')));
    await tester.pumpAndSettle();
    expect(find.text('new 0'), findsOneWidget);
    expect(find.text('late 0'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('clearing the query invalidates in-flight search',
      (tester) async {
    final pending = Completer<http.Response>();
    LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) =>
            request.url.path.contains('taxonomy')
                ? Future.value(response(taxonomy))
                : pending.future));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();
    await submit(tester, 'query');
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('输入关键词,或选择标签 / 分类 / 更新时间'), findsOneWidget);
    pending.complete(response(books('late')));
    await tester.pumpAndSettle();
    expect(find.text('late 0'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed replacement never shows the previous results',
      (tester) async {
    var calls = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('taxonomy')) return response(taxonomy);
      calls++;
      if (calls == 1) return response(books('previous'));
      return http.Response(
          jsonEncode({'code': 123, 'message': 'offline'}), 200);
    }));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();
    await submit(tester, 'first');
    await tester.pumpAndSettle();
    expect(find.text('previous 0'), findsOneWidget);
    await submit(tester, 'second');
    await tester.pumpAndSettle();
    expect(find.text('previous 0'), findsNothing);
    expect(find.textContaining('offline'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keyword presets, channels and clearing the last filter',
      (tester) async {
    final calls = <Map<String, dynamic>>[];
    final pending = <Completer<http.Response>>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) {
      if (request.url.path.contains('taxonomy')) {
        return Future.value(response(taxonomy));
      }
      calls.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      final c = Completer<http.Response>();
      pending.add(c);
      return c.future;
    }));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近更新'));
    await tester.pump();
    expect(calls[0]['q'], 'recent');
    expect(calls[0]['preset'], 'recent');
    await tester.tap(find.text('原创'));
    await tester.pump();
    expect(calls[1]['channel_code'], 'original');
    expect(calls[1]['work_type'], 'original');
    expect(calls[1]['preset'], '');
    await tester.tap(find.text('全部'));
    await tester.pump();
    expect(find.text('输入关键词,或选择标签 / 分类 / 更新时间'), findsOneWidget);
    pending[0].complete(response(books('preset late')));
    pending[1].complete(response(books('channel late')));
    await tester.pumpAndSettle();
    expect(find.text('preset late 0'), findsNothing);
    expect(find.text('channel late 0'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('EPUB uses the catalog feed instead of the empty work-type filter',
      (tester) async {
    final paths = <String>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path.contains('taxonomy')) {
        return response({
          ...taxonomy,
          'channels': [
            {'code': 'original', 'label': '原创'},
            {'code': 'epub', 'label': 'EPUB'},
          ],
        });
      }
      if (request.url.path.contains('home-epub-feed')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final page = body['page'];
        final size = body['pageSize'];
        if (page == 1 && size == 20) {
          return response(books('目录', count: 1, startId: 31634));
        }
        if (page == 1) {
          return response({
            'list': [
              {'book_id': 1, 'title': '普通轻小说'},
              {'book_id': 31634, 'title': '魔法师的隐遁计划', 'author_name': 'イズシロ'},
            ],
          });
        }
        return response({'list': const []});
      }
      return response(books('搜索接口不该被调用'));
    }));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EPUB'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('目录 0'), findsOneWidget);
    expect(paths.where((path) => path.contains('apk-search-result')), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('EPUB keyword search reads the catalog instead of work_type=epub',
      (tester) async {
    EpubCatalog.reset();
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      expect(request.url.path, contains('home-epub-feed'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['page'] == 1) {
        return response({
          'list': [
            {'book_id': 1, 'title': '普通轻小说'},
            {
              'book_id': 31634,
              'title': '魔法师的隐遁计划',
              'author_name': 'イズシロ'
            },
          ],
        });
      }
      return response({'list': const []});
    }));
    await EpubCatalog.collect(20, (book) => epubBookMatches(book, '隐遁'));
    final matched =
        EpubCatalog.books.where((book) => epubBookMatches(book, '隐遁'));
    expect(matched.map((book) => book.bookId), [31634]);
    expect(epubBookMatches(EpubCatalog.books.first, '隐遁'), isFalse);
  });

  testWidgets('refresh starts immediately and cannot overwrite a newer search',
      (tester) async {
    final calls = <Map<String, dynamic>>[];
    final pending = <Completer<http.Response>>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) {
      if (request.url.path.contains('taxonomy')) {
        return Future.value(response(taxonomy));
      }
      calls.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      final c = Completer<http.Response>();
      pending.add(c);
      return c.future;
    }));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();
    await submit(tester, 'first');
    pending[0].complete(response(books('old')));
    await tester.pumpAndSettle();
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(calls[1]['q'], 'first');
    expect(find.text('old 0'), findsNothing);
    await submit(tester, 'second');
    pending[2].complete(response(books('new')));
    await tester.pumpAndSettle();
    pending[1].complete(response(books('refresh late')));
    await refresh;
    await tester.pumpAndSettle();
    expect(find.text('new 0'), findsOneWidget);
    expect(find.text('refresh late 0'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'pagination uses submitted snapshot and retry preserves first page',
      (tester) async {
    LKStore.hideBraveBooks.value = true;
    final calls = <Map<String, dynamic>>[];
    final first = Completer<http.Response>();
    var pageAttempts = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('taxonomy')) return response(taxonomy);
      final data = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      calls.add(data);
      if (data['page'] == 0) return first.future;
      pageAttempts++;
      if (pageAttempts == 1) {
        return http.Response(
            jsonEncode({'code': 123, 'message': 'offline'}), 200);
      }
      return response(books('second', startId: 2000));
    }));
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));
    await tester.pumpAndSettle();
    await submit(tester, 'committed');
    await tester.enterText(find.byType(TextField), 'draft');
    first.complete(response(books('hidden', count: 20, brave: true)));
    await tester.pumpAndSettle();
    expect(calls.map((e) => e['q']), ['committed', 'committed']);
    expect(calls.map((e) => e['page']), [0, 1]);
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(calls.last['q'], 'committed');
    expect(calls.last['page'], 1);
    expect(find.text('second 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
