import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Yomiru',
      packageName: 'moe.yutro.yomiru',
      version: '1.5.1',
      buildNumber: '2013',
      buildSignature: '',
    );
  });

  group('NetworkDiagnosticService Unit Tests', () {
    test('all passed scenario produces normal summary', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'www.baidu.com') {
          return http.Response('OK', 200);
        }
        if (request.url.host == 'www.google.com') {
          return http.Response('', 204);
        }
        if (request.url.host == 'www.lightnovel.fun') {
          if (request.url.path.contains('/api/')) {
            return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
          }
          return http.Response('<html>LK Web</html>', 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = NetworkDiagnosticService(
        httpClient: client,
        dnsLookup: (host) async => ['1.2.3.4'],
      );

      final dns = await service.testDns();
      final baidu = await service.testBaidu();
      final google = await service.testGoogle();
      final lkWeb = await service.testLkWeb();
      final lkApi = await service.testLkApi();

      expect(dns.status, DiagnosticStatus.success);
      expect(baidu.status, DiagnosticStatus.success);
      expect(google.status, DiagnosticStatus.success);
      expect(lkWeb.status, DiagnosticStatus.success);
      expect(lkApi.status, DiagnosticStatus.success);

      final summary = NetworkDiagnosticService.evaluateSummary(
        results: {
          DiagnosticTarget.dns: dns,
          DiagnosticTarget.baidu: baidu,
          DiagnosticTarget.google: google,
          DiagnosticTarget.lkWeb: lkWeb,
          DiagnosticTarget.lkApi: lkApi,
        },
        appVersion: '1.5.1+2013',
        platformDescription: 'iOS',
      );

      expect(summary.allPassed, isTrue);
      expect(summary.title, contains('网络连接良好'));
      expect(summary.fullReport, contains('Yomiru 网络诊断报告'));
      expect(summary.fullReport, contains('1.5.1+2013'));
      // Never contains sensitive local IP in report
      expect(summary.fullReport, isNot(contains('1.2.3.4')));
    });

    test('web works but API fails produces targeted VPN/proxy suggestion',
        () async {
      final client = MockClient((request) async {
        if (request.url.host == 'www.baidu.com') {
          return http.Response('OK', 200);
        }
        if (request.url.host == 'www.google.com') {
          return http.Response('', 204);
        }
        if (request.url.host == 'www.lightnovel.fun') {
          if (request.url.path.contains('/api/')) {
            throw const SocketException('Connection refused');
          }
          return http.Response('<html>LK Web</html>', 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = NetworkDiagnosticService(
        httpClient: client,
        dnsLookup: (host) async => ['104.21.5.6'],
      );

      final dns = await service.testDns();
      final baidu = await service.testBaidu();
      final google = await service.testGoogle();
      final lkWeb = await service.testLkWeb();
      final lkApi = await service.testLkApi();

      expect(dns.status, DiagnosticStatus.success);
      expect(baidu.status, DiagnosticStatus.success);
      expect(lkWeb.status, DiagnosticStatus.success);
      expect(lkApi.status, DiagnosticStatus.failed);
      expect(lkApi.errorMessage, contains('拒绝连接'));

      final summary = NetworkDiagnosticService.evaluateSummary(
        results: {
          DiagnosticTarget.dns: dns,
          DiagnosticTarget.baidu: baidu,
          DiagnosticTarget.google: google,
          DiagnosticTarget.lkWeb: lkWeb,
          DiagnosticTarget.lkApi: lkApi,
        },
        appVersion: '1.5.1+2013',
        platformDescription: 'iOS',
      );

      expect(summary.allPassed, isFalse);
      expect(summary.title, contains('官网网页正常，但 API 接口连接失败'));
      expect(summary.suggestion, contains('VPN'));
      expect(summary.suggestion, contains('分流规则'));
    });

    test('dns lookup failure produces dns specific suggestion', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'www.baidu.com') {
          return http.Response('OK', 200);
        }
        return http.Response('fail', 500);
      });

      final service = NetworkDiagnosticService(
        httpClient: client,
        dnsLookup: (host) async =>
            throw const SocketException('Failed host lookup'),
      );

      final dns = await service.testDns();
      expect(dns.status, DiagnosticStatus.failed);
      expect(dns.errorMessage, contains('DNS 域名解析失败'));

      final summary = NetworkDiagnosticService.evaluateSummary(
        results: {
          DiagnosticTarget.dns: dns,
          DiagnosticTarget.baidu: await service.testBaidu(),
          DiagnosticTarget.google: await service.testGoogle(),
          DiagnosticTarget.lkWeb: await service.testLkWeb(),
          DiagnosticTarget.lkApi: await service.testLkApi(),
        },
        appVersion: '1.5.1+2013',
        platformDescription: 'iOS',
      );

      expect(summary.title, contains('LK 域名解析未通过'));
      expect(summary.suggestion, contains('DNS 设置'));
    });

    test('api business error (non-zero code) is surfaced cleanly', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/api/')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 429, 'message': '请求过于频繁，请稍后再试'})),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('OK', 200);
      });

      final service = NetworkDiagnosticService(
        httpClient: client,
        dnsLookup: (host) async => ['1.1.1.1'],
      );

      final lkApi = await service.testLkApi();
      expect(lkApi.status, DiagnosticStatus.failed);
      expect(lkApi.errorMessage, contains('code: 429'));
      expect(lkApi.errorMessage, isNot(contains('请求过于频繁')));
    });
  });

  group('NetworkDiagnosticPage Widget Tests', () {
    testWidgets(
        'renders initial idle view, triggers diagnostics, and shows report',
        (tester) async {
      String? copiedData;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedData = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final completer = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.url.host == 'www.baidu.com') {
          return completer.future;
        }
        if (request.url.host == 'www.google.com') {
          return http.Response('', 204);
        }
        if (request.url.host == 'www.lightnovel.fun') {
          if (request.url.path.contains('/api/')) {
            return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
          }
          return http.Response('<html>LK Web</html>', 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = NetworkDiagnosticService(
        httpClient: client,
        dnsLookup: (host) async => ['1.2.3.4'],
      );

      await tester.pumpWidget(MaterialApp(
        home: NetworkDiagnosticPage(service: service),
      ));
      await tester.pumpAndSettle();

      expect(find.text('网络连接诊断'), findsOneWidget);
      expect(find.text('开始网络诊断'), findsOneWidget);
      expect(find.text('国内网络连通性 (Baidu)'), findsOneWidget);
      expect(find.text('LK 数据接口 (API)'), findsOneWidget);
      expect(find.text('LK域名解析 (DNS)'), findsOneWidget);

      // Start testing
      await tester.tap(find.text('开始网络诊断'));
      await tester.pump();

      // Expect testing in progress
      expect(find.text('正在全面检测网络…'), findsOneWidget);

      completer.complete(http.Response('OK', 200));
      await tester.pumpAndSettle();

      // Expect testing finished
      expect(find.text('重新检测网络'), findsOneWidget);
      expect(find.text('网络连接良好，LK服务畅通'), findsOneWidget);
      expect(find.text('复制诊断结果'), findsOneWidget);

      // Tap copy report
      await tester.tap(find.text('复制诊断结果'));
      await tester.pumpAndSettle();
      expect(copiedData, contains('Yomiru 网络诊断报告'));
      expect(find.text('已复制诊断报告到剪贴板'), findsOneWidget);
    });
  });
}
