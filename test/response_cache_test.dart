import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';

const _prefix = 'lk_response_cache_v1_';

http.Response _response(String value) => http.Response(
    jsonEncode({
      'code': 0,
      'data': {'value': value}
    }),
    200);

String _cached(String value, {int savedAt = 1}) => jsonEncode({
      'saved_at': savedAt,
      'data': {'value': value}
    });

LKClient _client(Future<http.Response> Function(http.Request) handler) =>
    LKClient.forTesting(httpClient: MockClient(handler));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a new launch refreshes disk data once and then reuses it', () async {
    SharedPreferences.setMockInitialValues({'${_prefix}feed': _cached('old')});
    var calls = 0;
    final first = _client((_) async {
      calls++;
      return _response('first launch');
    });
    expect((await first.post('/feed', {}, cacheKey: 'feed'))['value'],
        'first launch');
    expect((await first.post('/feed', {}, cacheKey: 'feed'))['value'],
        'first launch');
    expect(calls, 1);
    await first.flushResponseCache();

    final second = _client((_) async {
      calls++;
      return _response('second launch');
    });
    expect((await second.post('/feed', {}, cacheKey: 'feed'))['value'],
        'second launch');
    expect(calls, 2);
    await second.flushResponseCache();
  });

  test('manual refresh always requests the server', () async {
    var calls = 0;
    final client = _client((_) async => _response('${++calls}'));
    await client.post('/feed', {}, cacheKey: 'feed');
    await client.post('/feed', {}, cacheKey: 'feed');
    final refreshed =
        await client.post('/feed', {}, cacheKey: 'feed', forceRefresh: true);
    expect(calls, 2);
    expect(refreshed['value'], '2');
    await client.flushResponseCache();
  });

  test('manual refresh reports failure without replacing the old disk data',
      () async {
    var fail = false;
    final client = _client((_) async {
      if (fail) throw http.ClientException('offline');
      return _response('old');
    });
    await client.post('/feed', {}, cacheKey: 'feed');
    await client.flushResponseCache();
    fail = true;

    await expectLater(
      client.post('/feed', {}, cacheKey: 'feed', forceRefresh: true),
      throwsA(isA<LKException>()
          .having((e) => e.message, 'message', contains('连接失败'))),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
        jsonDecode(prefs.getString('${_prefix}feed')!)['data']['value'], 'old');
  });

  test('an offline fallback does not mark last-launch data as validated',
      () async {
    SharedPreferences.setMockInitialValues({'${_prefix}feed': _cached('old')});
    var calls = 0;
    final client = _client((_) async {
      if (++calls == 1) throw http.ClientException('offline');
      return _response('new');
    });
    expect((await client.post('/feed', {}, cacheKey: 'feed'))['value'], 'old');
    expect((await client.post('/feed', {}, cacheKey: 'feed'))['value'], 'new');
    expect(calls, 2);
    await client.flushResponseCache();
  });

  test('snapshot pages can surface a failed silent refresh', () async {
    SharedPreferences.setMockInitialValues({'${_prefix}feed': _cached('old')});
    final client = _client((_) async => http.Response('unavailable', 503));
    await expectLater(
      client.post('/feed', {}, cacheKey: 'feed', allowCachedFallback: false),
      throwsA(isA<LKException>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('${_prefix}feed'), _cached('old'));
  });

  test('a late old response cannot overwrite a manual refresh', () async {
    final started = Completer<void>();
    final oldResponse = Completer<http.Response>();
    var calls = 0;
    final client = _client((_) async {
      if (++calls == 1) {
        started.complete();
        return oldResponse.future;
      }
      return _response('new');
    });
    final oldRequest = client.post('/feed', {}, cacheKey: 'feed');
    await started.future;
    await client.post('/feed', {}, cacheKey: 'feed', forceRefresh: true);
    oldResponse.complete(_response('old'));
    await oldRequest;
    expect((await client.post('/feed', {}, cacheKey: 'feed'))['value'], 'new');
    expect(calls, 2);
    await client.flushResponseCache();
    final prefs = await SharedPreferences.getInstance();
    expect(
        jsonDecode(prefs.getString('${_prefix}feed')!)['data']['value'], 'new');
  });

  test('ordinary readers share an in-flight manual refresh', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    var calls = 0;
    final client = _client((_) async {
      calls++;
      started.complete();
      return response.future;
    });
    final refresh =
        client.post('/feed', {}, cacheKey: 'feed', forceRefresh: true);
    await started.future;
    final other = client.post('/feed', {}, cacheKey: 'feed');
    response.complete(_response('new'));
    expect(await refresh, await other);
    expect(calls, 1);
    await client.flushResponseCache();
  });

  test('clearing the cache also invalidates pending writes', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final client = _client((_) async {
      started.complete();
      return response.future;
    });
    final request = client.post('/feed', {}, cacheKey: 'feed');
    await started.future;
    await client.clearResponseCache();
    response.complete(_response('outdated'));
    await request;
    await client.flushResponseCache();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('${_prefix}feed'), isFalse);
  });

  test('mutation invalidation forces the next read to request fresh data',
      () async {
    var calls = 0;
    final client = _client((_) async => _response('${++calls}'));
    await client.post('/book', {}, cacheKey: 'book_1');
    await client.invalidateCachePrefix('book_');
    expect((await client.post('/book', {}, cacheKey: 'book_1'))['value'], '2');
    await client.flushResponseCache();
  });

  test('disk cache evicts oldest responses without removing user settings',
      () async {
    SharedPreferences.setMockInitialValues({
      for (var i = 0; i < 300; i++)
        '${_prefix}entry_$i': _cached('$i', savedAt: i + 1),
      'uid': 42,
      'theme_mode': 'dark',
      'page_cache_v1_home': '[]',
      'local_shelf_books_v1': '[]',
    });
    final client = _client((_) async => _response('unused'));
    await client.trimResponseCache();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((key) => key.startsWith(_prefix)).length, 256);
    expect(prefs.containsKey('${_prefix}entry_0'), isFalse);
    expect(prefs.containsKey('${_prefix}entry_299'), isTrue);
    expect(prefs.getInt('uid'), 42);
    expect(prefs.getString('theme_mode'), 'dark');
    expect(prefs.getString('page_cache_v1_home'), '[]');
    expect(prefs.getString('local_shelf_books_v1'), '[]');
  });

  test('disk cache obeys total and per-response size limits', () async {
    SharedPreferences.setMockInitialValues({
      for (var i = 0; i < 20; i++)
        '${_prefix}entry_$i': _cached('x' * 450000, savedAt: i + 1),
      '${_prefix}oversized': _cached('x' * 600000, savedAt: 100),
      '${_prefix}broken': 'not json',
    });
    final client = _client((_) async => _response('unused'));
    await client.trimResponseCache();
    expect(await client.responseCacheSizeBytes(),
        lessThanOrEqualTo(8 * 1024 * 1024));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('${_prefix}oversized'), isFalse);
    expect(prefs.containsKey('${_prefix}broken'), isFalse);
    expect(prefs.containsKey('${_prefix}entry_19'), isTrue);
  });

  test('an oversized response is usable without being persisted', () async {
    final client = _client((_) async => _response('x' * 600000));
    final data = await client.post('/feed', {}, cacheKey: 'feed');
    expect((data['value'] as String).length, 600000);
    await client.flushResponseCache();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('${_prefix}feed'), isFalse);
  });
}
