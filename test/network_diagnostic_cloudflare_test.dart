import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/services/network_diagnostic_service.dart';

const _validRay = 'abcdef0123456789-HKG';
const _leaks = <String>[
  '198.51.100.42',
  'secret-password-xyz',
  'token-secret-xyz',
  'https://evil.example/private?key=secret',
];
const _hostile = '198.51.100.42 password=secret-password-xyz '
    'token=token-secret-xyz https://evil.example/private?key=secret';

NetworkDiagnosticService _service(
    http.Response Function(http.Request) respond) {
  return NetworkDiagnosticService(
    httpClient: MockClient((request) async => respond(request)),
    dnsLookup: (_) async => ['198.51.100.42'],
  );
}

DiagnosticSummary _summary(DiagnosticResultItem item, {bool? includeRayId}) {
  final results = {item.target: item};
  if (includeRayId == null) {
    return NetworkDiagnosticService.evaluateSummary(
      results: results,
      appVersion: '1.6.0+2014',
      platformDescription: 'test',
    );
  }
  return NetworkDiagnosticService.evaluateSummary(
    results: results,
    appVersion: '1.6.0+2014',
    platformDescription: 'test',
    includeRayId: includeRayId,
  );
}

void _expectNoLeaks(String text) {
  for (final value in _leaks) {
    expect(text, isNot(contains(value)),
        reason: 'private value leaked: $value');
  }
}

