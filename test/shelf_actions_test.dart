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
import 'package:yomiru/pages/shelf_page.dart';
import 'package:yomiru/widgets/common.dart';

void main() {
  final books = [
    LKBook(
        bookId: 1,
        title: 'Z作品',
        unreadChapterCount: 2,
        serialStatus: 'serializing',
        updatedAt: '2026-01-01'),
    LKBook(
        bookId: 2,
        title: 'A作品',
        serialStatus: 'completed',
        isCompleted: true,
        updatedAt: '2026-02-01'),
  ];
  var removes = 0;
  var fail = false;
  Completer<void>? pending;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = true;
    removes = 0;
    fail = false;
    pending = null;
    for (final book in books.reversed) {
      await LKStore.setLocalShelf(book, true);
    }
  });

  void installMock() {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/toggle-book-shelf')) {
        removes++;
        expect(request.body, contains('remove'));
        if (pending != null) await pending!.future;
        if (fail) {
          return http.Response('{"code":500,"msg":"mock failure"}', 200);
        }
      }
      final data = request.url.path.endsWith('/bookshelf-v1')
          ? {'list': books.map((book) => book.toJson()).toList()}
          : request.url.path.endsWith('/get-book-detail')
              ? books.last.toJson()
              : <String, dynamic>{};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }

  tearDown(() {
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
    LKStore.dataSaverMode.value = false;
  });

  Future<void> pumpShelf(WidgetTester tester,
      {bool cloud = false,
      bool grid = false,
      double scale = 1,
      Brightness brightness = Brightness.light,
      double width = 400}) async {
    installMock();
    if (cloud) {
      LKClient.shared.session.uid = 42;
      LKClient.shared.session.securityKey = 'mock';
      LKApi.client.session.uid = 42;
      LKApi.client.session.securityKey = 'mock';
    }
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo, brightness: brightness)),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: ShelfPage(listMode: !grid),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> confirmSheet(WidgetTester tester) async {
    await tester.longPress(find.text('Z作品').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('从书架移除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不删除阅读记录、正文或下载文件'), findsOneWidget);
  }

  for (final brightness in Brightness.values) {
    testWidgets('sheet close retains local book at 2x $brightness',
        (tester) async {
      await pumpShelf(tester,
          grid: true, scale: 2, width: 320, brightness: brightness);
      tester.view.physicalSize = const Size(320, 400);
      await tester.pumpAndSettle();
      await tester.longPressAt(
          tester.getTopLeft(find.byType(BookGridCard).first) +
              const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect((await LKStore.localShelf()).length, 2);
      expect(removes, 0);
      await tester.longPressAt(
          tester.getTopLeft(find.byType(BookGridCard).first) +
              const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('从书架移除'));
      await tester.tap(find.text('从书架移除'));
      await tester.pumpAndSettle();
      expect(find.text('确认移除'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await LKStore.localShelf()).length, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancel retains local book and reading position', (tester) async {
    await ReaderPrefs.setReadPosFrac(1, .42);
    await pumpShelf(tester);
    await confirmSheet(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('Z作品'), findsOneWidget);
    expect((await LKStore.localShelf()).length, 2);
    expect(await ReaderPrefs.readPosFrac(1), .42);
    expect(removes, 0);
  });

  testWidgets('guest grid removal uses only local store', (tester) async {
    await pumpShelf(tester, grid: true);
    await confirmSheet(tester);
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    expect(find.text('Z作品'), findsNothing);
    expect((await LKStore.localShelf()).map((b) => b.bookId), [2]);
    expect(removes, 0);
  });

  testWidgets('cloud waits for success then updates local mirror and cache',
      (tester) async {
    await pumpShelf(tester, cloud: true);
    pending = Completer<void>();
    await confirmSheet(tester);
    expect(find.textContaining('云端及本机'), findsOneWidget);
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    expect(find.text('Z作品'), findsOneWidget);
    expect(removes, 1);
    await tester.longPress(find.text('Z作品'));
    await tester.pumpAndSettle();
    expect(find.text('从书架移除'), findsNothing);
    pending!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Z作品'), findsNothing);
    expect((await LKStore.localShelf()).map((b) => b.bookId), [2]);
    final cached = await LKStore.cachedBooksPage(
        LKStore.pageCacheKey(kind: 'shelf', uid: 42, variant: 'cloud'));
    expect(cached!.map((b) => b.bookId), [2]);
  });

  testWidgets('cloud failure retains book and permits retry', (tester) async {
    await pumpShelf(tester, cloud: true);
    fail = true;
    await confirmSheet(tester);
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    expect(find.text('Z作品'), findsOneWidget);
    expect((await LKStore.localShelf()).length, 2);
    expect(find.text('移除失败，请重试'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从书架移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    expect(removes, 2);
    expect(find.text('Z作品'), findsNothing);
  });

  testWidgets('logged-in local source does not call cloud removal',
      (tester) async {
    await pumpShelf(tester, cloud: true);
    await tester.tap(find.widgetWithText(TextButton, '云端书架'));
    await tester.pumpAndSettle();
    await confirmSheet(tester);
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    expect(removes, 0);
    expect(find.text('Z作品'), findsNothing);
    expect((await LKStore.localShelf()).map((b) => b.bookId), [2]);
  });

  testWidgets(
      'account change during cloud removal leaves local mirror untouched',
      (tester) async {
    await pumpShelf(tester, cloud: true);
    pending = Completer<void>();
    await confirmSheet(tester);
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    pending!.complete();
    await tester.pumpAndSettle();
    expect((await LKStore.localShelf()).length, 2);
    expect(find.text('Z作品'), findsOneWidget);
  });

  testWidgets('removing a visible book retains list scroll offset',
      (tester) async {
    for (var i = 3; i <= 25; i++) {
      await LKStore.setLocalShelf(LKBook(bookId: i, title: '作品$i'), true);
    }
    await pumpShelf(tester);
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find
        .byWidgetPredicate(
            (widget) => widget is Scrollable && widget.axis == Axis.vertical)
        .first);
    final offset = scrollable.position.pixels;
    final localBooks = await LKStore.localShelf();
    final book = localBooks.firstWhere((book) {
      final finder = find.byKey(ValueKey('shelf-book-${book.bookId}'));
      if (finder.evaluate().isEmpty) return false;
      final rect = tester.getRect(finder);
      return rect.top > 240 && rect.bottom < 700;
    });
    await tester.longPress(find.text(book.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从书架移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认移除'));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, offset);
    expect(await LKStore.isLocalShelf(book.bookId), isFalse);
  });

  testWidgets('filter and sort close menu and retain independent selections',
      (tester) async {
    await pumpShelf(tester);
    await tester.tap(find.byTooltip('筛选与排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按书名'));
    await tester.pumpAndSettle();
    expect(find.text('筛选'), findsNothing);
    expect(tester.getTopLeft(find.text('A作品')).dy,
        lessThan(tester.getTopLeft(find.text('Z作品')).dy));
    await tester.tap(find.byTooltip('筛选与排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '有更新'));
    await tester.pumpAndSettle();
    expect(find.text('A作品'), findsNothing);
    await tester.tap(find.byTooltip('筛选与排序'));
    await tester.pumpAndSettle();
    final selected = tester
        .widgetList<Semantics>(find.descendant(
            of: find.byType(PopupMenuItem<String>),
            matching: find.byType(Semantics)))
        .where((widget) => widget.properties.selected == true);
    expect(selected.length, 2);
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '全部作品'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('A作品')).dy,
        lessThan(tester.getTopLeft(find.text('Z作品')).dy));
  });

  for (final brightness in Brightness.values) {
    testWidgets('menu fits narrow large-text $brightness', (tester) async {
      await pumpShelf(tester,
          width: 320, scale: 2, brightness: brightness, grid: true);
      await tester.tap(find.byTooltip('筛选与排序'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('按书名'));
      await tester.tap(find.text('按书名'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
