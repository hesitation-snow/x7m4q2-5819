import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/dynamic_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => LKApi.client = LKClient.shared);

  test('default feed always selects anonymous website follow source', () {
    for (final loggedIn in [false, true]) {
      expect(dynamicFeedSource('mixed', loggedIn: loggedIn),
          (tab: 'follow', anonymous: true));
    }
    expect(dynamicFeedSource('follow', loggedIn: true),
        (tab: 'follow', anonymous: false));
    expect(dynamicFeedSource('follow', loggedIn: false),
        (tab: 'follow', anonymous: true));
  });

  test('anonymous pagination omits credentials without logging the user out',
      () async {
    final requests = <Map<String, dynamic>>[];
    final client = LKClient.forTesting(httpClient: MockClient((request) async {
      expect(request.url.path.endsWith('/api/dynamic/get-feed-v1'), isTrue);
      expect(request.headers.containsKey('cookie'), isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      final page = body['page'] as int;
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'list': [
                {'dynamic_id': page, 'content': 'public activity'}
              ],
              'next_cursor': page == 1 ? 'after-first' : '',
              'has_more': page == 1,
            }
          }),
          200);
    }));
    client.session
      ..uid = 42
      ..securityKey = 'test-session';
    LKApi.client = client;
    final first = await LKApi.dynamicFeedPage(tab: 'follow', anonymous: true);
    final second = await LKApi.dynamicFeedPage(
        tab: 'follow', anonymous: true, page: 2, cursor: first.cursor);
    expect(first.hasMore, isTrue);
    expect(second.hasMore, isFalse);
    expect(second.items.single.dynamicId, 2);
    expect(requests[1]['cursor'], 'after-first');
    for (final request in requests) {
      expect(request['tab'], 'follow');
      expect(request.containsKey('security_key'), isFalse);
      expect(request.containsKey('uid'), isFalse);
    }
    expect(client.session.uid, 42);
    expect(client.session.securityKey, 'test-session');
  });

  test('explicit account follow and interaction requests retain authentication',
      () async {
    final requests = <Map<String, dynamic>>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
          '{"code":0,"data":{"list":[],"has_more":false}}', 200);
    }));
    LKApi.client.session
      ..uid = 42
      ..securityKey = 'test-session';
    await LKApi.dynamicFeedPage(tab: 'follow');
    await LKApi.toggleDynamicLike(17, true);
    expect(requests.every((body) => body['security_key'] == 'test-session'),
        isTrue);
    expect(requests.last['dynamic_id'], 17);
  });
}
