import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/book_detail_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
  });
  tearDown(() {
    LKApi.client = LKClient.shared;
    LKStore.dataSaverMode.value = false;
  });

  Future<void> pumpBook(WidgetTester tester,
      {required List<String> tags, required bool completed}) async {
    final book = {
      'book_id': 42,
      'title': '测试作品',
      'tags': tags,
      'is_completed': completed,
    };
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final data = request.url.path.endsWith('/reader-bootstrap-v1')
          ? <String, dynamic>{'book': book}
          : request.url.path.endsWith('/get-book-detail')
              ? book
              : <String, dynamic>{'list': []};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester
        .pumpWidget(const MaterialApp(home: BookDetailPage(bookId: 42)));
    await tester.pumpAndSettle();
  }

  for (final completed in [false, true]) {
    testWidgets('original badge sits with ${completed ? '完结' : '连载'}',
        (tester) async {
      await pumpBook(tester, tags: ['奇幻', '原创'], completed: completed);

      final status = find.text(completed ? '完结' : '连载');
      final statusLine = find.ancestor(
        of: status,
        matching: find.byType(Wrap),
      );
      expect(statusLine, findsOneWidget);
      final original = find.descendant(
        of: statusLine,
        matching: find.text('原创'),
      );
      expect(original, findsOneWidget);
      expect(tester.getTopLeft(original).dy, tester.getTopLeft(status).dy);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('books without the original tag have no original badge',
      (tester) async {
    await pumpBook(tester, tags: ['奇幻'], completed: false);
    expect(find.text('连载'), findsOneWidget);
    expect(find.text('原创'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
