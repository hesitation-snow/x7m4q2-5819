import 'package:flutter/material.dart';

/// Listening controls stay reachable while voice/settings content scrolls.
class ReaderListeningSheet extends StatelessWidget {
  const ReaderListeningSheet(
      {super.key,
      required this.content,
      required this.controls,
      required this.onClose});
  final Widget content;
  final Widget controls;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          ExcludeSemantics(
              child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(4)))),
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
              child: Row(children: [
                Icon(Icons.headphones_rounded,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                    child: Text('听书与音色', style: theme.textTheme.titleLarge)),
                IconButton(
                    tooltip: '关闭朗读',
                    onPressed: onClose,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded)),
              ])),
          Flexible(
              child: SingleChildScrollView(
                  key: const ValueKey('listening-settings-scroll'),
                  padding: EdgeInsets.fromLTRB(
                      16, 4, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
                  child: content)),
          DecoratedBox(
              decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  border: Border(
                      top: BorderSide(
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: .5)))),
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: controls)),
        ]),
      ),
    );
  }
}

class ListeningSourcePicker extends StatelessWidget {
  const ListeningSourcePicker(
      {super.key,
      required this.value,
      required this.onChanged,
      this.enabled = true});
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    const sources = [
      ('online', '在线自然音', '免密钥，中日韩自动换音色', Icons.cloud_outlined),
      ('system', '系统引擎', '使用手机已安装的语音', Icons.phone_android_rounded),
      ('custom', '自定义', 'Azure 或自己的 SSML 服务', Icons.tune_rounded),
    ];
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 520 &&
          MediaQuery.textScalerOf(context).scale(14) <= 20;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final source in sources)
          SizedBox(
              width:
                  wide ? (constraints.maxWidth - 16) / 3 : constraints.maxWidth,
              child: Semantics(
                  selected: value == source.$1,
                  button: true,
                  child: Material(
                    color: value == source.$1
                        ? theme.colorScheme.secondaryContainer
                        : theme.colorScheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                            color: value == source.$1
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outlineVariant)),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                        key: ValueKey('listening-source-${source.$1}'),
                        onTap: !enabled ? null : () => onChanged(source.$1),
                        child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(children: [
                              Icon(source.$4,
                                  color: value == source.$1
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                  size: 22),
                              const SizedBox(width: 10),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(source.$2,
                                        style: theme.textTheme.titleSmall),
                                    const SizedBox(height: 2),
                                    Text(source.$3,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                                color: theme.colorScheme
                                                    .onSurfaceVariant)),
                                  ])),
                              if (!wide) ...[
                                const SizedBox(width: 8),
                                Icon(
                                    value == source.$1
                                        ? Icons.radio_button_checked_rounded
                                        : Icons.radio_button_off_rounded,
                                    color: value == source.$1
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.outline,
                                    size: 20),
                              ],
                            ]))),
                  ))),
      ]);
    });
  }
}

class ListeningPlaybackCard extends StatelessWidget {
  const ListeningPlaybackCard(
      {super.key,
      required this.title,
      required this.status,
      required this.position,
      required this.segmentCount,
      this.text,
      this.loading = false,
      this.hasError = false});
  final String title;
  final String status;
  final int position;
  final int segmentCount;
  final String? text;
  final bool loading;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('listening-now-playing'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: hasError
              ? colors.errorContainer
              : colors.primaryContainer.withValues(alpha: .45),
          borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Semantics(
            liveRegion: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                  hasError
                      ? Icons.error_outline_rounded
                      : Icons.graphic_eq_rounded,
                  size: 18,
                  color: hasError ? colors.onErrorContainer : colors.primary),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: hasError
                              ? colors.onErrorContainer
                              : colors.onSurface,
                          fontWeight: FontWeight.w600))),
            ])),
        const SizedBox(height: 12),
        Text(text ?? '从当前阅读位置开始朗读',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.55)),
        if (!loading && status.startsWith('已暂停')) ...[
          const SizedBox(height: 8),
          Text('暂停后从当前语段开头恢复',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant)),
        ],
        const SizedBox(height: 14),
        ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
                minHeight: 4,
                value: loading
                    ? null
                    : segmentCount == 0
                        ? 0
                        : ((position + 1) / segmentCount).clamp(0, 1),
                semanticsLabel: loading ? '正在准备语音' : '语段进度',
                backgroundColor: colors.surfaceContainerHighest)),
      ]),
    );
  }
}

class ListeningSection extends StatelessWidget {
  const ListeningSection({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant))),
          child,
        ]),
      );
}
