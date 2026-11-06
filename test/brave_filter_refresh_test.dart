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
import 'package:yomiru/services/book_access_probe.dart';
import 'support/book_image_test_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final images = BookImageTestSandbox();
  setUpAll(images.open);
  tearDownAll(images.close);
  for (final listMode in [false, true]) {
    for (final hide in [true, false]) {
      testWidgets(
          'two existing lists refresh after later evidence; hide=$hide list=$listMode',
          (tester) async {
        final id = (hide ? 930001 : 930011) + (listMode ? 100 : 0);
        SharedPreferences.setMockInitialValues({'feed_list': listMode});
        LKStore.resetBraveBookIdsForTesting({});
        LKStore.hideBraveBooks.value = hide;
        LKStore.coverBlurMode.value = CoverBlurMode.none;
        LKStore.dataSaverMode.value = false;
        var feedRequests = 0;
        var metadataRequests = 0;
        LKApi.client =
            LKClient.forTesting(httpClient: MockClient((request) async {
          final path = request.url.path;
          final Map<String, dynamic> data;
          if (path.contains('/fixture/')) {
            feedRequests++;
            data = {
              'list': [
                {'book_id': id, 'title': '待识别作品'},
                {'book_id': id + 1, 'title': '普通作品', 'access_type': 'public'},
              ]
            };
          } else if (path.endsWith('get-volume-chapters')) {
            data = {
              'list': [
                {
                  'chapter_id': 99,
                  'meta_json': {'brave_scope': 'brave'},
                  'unlocked': 1
                }
              ]
            };
          } else if (path.endsWith('get-book-detail')) {
            metadataRequests++;
            data = {
              'book_id': id
            }; // Visible book initially has no book-level flag.
          } else {
            data = {'list': []};
          }
          return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
        try {
          await tester.pumpWidget(const MaterialApp(
              home: Scaffold(
                  body: Row(children: [
            Expanded(child: ChannelPage(path: '/fixture/first', label: '列表一')),
            Expanded(child: ChannelPage(path: '/fixture/second', label: '列表二')),
          ]))));
          await tester.pumpAndSettle();
          expect(find.text('待识别作品'), findsNWidgets(2));
          expect(find.text('普通作品'), findsNWidgets(2));
          expect(feedRequests, 2);
          expect(metadataRequests, hide ? 2 : 0);
          // Natural catalog browsing confirms the book after both lists exist.
          await tester.runAsync(() => LKApi.chapterPage(id, 1, 1));
          await tester.pumpAndSettle();
          expect(find.text('待识别作品'), hide ? findsNothing : findsNWidgets(2));
          expect(find.text('普通作品'), findsNWidgets(2));
          expect(feedRequests, 2,
              reason:
                  'The existing objects should update without refetching lists.');
          expect(LKStore.coverBlurMode.value, CoverBlurMode.none,
              reason: 'Identification must not modify cover blur preferences.');
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
  }
}
