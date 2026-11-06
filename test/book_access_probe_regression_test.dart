import 'dart:async';
import 'dart:convert';

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
  var sequence = 920000;
  late int id;
  late List<http.Request> requests;
  void install(Map<String, dynamic> Function(http.Request) respond) {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(
          jsonEncode({'code': 0, 'data': respond(request)}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }

  setUp(() {
    id = ++sequence;
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
      'empty catalog remains unknown; later confirmed evidence bypasses cooldown',
      () async {
    install((request) => request.url.path.endsWith('get-book-detail')
        ? {'book_id': id}
        : {'list': []});
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isNull);
    expect(LKStore.isBraveBook(id), isFalse);
    expect(requests, hasLength(2));
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isNull);
    expect(requests, hasLength(2));
    await LKStore.markBookBrave(id);
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isTrue);
    expect(requests, hasLength(2));
  });

  test('catalog traversal finds a positive chapter in a second volume',
      () async {
    final existing = LKBook.fromJson({'book_id': id});
    install((request) {
      final path = request.url.path;
      if (path.endsWith('get-book-detail')) return {'book_id': id};
      if (path.endsWith('get-book-volumes')) {
        return {
          'list': [
            {'volume_id': 1},
            {'volume_id': 2},
          ]
        };
      }
      final body = jsonDecode(request.body) as Map;
      return {
        'list': [
          body['volume_id'] == 2
              ? {
                  'chapter_id': 2,
                  'meta_json': {'brave_scope': 'brave'},
                  'unlocked': 1
                }
              : {'chapter_id': 1, 'access_type': 'public'}
        ]
      };
    });
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isTrue);
    expect(requests, hasLength(4));
    expect(existing.isBrave, isTrue);
    expect(LKStore.isBraveBook(id), isTrue);
  });

  test('repeated incomplete catalog pages never prove the whole book public',
      () async {
    install((request) {
      if (request.url.path.endsWith('get-book-detail')) return {'book_id': id};
      if (request.url.path.endsWith('get-book-volumes')) {
        return {
          'list': [
            {'volume_id': 1},
            {'volume_id': 2},
            {'volume_id': 3},
          ]
        };
      }
      return {
        'list': [
          {'chapter_id': 1, 'access_type': 'public'}
        ],
        'pagination': {'page': 1, 'page_size': 5, 'total': 200}
      };
    });
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isNull);
    expect(requests, hasLength(4));
    expect(
        requests.where(
            (request) => request.url.path.endsWith('get-volume-chapters')),
        hasLength(2));
    expect(LKStore.isBraveBook(id), isFalse);
    expect(LKBook.fromJson({'book_id': id}).accessStatus,
        BookAccessStatus.unknown);
  });

  for (final role in [false, true]) {
    test(
        'book metadata is recognized without depending on publisher brave=$role',
        () async {
      install((_) => {
            'book_id': id,
            'is_brave': 0,
            'isBrave': 1,
            'publisher': {'is_brave': role}
          });
      expect(await BookAccessProbe.shared.lookup(id, isCurrent: () => true),
          isTrue);
      expect(requests, hasLength(1));
      expect(LKStore.isBraveBook(id), isTrue);
    });
  }

  test('user-only flags and generic locks never become positive book evidence',
      () async {
    install((request) => request.url.path.endsWith('get-book-detail')
        ? {
            'book_id': id,
            'locked': 1,
            'publisher': {'is_brave': true},
            'profile': {'is_brave': true}
          }
        : {'list': []});
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isNull);
    expect(LKStore.isBraveBook(id), isFalse);
  });

  test('positive book list evidence propagates to a previously loaded model',
      () async {
    final existing = LKBook.fromJson({'book_id': id});
    install((_) => {
          'list': [
            {
              'book_id': id,
              'meta_json': {'brave_scope': ' BRAVE '}
            }
          ]
        });
    await LKApi.homeFeed('hot', 1);
    expect(existing.isBrave, isTrue);
    expect(LKStore.isBraveBook(id), isTrue);
  });

  test(
      'raw chapter detail metadata is learned even when the chapter is unlocked',
      () async {
    install((_) => {
          'chapter_id': id,
          'unlocked': 1,
          'locked': 0,
          'meta_json': {'brave_scope': ' BRAVE '},
          'body_snapshot': null,
          'render_preview': []
        });
    await LKApi.chapterDetail(id, id);
    expect(LKStore.isBraveBook(id), isTrue);
  });

  test(
      'queue hard limit prevents unbounded work while preserving deduplication',
      () async {
    final gate = Completer<void>();
    var calls = 0;
    final probe = BookAccessProbe(
        maxPending: 2,
        query: (_, current) async {
          calls++;
          await gate.future;
          return current() ? true : null;
        });
    final first = probe.lookup(1, isCurrent: () => true);
    final duplicate = probe.lookup(1, isCurrent: () => true);
    final second = probe.lookup(2, isCurrent: () => true);
    expect(await probe.lookup(3, isCurrent: () => true), isNull);
    expect(calls, 2);
    gate.complete();
    expect(await Future.wait([first, duplicate, second]), [true, true, true]);
    await probe.whenIdle;
  });

  test('later omitted flags cannot erase confirmed evidence for the same book',
      () async {
    var attempt = 0;
    install((_) => {
          'list': [
            {'book_id': id, 'is_brave': attempt++ == 0 ? 1 : 0}
          ]
        });
    final first = await LKApi.homeFeed('hot', 1, forceRefresh: true);
    final second = await LKApi.homeFeed('hot', 1, forceRefresh: true);
    expect(first.single.isBrave, isTrue);
    expect(second.single.isBrave, isTrue);
    expect(LKStore.isBraveBook(id), isTrue);
    expect(requests, hasLength(2));
  });

  test('deadline expires as unknown and does not block later queued work',
      () async {
    final gate = Completer<bool?>();
    final probe = BookAccessProbe(
        deadline: const Duration(milliseconds: 15),
        query: (id, _) => id == 1 ? gate.future : Future.value(true));
    expect(await probe.lookup(1, isCurrent: () => true), isNull);
    expect(await probe.lookup(2, isCurrent: () => true), isTrue);
    gate.complete(true); // An expired answer must not turn into a new positive.
    await probe.whenIdle;
  });

  test('data saver skips shared metadata requests', () async {
    LKStore.dataSaverMode.value = true;
    install((_) => {'book_id': id, 'is_brave': true});
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isNull);
    expect(requests, isEmpty);
    expect(LKStore.isBraveBook(id), isFalse);
    LKStore.dataSaverMode.value = false;
    expect(
        await BookAccessProbe.shared.lookup(id, isCurrent: () => true), isTrue);
    expect(requests, hasLength(1));
  });
}
