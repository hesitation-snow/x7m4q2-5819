import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/reader/reading_position.dart';

import 'reader_controls_test.dart' show withReader;

void main() {
  for (final paged in [false, true]) {
    testWidgets('returning to start replaces old position: paged=$paged',
        (tester) async {
      await withReader(tester, paged: paged, platform: TargetPlatform.android,
          run: (calls, key) async {
        for (var i = 0; i < 5; i++) {
          await key('next');
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 600));
        expect((await ReaderPrefs.readPosition(317815))!.blockIndex,
            greaterThan(0));
        if (paged) {
          tester
              .widget<PageView>(find.byType(PageView))
              .controller!
              .jumpToPage(0);
        } else {
          tester
              .widget<CustomScrollView>(find.byType(CustomScrollView).first)
              .controller!
              .jumpTo(0);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        final position = await ReaderPrefs.readPosition(317815);
        expect(position!.blockIndex, 0);
        expect(await ReaderPrefs.readPosFrac(317815), closeTo(0, 0.005));
      });
    });
  }

  testWidgets('leaving before network restore keeps the old saved anchor',
      (tester) async {
    final gate = Completer<void>();
    await withReader(tester, paged: false, platform: TargetPlatform.android,
        prepareLocal: (_) async {
      await ReaderPrefs.setPosition(
          317815, const ReadingPosition.text(blockIndex: 20, offset: 4));
      await ReaderPrefs.setReadPosFrac(317815, .4);
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/get-chapter-detail')) await gate.future;
        return http.Response('{"code":0,"data":{}}', 200);
      }));
    }, run: (calls, key) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final saved = await ReaderPrefs.readPosition(317815);
      expect(saved!.blockIndex, 20);
      expect(saved.textOffset, 4);
      expect(await ReaderPrefs.readPosFrac(317815), .4);
      gate.complete();
    });
  });

  for (final state in [
    (locked: false, unlocked: false, expected: true),
    (locked: true, unlocked: true, expected: true),
    (locked: true, unlocked: false, expected: false),
  ]) {
    testWidgets('first network history honors access and percentage: $state',
        (tester) async {
      final histories = <Map<String, dynamic>>[];
      try {
        await withReader(tester, paged: false, platform: TargetPlatform.android,
            prepareLocal: (_) async {
          await ReaderPrefs.setReadPosFrac(317815, .5);
          LKClient.shared.session.securityKey = 'fixture';
          LKClient.shared.session.uid = 123;
          final client =
              LKClient.forTesting(httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/save-book-history')) {
              histories.add(jsonDecode(request.body) as Map<String, dynamic>);
            }
            final data = request.url.path.endsWith('/get-chapter-detail')
                ? <String, dynamic>{
                    'chapter_id': 317815,
                    'volume_id': 2,
                    'locked': state.locked,
                    'unlocked': state.unlocked,
                    'body_snapshot': {
                      'body_html': List.generate(
                          60, (i) => '<p>第$i段测试正文，阅读位置用于历史百分比测试。</p>').join()
                    },
                  }
                : <String, dynamic>{};
            return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
                headers: {'content-type': 'application/json'});
          }));
          client.session.securityKey = 'fixture';
          client.session.uid = 123;
          LKApi.client = client;
        }, run: (calls, key) async {
          expect(histories.length, state.expected ? 1 : 0);
          if (state.expected) {
            expect(histories.single['progress_percent'], 50);
            expect(histories.single['volume_id'], 2);
          }
        });
      } finally {
        LKClient.shared.session.clear();
      }
    });
  }
}
