import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/app_motion.dart';
import '../services/network_diagnostic_service.dart';
import '../widgets/common.dart';

class NetworkDiagnosticPage extends StatefulWidget {
  const NetworkDiagnosticPage({super.key, this.service});

  final NetworkDiagnosticService? service;

  @override
  State<NetworkDiagnosticPage> createState() => _NetworkDiagnosticPageState();
}

class _NetworkDiagnosticPageState extends State<NetworkDiagnosticPage> {
  late final NetworkDiagnosticService _service =
      widget.service ?? NetworkDiagnosticService();

  late final Map<DiagnosticTarget, DiagnosticResultItem> _results = {
    for (final item in NetworkDiagnosticService.initialItems())
      item.target: item,
  };

  bool _testing = false;
  bool _hasRun = false;
  DiagnosticSummary? _summary;
  String _appVersion = '1.5.1';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = '${info.version}+${info.buildNumber}';
        });
      }
    } catch (_) {}
  }

  Future<void> _startDiagnostics() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _hasRun = true;
      _summary = null;
      for (final target in _results.keys) {
        _results[target] =
            _results[target]!.copyWith(status: DiagnosticStatus.running);
      }
    });

    Future<void> runTask(DiagnosticTarget target,
        Future<DiagnosticResultItem> Function() task) async {
      final res = await task();
      if (mounted) {
        setState(() {
          _results[target] = res;
        });
      }
    }

    // Run all 5 diagnostic targets concurrently
    await Future.wait([
      runTask(DiagnosticTarget.dns, _service.testDns),
      runTask(DiagnosticTarget.baidu, _service.testBaidu),
      runTask(DiagnosticTarget.google, _service.testGoogle),
      runTask(DiagnosticTarget.lkWeb, _service.testLkWeb),
      runTask(DiagnosticTarget.lkApi, _service.testLkApi),
    ]);

    if (!mounted) return;

    final summary = NetworkDiagnosticService.evaluateSummary(
      results: _results,
      appVersion: _appVersion,
      platformDescription: defaultTargetPlatform.name,
    );

    setState(() {
      _testing = false;
      _summary = summary;
    });
  }

  Future<void> _copyReport() async {
    final report = _summary?.fullReport;
    if (report == null || report.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: report));
    } catch (_) {}
    if (mounted) {
      showFloatingPrompt(context, '已复制诊断报告到剪贴板');
    }
  }

  Widget _buildStatusIcon(DiagnosticStatus status, ColorScheme scheme) {
    switch (status) {
      case DiagnosticStatus.idle:
        return Icon(Icons.radio_button_unchecked_rounded,
            size: 20, color: scheme.outline);
      case DiagnosticStatus.running:
        return const SizedBox.square(
          dimension: 18,
          child: MotionProgressIndicator(strokeWidth: 2),
        );
      case DiagnosticStatus.success:
        return Icon(Icons.check_circle_rounded,
            size: 22, color: scheme.primary);
      case DiagnosticStatus.failed:
        return Icon(Icons.cancel_rounded, size: 22, color: scheme.error);
    }
  }

  Widget _buildItemTile(DiagnosticResultItem item, ColorScheme scheme) {
    final isSuccess = item.status == DiagnosticStatus.success;
    final isFailed = item.status == DiagnosticStatus.failed;
    final isRunning = item.status == DiagnosticStatus.running;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildStatusIcon(item.status, scheme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.urlOrHost,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isRunning)
                Text(
                  '测试中…',
                  style: TextStyle(fontSize: 12, color: scheme.primary),
                )
              else if (isSuccess)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${item.latencyMs ?? 0} ms',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                )
              else if (isFailed)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '连接异常',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
            ],
          ),
          if (isFailed && item.errorMessage != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: Text(
                item.errorMessage!,
                style:
                    TextStyle(fontSize: 12, color: scheme.error, height: 1.3),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('网络连接诊断'),
        actions: [
          if (_summary != null)
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              tooltip: '复制诊断结果',
              onPressed: _copyReport,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Notice card
            Card(
              elevation: 0,
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.25),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '本诊断将依次测试轻之国度服务器、国内网络与国际网络的可达性，用于对照分析连接瓶颈。',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Diagnostic items container
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.25),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < _results.values.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 48,
                        endIndent: 16,
                        color: scheme.outlineVariant.withValues(alpha: 0.2),
                      ),
                    _buildItemTile(_results.values.elementAt(i), scheme),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Action button
            FilledButton.icon(
              onPressed: _testing ? null : _startDiagnostics,
              icon: _testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: MotionProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_hasRun
                      ? Icons.refresh_rounded
                      : Icons.network_check_rounded),
              label: Text(
                  _testing ? '正在全面检测网络…' : (_hasRun ? '重新检测网络' : '开始网络诊断')),
            ),
            const SizedBox(height: 20),

            // Summary / Suggestion section
            if (_summary != null) ...[
              Card(
                elevation: 0,
                color: _summary!.allPassed
                    ? scheme.primaryContainer.withValues(alpha: 0.35)
                    : scheme.errorContainer.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: (_summary!.allPassed ? scheme.primary : scheme.error)
                        .withValues(alpha: 0.3),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _summary!.allPassed
                                ? Icons.check_circle_rounded
                                : Icons.warning_amber_rounded,
                            color: _summary!.allPassed
                                ? scheme.primary
                                : scheme.error,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _summary!.title,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _summary!.suggestion,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton.icon(
                          onPressed: _copyReport,
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('复制诊断结果'),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
