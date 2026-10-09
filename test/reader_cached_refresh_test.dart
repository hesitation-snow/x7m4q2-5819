import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'reader_controls_test.dart' show withReader;

void main() {
  for (final paged in [false, true]) {
    testWidgets(
        'background content refresh preserves current anchor: paged=$paged',
        (tester) async {
      final gate = Completer<void>();
      String body(bool updated) => List.generate(
              60,
              (i) =>
                  '<p>第$i段：${updated ? '刷新后正文，' : ''}这是一段用于验证阅读位置的长篇正文，缓存更新不应把已经阅读的位置重置到开头，也不应保持失效的旧像素坐标。测试正常的中文换行以及段落间距。</p>')
          .join();
      await withReader(tester, paged: paged, platform: TargetPlatform.android,
          prepareLocal: (root) async {
        final dir = Directory('${root.path}/offline_library');
        await dir.create();
        await File('${dir.path}/0_1338_317815.json').writeAsString(jsonEncode(
            LKChapterDetail(
                    chapterId: 317815, volumeId: 1, bodyHtml: body(false))
                .toCacheJson()));
        LKApi.client =
            LKClient.forTesting(httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/get-chapter-detail')) {
            await gate.future;
            return http.Response(
                jsonEncode({
                  'code': 0,
                  'data': {
                    'chapter_id': 317815,
                    'volume_id': 1,
                    'body_snapshot': {'body_html': body(true)}
                  }
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          return http.Response('{"code":0,"data":{}}', 200);
        }));
      }, run: (calls, key) async {
        for (var i = 0; i < 5; i++) {
          await key('next');
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 600));
        final before = await ReaderPrefs.readPosition(317815);
        expect(before!.blockIndex, greaterThan(0));
        gate.complete();
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        final after = await ReaderPrefs.readPosition(317815);
        expect(after!.blockIndex, closeTo(before.blockIndex, 1));
        expect(find.textContaining('刷新后正文', findRichText: true), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
