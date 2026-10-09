import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/reader_cache.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/services/offline_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final library = OfflineLibrary.shared;
  var count = 3;
  var failId = 0;
  var lockedId = 0;
  var wrongId = 0;
  var requests = <int>[];
  Completer<void>? gate;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('yomiru-offline-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path);
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    count = 3;
    failId = 0;
    lockedId = 0;
    wrongId = 0;
    requests = [];
    gate = null;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final data = <String, dynamic>{};
      if (request.url.path.endsWith('/get-volume-chapters')) {
        final page = body['page'] as int;
        final size = body['pageSize'] as int;
        final start = (page - 1) * size;
        data['list'] = [
          for (var i = start; i < count && i < start + size; i++)
            {'chapter_id': i + 1, 'title': 'Chapter ${i + 1}'}
        ];
        data['total'] = count;
      } else if (request.url.path.endsWith('/get-chapter-detail')) {
        final id = body['chapter_id'] as int;
        requests.add(id);
        if (gate != null) await gate!.future;
        if (id == failId) {
          return http.Response(
              jsonEncode({'code': 500, 'msg': 'test failure'}), 200);
        }
        data.addAll({
          'chapter_id': id == wrongId ? 999 : id,
          'volume_id': 1,
          'title': 'Chapter $id',
          'locked': id == lockedId ? 1 : 0,
          'unlocked': 0,
          'body_snapshot': {
            'body_html': '<p>离线正文 $id</p>',
            'body_text': '离线正文 $id'
          }
        });
      }
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  });
  tearDown(() async {
    library.cancel();
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
    await ReaderContentCache.clear();
    await root.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
  });
  Future<void> download() =>
      library.download(7, 'Book', [LKVolume(volumeId: 1, title: 'Volume')]);

  test('durable chapters exceed cache cap and survive ordinary cache clearing',
      () async {
    count = 55;
    await download();
    final chapters = (await library.books()).single['chapters'] as List;
    expect(chapters.where((c) => c['status'] == 'ready'), hasLength(55),
        reason: '${chapters.first} / ${library.error}');
    await ReaderContentCache.clear();
    await LKStore.clearContentCaches();
    await LKClient.shared.clearResponseCache();
    expect((await library.read(7, 1, ownerUid: 0))?.bodyText, contains('离线正文'));
    expect(await library.read(7, 55, ownerUid: 0), isNotNull);
    requests.clear();
    await library.download(7, 'Book', []);
    expect(requests, isEmpty);
  });

  test(
      'retry only requests incomplete chapters and rejects mismatched responses',
      () async {
    failId = 2;
    wrongId = 3;
    await download();
    final chapters = (await library.books()).single['chapters'] as List;
    expect(chapters.map((c) => c['status']), ['ready', 'failed', 'failed']);
    expect(await library.read(7, 3, ownerUid: 0), isNull);
    requests.clear();
    failId = 0;
    wrongId = 0;
    await library.download(7, 'Book', []);
    expect(requests, [2, 3]);
    expect(
        ((await library.books()).single['chapters'] as List)
            .every((c) => c['status'] == 'ready'),
        isTrue);
  });

  test('locked preview cannot be downloaded', () async {
    lockedId = 2;
    await download();
    expect(await library.read(7, 2, ownerUid: 0), isNull);
    final chapters = (await library.books()).single['chapters'] as List;
    expect(chapters[1]['status'], 'failed');
  });

  test('account scopes and single book deletion are independent', () async {
    await download();
    LKClient.shared.session
      ..uid = 42
      ..securityKey = 'test';
    expect(await library.books(), isEmpty);
    expect(await library.read(7, 1, ownerUid: 42), isNull);
    await download();
    await library.remove(7);
    expect(await library.read(7, 1, ownerUid: 42), isNull);
    expect(await library.read(7, 1, ownerUid: 0), isNotNull);
  });

  test('pause discards pending response and resumes from durable catalog',
      () async {
    gate = Completer<void>();
    final job = download();
    while (requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    library.cancel();
    gate!.complete();
    await job;
    expect(library.busy, isFalse);
    expect(await library.read(7, 1, ownerUid: 0), isNull);
    expect((await library.books()).single['chapters'], hasLength(3));
    gate = null;
    await library.download(7, 'Book', []);
    expect(await library.read(7, 3, ownerUid: 0), isNotNull);
  });

  test('adding an earlier volume preserves book catalog order', () async {
    count = 2;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'offline_book_0_7',
        jsonEncode({
          'book_id': 7,
          'title': 'Book',
          'chapters': [
            {
              'id': 99,
              'volume': 2,
              'title': 'Later volume',
              'status': 'pending',
              'order': 0,
              'bytes': 0
            }
          ]
        }));
    await library
        .download(7, 'Book', [LKVolume(volumeId: 1)], volumeOrder: [1, 2]);
    final chapters = (await library.books()).single['chapters'] as List;
    expect(chapters.map((c) => c['id']), [1, 2, 99]);
  });
}
