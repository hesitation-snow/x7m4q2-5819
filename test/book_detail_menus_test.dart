import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/epub_maker_page.dart';
import 'package:yomiru/pages/book_detail_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    LKApi.client = LKClient.shared;
  });
  testWidgets('export action opens maker without changing action semantics',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
    LKStore.epubDownloadEnabled.value = true;
    LKClient.shared.session
      ..securityKey = 'test-session'
      ..uid = 42;
    addTearDown(() {
      LKStore.dataSaverMode.value = false;
      LKStore.epubDownloadEnabled.value = false;
      LKClient.shared.session.clear();
    });
    final book = {'book_id': 42, 'title': '操作测试', 'summary': ''};
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final data = request.url.path.endsWith('/reader-bootstrap-v1')
          ? {'book': book}
          : request.url.path.endsWith('/get-book-detail')
              ? book
              : {'list': []};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester
        .pumpWidget(const MaterialApp(home: BookDetailPage(bookId: 42)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('分享书籍'), findsOneWidget);
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'success';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.tap(find.text('分享书籍'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(
        calls.single.arguments['text'], 'https://www.lightnovel.fun/reader/42');
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书籍导出'));
    await tester.pumpAndSettle();
    expect(find.byType(EpubMakerPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
        'volume menu selects and handles long names, narrow large text $brightness',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final requests = <Uri>[];
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'list': [], 'total': 0}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }));
      tester.view.physicalSize = const Size(280, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const longName = '非常非常长的分卷名称用于验证窄屏大字体时不会产生横向溢出并保留完整语义';
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.indigo, brightness: brightness)),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!),
        home: ChaptersPage(
            bookId: 42,
            volumeId: 1,
            volumeTitle: '第一卷',
            bookTitle: '测试书籍',
            volumes: [
              LKVolume(volumeId: 1, title: '第一卷', chapterCount: 0),
              LKVolume(volumeId: 2, title: longName, chapterCount: 123),
            ]),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('切换分卷'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckedPopupMenuItem<int>), findsNothing);
      expect(find.text('123 章'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      final title = tester.widget<Text>(find.text(longName));
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      final before = requests.length;
      await tester.tap(find.text(longName));
      await tester.pumpAndSettle();
      expect(requests.length, greaterThan(before));
      await tester.tap(find.byTooltip('切换分卷'));
      await tester.pumpAndSettle();
      final selected = find.ancestor(
          of: find.text(longName).last, matching: find.byType(Semantics));
      expect(
          selected
              .evaluate()
              .any((e) => (e.widget as Semantics).properties.selected == true),
          isTrue);
      final after = requests.length;
      await tester.tap(find.text(longName).last);
      await tester.pumpAndSettle();
      expect(requests.length, after);
      expect(tester.takeException(), isNull);
    });
  }
}
