import '../services/app_motion.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/reader_cache.dart';
import '../api/store.dart';
import '../services/app_cache.dart';
import '../services/app_update_service.dart';
import '../widgets/common.dart';
import 'feedback_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _readerCacheCount = 0;
  int? _cacheBytes;
  bool _clearingCache = false;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadCacheUsage();
  }

  Future<void> _loadCacheUsage() async {
    final values = await Future.wait<int>([
      ReaderContentCache.count(),
      YomiruAppCache.sizeBytes(),
    ]);
    if (!mounted) return;
    setState(() {
      _readerCacheCount = values[0];
      _cacheBytes = values[1];
    });
  }

  Future<void> _clearAllCaches() async {
    final confirmed = await showDialog<bool>(
      animationStyle: AppMotion.style(context),
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清除缓存'),
        content: Text(
          '将清除所有缓存图片、$_readerCacheCount 章正文和可重新获取的页面数据。'
          '不会影响登录状态、本机书架或阅读进度。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('清除')),
        ],
      ),
    );
    if (confirmed != true || !mounted || _clearingCache) return;
    setState(() => _clearingCache = true);
    try {
      await YomiruAppCache.clearAll();
      if (!mounted) return;
      await _loadCacheUsage();
      if (!mounted) return;
      showFloatingPrompt(context, '缓存已清除');
    } catch (e) {
      if (mounted) showLkError(context, '缓存清理失败：$e');
    } finally {
      if (mounted) {
        await _loadCacheUsage();
        if (mounted) setState(() => _clearingCache = false);
      }
    }
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final info = await YomiruUpdateService.check();
      if (!mounted) return;
      await YomiruUpdateService.showResult(context, info);
    } catch (e) {
      if (mounted) showLkError(context, e);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  String _formatCacheSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _settingsIcon(
    BuildContext context,
    IconData icon, {
    bool danger = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? scheme.error : scheme.primary;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 21, color: color),
    );
  }

  Widget _settingsGroup(BuildContext context, List<Widget> tiles) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final children = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      if (i > 0) {
        children.add(Divider(
          height: 1,
          indent: 70,
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ));
      }
      children.add(tiles[i]);
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      color: theme.cardTheme.color ?? scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.28),
        ),
      ),
      child: ListTileTheme(
        data: ListTileThemeData(
          tileColor: Colors.transparent,
          iconColor: scheme.onSurfaceVariant,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const RoundedRectangleBorder(),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Future<void> _showAbout() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      await showDialog<void>(
        animationStyle: AppMotion.style(context),
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('关于'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('使用 Flutter 开发的 轻之国度 第三方客户端'),
              const SizedBox(height: 8),
              Text('当前版本：${info.version}+${info.buildNumber}'),
              const SizedBox(height: 18),
              Text(
                '项目仓库',
                style: Theme.of(dialogContext).textTheme.labelLarge?.copyWith(
                      color:
                          Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 6),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () async {
                  Navigator.pop(dialogContext);
                  await YomiruUpdateService.openExternal(
                    context,
                    YomiruUpdateService.repositoryUrl,
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'github.com/hesitation-snow/yomiru',
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 18,
                        color: Theme.of(dialogContext).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = LKStore.themeMode.value;
    final modeLabel = switch (mode) {
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
      ThemeMode.system => '跟随系统',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        children: [
          _sectionTitle(context, '显示'),
          _settingsGroup(context, [
            ListTile(
              leading: _settingsIcon(context, Icons.dark_mode_outlined),
              title: const Text('主题模式'),
              subtitle: Text('当前：$modeLabel'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _darkMode(context),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.landscapeEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: _settingsIcon(context, Icons.screen_rotation),
                title: const Text('横屏适配'),
                subtitle: const Text('允许手机随屏幕旋转'),
                value: enabled,
                onChanged: LKStore.setLandscapeEnabled,
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.animationsEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary:
                    _settingsIcon(context, Icons.motion_photos_off_outlined),
                title: const Text('关闭动画'),
                subtitle: const Text('关闭页面和翻页动效'),
                value: !enabled,
                onChanged: (disabled) =>
                    LKStore.setAnimationsEnabled(!disabled),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionTitle(context, '浏览'),
          _settingsGroup(context, [
            ValueListenableBuilder<int>(
              valueListenable: LKStore.gridColumnCount,
              builder: (context, count, _) {
                final label =
                    count == 0 ? '自动（根据屏幕自适应）' : '每行 $count 本';
                return ListTile(
                  leading: _settingsIcon(context, Icons.grid_view_rounded),
                  title: const Text('网格列数'),
                  subtitle: Text('当前：$label'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showGridColumnsSheet(context),
                );
              },
            ),
            ValueListenableBuilder<CoverBlurMode>(
              valueListenable: LKStore.coverBlurMode,
              builder: (context, mode, _) {
                final modeLabel = switch (mode) {
                  CoverBlurMode.all => '全部书籍',
                  CoverBlurMode.brave => '勇者书籍',
                  CoverBlurMode.none => '关闭',
                };
                return ListTile(
                  leading: _settingsIcon(context, Icons.blur_on_rounded),
                  title: const Text('封面模糊'),
                  subtitle: Text('当前：$modeLabel'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _blurCoverMode(context),
                );
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.hideBraveBooks,
              builder: (context, enabled, _) => SwitchListTile(
                secondary:
                    _settingsIcon(context, Icons.visibility_off_outlined),
                title: const Text('隐藏勇者书籍'),
                value: enabled,
                onChanged: (v) => LKStore.setHideBraveBooks(v),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.dataSaverMode,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: _settingsIcon(context, Icons.data_saver_on_outlined),
                title: const Text('流量节省模式'),
                subtitle: const Text('图片按需加载'),
                value: enabled,
                onChanged: (v) => LKStore.setDataSaverMode(v),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionTitle(context, '应用'),
          _settingsGroup(context, [
            ListTile(
              leading: _settingsIcon(context, Icons.offline_bolt_outlined),
              title: const Text('清除缓存'),
              subtitle: Text(_cacheBytes == null
                  ? '正在计算缓存占用…'
                  : '缓存占用：${_formatCacheSize(_cacheBytes!)}'),
              trailing: _clearingCache
                  ? const SizedBox.square(
                      dimension: 22,
                      child: MotionProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right_rounded),
              onTap: _clearingCache ? null : _clearAllCaches,
            ),
            ListTile(
              leading: _settingsIcon(context, Icons.system_update_outlined),
              title: const Text('检查更新'),
              trailing: _checkingUpdate
                  ? const SizedBox.square(
                      dimension: 22,
                      child: MotionProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right_rounded),
              onTap: _checkingUpdate ? null : _checkForUpdate,
            ),
            ListTile(
              leading: _settingsIcon(context, Icons.feedback_outlined),
              title: const Text('反馈问题'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                final sent = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute<bool>(
                    builder: (_) => const FeedbackPage(),
                  ),
                );
                if (sent == true && context.mounted) {
                  showLkError(context, '反馈已发送，谢谢你的反馈');
                }
              },
            ),
          ]),
          const SizedBox(height: 20),
          _sectionTitle(context, '账号与信息'),
          _settingsGroup(context, [
            if (LKClient.shared.session.isLoggedIn)
              ListTile(
                leading: _settingsIcon(
                  context,
                  Icons.logout_rounded,
                  danger: true,
                ),
                title: Text(
                  '退出登录',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () async {
                  final allDevices = await showLogoutScopeDialog(context);
                  if (allDevices == null) return;
                  try {
                    await LKApi.logout(allDevices: allDevices);
                  } catch (_) {
                    if (context.mounted) {
                      showLkError(context, '未能退出所有设备，请重试或选择“仅退出本机”');
                    }
                    return;
                  }
                  if (LKClient.shared.session.isLoggedIn) return;
                  await LKStore.clear();
                  if (!context.mounted) return;
                  showLkError(context, allDevices ? '已退出所有设备' : '已退出本机');
                  Navigator.pop(context);
                },
              ),
            ListTile(
              leading: _settingsIcon(context, Icons.info_outline_rounded),
              title: const Text('关于'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _showAbout,
            ),
          ]),
        ],
      ),
    );
  }

  void _darkMode(BuildContext context) {
    showModalBottomSheet<void>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('主题模式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            for (final (label, value) in [
              ('跟随系统', ThemeMode.system),
              ('浅色', ThemeMode.light),
              ('深色', ThemeMode.dark),
            ])
              ListTile(
                title: Text(label),
                trailing: LKStore.themeMode.value == value
                    ? Icon(Icons.check_circle_rounded,
                        color: Theme.of(context).colorScheme.primary)
                    : const Icon(Icons.circle_outlined, color: Colors.grey),
                onTap: () {
                  LKStore.setThemeMode(value);
                  Navigator.pop(sheetCtx);
                },
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  void _blurCoverMode(BuildContext context) {
    showModalBottomSheet<void>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('封面模糊',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            for (final (label, value) in [
              ('全部书籍', CoverBlurMode.all),
              ('勇者书籍', CoverBlurMode.brave),
              ('关闭', CoverBlurMode.none),
            ])
              ListTile(
                title: Text(label),
                trailing: LKStore.coverBlurMode.value == value
                    ? Icon(Icons.check_circle_rounded,
                        color: Theme.of(context).colorScheme.primary)
                    : const Icon(Icons.circle_outlined, color: Colors.grey),
                onTap: () {
                  LKStore.setCoverBlurMode(value);
                  Navigator.pop(sheetCtx);
                },
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }
}