void main() {
  group('LK API request mirrors the app without credentials', () {
    test('sends the app headers, method and unauthenticated JSON body',
        () async {
      http.Request? captured;
      final service = _service((request) {
        captured = request;
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      });
      final result = await service.testLkApi();
      expect(result.status, DiagnosticStatus.success);
      final request = captured!;
      expect(request.method, 'POST');
      expect(request.url.toString(),
          'https://www.lightnovel.fun/api/pc-proxy/api/bff/home-promo-v1');
      final headers =
          request.headers.map((k, v) => MapEntry(k.toLowerCase(), v));
      expect(headers['content-type'], startsWith('application/json'));
      expect(headers['accept'], 'application/json');
      expect(headers['user-agent'],
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36 LKFlutter/0.1');
      expect(headers['origin'], 'https://www.lightnovel.fun');
      expect(headers['referer'], 'https://www.lightnovel.fun/');
      expect(headers.containsKey('cookie'), isFalse);
      expect(headers.containsKey('authorization'), isFalse);
      expect(headers.containsKey('security_key'), isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body, {'page': 1, 'pageSize': 8});
      expect(body.containsKey('security_key'), isFalse);
    });
  });

  group('Cloudflare challenge classification', () {
    for (final status in [200, 403, 429, 503]) {
      test('cf-mitigated challenge takes precedence for HTTP $status',
          () async {
        final service = _service((_) => http.Response(
              // A challenge must win even over an otherwise valid business body.
              jsonEncode({'code': 0, 'data': {}}),
              status,
              headers: {'Cf-Mitigated': 'challenge'},
            ));
        final result = await service.testLkApi();
        expect(result.status, DiagnosticStatus.failed);
        expect(result.statusCode, status);
        expect(
            '${result.errorMessage} ${result.detail}'.toLowerCase(),
            anyOf(contains('cloudflare'), contains('challenge'), contains('挑战'),
                contains('验证')));
      });
    }

    for (final status in [200, 403]) {
      test('LK Web HTTP $status challenge is not reported as normal', () async {
        final result = await _service((_) => http.Response(
              '<html>verification</html>',
              status,
              headers: {'cf-mitigated': 'challenge'},
            )).testLkWeb();
        expect(result.status, DiagnosticStatus.failed);
        expect(result.statusCode, status);
        expect(
            '${result.errorMessage} ${result.detail}'.toLowerCase(),
            anyOf(contains('cloudflare'), contains('challenge'), contains('挑战'),
                contains('验证')));
      });
    }

    test('plain HTTP 403 is failure without asserting a Cloudflare challenge',
        () async {
      final result =
          await _service((_) => http.Response('Forbidden', 403)).testLkApi();
      expect(result.status, DiagnosticStatus.failed);
      expect(result.statusCode, 403);
      final text = '${result.errorMessage} ${result.detail}'.toLowerCase();
      expect(text, isNot(contains('cloudflare')));
      expect(text, isNot(contains('challenge')));
      expect(text, isNot(contains('挑战')));
    });

    test('non-challenge mitigation header does not become a challenge',
        () async {
      final result = await _service((_) => http.Response(
            jsonEncode({'code': 0, 'data': {}}),
            200,
            headers: {'cf-mitigated': 'not-a-challenge'},
          )).testLkApi();
      expect(result.status, DiagnosticStatus.success);
    });
  });

  group('Cloudflare metadata and copyable report privacy', () {
    test('valid cache status may be reported; raw cf-ray requires consent',
        () async {
      final result = await _service((_) => http.Response(
            jsonEncode({'code': 0, 'data': {}}),
            200,
            headers: {'cf-cache-status': 'HIT', 'cf-ray': _validRay},
          )).testLkApi();
      final defaultReport = _summary(result).fullReport;
      final explicitNo = _summary(result, includeRayId: false).fullReport;
      final explicitYes = _summary(result, includeRayId: true).fullReport;
      expect(defaultReport.toUpperCase(), contains('HIT'));
      expect(defaultReport, isNot(contains(_validRay)));
      expect(explicitNo, isNot(contains(_validRay)));
      expect(explicitYes, contains(_validRay));
    });

    for (final bad in [_hostile, 'HIT; $_hostile', 'HIT\n$_hostile']) {
      test('rejects untrusted cache and ray header values: $bad', () async {
        final result = await _service((_) => http.Response(
              jsonEncode({'code': 0, 'data': {}}),
              200,
              headers: {'cf-cache-status': bad, 'cf-ray': bad},
            )).testLkApi();
        final report = _summary(result, includeRayId: true).fullReport;
        _expectNoLeaks(report);
        expect(report, isNot(contains(bad)));
      });
    }

    test('business error code and hostile message do not leak into report',
        () async {
      final result = await _service((_) => http.Response(
            jsonEncode({'code': 429, 'message': _hostile}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )).testLkApi();
      expect(result.status, DiagnosticStatus.failed);
      expect(_summary(result).fullReport, contains('429'));
      _expectNoLeaks(_summary(result).fullReport);
    });

    test('unknown exception and socket exception are not copied verbatim',
        () async {
      for (final error in [
        Exception(_hostile),
        const SocketException(_hostile)
      ]) {
        final service = NetworkDiagnosticService(
          httpClient: MockClient((_) async => throw error),
          dnsLookup: (_) async => ['198.51.100.42'],
        );
        final result = await service.testLkApi();
        expect(result.status, DiagnosticStatus.failed);
        _expectNoLeaks(_summary(result).fullReport);
      }
    });

    test('malicious business code, metadata and invalid HTML do not leak',
        () async {
      for (final response in [
        http.Response(jsonEncode({'code': _hostile, 'msg': _hostile}), 200),
        http.Response('<html>$_hostile</html>', 200),
      ]) {
        final item = await _service((_) => response).testLkApi();
        expect(item.status, DiagnosticStatus.failed);
        _expectNoLeaks(_summary(item).fullReport);
      }
    });
  });

  group('connectivity interpretation', () {
    test('Google generate_204 succeeds only with 204, not a captive portal 200',
        () async {
      for (final status in [200, 302, 403]) {
        final result =
            await _service((_) => http.Response('<html>login</html>', status))
                .testGoogle();
        expect(result.status, DiagnosticStatus.failed, reason: 'HTTP $status');
      }
      final result = await _service((_) => http.Response('', 204)).testGoogle();
      expect(result.status, DiagnosticStatus.success);
    });

    test('mixed results do not claim all networks are healthy', () {
      for (final failing in [
        DiagnosticTarget.baidu,
        DiagnosticTarget.dns,
        DiagnosticTarget.google
      ]) {
        final results = <DiagnosticTarget, DiagnosticResultItem>{
          for (final item in NetworkDiagnosticService.initialItems())
            item.target: item.copyWith(
              status: item.target == failing
                  ? DiagnosticStatus.failed
                  : DiagnosticStatus.success,
            ),
        };
        final summary = NetworkDiagnosticService.evaluateSummary(
          results: results,
          appVersion: '1.6.0+2014',
          platformDescription: 'test',
        );
        expect(summary.allPassed, isFalse);
        expect(summary.title, isNot(contains('网络连接良好')));
        expect(summary.suggestion,
            isNot(contains('国内网络、国际网络与 LK 网站及 API 接口均可正常访问')));
        if (failing == DiagnosticTarget.baidu) {
          expect(summary.suggestion, isNot(contains('国内网络与 LK 服务均正常')));
        }
      }
    });
  });
}
