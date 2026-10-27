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
        expect(find.byType(ChoiceChip), findsNothing);
        if (embedded) {
          expect(find.text('书架'), findsOneWidget);
          final titleRect = tester.getRect(find.text('书架'));
          final sourceRect =
              tester.getRect(find.widgetWithText(TextButton, '本机书架'));
          expect(sourceRect.left, greaterThan(titleRect.right));
          final actionsRect = tester
              .getRect(find.byKey(const ValueKey('shelf-toolbar-actions')));
          final viewportWidth =
              tester.view.physicalSize.width / tester.view.devicePixelRatio;
          expect(viewportWidth - actionsRect.right, lessThanOrEqualTo(16));
        }
        await tester.tap(find.byTooltip('筛选与排序'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(PopupMenuItem<String>, '有更新'));
        await tester.pumpAndSettle();
        expect(find.text('1 部作品 · 默认顺序'), findsOneWidget);
        expect(find.byKey(const ValueKey('shelf-book-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('shelf-book-1')), findsNothing);
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
        'updated_at': '2026-05-06 12:34:56',
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
      addTearDown(() => LKApi.client = LKClient.shared);
      await pumpPage(tester, const BookDetailPage(bookId: 42), brightness);
      final publisher = find.byKey(const ValueKey('book-publisher-row'));
      expect(publisher, findsOneWidget);
      final publisherGap = find.byKey(const ValueKey('publisher-row-gap'));
      expect(publisherGap, findsOneWidget);
      expect(tester.getSize(publisherGap).height, 12);
      final publisherName =
          find.descendant(of: publisher, matching: find.text('发布者名称'));
      expect(publisherName, findsOneWidget);
      expect(
          find.descendant(of: publisher, matching: find.textContaining('UID')),
          findsNothing);
      expect(
          find.descendant(
              of: publisher,
              matching: find.byKey(const ValueKey('publisher-medals'))),
          findsNothing);
      final updateText = find.descendant(
          of: publisher, matching: find.text('2026-05-06 12:34'));
      expect(updateText, findsOneWidget);
      expect(
          find.descendant(of: publisher, matching: find.textContaining('最后更新')),
          findsNothing);
      final avatar = tester.getRect(find.descendant(
          of: publisher, matching: find.byType(CircleAvatar).first));
      final nameRect = tester.getRect(publisherName);
      final updateRect = tester.getRect(updateText);
      final follow = tester
          .getRect(find.descendant(of: publisher, matching: find.text('关注')));
      expect(updateRect.left - avatar.right, greaterThanOrEqualTo(8));
      expect(updateRect.top, greaterThan(nameRect.bottom));
      expect(follow.left - nameRect.right, greaterThanOrEqualTo(8));

      final action = find.byKey(const ValueKey('primary-reading-action'));
      final actionVisibility =
          find.byKey(const ValueKey('reading-action-visibility'));
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.widget<FloatingActionButton>(action).onPressed, isNotNull);
      expect(tester.widget<IgnorePointer>(actionVisibility).ignoring, isFalse);
      final detailScaffold = tester.widget<Scaffold>(
          find.ancestor(of: action, matching: find.byType(Scaffold).first));
      expect(detailScaffold.floatingActionButtonAnimator,
          same(FloatingActionButtonAnimator.noAnimation));
      expect(find.ancestor(of: action, matching: find.byType(AnimatedSlide)),
          findsOneWidget);
      expect(find.ancestor(of: action, matching: find.byType(AnimatedOpacity)),
          findsOneWidget);
      expect(
          tester
              .widget<AnimatedOpacity>(find.ancestor(
                  of: action, matching: find.byType(AnimatedOpacity)))
              .opacity,
          1);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -320));
      await tester.pump();
      expect(tester.widget<IgnorePointer>(actionVisibility).ignoring, isTrue);
      final slide =
          find.ancestor(of: action, matching: find.byType(AnimatedSlide));
      final fade =
          find.ancestor(of: action, matching: find.byType(AnimatedOpacity));
      expect(tester.widget<AnimatedSlide>(slide).offset, const Offset(0, 2));
      expect(tester.widget<AnimatedOpacity>(fade).opacity, 0);
      expect(action, findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
      await tester.pump();
      expect(tester.widget<IgnorePointer>(actionVisibility).ignoring, isFalse);
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.takeException(), isNull);
    });
  }
}
