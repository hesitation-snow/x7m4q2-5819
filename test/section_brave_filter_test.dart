import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/home_page.dart';
import 'package:yomiru/services/book_access_probe.dart';
import 'support/book_image_test_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final images = BookImageTestSandbox();
  setUpAll(images.open);
  tearDownAll(images.close);

  testWidgets(
      'section previews filter cached flags and later chapter evidence without changing blur',
      (tester) async {
    const path = '/api/bff/home-lightnovel-feed-v1';
    final books = [
      {'book_id': 950001, 'title': '已确认勇者作品', 'is_brave': 1},
      {'book_id': 950002, 'title': '后续识别作品'},
      {'book_id': 950003, 'title': '普通预览作品', 'access_type': 'public'},
    ];
    SharedPreferences.setMockInitialValues(
        {'section_latest_$path': jsonEncode(books)});
    LKStore.resetBraveBookIdsForTesting({});
    LKStore.hideBraveBooks.value = true;
    LKStore.coverBlurMode.value = CoverBlurMode.none;
    LKStore.dataSaverMode.value = false;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final Map<String, dynamic> data;
      if (request.url.path.endsWith('home-lightnovel-feed-v1')) {
        data = {'list': books};
      } else if (request.url.path.endsWith('get-volume-chapters')) {
        data = {
          'list': [
            {'chapter_id': 1, 'access_type': ' Brave '}
          ]
        };
      } else if (request.url.path.endsWith('get-book-detail')) {
        data = {'book_id': (jsonDecode(request.body) as Map)['book_id']};
      } else {
        data = {'list': []};
      }
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    try {
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: SectionTab())));
      await tester.pumpAndSettle();
      expect(find.text('已确认勇者作品'), findsNothing);
      expect(find.text('后续识别作品'), findsOneWidget);
      expect(find.text('普通预览作品'), findsOneWidget);
      await tester.runAsync(() => LKApi.chapterPage(950002, 1, 1));
      await tester.pumpAndSettle();
      expect(find.text('后续识别作品'), findsNothing);
      expect(find.text('普通预览作品'), findsOneWidget);
      await LKStore.setHideBraveBooks(false);
      await tester.pumpAndSettle();
      expect(find.text('已确认勇者作品'), findsOneWidget);
      expect(find.text('后续识别作品'), findsOneWidget);
      expect(LKStore.coverBlurMode.value, CoverBlurMode.none);
      final prefs = await SharedPreferences.getInstance();
      final cached =
          jsonDecode(prefs.getString('section_latest_$path')!) as List;
      expect((cached.first as Map)['is_brave'], 1);
      expect((cached.first as Map)['book_access_state'], 'brave');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() => BookAccessProbe.shared.whenIdle);
      LKApi.client = LKClient.shared;
      LKStore.hideBraveBooks.value = true;
      LKStore.coverBlurMode.value = CoverBlurMode.brave;
    }
  });
}
