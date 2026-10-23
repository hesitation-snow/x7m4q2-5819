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
import 'package:yomiru/pages/book_detail_page.dart';
import 'package:yomiru/pages/shelf_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = true;
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = false;
  });

  Future<void> pumpPage(WidgetTester tester, Widget page, Brightness brightness,
      {double height = 700}) async {
    tester.view.physicalSize = Size(320, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal, brightness: brightness),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: page,
    ));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final embedded in [false, true]) {
      testWidgets(
          'shelf quick filters work at 2x $brightness embedded=$embedded',
          (tester) async {
        await LKStore.setLocalShelf(
            LKBook(bookId: 1, title: '已读作品', serialStatus: 'completed'), true);
        await LKStore.setLocalShelf(
            LKBook(bookId: 2, title: '更新作品', unreadChapterCount: 3), true);
        final page = ShelfPage(embedded: embedded, listMode: true);
        await pumpPage(
            tester,
            embedded ? Scaffold(body: SafeArea(child: page)) : page,
            brightness);
        expect(find.text('2 部作品 · 默认顺序'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, '有更新'));
        await tester.pumpAndSettle();
        expect(find.text('1 部作品 · 默认顺序'), findsOneWidget);
        expect(find.byKey(const ValueKey('shelf-book-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('shelf-book-1')), findsNothing);
        final selected =
            tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '有更新'));
        expect(selected.selected, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('empty shelf fits short screen and large text $brightness',
        (tester) async {
      await pumpPage(tester, const ShelfPage(listMode: true), brightness,
          height: 400);
      expect(find.text('书架还是空的'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('detail keeps reading action visible at 2x $brightness',
        (tester) async {
      final book = {
        'book_id': 42,
        'title': '一部拥有很长标题但应当完整呈现的阅读作品',
        'author_name': '作者名称',
        'publisher_name': '发布者名称',
        'publisher_uid': 88,
        'summary': List.filled(30, '正文简介应保持舒适的行距与主题对比度。').join(),
        'tags': ['奇幻', '一段很长很长的作品分类标签', '原创'],
        'default_chapter_id': 9,
        'default_volume_id': 3,
      };
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        final data = request.url.path.endsWith('/reader-bootstrap-v1')
            ? {'book': book}
            : request.url.path.endsWith('/get-book-detail')
                ? book
                : {'list': []};
        return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }));
      await pumpPage(tester, const BookDetailPage(bookId: 42), brightness);
      final action = find.byKey(const ValueKey('primary-reading-action'));
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
      final before = tester.getRect(action);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.getRect(action), before);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
