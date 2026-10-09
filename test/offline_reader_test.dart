import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/widgets/content_state_view.dart';
import 'reader_controls_test.dart' show withReader;

void main() {
  for (final offline in [true, false]) {
    testWidgets(
        'downloaded chapter renders without network: explicit offline=$offline',
        (tester) async {
      var requests = 0;
      await withReader(tester,
          paged: false,
          platform: TargetPlatform.android,
          offlineOnly: offline, prepareLocal: (root) async {
        final directory = Directory('${root.path}/offline_library');
        await directory.create();
        final detail = LKChapterDetail(
            chapterId: 317815,
            volumeId: 1,
            title: '离线第一章',
            bodyText: '离线第一章正文',
            bodyHtml: '<p>离线第一章正文</p>');
        await File('${directory.path}/0_1338_317815.json')
            .writeAsString(jsonEncode(detail.toCacheJson()));
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'offline_book_0_1338',
            jsonEncode({
              'book_id': 1338,
              'title': 'fixture',
              'updated': '',
              'chapters': [
                {
                  'id': 317815,
                  'volume': 1,
                  'title': '离线第一章',
                  'status': 'ready',
                  'bytes': 100
                }
              ]
            }));
        LKApi.client = LKClient.forTesting(httpClient: MockClient((_) async {
          requests++;
          throw const SocketException('test offline');
        }));
      }, run: (calls, key) async {
        expect(
            find.textContaining('离线第一章正文', findRichText: true), findsWidgets);
        if (offline) {
          expect(requests, 0);
          await tester.tap(find.text('目录'));
          await tester.pumpAndSettle();
          for (var i = 0; i < 4; i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 15)));
            await tester.pump();
          }
          expect(find.text('离线第一章'), findsWidgets);
          expect(requests, 0);
        } else {
          expect(requests, greaterThan(0));
          expect(find.text('正在阅读本地缓存，联网刷新失败'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    });
  }
  testWidgets('failed load is a retry state, not a body paragraph',
      (tester) async {
    await withReader(tester, paged: false, platform: TargetPlatform.android,
        prepareLocal: (_) async {
      LKApi.client = LKClient.forTesting(
          httpClient: MockClient(
              (_) async => throw const SocketException('test failure')));
    }, run: (calls, key) async {
      expect(find.byType(ContentStateView), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('去登录'), findsNothing);
      expect(find.byType(CustomScrollView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
