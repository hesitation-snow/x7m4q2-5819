import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/comments_page.dart';

void main() {
  var comments = <Map<String, Object>>[];
  setUp(() {
    comments = [];
    SharedPreferences.setMockInitialValues({});
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final data = request.url.path.contains('comment-emoji-list')
          ? {
              'list': [
                {
                  'name': '测试表情',
                  'items': [
                    {'code': '😀'}
                  ]
                }
              ]
            }
          : request.url.path.contains('get-book-comments')
              ? {'list': comments, 'has_more': false}
              : <String, Object>{};
      return http.Response.bytes(
          utf8.encode(jsonEncode({'code': 0, 'data': data})), 200,
          headers: {'content-type': 'application/json'});
    }));
  });
  tearDown(() => LKApi.client = LKClient.shared);

  Future<void> openPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      home: const CommentsPage(bookId: 1),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('blank tap closes keyboard and preserves draft', (tester) async {
    await openPage(tester);
    await tester.enterText(find.byType(TextField), '草稿');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue);
    await tester.tapAt(const Offset(760, 450));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse);
    expect(find.text('草稿'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('emoji selection, blank dismissal and keyboard transition',
      (tester) async {
    await openPage(tester);
    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle();
    expect(find.text('测试表情'), findsOneWidget);
    await tester.tap(find.text('😀'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '😀');
    expect(find.text('测试表情'), findsOneWidget);
    await tester.tapAt(const Offset(760, 200));
    await tester.pump();
    expect(find.text('测试表情'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '😀');
    await tester.tap(find.byTooltip('表情'));
    await tester.pump();
    await tester.tap(find.byTooltip('键盘'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue);
    await tester.tapAt(const Offset(760, 200));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reply and scrolling remain interactive while panel is open',
      (tester) async {
    comments = List.generate(
        18,
        (i) => {
              'comment_id': i + 1,
              'nickname': '用户$i',
              'content': '评论$i',
              'avatar': ''
            });
    await openPage(tester);
    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回复').first);
    await tester.pump();
    expect(find.text('回复 @用户0'), findsOneWidget);
    expect(find.text('测试表情'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('测试表情'), findsOneWidget);
    expect(find.text('评论0'), findsNothing);
    await tester.tap(find.byTooltip('取消回复'));
    await tester.pump();
    expect(find.text('回复 @用户0'), findsNothing);
    expect(find.text('测试表情'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
