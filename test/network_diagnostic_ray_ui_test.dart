import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:yomiru/pages/network_diagnostic_page.dart';
import 'package:yomiru/services/network_diagnostic_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cache status and opt-in Ray ID in copied diagnostic reports',
      (tester) async {
    const ray = 'abcd123456789abc-HKG';
    const bodySecret = 'sensitive-api-body-value';
    const headerSecret = 'sensitive-response-header-value';
    const webSecret = 'sensitive-web-body-value';
    const dnsAddress = '192.0.2.123';
    final copies = <String>[];
    final requests = <String>[];
    var dnsLookups = 0;

    PackageInfo.setMockInitialValues(
      appName: 'Yomiru',
      packageName: 'moe.yutro.yomiru',
      version: '1.6.0',
      buildNumber: '2014',
      buildSignature: '',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copies.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = MockClient((request) async {
      requests.add('${request.method} ${request.url}');
      if (request.url.host == 'www.baidu.com') {
        return http.Response('OK', 200);
      }
      if (request.url.host == 'www.google.com') {
        return http.Response('', 204);
      }
      if (request.url.host == 'www.lightnovel.fun') {
        if (request.url.path.contains('/api/')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'private': bodySecret}
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json',
              'cf-ray': ray,
              'cf-cache-status': 'HIT',
              'set-cookie': headerSecret,
              'x-private-header': headerSecret,
            },
          );
        }
        return http.Response('<html>$webSecret</html>', 200);
      }
      throw StateError('Unexpected request: ${request.url}');
    });
    addTearDown(client.close);
    final service = NetworkDiagnosticService(
      httpClient: client,
      dnsLookup: (_) async {
        dnsLookups++;
        return [dnsAddress];
      },
    );

    // Bounded pumping avoids waiting indefinitely on an animation or a request.
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(finder, findsOneWidget);
    }

    void expectPrivateValuesAbsent(String report) {
      expect(report, contains('Yomiru 网络诊断报告'));
      for (final secret in [bodySecret, headerSecret, webSecret, dnsAddress]) {
        expect(report, isNot(contains(secret)));
      }
      expect(report.toLowerCase(), isNot(contains('set-cookie')));
      expect(report.toLowerCase(), isNot(contains('x-private-header')));
    }

    await tester.pumpWidget(MaterialApp(
      home: NetworkDiagnosticPage(service: service),
    ));
    await tester.pump();
    await tester.tap(find.text('开始网络诊断'));
    await waitFor(find.text('重新检测网络'));
    expect(find.text('网络连接良好，LK服务畅通'), findsOneWidget);
    expect(find.text('Cloudflare 缓存状态：HIT'), findsOneWidget);
    expect(dnsLookups, 1);
    expect(requests, hasLength(4));

    final checkbox = find.byKey(const ValueKey('diagnostic-include-ray-id'));
    expect(checkbox, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);

    final copyButton = find.widgetWithText(OutlinedButton, '复制诊断结果');
    await tester.ensureVisible(copyButton);
    await tester.tap(copyButton);
    await tester.pump();
    expect(copies, hasLength(1));
    expect(copies.last, contains('HIT'));
    expect(copies.last, isNot(contains(ray)));
    expectPrivateValuesAbsent(copies.last);

    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    await tester.ensureVisible(copyButton);
    await tester.tap(copyButton);
    await tester.pump();
    expect(copies, hasLength(2));
    expect(copies.last, contains(ray));
    expectPrivateValuesAbsent(copies.last);

    await tester.ensureVisible(find.text('重新检测网络'));
    await tester.tap(find.text('重新检测网络'));
    await tester.pump();
    await waitFor(find.text('重新检测网络'));
    expect(dnsLookups, 2);
    expect(requests, hasLength(8));
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    await tester.ensureVisible(copyButton);
    await tester.tap(copyButton);
    await tester.pump();
    expect(copies, hasLength(3));
    expect(copies.last, isNot(contains(ray)));
    expectPrivateValuesAbsent(copies.last);
  });
}
