import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import '../api/lk_client.dart';

enum DiagnosticTarget {
  dns,
  baidu,
  google,
  lkWeb,
  lkApi,
}

enum DiagnosticStatus {
  idle,
  running,
  success,
  failed,
}

class DiagnosticResultItem {
  final DiagnosticTarget target;
  final String label;
  final String urlOrHost;
  final DiagnosticStatus status;
  final int? statusCode;
  final int? latencyMs;
  final String? errorMessage;
  final String? detail;
  final String? cfRay;
  final String? cfCacheStatus;

  const DiagnosticResultItem({
    required this.target,
    required this.label,
    required this.urlOrHost,
    this.status = DiagnosticStatus.idle,
    this.statusCode,
    this.latencyMs,
    this.errorMessage,
    this.detail,
    this.cfRay,
    this.cfCacheStatus,
  });

  DiagnosticResultItem copyWith({
    DiagnosticStatus? status,
    int? statusCode,
    int? latencyMs,
    String? errorMessage,
    String? detail,
    String? cfRay,
    String? cfCacheStatus,
  }) {
    return DiagnosticResultItem(
      target: target,
      label: label,
      urlOrHost: urlOrHost,
      status: status ?? this.status,
      statusCode: statusCode ?? this.statusCode,
      latencyMs: latencyMs ?? this.latencyMs,
      errorMessage: errorMessage ?? this.errorMessage,
      detail: detail ?? this.detail,
      cfRay: cfRay ?? this.cfRay,
      cfCacheStatus: cfCacheStatus ?? this.cfCacheStatus,
    );
  }
}

class DiagnosticSummary {
  final bool allPassed;
  final String title;
  final String suggestion;
  final String fullReport;

  const DiagnosticSummary({
    required this.allPassed,
    required this.title,
    required this.suggestion,
    required this.fullReport,
  });
}

class NetworkDiagnosticService {
  NetworkDiagnosticService({
    http.Client? httpClient,
    Future<List<String>> Function(String host)? dnsLookup,
  })  : _client = httpClient ?? http.Client(),
        _dnsLookup = dnsLookup ?? _defaultDnsLookup;

  final http.Client _client;
  final Future<List<String>> Function(String host) _dnsLookup;

  static Future<List<String>> _defaultDnsLookup(String host) async {
    final addresses =
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
    return addresses.map((a) => a.address).toList();
  }

  static const defaultTimeout = Duration(seconds: 8);

  static List<DiagnosticResultItem> initialItems() => const [
        DiagnosticResultItem(
          target: DiagnosticTarget.dns,
          label: 'LK 域名解析 (DNS)',
          urlOrHost: 'www.lightnovel.fun',
        ),
        DiagnosticResultItem(
          target: DiagnosticTarget.baidu,
          label: '国内网络连通性 (Baidu)',
          urlOrHost: 'https://www.baidu.com/',
        ),
        DiagnosticResultItem(
          target: DiagnosticTarget.google,
          label: '国际网络连通性 (Google)',
          urlOrHost: 'https://www.google.com/generate_204',
        ),
        DiagnosticResultItem(
          target: DiagnosticTarget.lkWeb,
          label: 'LK 官网网页 (Web)',
          urlOrHost: 'https://www.lightnovel.fun/',
        ),
        DiagnosticResultItem(
          target: DiagnosticTarget.lkApi,
          label: 'LK 数据接口 (API)',
          urlOrHost:
              'https://www.lightnovel.fun/api/pc-proxy/api/bff/home-promo-v1',
        ),
      ];

