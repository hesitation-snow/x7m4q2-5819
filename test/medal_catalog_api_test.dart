import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/medal_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => LKApi.client = LKClient.shared);

  http.Response response(Map<String, dynamic> data) =>
      http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});

  test('build flag selects full catalogue without altering normal requests',
      () async {
    final pages = <int>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      expect(request.url.path, endsWith('/api/bff/my-medal-center-v1'));
      final body = jsonDecode(request.body) as Map;
      expect(body['pageSize'], allMedalsBuild ? 50 : 20);
      final page = body['page'] as int;
      pages.add(page);
      return response({
        'page_info': {'cur': page == 0 ? 1 : page, 'count': 3, 'size': 2},
        'exchange_medals': page == 0
            ? [
                {'goods_id': 1},
                {'goods_id': 2}
              ]
            : [
                {'goods_id': 3, 'name': '测试勋章'}
              ],
      });
    }));
    final result = await LKApi.medalCenter();
    expect(pages, allMedalsBuild ? [0, 2] : [0]);
    expect((result['exchange_medals'] as List).length, allMedalsBuild ? 3 : 2);
  });

  test('exchange endpoint and goods ID remain unchanged', () async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      expect(request.url.path, endsWith('/api/bff/exchange-my-medal-v1'));
      expect(jsonDecode(request.body), {'goods_id': 123});
      return response({});
    }));
    await LKApi.exchangeMedal(456, goodsId: 123);
  });

  test('session changes stop subsequent pages', () async {
    var calls = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      calls++;
      LKApi.client.session.uid = 20;
      return response({
        'page_info': {'cur': 1, 'count': 3, 'size': 2},
        'exchange_medals': [
          {'goods_id': 1},
          {'goods_id': 2}
        ],
      });
    }));
    LKApi.client.session.uid = 10;
    if (allMedalsBuild) {
      await expectLater(LKApi.medalCenter(), throwsA(isA<LKException>()));
    } else {
      await LKApi.medalCenter();
    }
    expect(calls, 1);
  });
}
