import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/services/book_access_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<http.Request> requests;
  void install(
      Map<String, dynamic> Function(http.Request, Map<String, dynamic>)
          respond) {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': respond(request,
                Map<String, dynamic>.from(jsonDecode(request.body) as Map))
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }

  setUp(() {
    requests = [];
    SharedPreferences.setMockInitialValues({});
    LKStore.resetBraveBookIdsForTesting({});
    LKStore.dataSaverMode.value = false;
  });
  tearDown(() async {
    await BookAccessProbe.shared.whenIdle;
    LKApi.client = LKClient.shared;
  });

  test(
      'real 33172 metadata finds title chapter nine at catalog position eleven',
      () async {
    final fixture = jsonDecode(
        await File('test/fixtures/mixed_access_book_33172.json')
            .readAsString()) as Map<String, dynamic>;
    final book =
        LKBook.fromJson(Map<String, dynamic>.from(fixture['book'] as Map));
    final list = (fixture['chapters'] as Map)['list'] as List;
    expect(book.isBrave, isFalse);
    expect(
        list.take(5).every((item) => item['access_type'] == 'public'), isTrue);
    expect(list[10]['chapter_id'], 324018);
    expect(list[10]['access_type'], 'brave');
    install((request, body) {
      expect(body['book_id'], 33172);
      if (request.url.path.endsWith('get-book-detail')) {
        return Map<String, dynamic>.from(fixture['book'] as Map);
      }
      if (request.url.path.endsWith('get-book-volumes')) {
        return Map<String, dynamic>.from(fixture['volumes'] as Map);
      }
      expect(request.url.path, endsWith('get-volume-chapters'));
      expect(body['volume_id'], 50815);
      expect(body['pageSize'], 50);
      return Map<String, dynamic>.from(fixture['chapters'] as Map);
    });
    expect(await BookAccessProbe.shared.lookup(33172, isCurrent: () => true),
        isTrue);
    expect(requests, hasLength(3));
    expect(book.isBrave, isTrue,
        reason: 'Existing list models must update without reloading.');
    expect(
        requests
            .any((request) => request.url.path.endsWith('get-chapter-detail')),
        isFalse);
  });

  test(
      'shared pipeline continues into the second page instead of only sampling the first',
      () async {
    const id = 960001;
    install((request, body) {
      if (request.url.path.endsWith('get-book-detail')) {
        return {
          'book_id': id,
          'volume_count': 1,
          'chapter_count': 80,
          'access_type': 'public',
          'updated_at': 'v1'
        };
      }
      if (request.url.path.endsWith('get-book-volumes')) {
        return {
          'list': [
            {'volume_id': 1, 'chapter_count': 80}
          ],
          'pagination': {'page': 1, 'page_size': 50, 'total': 1}
        };
      }
      final page = body['page'] as int;
      final start = page == 1 ? 1 : 51;
      return {
        'list': List.generate(
            page == 1 ? 50 : 30,
            (i) => {
                  'chapter_id': start + i,
                  'access_type': start + i == 80 ? 'brave' : 'public'
                }),
        'pagination': {'page': page, 'page_size': 50, 'total': 80}
      };
    });
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isTrue);
    expect(requests, hasLength(4));
    expect(
        requests
            .where(
                (request) => request.url.path.endsWith('get-volume-chapters'))
            .map((request) => (jsonDecode(request.body) as Map)['page']),
        [1, 2]);
  });

  test(
      'multiple volumes continue across rounds and late positive evidence wins',
      () async {
    const id = 960002;
    var bookLoads = 0;
    install((request, body) {
      if (request.url.path.endsWith('get-book-detail')) {
        bookLoads++;
        return {
          'book_id': id,
          'volume_count': 3,
          'chapter_count': 9,
          'updated_at': 'same'
        };
      }
      if (request.url.path.endsWith('get-book-volumes')) {
        return {
          'list':
              List.generate(3, (i) => {'volume_id': i + 1, 'chapter_count': 3}),
          'pagination': {'page': 1, 'page_size': 50, 'total': 3}
        };
      }
      final volume = body['volume_id'] as int;
      return {
        'list': List.generate(
            3,
            (i) => {
                  'chapter_id': volume * 100 + i,
                  'access_type': volume == 3 && i == 2 ? 'brave' : 'public'
                }),
        'pagination': {'page': 1, 'page_size': 50, 'total': 3}
      };
    });
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isTrue);
    expect(bookLoads, 2,
        reason: 'A second bounded round refreshes the catalog fingerprint.');
    expect(requests, hasLength(6));
    expect(LKStore.isBraveBook(id), isTrue);
  });

  test('verification-only API reads do not commit positive marks by themselves',
      () async {
    const id = 960003;
    install((request, _) => request.url.path.endsWith('get-book-detail')
        ? {'book_id': id, 'is_brave': true}
        : {
            'list': [
              {'chapter_id': 1, 'access_type': 'brave'}
            ]
          });
    expect((await LKApi.bookDetail(id, forAccessVerification: true)).isBrave,
        isTrue);
    expect(LKStore.isBraveBook(id), isFalse);
    expect(
        (await LKApi.chapterPage(id, 1, 1, requireList: true))
            .items
            .single
            .braveOnly,
        isTrue);
    expect(LKStore.isBraveBook(id), isFalse);
  });

  test(
      'a late cancelled catalog response cannot populate shared positive evidence',
      () async {
    const id = 960004;
    var active = true;
    final chapterStarted = Completer<void>();
    final chapterResponse = Completer<http.Response>();
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('get-volume-chapters')) {
        if (!chapterStarted.isCompleted) chapterStarted.complete();
        return chapterResponse.future;
      }
      final data = request.url.path.endsWith('get-book-detail')
          ? {
              'book_id': id,
              'volume_count': 1,
              'chapter_count': 1,
              'updated_at': 'same'
            }
          : {
              'list': [
                {'volume_id': 1, 'chapter_count': 1}
              ],
              'pagination': {'page': 1, 'page_size': 50, 'total': 1}
            };
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json'});
    }));
    final first = BookAccessProbe.shared.lookup(id, isCurrent: () => active);
    await chapterStarted.future;
    active = false;
    chapterResponse.complete(http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'list': [
              {'chapter_id': 1, 'access_type': 'brave'}
            ],
            'pagination': {'page': 1, 'page_size': 50, 'total': 1}
          }
        }),
        200,
        headers: {'content-type': 'application/json'}));
    expect(await first, isNull);
    expect(LKStore.isBraveBook(id), isFalse);
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isTrue);
    expect(LKStore.isBraveBook(id), isTrue);
    expect(requests, hasLength(5),
        reason:
            'The accepted volume cursor resumes, not the cancelled chapter result.');
  });

  test('a stale positive query cannot poison the local probe memo', () async {
    var active = true;
    var calls = 0;
    final gate = Completer<bool>();
    final commits = <int>[];
    final probe = BookAccessProbe(query: (_, __) {
      calls++;
      return gate.future;
    }, onConfirmed: (id) async {
      commits.add(id);
    });
    final first = probe.lookup(1, isCurrent: () => active);
    active = false;
    gate.complete(true);
    expect(await first, isNull);
    expect(commits, isEmpty);
    expect(await probe.lookup(1, isCurrent: () => true), isTrue);
    expect(calls, 2);
    expect(commits, [1]);
  });

  test('yielded rounds let other books advance instead of holding queue slots',
      () async {
    final order = <int>[];
    final counts = <int, int>{};
    final probe = BookAccessProbe(
        query: (id, _) async {
          order.add(id);
          counts[id] = (counts[id] ?? 0) + 1;
          return counts[id] == 3 ? true : null;
        },
        needsContinuation: (_) => true,
        maxRounds: 3);
    final first = probe.lookup(1, isCurrent: () => true);
    final second = probe.lookup(2, isCurrent: () => true);
    final third = probe.lookup(3, isCurrent: () => true);
    expect(await Future.wait([first, second, third]), [true, true, true]);
    expect(order.take(3), [1, 2, 3]);
    expect(counts.values, everyElement(3));
  });

  test('round cap preserves progress and resumes only after partial cooldown',
      () async {
    var now = DateTime(2026, 1, 1);
    var calls = 0;
    var starts = 0;
    final probe = BookAccessProbe(
        now: () => now,
        maxRounds: 2,
        onLookupStarted: (_) {
          starts++;
        },
        needsContinuation: (_) => true,
        query: (_, __) async => ++calls >= 4 ? true : null);
    expect(await probe.lookup(1, isCurrent: () => true), isNull);
    expect(calls, 2);
    expect(await probe.lookup(1, isCurrent: () => true), isNull);
    expect(calls, 2);
    now = now.add(const Duration(seconds: 16));
    expect(await probe.lookup(1, isCurrent: () => true), isTrue);
    expect(calls, 4);
    expect(starts, 2);
  });

  test('leaving during a round yield prevents subsequent requests', () async {
    var active = true;
    var calls = 0;
    final yielding = Completer<void>();
    final probe = BookAccessProbe(
        roundDelay: const Duration(milliseconds: 20),
        query: (_, __) async {
          calls++;
          return null;
        },
        needsContinuation: (_) {
          if (!yielding.isCompleted) yielding.complete();
          return true;
        });
    final result = probe.lookup(1, isCurrent: () => active);
    await yielding.future;
    active = false;
    expect(await result, isNull);
    expect(calls, 1);
    await probe.whenIdle;
  });
}
