import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/login_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LKClient previousClient;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    previousClient = LKApi.client;
    LKClient.shared.session.clear();
  });
  tearDown(() {
    LKApi.client = previousClient;
    LKClient.shared.session.clear();
  });

  test('business errors never fall back to cached data', () async {
    SharedPreferences.setMockInitialValues({
      'lk_response_cache_v1_feed': jsonEncode({
        'saved_at': 1,
        'data': {'value': 'old'}
      })
    });
    for (final code in [500, 1001]) {
      final client = LKClient.forTesting(
          httpClient: MockClient((_) async => http.Response(
              jsonEncode({'code': code, 'message': 'business error'}), 200)));
      await expectLater(client.post('/feed', {}, cacheKey: 'feed'),
          throwsA(isA<LKException>().having((e) => e.code, 'code', code)));
    }
  });

  test('HTTP 503 still permits stale cache fallback', () async {
    SharedPreferences.setMockInitialValues({
      'lk_response_cache_v1_feed': jsonEncode({
        'saved_at': 1,
        'data': {'value': 'old'}
      })
    });
    final client = LKClient.forTesting(
        httpClient: MockClient((_) async => http.Response('unavailable', 503)));
    expect((await client.post('/feed', {}, cacheKey: 'feed'))['value'], 'old');
  });

  test('late logout does not clear a newer injected session', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final client = LKClient.forTesting(httpClient: MockClient((request) {
      expect(jsonDecode(request.body)['security_key'], 'old');
      started.complete();
      return response.future;
    }));
    LKApi.client = client;
    client.session
      ..securityKey = 'old'
      ..uid = 1;
    final logout = LKApi.logout();
    await started.future;
    client.session
      ..securityKey = 'new'
      ..uid = 2;
    response.complete(http.Response(jsonEncode({'code': 0, 'data': {}}), 200));
    await logout;
    expect(client.session.securityKey, 'new');
    expect(client.session.uid, 2);
  });

  test('failed remote logout retains current session', () async {
    final client = LKClient.forTesting(
        httpClient: MockClient((_) async =>
            http.Response(jsonEncode({'code': 6, 'message': 'failed'}), 200)));
    LKApi.client = client;
    client.session
      ..securityKey = 'old'
      ..uid = 1;
    await expectLater(LKApi.logout(), throwsA(isA<LKException>()));
    expect(client.session.securityKey, 'old');
    expect(client.session.uid, 1);
  });

  testWidgets('repeated keyboard submit sends only one login', (tester) async {
    final response = Completer<http.Response>();
    var calls = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((_) {
      calls++;
      return response.future;
    }));
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.enterText(find.byType(TextField).first, 'test@example.com');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(calls, 1);
    response.complete(http.Response(jsonEncode({'code': 2}), 200));
    await tester.pumpAndSettle();
    expect(find.text('密码错误，请检查后重试'), findsOneWidget);
  });

  testWidgets('logout failure displays error and retains session',
      (tester) async {
    LKClient.shared.session
      ..securityKey = 'old'
      ..uid = 1
      ..nickname = 'user';
    final client = LKClient.forTesting(
        httpClient: MockClient((_) async =>
            http.Response(jsonEncode({'code': 6, 'message': 'failed'}), 200)));
    client.session
      ..securityKey = 'old'
      ..uid = 1;
    LKApi.client = client;
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.tap(find.text('退出登录(当前: user)'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('退出所有设备'));
    await tester.pumpAndSettle();
    expect(find.text('退出失败，请重试或选择“仅退出本机”'), findsOneWidget);
    expect(LKClient.shared.session.securityKey, 'old');
    expect(tester.takeException(), isNull);
  });
}
