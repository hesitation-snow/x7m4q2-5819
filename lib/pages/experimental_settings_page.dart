import 'package:flutter/material.dart';

import '../api/store.dart';

class ExperimentalSettingsPage extends StatelessWidget {
  const ExperimentalSettingsPage({super.key});

  Widget _settingsIcon(
    BuildContext context,
    IconData icon, {
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveColor = color ?? scheme.primary;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 21, color: effectiveColor),
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
          titleAlignment: ListTileTitleAlignment.center,
          tileColor: Colors.transparent,
          iconColor: scheme.onSurfaceVariant,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const RoundedRectangleBorder(),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Future<void> _handleBookExportToggle(BuildContext context, bool enable) async {
    if (!enable) {
      await LKStore.setEpubDownloadEnabled(false);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('使用须知'),
        content: const Text(
          '作品版权归原作者或相应权利人所有。请遵守站点规则及作品授权要求，未经许可，请勿上传、分享、售卖或用于其他商业用途。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await LKStore.setEpubDownloadEnabled(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('实验性功能')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        children: [
          _settingsGroup(context, [
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.epubDownloadEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: _settingsIcon(
                  context,
                  Icons.download_for_offline_outlined,
                ),
                title: const Text('书籍导出'),
                subtitle: const Text(
                  '在书籍详情页支持导出为 EPUB 或 TXT',
                ),
                value: enabled,
                onChanged: (v) => _handleBookExportToggle(context, v),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.enhancedContentStyleEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: _settingsIcon(
                  context,
                  Icons.format_paint_outlined,
                ),
                title: const Text('正文样式增强'),
                subtitle: const Text(
                  '保留正文的标题、强调与注释样式',
                ),
                value: enabled,
                onChanged: (v) => LKStore.setEnhancedContentStyleEnabled(v),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Card(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.2),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '实验性功能可能随版本更新持续调整。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