  Future<DiagnosticResultItem> testDns() async {
    const target = DiagnosticTarget.dns;
    const label = 'LK 域名解析 (DNS)';
    const host = 'www.lightnovel.fun';
    final sw = Stopwatch()..start();
    try {
      final ips = await _dnsLookup(host);
      sw.stop();
      if (ips.isEmpty) {
        return const DiagnosticResultItem(
          target: target,
          label: label,
          urlOrHost: host,
          status: DiagnosticStatus.failed,
          errorMessage: '未能解析到有效 IP 地址记录',
        );
      }
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: host,
        status: DiagnosticStatus.success,
        latencyMs: sw.elapsedMilliseconds,
        detail: '解析成功 (返回 ${ips.length} 个地址记录)',
      );
    } catch (e) {
      sw.stop();
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: host,
        status: DiagnosticStatus.failed,
        errorMessage: _formatError(e),
      );
    }
  }

  Future<DiagnosticResultItem> testBaidu() async {
    const target = DiagnosticTarget.baidu;
    const label = '国内网络连通性 (Baidu)';
    const url = 'https://www.baidu.com/';
    final sw = Stopwatch()..start();
    try {
      final res = await _client.get(Uri.parse(url)).timeout(defaultTimeout);
      sw.stop();
      if (res.statusCode >= 200 && res.statusCode < 400) {
        return DiagnosticResultItem(
          target: target,
          label: label,
          urlOrHost: url,
          status: DiagnosticStatus.success,
          statusCode: res.statusCode,
          latencyMs: sw.elapsedMilliseconds,
          detail: 'HTTP ${res.statusCode}',
        );
      } else {
        return DiagnosticResultItem(
          target: target,
          label: label,
          urlOrHost: url,
          status: DiagnosticStatus.failed,
          statusCode: res.statusCode,
          latencyMs: sw.elapsedMilliseconds,
          errorMessage: '响应状态码异常 (HTTP ${res.statusCode})',
        );
      }
    } catch (e) {
      sw.stop();
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: url,
        status: DiagnosticStatus.failed,
        errorMessage: _formatError(e),
      );
    }
  }

  Future<DiagnosticResultItem> testGoogle() async {
    const target = DiagnosticTarget.google;
    const label = '国际网络连通性 (Google)';
    const url = 'https://www.google.com/generate_204';
    final sw = Stopwatch()..start();
    try {
      final res = await _client.get(Uri.parse(url)).timeout(defaultTimeout);
      sw.stop();
      if (res.statusCode == 204) {
        return DiagnosticResultItem(
          target: target,
          label: label,
          urlOrHost: url,
          status: DiagnosticStatus.success,
          statusCode: res.statusCode,
          latencyMs: sw.elapsedMilliseconds,
          detail: 'HTTP ${res.statusCode}',
        );
      } else {
        return DiagnosticResultItem(
          target: target,
          label: label,
          urlOrHost: url,
          status: DiagnosticStatus.failed,
          statusCode: res.statusCode,
          latencyMs: sw.elapsedMilliseconds,
          errorMessage: '未确认国际网络连通性 (HTTP ${res.statusCode})',
        );
      }
    } catch (e) {
      sw.stop();
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: url,
        status: DiagnosticStatus.failed,
        errorMessage: _formatError(e),
      );
    }
  }

  static bool _matchesExactly(String pattern, String value) {
    final match = RegExp(pattern).matchAsPrefix(value);
    return match != null && match.end == value.length;
  }

  // 仅接受 Cloudflare Ray ID 的规范形式和已知缓存状态。
  static String? _safeRay(String? value) {
    if (value == null ||
        !_matchesExactly(r'[0-9a-fA-F]{16,32}-[A-Za-z]{3}', value)) {
      return null;
    }
    return value;
  }

  static String? _safeCacheStatus(String? value) {
    const allowed = {
      'HIT',
      'MISS',
      'DYNAMIC',
      'BYPASS',
      'EXPIRED',
      'STALE',
      'UPDATING',
      'REVALIDATED',
      'NONE',
    };
    return value != null && allowed.contains(value) ? value : null;
  }

  static String? _header(http.Response response, String name) {
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  static bool _isChallenge(http.Response response) =>
      _header(response, 'cf-mitigated')?.trim().toLowerCase() == 'challenge';

  Future<DiagnosticResultItem> testLkWeb() async {
    const target = DiagnosticTarget.lkWeb;
    const label = 'LK 官网网页 (Web)';
    const url = 'https://www.lightnovel.fun/';
    final sw = Stopwatch()..start();
    try {
      final res = await _client.get(Uri.parse(url)).timeout(defaultTimeout);
      sw.stop();
      final challenge = _isChallenge(res);
      final ok = !challenge && res.statusCode >= 200 && res.statusCode < 400;
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: url,
        status: ok ? DiagnosticStatus.success : DiagnosticStatus.failed,
        statusCode: res.statusCode,
        latencyMs: sw.elapsedMilliseconds,
        detail: ok ? 'HTTP ${res.statusCode}' : null,
        errorMessage: challenge
            ? 'Cloudflare 验证挑战 (HTTP ${res.statusCode})'
            : ok
                ? null
                : '网页返回状态码异常 (HTTP ${res.statusCode})',
        cfRay: _safeRay(_header(res, 'cf-ray')),
        cfCacheStatus: _safeCacheStatus(_header(res, 'cf-cache-status')),
      );
    } catch (e) {
      sw.stop();
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: url,
        status: DiagnosticStatus.failed,
        errorMessage: _formatError(e),
      );
    }
  }

  Future<DiagnosticResultItem> testLkApi() async {
    const target = DiagnosticTarget.lkApi;
    const label = 'LK 数据接口 (API)';
    const url = 'https://www.lightnovel.fun/api/pc-proxy/api/bff/home-promo-v1';
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .post(
            Uri.parse(url),
            headers: LKClient.publicReadOnlyHeaders(),
            body: jsonEncode({'page': 1, 'pageSize': 8}),
          )
          .timeout(defaultTimeout);
      sw.stop();
      String? error;
      String? detail;
      if (_isChallenge(res)) {
        error = 'Cloudflare 验证挑战 (HTTP ${res.statusCode})';
      } else if (res.statusCode != 200) {
        error = '接口返回错误 HTTP ${res.statusCode}';
      } else {
        Object? decoded;
        var parsed = false;
        try {
          decoded = jsonDecode(utf8.decode(res.bodyBytes));
          parsed = true;
        } catch (_) {
          // 响应正文不可用于错误信息。
        }
        if (!parsed) {
          error = '响应非合法 JSON 格式';
        } else if (decoded is! Map) {
          error = 'API 响应格式错误';
        } else {
          final code = _safeBusinessCode(decoded['code']);
          if (code == '0') {
            detail = 'API 正常 (code: 0)';
          } else if (code != null) {
            error = '业务错误返回 (code: $code)';
          } else {
            error = 'API 业务码无效';
          }
        }
      }
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: url,
        status:
            error == null ? DiagnosticStatus.success : DiagnosticStatus.failed,
        statusCode: res.statusCode,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: error,
        detail: detail,
        cfRay: _safeRay(_header(res, 'cf-ray')),
        cfCacheStatus: _safeCacheStatus(_header(res, 'cf-cache-status')),
      );
    } catch (e) {
      sw.stop();
      return DiagnosticResultItem(
        target: target,
        label: label,
        urlOrHost: url,
        status: DiagnosticStatus.failed,
        errorMessage: _formatError(e),
      );
    }
  }

  static String? _safeBusinessCode(Object? value) {
    // 限定整数及十进制数字字符串；避免将任意服务端内容带入报告。
    if (value is int && value >= 0 && value <= 999999999) {
      return value.toString();
    }
    if (value is String && _matchesExactly(r'(0|[1-9][0-9]{0,8})', value)) {
      return value;
    }
    return null;
  }

  static String _formatError(Object error) {
    if (error is TimeoutException) return '连接或等待超时 (Timeout)';
    if (error is HandshakeException || error is TlsException) {
      return 'SSL/TLS 证书校验或握手失败';
    }
    if (error is SocketException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('failed host lookup') ||
          msg.contains('nodename') ||
          msg.contains('servname')) {
        return 'DNS 域名解析失败 (Host lookup failed)';
      }
      if (msg.contains('connection refused')) {
        return '服务器拒绝连接 (Connection refused)';
      }
      if (msg.contains('network is unreachable')) {
        return '网络不可达 (Network unreachable)';
      }
      if (msg.contains('connection reset') || msg.contains('broken pipe')) {
        return '连接被重置 (Connection reset by peer)';
      }
      return '网络套接字错误';
    }
    return '连接或请求失败';
  }

  static String? _safeReportMessage(String? value) {
    if (value == null) return null;
    const fixed = {
      '未能解析到有效 IP 地址记录',
      '连接或等待超时 (Timeout)',
      'SSL/TLS 证书校验或握手失败',
      'DNS 域名解析失败 (Host lookup failed)',
      '服务器拒绝连接 (Connection refused)',
      '网络不可达 (Network unreachable)',
      '连接被重置 (Connection reset by peer)',
      '网络套接字错误',
      '连接或请求失败',
      '响应非合法 JSON 格式',
      'API 响应格式错误',
      'API 业务码无效',
      'API 正常 (code: 0)',
    };
    if (fixed.contains(value)) return value;
    const patterns = [
      r'^解析成功 \(返回 [0-9]{1,9} 个地址记录\)$',
      r'^HTTP [1-5][0-9]{2}$',
      r'^响应状态码异常 \(HTTP [1-5][0-9]{2}\)$',
      r'^未确认国际网络连通性 \(HTTP [1-5][0-9]{2}\)$',
      r'^网页返回状态码异常 \(HTTP [1-5][0-9]{2}\)$',
      r'^Cloudflare 验证挑战 \(HTTP [1-5][0-9]{2}\)$',
      r'^接口返回错误 HTTP [1-5][0-9]{2}$',
      r'^业务错误返回 \(code: (0|[1-9][0-9]{0,8})\)$',
    ];
    return patterns.any((pattern) => _matchesExactly(pattern, value))
        ? value
        : null;
  }

  static DiagnosticSummary evaluateSummary({
    required Map<DiagnosticTarget, DiagnosticResultItem> results,
    required String appVersion,
    required String platformDescription,
    bool includeRayId = false,
  }) {
    final dns = results[DiagnosticTarget.dns];
    final baidu = results[DiagnosticTarget.baidu];
    final google = results[DiagnosticTarget.google];
    final lkWeb = results[DiagnosticTarget.lkWeb];
    final lkApi = results[DiagnosticTarget.lkApi];

    final isDnsOk = dns?.status == DiagnosticStatus.success;
    final isBaiduOk = baidu?.status == DiagnosticStatus.success;
    final isGoogleOk = google?.status == DiagnosticStatus.success;
    final isLkWebOk = lkWeb?.status == DiagnosticStatus.success;
    final isLkApiOk = lkApi?.status == DiagnosticStatus.success;

    final allPassed =
        isDnsOk && isBaiduOk && isGoogleOk && isLkWebOk && isLkApiOk;

    String title;
    String suggestion;

    final allCompleted = DiagnosticTarget.values.every((target) {
      final status = results[target]?.status;
      return status == DiagnosticStatus.success ||
          status == DiagnosticStatus.failed;
    });

    if (allPassed) {
      title = '网络连接良好，LK服务畅通';
      suggestion = '本次各检测目标均返回预期结果。';
    } else if (!allCompleted) {
      title = '网络诊断尚未完成';
      suggestion = '部分目标尚未完成检测，请参考已完成项目的结果。';
    } else if (isLkApiOk && isLkWebOk) {
      title = 'LK 服务连接正常';
      suggestion = 'LK 网页与 API 本次检测通过；其他目标请查看各自结果。'
          'Google 未返回预期结果时，国际网络连通性尚未确认。';
    } else if (isLkWebOk && !isLkApiOk) {
      title = '官网网页正常，但 API 接口连接失败';
      suggestion = '网页与 API 使用同一域名，pc-proxy 是接口路径而非独立域名。'
          '本次 API 检测未通过，原因尚未确定；可检查 VPN / 代理分流规则，'
          '切换网络或稍后重试，并参考具体检测结果。';
    } else if (isBaiduOk && !isLkWebOk && !isLkApiOk && !isDnsOk) {
      title = 'Baidu 检测通过，LK 域名解析未通过';
      suggestion = '请检查 DNS 设置或切换网络后重试；具体原因尚未确定。';
    } else if (isBaiduOk && !isLkWebOk && !isLkApiOk) {
      title = 'Baidu 检测通过，LK 检测未通过';
      suggestion = '可稍后重试或切换网络，并参考各项错误信息；具体原因尚未确定。';
    } else if (!isBaiduOk && !isGoogleOk && !isLkWebOk && !isLkApiOk) {
      title = '多个网络目标未通过检测';
      suggestion = '本次检测未确认这些目标的连通性。请检查网络连接及应用联网权限，'
          '或切换网络后重试。';
    } else {
      title = '部分网络目标未通过检测';
      suggestion = '请根据下方各项检测结果排查，或切换网络后重试。';
    }

    final now = DateTime.now();
    final timeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    final report = StringBuffer();
    report.writeln('Yomiru 网络诊断报告');
    report.writeln('- 测试时间：$timeStr');
    final versionAllowed = _matchesExactly(
        r'[0-9]{1,6}(?:\.[0-9]{1,6}){0,3}(?:\+[0-9]{1,10})?', appVersion);
    final resemblesIpv4 =
        _matchesExactly(r'[0-9]{1,3}(?:\.[0-9]{1,3}){3}', appVersion);
    final safeVersion = versionAllowed && !resemblesIpv4 ? appVersion : '未知';
    const platforms = {
      'android',
      'iOS',
      'ios',
      'macOS',
      'macos',
      'windows',
      'linux',
      'fuchsia'
    };
    final safePlatform =
        platforms.contains(platformDescription) ? platformDescription : '未知';
    report.writeln('- 应用版本：$safeVersion');
    report.writeln('- 设备平台：$safePlatform');
    report.writeln();
    report.writeln('测试详情：');
    final labels = {for (final item in initialItems()) item.target: item.label};
    for (final entry in results.entries) {
      final item = entry.value;
      final statusStr = switch (item.status) {
        DiagnosticStatus.success => '成功',
        DiagnosticStatus.failed => '失败',
        DiagnosticStatus.running => '检测中',
        DiagnosticStatus.idle => '未检测',
      };
      final message = _safeReportMessage(item.status == DiagnosticStatus.success
          ? item.detail
          : item.errorMessage);
      final parts = <String>[statusStr];
      if (message != null) parts.add(message);
      if (item.latencyMs != null &&
          item.latencyMs! >= 0 &&
          item.latencyMs! <= 86400000) {
        parts.add('${item.latencyMs}ms');
      }
      final cache = _safeCacheStatus(item.cfCacheStatus);
      if (cache != null) parts.add('cf-cache-status: $cache');
      final ray = _safeRay(item.cfRay);
      if (includeRayId && ray != null) parts.add('cf-ray: $ray');
      report.writeln('• ${labels[entry.key]}：${parts.join('，')}');
    }
    report.writeln();
    report.writeln('诊断结论：【$title】');
    report.writeln(suggestion);

    return DiagnosticSummary(
      allPassed: allPassed,
      title: title,
      suggestion: suggestion,
      fullReport: report.toString().trim(),
    );
  }
}
