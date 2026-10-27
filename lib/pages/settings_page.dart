import 'dart:async';
import 'laboratory_page.dart';
import 'network_diagnostic_page.dart';

import '../widgets/m3_menu_sheet.dart';
import '../widgets/m3_controls.dart';
import '../widgets/app_theme_color_picker.dart';
import '../services/app_motion.dart';
import '../widgets/dynamic_feed_source_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/reader_cache.dart';
import '../api/store.dart';
import '../services/app_cache.dart';
import '../services/app_update_service.dart';
import '../widgets/common.dart';
import 'feedback_options_sheet.dart';

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
  Timer? _aboutPressTimer;
  bool _aboutLongPressTriggered = false;
  int? _aboutPointer;
  Offset? _aboutPointerStart;
  bool _checkingBrave = false;

  @override
  void initState() {
    super.initState();
    LKClient.sessionRev.addListener(_onSessionRev);
    _loadCacheUsage();
  }

  @override
  void dispose() {
    _aboutPressTimer?.cancel();
    LKClient.sessionRev.removeListener(_onSessionRev);
    super.dispose();
  }

  void _onSessionRev() {
    if (mounted) setState(() {});
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

  Future<void> _handleBookExportToggle(bool enable) async {
    if (!enable) {
      await LKStore.setEpubDownloadEnabled(false);
      return;
    }
    if (!LKClient.shared.session.isLoggedIn) return;
    final uid = LKClient.shared.session.uid;
    final key = LKClient.shared.session.securityKey;
    final revision = LKClient.sessionRev.value;
    final confirmed = await showDialog<bool>(
      animationStyle: AppMotion.style(context),
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('使用须知'),
        content: const Text(
          '作品版权归原作者或相关权利人。导出文件请仅用于个人离线阅读，并遵守作品授权与站点规则；未经许可，请勿公开上传、传播、售卖或商用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        mounted &&
        LKClient.shared.session.isLoggedIn &&
        LKClient.shared.session.uid == uid &&
        LKClient.shared.session.securityKey == key &&
        LKClient.sessionRev.value == revision) {
      await LKStore.setEpubDownloadEnabled(true);
    }
  }

  Widget _sectionTitle(BuildContext context, String title) =>
      AppSectionTitle(title);

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

  Widget _settingsIcon(BuildContext context, IconData icon,
          {bool danger = false}) =>
      AppSettingIcon(icon, danger: danger);

  Widget _settingsGroup(BuildContext context, List<Widget> tiles) =>
      AppSettingsGroup(children: tiles);

  Future<void> _showAbout() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      await showDialog<void>(
        animationStyle: AppMotion.style(context),
        context: context,
        builder: (dialogContext) {
          final scheme = Theme.of(dialogContext).colorScheme;
          return AlertDialog(
            title: const Text('关于'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('使用 Flutter 开发的轻之国度第三方客户端'),
                  const SizedBox(height: 8),
                  Text('当前版本：${info.version}+${info.buildNumber}'),
                  const SizedBox(height: 18),
                  Text(
                    '项目仓库',
                    style:
                        Theme.of(dialogContext).textTheme.labelLarge?.copyWith(
                              color: scheme.onSurfaceVariant,
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
                                color: scheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.open_in_new_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Telegram',
                    style:
                        Theme.of(dialogContext).textTheme.labelLarge?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                  ),
                  const SizedBox(height: 6),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () async {
                      Navigator.pop(dialogContext);
                      await YomiruUpdateService.openExternal(
                        context,
                        'https://t.me/FurippuFurappazu',
                      );
                    },
                    onLongPress: () async {
                      await Clipboard.setData(
                        const ClipboardData(
                            text: 'https://t.me/FurippuFurappazu'),
                      );
                      if (mounted) {
                        showFloatingPrompt(context, '已复制 Telegram 链接');
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              't.me/FurippuFurappazu',
                              style: TextStyle(
                                color: scheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.open_in_new_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('好'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  Widget _aboutDisclaimerItem(
      BuildContext context, int index, String title, String content) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$index. $title',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            content,
            style: TextStyle(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
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
              valueListenable: LKStore.pureBlackDark,
              builder: (context, pureBlack, _) => SwitchListTile(
                secondary:
                    _settingsIcon(context, Icons.nightlight_round_outlined),
                title: const Text('深色模式使用纯黑主题'),
                value: pureBlack,
                onChanged: LKStore.setPureBlackDark,
              ),
            ),
            ValueListenableBuilder<int?>(
              valueListenable: LKStore.themeSeedColor,
              builder: (context, seed, _) {
                final presetName = seed == null
                    ? '默认紫'
                    : kAppThemeColorPresets
                            .where((p) => p.$2.toARGB32() == seed)
                            .firstOrNull
                            ?.$1 ??
                        '自定义 #${seed.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      leading: _settingsIcon(context, Icons.colorize_rounded),
                      title: const Text('主题配色'),
                      subtitle: Text('当前：$presetName'),
                      trailing: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: AppThemeColorSection(),
                    ),
                  ],
                );
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.liquidGlassBottomBarEnabled,
              builder: (context, enabled, _) => ListTile(
                key: const ValueKey('settings-liquid-glass-tile'),
                leading: _settingsIcon(context, Icons.blur_on_rounded),
                title: const Text('液态玻璃底栏 (测试)'),
                subtitle: const Text('点击调整详细设置与实时预览'),
                trailing: Switch(
                  key: const ValueKey('settings-liquid-glass-switch'),
                  value: enabled,
                  onChanged: LKStore.setLiquidGlassBottomBarEnabled,
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const LiquidGlassLabPage(),
                  ),
                ),
              ),
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
            DynamicFeedSourceSwitch(
              secondary: _settingsIcon(context, Icons.dynamic_feed_outlined),
            ),
            ValueListenableBuilder<int>(
              valueListenable: LKStore.gridColumnCount,
              builder: (context, count, _) {
                final label = count == 0 ? '自动' : '每行 $count 本';
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
                subtitle: const Text('在列表与搜索中隐藏勇者作品'),
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
          _sectionTitle(context, '阅读'),
          _settingsGroup(context, [
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.enhancedContentStyleEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: _settingsIcon(context, Icons.format_paint_outlined),
                title: const Text('原文格式'),
                subtitle: const Text('如原文支持，显示文字样式'),
                value: enabled,
                onChanged: LKStore.setEnhancedContentStyleEnabled,
              ),
            ),
            if (LKClient.shared.session.isLoggedIn)
              ValueListenableBuilder<bool>(
                valueListenable: LKStore.epubDownloadEnabled,
                builder: (context, enabled, _) => SwitchListTile(
                  secondary: _settingsIcon(
                      context, Icons.download_for_offline_outlined),
                  title: const Text('书籍导出'),
                  subtitle: const Text('在书籍详情页导出 EPUB 或 TXT'),
                  value: enabled,
                  onChanged: _handleBookExportToggle,
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
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.autoCheckUpdateEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: _settingsIcon(context, Icons.update_outlined),
                title: const Text('自动检查更新'),
                subtitle: const Text('启动时自动检测新版本'),
                value: enabled,
                onChanged: LKStore.setAutoCheckUpdateEnabled,
              ),
            ),
            ListTile(
              leading: _settingsIcon(context, Icons.network_check_rounded),
              title: const Text('网络连接诊断'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const NetworkDiagnosticPage()),
              ),
            ),
            ListTile(
              leading: _settingsIcon(context, Icons.feedback_outlined),
              title: const Text('反馈问题'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showFeedbackOptions(context),
            ),
          ]),
          const SizedBox(height: 20),
          _sectionTitle(context, '账号与信息'),
          _settingsGroup(context, [
            Listener(
              onPointerDown: (event) {
                if (_aboutPointer != null) return;
                _aboutPointer = event.pointer;
                _aboutPointerStart = event.position;
                _aboutLongPressTriggered = false;
                _aboutPressTimer = Timer(const Duration(seconds: 1), () {
                  _aboutPressTimer = null;
                  _aboutLongPressTriggered = true;
                  unawaited(_handleAboutLongPress());
                });
              },
              onPointerMove: (event) {
                if (event.pointer == _aboutPointer &&
                    _aboutPointerStart != null &&
                    (event.position - _aboutPointerStart!).distance >
                        kTouchSlop) {
                  _cancelAboutPress();
                }
              },
              onPointerUp: (event) {
                if (event.pointer == _aboutPointer) _cancelAboutPress();
              },
              onPointerCancel: (event) {
                if (event.pointer == _aboutPointer) _cancelAboutPress();
              },
              child: ListTile(
                leading: _settingsIcon(context, Icons.info_outline_rounded),
                title: const Text('关于'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  if (_aboutLongPressTriggered) {
                    _aboutLongPressTriggered = false;
                    return;
                  }
                  _showAbout();
                },
              ),
            ),
            Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                expandedAlignment: Alignment.centerLeft,
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                leading: _settingsIcon(context, Icons.shield_outlined),
                title: const Text('免责声明'),
                children: [
                  _aboutDisclaimerItem(
                    context,
                    1,
                    '非官方声明',
                    'Yomiru 是一款非官方的轻之国度（LK）第三方客户端，与轻之国度（LK / 魔王轻文学社区）平台及其运营方无任何关联。',
                  ),
                  const SizedBox(height: 10),
                  _aboutDisclaimerItem(
                    context,
                    2,
                    '非商业用途',
                    '本程序完全出于个人兴趣爱好开发，旨在优化移动端阅读体验，仅供学习交流使用，严禁用于任何商业用途或营利行为。',
                  ),
                  const SizedBox(height: 10),
                  _aboutDisclaimerItem(
                    context,
                    3,
                    '数据与网络',
                    '应用会在设备上保存登录会话、本机书架和部分阅读数据；登录后也可使用平台的云书架与阅读历史。平台接口、图片资源和更新检查可能访问不同的网络服务，请以实际功能和服务提供方的说明为准。',
                  ),
                  const SizedBox(height: 10),
                  _aboutDisclaimerItem(
                    context,
                    4,
                    '版权与内容归属',
                    '本程序展示的小说原作、译文、插图、社区动态及评论等内容，其权利归相应作者、译者、投稿用户或其他权利人所有；轻之国度平台依据其与相关权利人的约定提供内容发布、存储或展示服务。本程序仅作为第三方客户端提供内容访问与呈现功能，相关内容的权利归属以权利人及平台的实际授权关系为准。',
                  ),
                  const SizedBox(height: 10),
                  _aboutDisclaimerItem(
                    context,
                    5,
                    '账号安全',
                    '本程序基于公开网络接口实现。请严格遵守轻之国度社区公约及相关法律法规。因违规使用或滥用接口导致账号受限、封禁或其他损失，均由使用者自行承担，开发者概不负责。',
                  ),
                  const SizedBox(height: 10),
                  _aboutDisclaimerItem(
                    context,
                    6,
                    '官方协议准则',
                    '使用本程序同时须遵守轻之国度官方的《用户协议》与《隐私政策》。',
                  ),
                  const SizedBox(height: 10),
                  _aboutDisclaimerItem(
                    context,
                    7,
                    '声明认可',
                    '使用本应用程序即表示您已充分阅读、理解并同意本免责声明的全部内容。如有任何疑问或意见，请联系开发者。',
                  ),
                ],
              ),
            ),
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
                  if (!context.mounted) return;
                  showLkError(context, allDevices ? '已退出所有设备' : '已退出本机');
                  Navigator.pop(context);
                },
              ),
          ]),
        ],
      ),
    );
  }

  void _cancelAboutPress() {
    _aboutPressTimer?.cancel();
    _aboutPressTimer = null;
    _aboutPointer = null;
    _aboutPointerStart = null;
  }

  Future<void> _handleAboutLongPress() async {
    final session = LKClient.shared.session;
    if (_checkingBrave || !session.isLoggedIn || session.uid <= 0) return;
    final uid = session.uid;
    final key = session.securityKey;
    final revision = LKClient.sessionRev.value;
    _checkingBrave = true;
    try {
      final profile = await LKStore.cachedMyProfile(uid);
      if (!mounted ||
          !session.isLoggedIn ||
          session.uid != uid ||
          session.securityKey != key ||
          LKClient.sessionRev.value != revision) {
        return;
      }
      if (profile == null) {
        showFloatingPrompt(context, '个人资料尚未加载，请先打开“我的”页面');
        return;
      }
      if (profile.uid != uid || !profile.isBrave) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const LaboratoryPage(),
      ));
    } catch (_) {
      if (mounted &&
          session.isLoggedIn &&
          session.uid == uid &&
          session.securityKey == key &&
          LKClient.sessionRev.value == revision) {
        showFloatingPrompt(context, '个人资料尚未加载，请先打开“我的”页面');
      }
    } finally {
      _checkingBrave = false;
    }
  }

  void _darkMode(BuildContext context) {
    showModalBottomSheet<void>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => M3MenuSheet(
        title: '主题模式',
        icon: Icons.palette_outlined,
        children: [
          for (final (label, value, icon) in [
            ('跟随系统', ThemeMode.system, Icons.brightness_auto_outlined),
            ('浅色模式', ThemeMode.light, Icons.light_mode_outlined),
            ('深色模式', ThemeMode.dark, Icons.dark_mode_outlined),
          ])
            M3OptionTile(
              title: label,
              icon: icon,
              selected: LKStore.themeMode.value == value,
              onTap: () {
                LKStore.setThemeMode(value);
                Navigator.pop(sheetCtx);
              },
            ),
        ],
      ),
    );
  }

  void _blurCoverMode(BuildContext context) {
    showModalBottomSheet<void>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => M3MenuSheet(
        title: '封面模糊',
        icon: Icons.blur_on_rounded,
        children: [
          for (final (label, sub, value, icon) in [
            (
              '全部书籍',
              '所有小说的封面均进行模糊处理',
              CoverBlurMode.all,
              Icons.blur_on_rounded
            ),
            (
              '勇者书籍',
              '仅模糊勇者书籍封面',
              CoverBlurMode.brave,
              Icons.visibility_off_outlined
            ),
            ('关闭', '展示原始小说封面', CoverBlurMode.none, Icons.blur_off_rounded),
          ])
            M3OptionTile(
              title: label,
              subtitle: sub,
              icon: icon,
              selected: LKStore.coverBlurMode.value == value,
              onTap: () {
                LKStore.setCoverBlurMode(value);
                Navigator.pop(sheetCtx);
              },
            ),
        ],
      ),
    );
  }
}
