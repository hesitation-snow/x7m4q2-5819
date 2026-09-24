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
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = true;
    LKStore.epubDownloadEnabled.value = false;
  });
  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = false;
    LKStore.epubDownloadEnabled.value = false;
  });

  Future<void> pumpBook(WidgetTester tester,
      {required List<String> tags,
      required bool completed,
      ThemeData? theme}) async {
    final book = {
      'book_id': 42,
      'title': '测试作品',
      'summary': '这是一段用于检查阅读对比度的书籍简介。',
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
    await tester.pumpWidget(
        MaterialApp(theme: theme, home: const BookDetailPage(bookId: 42)));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    testWidgets('book summary is readable in $brightness', (tester) async {
      final scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFF5C6BC0), brightness: brightness);
      final background = brightness == Brightness.dark
          ? const Color(0xFF121316)
          : const Color(0xFFF6F7FB);
      await pumpBook(tester,
          tags: [],
          completed: false,
          theme: ThemeData(
              colorScheme: scheme,
              scaffoldBackgroundColor: background));
      final summary = tester.widget<Text>(
          find.text('这是一段用于检查阅读对比度的书籍简介。'));
      expect(summary.style!.color, scheme.onSurfaceVariant);
      final foregroundLuminance = summary.style!.color!.computeLuminance();
      final backgroundLuminance = background.computeLuminance();
      final contrast = foregroundLuminance > backgroundLuminance
          ? (foregroundLuminance + 0.05) / (backgroundLuminance + 0.05)
          : (backgroundLuminance + 0.05) / (foregroundLuminance + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    });
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

  for (final loggedIn in [false, true]) {
    testWidgets('book export menu ${loggedIn ? 'shows' : 'hides'} by login',
        (tester) async {
      LKStore.epubDownloadEnabled.value = true;
      if (loggedIn) {
        LKClient.shared.session
          ..securityKey = 'test-session'
          ..uid = 42;
      }
      await pumpBook(tester, tags: const [], completed: false);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('分享书籍'), findsOneWidget);
      expect(find.text('书籍导出'), loggedIn ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
