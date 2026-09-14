import 'app_motion.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/lk_api.dart';
import '../api/models.dart';
import '../widgets/common.dart';

class AppUpdateInfo {
  final PackageInfo package;
  final LKRelease? release;

  const AppUpdateInfo({required this.package, required this.release});

  String get currentVersion => package.version;
  String get currentLabel => '${package.version}+${package.buildNumber}';
  String get latestVersion =>
      release?.tag.replaceFirst(RegExp(r'^v'), '') ?? '';
  bool get hasNewVersion =>
      latestVersion.isNotEmpty &&
      compareVersions(latestVersion, currentVersion) > 0;
}

/// 应用更新入口。启动检查和设置页手动检查共用同一份版本判断与下载弹窗。
class YomiruUpdateService {
  static const repositoryUrl = 'https://github.com/hesitation-snow/yomiru';
  static const releasesUrl = '$repositoryUrl/releases';
  static const baiduDownloadUrl =
      'https://pan.baidu.com/s/1UK9bD81BBMg4KbUWtobO3Q?pwd=ga6c';

  static bool _startupCheckStarted = false;
  static Future<AppUpdateInfo>? _inFlight;

  static Future<AppUpdateInfo> check() {
    return _inFlight ??= _fetch().whenComplete(() => _inFlight = null);
  }

  static Future<AppUpdateInfo> _fetch() async {
    final results = await Future.wait<Object?>([
      PackageInfo.fromPlatform(),
      LKApi.latestRelease(),
    ]);
    return AppUpdateInfo(
      package: results[0] as PackageInfo,
      release: results[1] as LKRelease?,
    );
  }

  /// 每次冷启动只检查一次；网络异常和“已是最新”均保持静默。
  static Future<void> checkAtStartup(BuildContext context) async {
    if (_startupCheckStarted) return;
    _startupCheckStarted = true;
    try {
      final info = await check();
      if (!context.mounted || !info.hasNewVersion) return;
      await showResult(context, info, onlyWhenNewer: true);
    } catch (_) {
      // 启动检查不能干扰正常进入应用，用户仍可在设置中手动重试。
    }
  }

  static Future<void> showResult(
    BuildContext context,
    AppUpdateInfo info, {
    bool onlyWhenNewer = false,
  }) async {
    if (!context.mounted || onlyWhenNewer && !info.hasNewVersion) return;
    final release = info.release;
    if (release == null || info.latestVersion.isEmpty) {
      await showDialog<void>(
        animationStyle: AppMotion.style(context),
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('检查更新'),
          content: Text(
            '当前版本 ${info.currentLabel}\n\n'
            '暂未找到可用的 GitHub Release，请稍后重试。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好'),
            ),
          ],
        ),
      );
      return;
    }

    final notes = release.body.trim();
    final visibleNotes =
        notes.length > 500 ? '${notes.substring(0, 500)}…' : notes;
    await showDialog<void>(
      animationStyle: AppMotion.style(context),
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(info.hasNewVersion ? '发现新版本' : '已是最新版本'),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        actionsOverflowButtonSpacing: 6,
        content: info.hasNewVersion
            ? ConstrainedBox(
                key: const Key('update_dialog_content'),
                constraints: BoxConstraints(
                  maxHeight: math.min(
                    260,
                    MediaQuery.sizeOf(dialogContext).height * 0.30,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前版本 ${info.currentLabel}\n'
                      '最新版本 ${info.latestVersion}',
                    ),
                    if (visibleNotes.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Flexible(
                        fit: FlexFit.loose,
                        child: Scrollbar(
                          child: SingleChildScrollView(
                            key: const Key('release_notes_scroll'),
                            child: SelectionArea(child: Text(visibleNotes)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              )
            : Text('当前版本 ${info.currentLabel} 已是最新'),
        actions: [
          if (!info.hasNewVersion)
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好'),
            ),
          if (info.hasNewVersion)
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              runSpacing: 6,
              children: [
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('稍后'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    unawaited(openExternal(context, baiduDownloadUrl));
                  },
                  child: const Text('百度网盘'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    unawaited(openExternal(
                      context,
                      release.url.isEmpty ? releasesUrl : release.url,
                    ));
                  },
                  child: const Text('GitHub'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static Future<void> openExternal(BuildContext context, String url) async {
    try {
      final uri = Uri.parse(url);
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) {
        _showOpenError(context);
      }
    } catch (_) {
      if (context.mounted) _showOpenError(context);
    }
  }

  static void _showOpenError(BuildContext context) {
    showFloatingPrompt(context, '无法打开浏览器，请稍后重试');
  }
}
