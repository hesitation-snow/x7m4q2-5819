import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/channel_page.dart';
import 'package:yomiru/widgets/filtered_list_continuation.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
    LKStore.hideBraveBooks.value = true;
  });
  tearDown(() {
    LKApi.client = LKClient.shared;
    LKStore.dataSaverMode.value = false;
    LKStore.hideBraveBooks.value = false;
  });

  testWidgets('fully hidden first page still fetches the next visible book',
      (tester) async {
    final pages = <int>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final page = (jsonDecode(request.body) as Map)['page'] as int;
      pages.add(page);
      final books = page == 1
          ? List.generate(
              20,
              (i) => {
                    'book_id': 20000 + i,
                    'title': 'restricted $i',
                    'is_brave': 1,
                  })
          : [
              {'book_id': 22222, 'title': 'Visible second page', 'is_brave': 0}
            ];
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'list': books}
          }),
          200,
          headers: {'content-type': 'application/json'});
    }));
    await tester.pumpWidget(const MaterialApp(
        home: ChannelPage(
      path: '/api/bff/home-feed-v1',
      label: 'test',
    )));
    await tester.pumpAndSettle();
    expect(pages, [1, 2]);
    expect(find.text('Visible second page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'consecutive filtered pages are bounded and retain manual continuation',
      (tester) async {
    var page = 1;
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, setState) => FilteredListContinuation(
        message: 'filtered',
        hasMore: true,
        loading: false,
        pageKey: page,
        onLoadMore: () {
          setState(() {
            calls++;
            page++;
          });
        },
      ),
    ))));
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.tap(find.text('继续加载'));
    await tester.pumpAndSettle();
    expect(calls, 3);
  });

  testWidgets('network errors stop automatic retry and retain retry control',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FilteredListContinuation(
      message: 'filtered',
      hasMore: true,
      loading: false,
      pageKey: 1,
      error: 'offline',
      onLoadMore: () => calls++,
    ))));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.text('加载失败，点击重试'));
    expect(calls, 1);
  });
}
