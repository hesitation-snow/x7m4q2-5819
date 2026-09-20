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
          tileColor: Colors.transparent,
          iconColor: scheme.onSurfaceVariant,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          shape: const RoundedRectangleBorder(),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
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
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              '书籍与导出',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _settingsGroup(context, [
            ValueListenableBuilder<bool>(
              valueListenable: LKStore.epubDownloadEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: _settingsIcon(
                  context,
                  Icons.download_for_offline_outlined,
                ),
                title: const Text('EPUB 下载'),
                subtitle: const Text(
                  '开启后，在书籍详情页菜单中提供「制作 EPUB」功能，支持选择单卷、多卷或全书导出为符合标准的 EPUB 3 电子书。',
                ),
                isThreeLine: true,
                value: enabled,
                onChanged: (v) => LKStore.setEpubDownloadEnabled(v),
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
                      '实验性功能可能随版本更新持续调整。导出的 EPUB 文件仅供个人学习与离线阅读使用，严禁用于商业传播。',
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
