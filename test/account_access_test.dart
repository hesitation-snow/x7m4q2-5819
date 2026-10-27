import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/api/account_access.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/account_access_page.dart';

void main() {
  test('official registration/reset contract never modifies session', () async {
    final calls = <http.Request>[];
    final client = LKClient.forTesting(httpClient: MockClient((r) async {
      calls.add(r);
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'registered': false}
          }),
          200);
    }));
    client.session.securityKey = 'existing-session';
    final api = AccountAccessApi(client: client);
    await api.sendCode(' x@example.com ', register: true);
    await api.submit(
        register: true,
        email: 'x@example.com',
        code: '123',
        nickname: '昵称',
        password: 'Password1');
    await api.sendCode('x@example.com', register: false);
    await api.submit(
        register: false,
        email: 'x@example.com',
        code: '123',
        nickname: '',
        password: 'Password1');
    expect(calls.map((r) => r.url.path), [
      '/api/pc-proxy/api/bff/auth-email-status-v1',
      '/api/pc-proxy/api/bff/auth-email-register-captcha-send-v1',
      '/api/pc-proxy/api/bff/auth-email-register-v1',
      '/api/pc-proxy/api/bff/auth-reset-password-captcha-send-v1',
      '/api/pc-proxy/api/bff/auth-reset-password-v1',
    ]);
    expect(jsonDecode(calls[2].body), {
      'email': 'x@example.com',
      'captcha': '123',
      'code': '123',
      'nickname': '昵称',
      'password': 'Password1'
    });
    expect(jsonDecode(calls[4].body), {
      'email': 'x@example.com',
      'captcha': '123',
      'new_password': 'Password1'
    });
    expect(client.session.securityKey, 'existing-session');
  });

  testWidgets('pending request disables actions and server message is visible',
      (tester) async {
    final response = Completer<http.Response>();
    var calls = 0;
    final api = AccountAccessApi(
        client: LKClient.forTesting(httpClient: MockClient((r) {
      calls++;
      return response.future;
    })));
    await tester.pumpWidget(
        MaterialApp(home: AccountAccessPage(register: false, api: api)));
    await tester.enterText(find.byType(TextFormField).first, 'x@example.com');
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(calls, 1);
    response.complete(http.Response(
        jsonEncode({'code': 2, 'message': '验证码发送太频繁', 'data': {}}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpAndSettle();
    expect(find.textContaining('验证码发送太频繁'), findsOneWidget);
  });

  testWidgets('cooldown prevents resend and disposes its timer',
      (tester) async {
    var calls = 0;
    final api = AccountAccessApi(
        client: LKClient.forTesting(httpClient: MockClient((r) async {
      calls++;
      return http.Response('{"code":0,"data":{}}', 200);
    })));
    await tester.pumpWidget(
        MaterialApp(home: AccountAccessPage(register: false, api: api)));
    await tester.enterText(find.byType(TextFormField).first, 'x@example.com');
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('重新发送（60 秒）'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('重新发送（59 秒）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 65));
    expect(tester.takeException(), isNull);
  });

  test('server failure preserves message and skips captcha for existing email',
      () async {
    var calls = 0;
    final api = AccountAccessApi(
        client: LKClient.forTesting(httpClient: MockClient((r) async {
      calls++;
      return http.Response('{"code":0,"data":{"registered":true}}', 200);
    })));
    await expectLater(
        api.sendCode('x@example.com', register: true),
        throwsA(isA<LKException>()
            .having((e) => e.message, 'message', contains('已注册'))));
    expect(calls, 1);
  });

  testWidgets('invalid input never sends requests and confirms password',
      (tester) async {
    var calls = 0;
    final api = AccountAccessApi(
        client: LKClient.forTesting(httpClient: MockClient((r) async {
      calls++;
      return http.Response('{"code":0,"data":{}}', 200);
    })));
    await tester.pumpWidget(
        MaterialApp(home: AccountAccessPage(register: true, api: api)));
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    expect(find.text('请输入正确的邮箱'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(FilledButton, '注册账号'));
    await tester.tap(find.widgetWithText(FilledButton, '注册账号'));
    await tester.pump();
    expect(find.text('两次输入的密码不一致'), findsOneWidget);
    expect(calls, 0);
  });
  testWidgets(
      'narrow large text stacks code controls and labels password buttons',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
      data: MediaQueryData(
          size: Size(320, 700), textScaler: TextScaler.linear(2)),
      child: AccountAccessPage(register: true),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('显示密码'));
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(find.byTooltip('隐藏密码'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('显示确认密码'));
    await tester.tap(find.byTooltip('显示确认密码'));
    await tester.pump();
    expect(find.byTooltip('隐藏确认密码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
