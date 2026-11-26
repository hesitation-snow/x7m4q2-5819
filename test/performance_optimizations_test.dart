import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/messages_page.dart';
import 'package:yomiru/reader/reader_speech_session.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.resetBraveBookIdsForTesting();
    LKClient.shared.session.clear();
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKStore.resetBraveBookIdsForTesting();
  });

  test('trimResponseCache fast-parses saved_at headers and evicts broken JSON',
      () async {
    SharedPreferences.setMockInitialValues({
      'lk_response_cache_v1_valid_old':
          '{"saved_at":10,"data":{"list":[{"id":1}]}}',
      'lk_response_cache_v1_valid_new':
          '{"saved_at":20,"data":{"list":[{"id":2}]}}',
      'lk_response_cache_v1_broken': '{not-valid-json',
      'lk_response_cache_v1_bad_data': '{"saved_at":30,"data":[]}',
    });

    final client = LKClient.forTesting(
      httpClient: MockClient((_) async => http.Response('{"code":0,"data":{}}', 200)),
    );
    await client.trimResponseCache();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lk_response_cache_v1_valid_old'), isTrue);
    expect(prefs.containsKey('lk_response_cache_v1_valid_new'), isTrue);
    expect(prefs.containsKey('lk_response_cache_v1_broken'), isFalse);
    expect(prefs.containsKey('lk_response_cache_v1_bad_data'), isFalse);
  });

  test('markBookVerifiedNoBrave updates memory immediately and debounces persistence',
      () async {
    await LKStore.markBookVerifiedNoBrave(101, 'fp-101');
    await LKStore.markBookVerifiedNoBrave(102, 'fp-102');

    expect(LKStore.isVerifiedNoBrave(101, 'fp-101'), isTrue);
    expect(LKStore.isVerifiedNoBrave(102, 'fp-102'), isTrue);

    final prefsBeforeFlush = await SharedPreferences.getInstance();
    expect(
      prefsBeforeFlush.getString('verified_no_brave_fingerprints_v1'),
      isNull,
    );

    await LKStore.flushVerifiedNoBraveWrites();
    final prefsAfterFlush = await SharedPreferences.getInstance();
    final saved = jsonDecode(
      prefsAfterFlush.getString('verified_no_brave_fingerprints_v1')!,
    ) as Map<String, dynamic>;
    expect(saved['101'], 'fp-101');
    expect(saved['102'], 'fp-102');
  });

  test('SpeechAudioCache handles concurrent put calls under tight budget safely',
      () async {
    final temp = await Directory.systemTemp.createTemp('speech-concurrent-test');
    addTearDown(() async {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
      } catch (_) {}
    });
    final cache = SpeechAudioCache(
      temporaryDirectory: () async => temp,
      budgetBytes: 1024,
    );
    const config = SpeechSynthesisConfig(
      source: 'edge',
      voice: 'v1',
      language: 'zh-CN',
      rate: 1.0,
    );

    final files = await Future.wait(
      List.generate(12, (i) {
        return cache.put('acc', 'segment-$i', config, (path) async {
          final file = File(path);
          await file.writeAsBytes(List<int>.filled(300, i + 1));
          return file;
        });
      }),
    );

    expect(files, hasLength(12));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  testWidgets('MessagesPage initially loads only unread summary and active tab',
      (tester) async {
    LKClient.shared.session
      ..uid = 77
      ..securityKey = 'token';
    final paths = <String>[];
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'items': [],
              'list': [],
              'pagination': {'total': 0, 'page_size': 20, 'has_next': 0},
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await tester.pumpWidget(const MaterialApp(home: MessagesPage()));
    await tester.pumpAndSettle();

    expect(
      paths,
      unorderedEquals([
        endsWith('/api/bff/message-unread-v1'),
        endsWith('/api/bff/message-replies-v1'),
      ]),
    );

    paths.clear();
    await tester.ensureVisible(find.text('点赞'));
    await tester.tap(find.text('点赞'));
    await tester.pumpAndSettle();
    expect(paths, [endsWith('/api/bff/message-likes-v1')]);
  });
}
