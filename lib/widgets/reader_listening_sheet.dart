import 'package:flutter/material.dart';

import 'm3_controls.dart';

/// Listening controls stay reachable while voice settings scroll.
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
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92),
        child: ColoredBox(
          color: scheme.surface,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            ExcludeSemantics(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(children: [
                const AppSettingIcon(Icons.headphones_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('听书', style: theme.textTheme.titleMedium),
                      Text('退出阅读后仍会继续播放',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭朗读',
                  onPressed: onClose,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('listening-settings-scroll'),
                padding: EdgeInsets.fromLTRB(
                    16, 4, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
                child: content,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: .35)),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: controls,
              ),
            ),
          ]),
        ),
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
    final scheme = theme.colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 520 &&
          MediaQuery.textScalerOf(context).scale(14) <= 20;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final source in sources)
          SizedBox(
            width: wide ? (constraints.maxWidth - 16) / 3 : constraints.maxWidth,
            child: Semantics(
              selected: value == source.$1,
              button: true,
              child: Material(
                color: value == source.$1
                    ? scheme.secondaryContainer
                    : scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: value == source.$1
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: .35),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: ValueKey('listening-source-${source.$1}'),
                  onTap: !enabled ? null : () => onChanged(source.$1),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      AppSettingIcon(source.$4),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(source.$2, style: theme.textTheme.titleSmall),
                            const SizedBox(height: 2),
                            Text(source.$3,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      if (!wide) ...[
                        const SizedBox(width: 8),
                        Icon(
                          value == source.$1
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          color: value == source.$1
                              ? scheme.primary
                              : scheme.outline,
                          size: 20,
                        ),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ),
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
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: hasError ? colors.errorContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasError
              ? colors.error.withValues(alpha: .35)
              : colors.outlineVariant.withValues(alpha: .35),
        ),
      ),
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
              hasError ? Icons.error_outline_rounded : Icons.graphic_eq_rounded,
              size: 18,
              color: hasError ? colors.onErrorContainer : colors.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(status,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: hasError ? colors.onErrorContainer : colors.onSurface,
                    fontWeight: FontWeight.w600,
                  )),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Text(text ?? '从当前阅读位置开始朗读',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: colors.onSurface, height: 1.45)),
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
            backgroundColor: colors.surfaceContainerHighest,
          ),
        ),
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
        padding: const EdgeInsets.only(top: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSectionTitle(title),
            child,
          ],
        ),
      );
}

/// Rate control used by the reader listening sheet. Matches settings cards.
class ListeningRateControl extends StatelessWidget {
  const ListeningRateControl({
    super.key,
    required this.rate,
    required this.onChanged,
    this.onChangeEnd,
  });

  final double rate;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = rate.clamp(.5, 3).toDouble();
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const AppSettingIcon(Icons.speed_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text('语速', style: theme.textTheme.titleSmall),
              ),
              Text('${shown.toStringAsFixed(2)}×',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: scheme.primary)),
            ]),
            Slider(
              min: .5,
              max: 3,
              divisions: 25,
              value: shown,
              label: '${shown.toStringAsFixed(2)}×',
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ],
        ),
      ),
    );
  }
}
