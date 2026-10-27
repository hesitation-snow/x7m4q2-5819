import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

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

  const DiagnosticResultItem({
    required this.target,
    required this.label,
    required this.urlOrHost,
    this.status = DiagnosticStatus.idle,
    this.statusCode,
    this.latencyMs,
    this.errorMessage,
    this.detail,
  });

  DiagnosticResultItem copyWith({
    DiagnosticStatus? status,
    int? statusCode,
    int? latencyMs,
    String? errorMessage,
    String? detail,
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
          label: 'LK域名解析 (DNS)',
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
          label: 'LK官网网页 (Web)',
          urlOrHost: 'https://www.lightnovel.fun/',
        ),
        DiagnosticResultItem(
          target: DiagnosticTarget.lkApi,
          label: 'LK数据接口 (API)',
          urlOrHost:
              'https://www.lightnovel.fun/api/pc-proxy/api/bff/home-promo-v1',
        ),
      ];

  Future<DiagnosticResultItem> testDns() async {
    const target = DiagnosticTarget.dns;
    const label = 'LK域名解析 (DNS)';
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
      if (res.statusCode == 204 ||
          (res.statusCode >= 200 && res.statusCode < 400)) {
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

  Future<DiagnosticResultItem> testLkWeb() async {
    const target = DiagnosticTarget.lkWeb;
    const label = 'LK官网网页 (Web)';
    const url = 'https://www.lightnovel.fun/';
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
          errorMessage: '网页返回状态码异常 (HTTP ${res.statusCode})',
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

  Future<DiagnosticResultItem> testLkApi() async {
    const target = DiagnosticTarget.lkApi;
    const label = 'LK数据接口 (API)';
    const url = 'https://www.lightnovel.fun/api/pc-proxy/api/bff/home-promo-v1';
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'page': 1, 'pageSize': 8}),
          )
          .timeout(defaultTimeout);
      sw.stop();
      if (res.statusCode == 200) {
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is Map && decoded['code'] == 0) {
            return DiagnosticResultItem(
              target: target,
              label: label,
              urlOrHost: url,
              status: DiagnosticStatus.success,
              statusCode: 200,
              latencyMs: sw.elapsedMilliseconds,
              detail: 'API 正常 (code: 0)',
            );
          } else {
            final code = decoded is Map ? decoded['code'] : 'format error';
            final msg = decoded is Map
                ? (decoded['message'] ?? decoded['msg'] ?? '')
                : '';
            final msgStr = msg.toString().trim();
            return DiagnosticResultItem(
              target: target,
              label: label,
              urlOrHost: url,
              status: DiagnosticStatus.failed,
              statusCode: 200,
              latencyMs: sw.elapsedMilliseconds,
              errorMessage:
                  '业务错误返回 (code: $code${msgStr.isNotEmpty ? ' $msgStr' : ''})',
            );
          }
        } catch (_) {
          return DiagnosticResultItem(
            target: target,
            label: label,
            urlOrHost: url,
            status: DiagnosticStatus.failed,
            statusCode: 200,
            latencyMs: sw.elapsedMilliseconds,
            errorMessage: '响应非合法 JSON 格式',
          );
        }
      } else {
        return DiagnosticResultItem(
          target: target,
          label: label,
          urlOrHost: url,
          status: DiagnosticStatus.failed,
          statusCode: res.statusCode,
          latencyMs: sw.elapsedMilliseconds,
          errorMessage: '接口返回错误 HTTP ${res.statusCode}',
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

  static String _formatError(Object error) {
    if (error is TimeoutException) {
      return '连接或等待超时 (Timeout)';
    }
    final str = error.toString();
    if (error is HandshakeException ||
        str.contains('Certificate') ||
        str.contains('Handshake') ||
        str.contains('CERTIFICATE_VERIFY_FAILED')) {
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
      return '网络套接字错误 (${error.message})';
    }
    return str.replaceAll('Exception: ', '').trim();
  }

  static DiagnosticSummary evaluateSummary({
    required Map<DiagnosticTarget, DiagnosticResultItem> results,
    required String appVersion,
    required String platformDescription,
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

    if (isLkApiOk && isLkWebOk) {
      if (isGoogleOk) {
        title = '网络连接良好，LK服务畅通';
        suggestion = '国内网络、国际网络与LK网站及 API 接口均可正常访问。';
      } else {
        title = 'LK服务连接正常';
        suggestion = '国内网络与LK服务均正常。当前未连接国际网络（若未开启海外代理属正常现象）。';
      }
    } else if (isLkWebOk && !isLkApiOk) {
      title = '官网网页正常，但 API 接口连接失败';
      suggestion = 'LK网页可以正常打开，但 App 数据接口（API）连接失败。这通常由以下原因造成：\n'
          '1. VPN / 代理分流规则未包含 API 域名网关（pc-proxy）；\n'
          '2. 节点或网络服务商拦截了接口数据包；\n'
          '3. 接口服务器临时出现波动或针对当前 IP 限制。\n'
          '建议排查：尝试完全断开并关闭 VPN 后重新测试；若必须使用 VPN，请将代理模式切换为「全局/全部代理」或尝试更换手机热点。';
    } else if (isBaiduOk && !isLkWebOk && !isLkApiOk) {
      if (!isDnsOk) {
        title = '国内网络正常，但LK域名解析失败';
        suggestion =
            '国内基础网络正常，但无法解析LK服务器域名（DNS 失败）。建议检查当前 Wi-Fi 的 DNS 设置（尝试手动修改为公共 DNS，如 223.5.5.5 或 119.29.29.29），或切换为手机热点重试。';
      } else {
        title = '国内网络正常，但无法连接LK';
        suggestion =
            '国内基础网络连接正常，但无法连通LK服务器。可能LK服务器正在维护，或当前网络节点到LK机房路由受阻。建议稍后重试，或尝试切换网络线路。';
      }
    } else if (!isBaiduOk && !isGoogleOk && !isLkWebOk && !isLkApiOk) {
      title = '设备未连接互联网或网络完全受阻';
      suggestion =
          '所有目标站点均无法连接。请检查设备是否已开启飞行模式、Wi-Fi / 移动数据是否已连接，以及系统是否禁止了 Yomiru 的无线局域网与蜂窝数据访问权限。';
    } else {
      title = '部分网络节点连接异常';
      suggestion = '部分目标站点连接失败，请根据下方详细诊断条目排查具体网络环节。';
    }

    final now = DateTime.now();
    final timeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    final report = StringBuffer();
    report.writeln('Yomiru 网络诊断报告');
    report.writeln('- 测试时间：$timeStr');
    report.writeln('- 应用版本：$appVersion');
    report.writeln('- 设备平台：$platformDescription');
    report.writeln();
    report.writeln('测试详情：');
    for (final item in results.values) {
      final statusStr = item.status == DiagnosticStatus.success
          ? '成功 (${item.detail ?? 'HTTP ${item.statusCode}'}, ${item.latencyMs}ms)'
          : '失败 (${item.errorMessage ?? '错误'})';
      report.writeln('• ${item.label}：$statusStr');
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
