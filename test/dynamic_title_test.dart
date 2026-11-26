import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/pages/dynamic_publish_page.dart';

http.Response _jsonOk(Map<String, dynamic> data) => http.Response(
      jsonEncode({'code': 0, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
  });

  tearDown(() {
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
  });

  group('Dynamic title API & UI', () {
    test('publishShortDynamic sends trimmed title separately from summary/content',
        () async {
      final publishBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/api/dynamic/publish-short-post-v1')) {
            publishBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonOk({
              'dynamic': {
                'dynamic_id': 2001,
                'title': '动态标题',
                'summary': '正文内容',
              },
            });
          }
          return _jsonOk({});
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'mock-key';

      final created = await LKApi.publishShortDynamic(
        '正文内容',
        title: '  动态标题  ',
      );
      expect(created.title, '动态标题');
      expect(publishBodies, hasLength(1));
      expect(publishBodies.single['title'], '动态标题');
      expect(publishBodies.single['summary'], '正文内容');
      expect(publishBodies.single['content'], '正文内容');
    });

    test('publishShortDynamic always sends empty string title when omitted',
        () async {
      final publishBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/api/dynamic/publish-short-post-v1')) {
            publishBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonOk({
              'dynamic': {
                'dynamic_id': 2002,
                'title': '',
                'summary': '仅正文',
              },
            });
          }
          return _jsonOk({});
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'mock-key';

      await LKApi.publishShortDynamic('仅正文');
      expect(publishBodies, hasLength(1));
      expect(publishBodies.single.containsKey('title'), isTrue);
      expect(publishBodies.single['title'], '');
      expect(publishBodies.single['summary'], '仅正文');
      expect(publishBodies.single['content'], '仅正文');
    });

    testWidgets(
        'DynamicPublishPage supports optional 48-char title, clear action, and body-only submit',
        (tester) async {
      final publishBodies = <Map<String, dynamic>>[];
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/api/dynamic/publish-short-post-v1')) {
            publishBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonOk({
              'dynamic': {'dynamic_id': 3001},
            });
          }
          if (request.url.path.endsWith('/api/dynamic/get-topic-tags-v1')) {
            return _jsonOk({'list': const []});
          }
          return _jsonOk({});
        }),
      );
      LKApi.client.session
        ..uid = 42
        ..securityKey = 'mock-key';
      LKClient.shared.session
        ..uid = 42
        ..securityKey = 'mock-key';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<bool>(
                    builder: (_) => const DynamicPublishPage(),
                  ),
                ),
                child: const Text('打开发布页'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开发布页'));
      await tester.pumpAndSettle();

      final titleFinder = find.byKey(const ValueKey('dynamic-title-input'));
      final contentFinder = find.byKey(const ValueKey('dynamic-content-input'));
      expect(titleFinder, findsOneWidget);
      expect(contentFinder, findsOneWidget);
      expect(find.text('好的标题更容易获得支持，选填 20 字'), findsOneWidget);
      expect(find.text('选填'), findsOneWidget);

      final titleField = tester.widget<TextField>(titleFinder);
      final contentField = tester.widget<TextField>(contentFinder);
      expect(titleField.autofocus, isFalse);
      expect(titleField.maxLength, 48);
      expect(contentField.autofocus, isTrue);

      // Only typing title without body must not publish.
      final overLimitTitle = '标' * 55;
      await tester.enterText(titleFinder, overLimitTitle);
      await tester.pump();
      expect(titleField.controller!.text.characters.length, 48);
      expect(find.text('48/48'), findsOneWidget);
      expect(find.byKey(const ValueKey('dynamic-title-clear')), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pump();
      expect(publishBodies, isEmpty);

      // Clear title via clear button, then verify empty-title body-only publish.
      await tester.tap(find.byKey(const ValueKey('dynamic-title-clear')));
      await tester.pump();
      expect(titleField.controller!.text, isEmpty);
      expect(find.text('选填'), findsOneWidget);

      await tester.enterText(contentFinder, '不带标题也能发');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pumpAndSettle();

      expect(publishBodies, hasLength(1));
      expect(publishBodies.single['title'], '');
      expect(publishBodies.single['summary'], '不带标题也能发');
      expect(publishBodies.single['content'], '不带标题也能发');

      // Re-open composer and publish with both title and body.
      await tester.tap(find.text('打开发布页'));
      await tester.pumpAndSettle();
      await tester.enterText(titleFinder, '  周末读书笔记  ');
      await tester.enterText(contentFinder, '这卷节奏很棒');
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '发布'));
      await tester.pumpAndSettle();

      expect(publishBodies, hasLength(2));
      expect(publishBodies.last['title'], '周末读书笔记');
      expect(publishBodies.last['summary'], '这卷节奏很棒');
      expect(publishBodies.last['content'], '这卷节奏很棒');
    });

    testWidgets('DynamicPage renders title above body only when distinct and non-empty',
        (tester) async {
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('get-feed-v1')) {
            return _jsonOk({
              'list': [
                {
                  'dynamic_id': 401,
                  'title': '推荐新番小说',
                  'summary': '第一卷剧情非常精彩。',
                  'topic_tags': const [],
                },
                {
                  'dynamic_id': 402,
                  'title': '',
                  'summary': '没有标题的普通动态。',
                  'topic_tags': const [],
                },
              ],
              'has_more': false,
            });
          }
          return _jsonOk({});
        }),
      );

      await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
      await tester.pumpAndSettle();

      final titleWidget = find.text('推荐新番小说');
      final bodyWidget = find.text('第一卷剧情非常精彩。');
      expect(titleWidget, findsOneWidget);
      expect(bodyWidget, findsOneWidget);
      expect(
        tester.getTopLeft(titleWidget).dy,
        lessThan(tester.getTopLeft(bodyWidget).dy),
      );
      expect(find.text('没有标题的普通动态。'), findsOneWidget);
    });
  });
}
